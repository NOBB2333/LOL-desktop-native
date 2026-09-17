const std = @import("std");
const builtin = @import("builtin");
const RequestControl = @import("lcu").RequestControl;

const vk_return: u16 = 0x0d;
const keyeventf_keyup: u32 = 0x0002;
const keyeventf_unicode: u32 = 0x0004;
const input_keyboard: u32 = 1;
const max_text_utf16_units: usize = 2048;
/// 多条消息之间的间隔。数值与 LeagueAkari 的 `in-game-send` 对齐：
/// 默认 65ms、下限也取 65ms，上限 3500ms（AK `state.ts` 的 `sendInterval`
/// 与 `InGameSend.vue` 的 `:min/:max`）。
const min_message_interval_ms: i64 = 65;
const max_message_interval_ms: i64 = 3500;
/// 单条消息内部的固定停顿：回车开聊天框后、整行文字注入后，各等这么久。
/// 对齐 AK 的 `IN_GAME_SEND_ENTER_KEY_INTERNAL_DELAY = 20`——AK 的每行节奏是
/// 「回车 → 20 → 打字 → 20 → 回车」，我们原来在这里各等 100 / 80，所以每行比
/// AK 多花约 160ms，发十条就能感觉出「有点延迟」。
const send_step_delay_ms: i64 = 20;

var send_mutex: std.atomic.Mutex = .unlocked;

/// 一批消息串行发送；每条消息整行注入，只有游戏窗口处于前台时才允许输入。
///
/// 这里刻意**不**做全局输入屏蔽。曾经的 `BlockInput(1)` 会在打字期间锁住整个
/// 系统的鼠标和键盘（光标完全无法移动），换来的收益却只是「防误触」。LeagueAkari
/// 的 `in-game-send/send-executor.ts` 从不拦截输入：它只确认游戏窗口在前台，然后
/// 回车 → 输入整行 → 回车。对齐它既恢复了鼠标可用性，也顺带去掉了管理员权限要求。
pub fn sendChatLines(io: std.Io, lines: std.json.Value, interval_ms: i64, control: RequestControl) !void {
    try control.check();
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    if (lines != .array or lines.array.items.len == 0) return error.NoMessages;

    if (!send_mutex.tryLock()) return error.SendInProgress;
    defer send_mutex.unlock();

    var valid_line_count: usize = 0;
    for (lines.array.items) |line| {
        if (line == .string and std.mem.trim(u8, line.string, " \t\r\n").len > 0) valid_line_count += 1;
    }
    if (valid_line_count == 0) return error.NoMessages;

    // 在打开聊天框之前检查整批文本，避免发送到一半才发现无效字符。
    for (lines.array.items) |line| if (line == .string and std.mem.trim(u8, line.string, " \t\r\n").len > 0) {
        var utf16: [max_text_utf16_units]u16 = undefined;
        _ = try messageUnits(line.string, &utf16);
    };
    try prepareGameForeground(io);

    const delay_ms = configuredMessageInterval(interval_ms);
    var sent_count: usize = 0;
    for (lines.array.items) |line| {
        if (line != .string or std.mem.trim(u8, line.string, " \t\r\n").len == 0) continue;
        sendChatLine(io, line.string, control) catch |err| return if (sent_count > 0) error.ChatSendPartiallyCompleted else err;
        sent_count += 1;
        if (sent_count < valid_line_count) {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(delay_ms), .awake) catch {};
        }
    }
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(150), .awake) catch {};
}

fn sendChatLine(io: std.Io, text: []const u8, control: RequestControl) !void {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    try ensureLeagueGameForeground();
    // 快捷键修饰键尚未松开时，回车可能切换聊天频道，必须先等待释放。
    try waitForModifiers(io);
    try control.check();
    try ensureLeagueGameForeground();
    try pressVirtualKey(io, vk_return);
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(send_step_delay_ms), .awake) catch {};
    // 失败时不补发回车，防止提交残缺文本或向切换后的窗口输入。
    try sendOpenChatLine(io, text, control);
}

fn waitForModifiers(io: std.Io) !void {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    for (0..100) |_| {
        var held = false;
        for ([_]i32{ 0x10, 0x11, 0x12, 0x5b, 0x5c }) |key| {
            if (windows.GetAsyncKeyState(key) < 0) held = true;
        }
        if (!held) return;
        try ensureLeagueGameForeground();
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    }
    return error.ModifierKeyHeld;
}

fn configuredMessageInterval(interval_ms: i64) i64 {
    return std.math.clamp(interval_ms, min_message_interval_ms, max_message_interval_ms);
}

fn sendOpenChatLine(io: std.Io, text: []const u8, control: RequestControl) !void {
    try control.check();
    try ensureLeagueGameForeground();
    try sendUnicodeText(io, text);
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(send_step_delay_ms), .awake) catch {};
    try control.check();
    try ensureLeagueGameForeground();
    try pressVirtualKey(io, vk_return);
}

fn ensureLeagueGameForeground() !void {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const window = windows.GetForegroundWindow() orelse return error.GameWindowNotForeground;
    if (!isLeagueGameWindow(window)) return error.GameWindowNotForeground;
}

fn isLeagueGameWindow(window: *anyopaque) bool {
    if (builtin.os.tag != .windows) return false;
    var process_id: u32 = 0;
    _ = windows.GetWindowThreadProcessId(window, &process_id);
    if (process_id == 0) return false;
    const process = windows.OpenProcess(windows.process_query_limited_information, 0, process_id) orelse return false;
    defer _ = windows.CloseHandle(process);

    var path: [32768]u16 = undefined;
    var path_len: u32 = path.len;
    if (windows.QueryFullProcessImageNameW(process, 0, &path, &path_len) == 0 or path_len == 0) return false;
    return isLeagueGamePath(path[0..path_len]);
}

fn prepareGameForeground(io: std.Io) !void {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const foreground = windows.GetForegroundWindow() orelse return error.GameWindowNotForeground;
    if (isLeagueGameWindow(foreground)) return;
    var process_id: u32 = 0;
    _ = windows.GetWindowThreadProcessId(foreground, &process_id);
    // 从辅助窗口点击发送时切回游戏；用户已经切到其他程序时不争抢焦点。
    if (process_id != windows.GetCurrentProcessId()) return error.GameWindowNotForeground;
    var game: ?*anyopaque = null;
    _ = windows.EnumWindows(findGameWindow, @bitCast(@intFromPtr(&game)));
    const target = game orelse return error.GameWindowNotForeground;
    if (windows.IsIconic(target) != 0) _ = windows.ShowWindow(target, 9);
    if (windows.SetForegroundWindow(target) == 0) return error.GameWindowNotForeground;
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .awake) catch {};
    try ensureLeagueGameForeground();
}

fn findGameWindow(window: *anyopaque, data: isize) callconv(.winapi) i32 {
    if (builtin.os.tag != .windows) return 0;
    if (windows.IsWindowVisible(window) == 0 or !isLeagueGameWindow(window)) return 1;
    const result: *?*anyopaque = @ptrFromInt(@as(usize, @bitCast(data)));
    result.* = window;
    return 0;
}

fn isLeagueGamePath(path: []const u16) bool {
    const expected = "League of Legends.exe";
    var start = path.len;
    while (start > 0 and path[start - 1] != '\\' and path[start - 1] != '/') start -= 1;
    const name = path[start..];
    if (name.len != expected.len) return false;
    for (name, expected) |actual, wanted| {
        if (actual > 0x7f or std.ascii.toLower(@as(u8, @intCast(actual))) != std.ascii.toLower(wanted)) return false;
    }
    return true;
}

fn pressVirtualKey(io: std.Io, key: u16) !void {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const scan: u16 = @truncate(windows.MapVirtualKeyW(key, windows.mapvk_vk_to_vsc));
    var down = keyboardInput(key, scan, 0);
    var up = keyboardInput(key, scan, keyeventf_keyup);
    var released = false;
    // 保留回车按压间隔；途中失去焦点时也释放按键，避免留下按住状态。
    defer if (!released) {
        _ = windows.SendInput(1, (&up)[0..1].ptr, @sizeOf(windows.Input));
    };
    try sendInputs(io, (&down)[0..1]);
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .awake) catch {};
    try sendInputs(io, (&up)[0..1]);
    released = true;
}

fn sendUnicodeText(io: std.Io, text: []const u8) !void {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    var utf16: [max_text_utf16_units]u16 = undefined;
    const length = try messageUnits(text, &utf16);
    const inputs = try std.heap.page_allocator.alloc(windows.Input, length * 2);
    defer std.heap.page_allocator.free(inputs);
    const input_count = unicodeInputsForUnits(utf16[0..length], inputs);
    // 同一次 SendInput 内的整行事件不会与其他输入交错，也不会拆开代理项。
    try sendInputs(io, inputs[0..input_count]);
}

fn messageUnits(text: []const u8, output: []u16) !usize {
    for (text) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidMessage;
    return std.unicode.utf8ToUtf16Le(output, text) catch return error.InvalidMessage;
}

fn unicodeInputsForUnits(units: []const u16, output: []windows.Input) usize {
    std.debug.assert(output.len >= units.len * 2);
    for (units, 0..) |unit, index| {
        output[index * 2] = keyboardInput(0, unit, keyeventf_unicode);
        output[index * 2 + 1] = keyboardInput(0, unit, keyeventf_unicode | keyeventf_keyup);
    }
    return units.len * 2;
}

fn keyboardInput(key: u16, scan: u16, flags: u32) windows.Input {
    return .{
        .input_type = input_keyboard,
        .data = .{ .keyboard = .{
            .virtual_key = key,
            .scan_code = scan,
            .flags = flags,
            .time = 0,
            .extra_info = 0,
        } },
    };
}

fn sendInputs(io: std.Io, inputs: []const windows.Input) !void {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    if (inputs.len == 0) return;
    var progress = InputProgress{};
    while (progress.sent < inputs.len) {
        try ensureLeagueGameForeground();
        const remaining = inputs[progress.sent..];
        const sent = windows.SendInput(@intCast(remaining.len), remaining.ptr, @sizeOf(windows.Input));
        try progress.advance(sent, inputs.len);
        if (progress.sent < inputs.len) std.Io.sleep(io, std.Io.Duration.fromMilliseconds(5), .awake) catch {};
    }
}

const InputProgress = struct {
    sent: usize = 0,
    stalled: usize = 0,
    attempts: usize = 0,

    fn advance(self: *InputProgress, count: usize, total: usize) !void {
        self.attempts += 1;
        if (self.attempts > 8) return error.InputSimulationFailed;
        if (count > total - self.sent) return error.InputSimulationFailed;
        if (count == 0) {
            self.stalled += 1;
            if (self.stalled >= 2) return error.InputSimulationFailed;
        } else {
            self.sent += count;
            self.stalled = 0;
        }
    }
};

const windows = if (builtin.os.tag == .windows) struct {
    const process_query_limited_information: u32 = 0x1000;
    const mapvk_vk_to_vsc: u32 = 0;

    const MouseInput = extern struct {
        dx: i32,
        dy: i32,
        mouse_data: u32,
        flags: u32,
        time: u32,
        extra_info: usize,
    };
    const KeyboardInput = extern struct {
        virtual_key: u16,
        scan_code: u16,
        flags: u32,
        time: u32,
        extra_info: usize,
    };
    const HardwareInput = extern struct { message: u32, param_low: u16, param_high: u16 };
    const InputData = extern union { mouse: MouseInput, keyboard: KeyboardInput, hardware: HardwareInput };
    const Input = extern struct { input_type: u32, data: InputData };

    extern "user32" fn GetForegroundWindow() callconv(.winapi) ?*anyopaque;
    extern "user32" fn SetForegroundWindow(window: *anyopaque) callconv(.winapi) i32;
    extern "user32" fn EnumWindows(callback: *const fn (*anyopaque, isize) callconv(.winapi) i32, data: isize) callconv(.winapi) i32;
    extern "user32" fn IsWindowVisible(window: *anyopaque) callconv(.winapi) i32;
    extern "user32" fn IsIconic(window: *anyopaque) callconv(.winapi) i32;
    extern "user32" fn ShowWindow(window: *anyopaque, command: i32) callconv(.winapi) i32;
    extern "user32" fn GetWindowThreadProcessId(window: *anyopaque, process_id: *u32) callconv(.winapi) u32;
    extern "user32" fn MapVirtualKeyW(code: u32, map_type: u32) callconv(.winapi) u32;
    extern "user32" fn SendInput(count: u32, inputs: [*]const Input, size: i32) callconv(.winapi) u32;
    extern "user32" fn GetAsyncKeyState(key: i32) callconv(.winapi) i16;
    extern "kernel32" fn OpenProcess(access: u32, inherit_handle: i32, process_id: u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
    extern "kernel32" fn QueryFullProcessImageNameW(process: *anyopaque, flags: u32, path: [*]u16, length: *u32) callconv(.winapi) i32;
    extern "kernel32" fn CloseHandle(handle: *anyopaque) callconv(.winapi) i32;
} else struct {
    const Input = struct {};
};

test "仅识别英雄联盟游戏进程" {
    const valid = [_]u16{ 'C', ':', '\\', 'G', 'a', 'm', 'e', '\\', 'L', 'e', 'a', 'g', 'u', 'e', ' ', 'o', 'f', ' ', 'L', 'e', 'g', 'e', 'n', 'd', 's', '.', 'e', 'x', 'e' };
    const invalid = [_]u16{ 'C', ':', '\\', 'L', 'e', 'a', 'g', 'u', 'e', 'C', 'l', 'i', 'e', 'n', 't', 'U', 'x', '.', 'e', 'x', 'e' };
    try std.testing.expect(isLeagueGamePath(&valid));
    try std.testing.expect(!isLeagueGamePath(&invalid));
}

test "输入结构体布局包含最大联合体成员" {
    if (builtin.os.tag == .windows) try std.testing.expectEqual(@as(usize, 40), @sizeOf(windows.Input));
}

test "每个文字编码单元生成完整按下和释放事件" {
    if (builtin.os.tag != .windows) return;
    const units = [_]u16{ 'A', 0x4e2d, 0xd83d, 0xde00 };
    var inputs: [units.len * 2]windows.Input = undefined;
    const count = unicodeInputsForUnits(&units, &inputs);
    try std.testing.expectEqual(units.len * 2, count);
    for (units, 0..) |unit, index| {
        const down = inputs[index * 2].data.keyboard;
        const up = inputs[index * 2 + 1].data.keyboard;
        try std.testing.expectEqual(@as(u16, 0), down.virtual_key);
        try std.testing.expectEqual(unit, down.scan_code);
        try std.testing.expectEqual(keyeventf_unicode, down.flags);
        try std.testing.expectEqual(@as(u16, 0), up.virtual_key);
        try std.testing.expectEqual(unit, up.scan_code);
        try std.testing.expectEqual(keyeventf_unicode | keyeventf_keyup, up.flags);
    }
}

test "部分输入重试只续发未完成的事件" {
    var progress = InputProgress{};
    try progress.advance(5, 12);
    try std.testing.expectEqual(@as(usize, 5), progress.sent);
    try progress.advance(0, 12);
    try std.testing.expectEqual(@as(usize, 5), progress.sent);
    try progress.advance(7, 12);
    try std.testing.expectEqual(@as(usize, 12), progress.sent);
    var stalled = InputProgress{};
    try stalled.advance(0, 2);
    try std.testing.expectError(error.InputSimulationFailed, stalled.advance(0, 2));
}

test "发送前拒绝控制字符并保留完整中文编码" {
    var units: [32]u16 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try messageUnits("测试消息", &units));
    try std.testing.expectError(error.InvalidMessage, messageUnits("消息\n另一行", &units));
    try std.testing.expectError(error.InvalidMessage, messageUnits("\x1b", &units));
}

test "消息间隔限制在允许范围内" {
    try std.testing.expectEqual(@as(i64, 65), configuredMessageInterval(1));
    try std.testing.expectEqual(@as(i64, 65), configuredMessageInterval(65));
    try std.testing.expectEqual(@as(i64, 1000), configuredMessageInterval(1000));
    try std.testing.expectEqual(@as(i64, 3500), configuredMessageInterval(9000));
}
