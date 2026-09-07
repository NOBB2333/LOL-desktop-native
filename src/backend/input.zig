const std = @import("std");
const builtin = @import("builtin");

const vk_return: u16 = 0x0d;
const keyeventf_keyup: u32 = 0x0002;
const keyeventf_unicode: u32 = 0x0004;
const input_keyboard: u32 = 1;
const text_chunk_utf16_units: usize = 8;
const min_message_interval_ms: i64 = 250;
const max_message_interval_ms: i64 = 5000;

var send_mutex: std.atomic.Mutex = .unlocked;

/// Send chat text without spawning PowerShell or modifying the clipboard.
/// Input is accepted only while the League game executable owns the
/// foreground window, matching the safety boundary used by the Rust host.
pub fn sendChatLines(io: std.Io, lines: std.json.Value, interval_ms: i64) !void {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    if (lines != .array or lines.array.items.len == 0) return error.NoMessages;

    if (!send_mutex.tryLock()) return error.SendInProgress;
    defer send_mutex.unlock();
    if (!try currentProcessIsElevated()) return error.AdministratorRequired;

    var valid_line_count: usize = 0;
    for (lines.array.items) |line| {
        if (line == .string and std.mem.trim(u8, line.string, " \t\r\n").len > 0) valid_line_count += 1;
    }
    if (valid_line_count == 0) return error.NoMessages;

    const delay_ms = configuredMessageInterval(interval_ms);
    var sent_count: usize = 0;
    for (lines.array.items) |line| {
        if (line != .string or std.mem.trim(u8, line.string, " \t\r\n").len == 0) continue;
        try ensureLeagueGameForeground();
        try pressVirtualKey(io, vk_return);
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .awake) catch {};
        sendOpenChatLine(io, line.string) catch |err| {
            pressVirtualKey(io, vk_return) catch {};
            return err;
        };
        sent_count += 1;
        if (sent_count < valid_line_count) {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(delay_ms), .awake) catch {};
        }
    }
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(150), .awake) catch {};
}

fn configuredMessageInterval(interval_ms: i64) i64 {
    return std.math.clamp(interval_ms, min_message_interval_ms, max_message_interval_ms);
}

fn sendOpenChatLine(io: std.Io, text: []const u8) !void {
    try ensureLeagueGameForeground();
    try sendUnicodeText(io, text);
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(80), .awake) catch {};
    try ensureLeagueGameForeground();
    try pressVirtualKey(io, vk_return);
}

fn ensureLeagueGameForeground() !void {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const window = windows.GetForegroundWindow() orelse return error.GameWindowNotForeground;
    var process_id: u32 = 0;
    _ = windows.GetWindowThreadProcessId(window, &process_id);
    if (process_id == 0) return error.GameWindowNotForeground;
    const process = windows.OpenProcess(windows.process_query_limited_information, 0, process_id) orelse return error.ProcessQueryFailed;
    defer _ = windows.CloseHandle(process);

    var path: [32768]u16 = undefined;
    var path_len: u32 = path.len;
    if (windows.QueryFullProcessImageNameW(process, 0, &path, &path_len) == 0 or path_len == 0) return error.ProcessQueryFailed;
    if (!isLeagueGamePath(path[0..path_len])) return error.GameWindowNotForeground;
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
    try sendInputs(io, (&down)[0..1]);
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .awake) catch {};
    var up = keyboardInput(key, scan, keyeventf_keyup);
    try sendInputs(io, (&up)[0..1]);
}

fn sendUnicodeText(io: std.Io, text: []const u8) !void {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    var utf16: [16384]u16 = undefined;
    const length = std.unicode.wtf8ToWtf16Le(&utf16, text) catch return error.InvalidMessage;
    var cursor: usize = 0;
    while (cursor < length) {
        const count = @min(text_chunk_utf16_units, length - cursor);
        var inputs: [text_chunk_utf16_units * 2]windows.Input = undefined;
        const input_count = unicodeInputsForUnits(utf16[cursor .. cursor + count], &inputs);
        try sendInputs(io, inputs[0..input_count]);
        cursor += count;
        if (cursor < length) std.Io.sleep(io, std.Io.Duration.fromMilliseconds(3), .awake) catch {};
    }
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
    // SendInput can transiently return a short count while the game window is
    // changing focus. A single short retry matches the Rust host's timing
    // tolerance without hiding a persistent permission or hook failure.
    var attempt: usize = 0;
    while (attempt < 2) : (attempt += 1) {
        const sent = windows.SendInput(@intCast(inputs.len), inputs.ptr, @sizeOf(windows.Input));
        if (sent == inputs.len) return;
        if (attempt == 0) std.Io.sleep(io, std.Io.Duration.fromMilliseconds(5), .awake) catch {};
    }
    return error.InputSimulationFailed;
}

fn currentProcessIsElevated() !bool {
    if (builtin.os.tag != .windows) return false;
    var token: ?*anyopaque = null;
    if (windows.OpenProcessToken(windows.GetCurrentProcess(), windows.token_query, &token) == 0 or token == null) return error.ProcessQueryFailed;
    defer _ = windows.CloseHandle(token.?);

    var elevation: windows.TokenElevation = .{ .token_is_elevated = 0 };
    var returned_length: u32 = 0;
    if (windows.GetTokenInformation(token.?, windows.token_elevation, &elevation, @sizeOf(windows.TokenElevation), &returned_length) == 0) return error.ProcessQueryFailed;
    return elevation.token_is_elevated != 0;
}

const windows = if (builtin.os.tag == .windows) struct {
    const process_query_limited_information: u32 = 0x1000;
    const mapvk_vk_to_vsc: u32 = 0;
    const token_query: u32 = 0x0008;
    const token_elevation: u32 = 20;

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
    const TokenElevation = extern struct { token_is_elevated: u32 };

    extern "user32" fn GetForegroundWindow() callconv(.winapi) ?*anyopaque;
    extern "user32" fn GetWindowThreadProcessId(window: *anyopaque, process_id: *u32) callconv(.winapi) u32;
    extern "user32" fn MapVirtualKeyW(code: u32, map_type: u32) callconv(.winapi) u32;
    extern "user32" fn SendInput(count: u32, inputs: [*]const Input, size: i32) callconv(.winapi) u32;
    extern "kernel32" fn OpenProcess(access: u32, inherit_handle: i32, process_id: u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) *anyopaque;
    extern "advapi32" fn OpenProcessToken(process: *anyopaque, access: u32, token: *?*anyopaque) callconv(.winapi) i32;
    extern "advapi32" fn GetTokenInformation(token: *anyopaque, class: u32, information: *anyopaque, information_length: u32, returned_length: *u32) callconv(.winapi) i32;
    extern "kernel32" fn QueryFullProcessImageNameW(process: *anyopaque, flags: u32, path: [*]u16, length: *u32) callconv(.winapi) i32;
    extern "kernel32" fn CloseHandle(handle: *anyopaque) callconv(.winapi) i32;
} else struct {
    const Input = struct {};
};

test "recognizes only the League game executable" {
    const valid = [_]u16{ 'C', ':', '\\', 'G', 'a', 'm', 'e', '\\', 'L', 'e', 'a', 'g', 'u', 'e', ' ', 'o', 'f', ' ', 'L', 'e', 'g', 'e', 'n', 'd', 's', '.', 'e', 'x', 'e' };
    const invalid = [_]u16{ 'C', ':', '\\', 'L', 'e', 'a', 'g', 'u', 'e', 'C', 'l', 'i', 'e', 'n', 't', 'U', 'x', '.', 'e', 'x', 'e' };
    try std.testing.expect(isLeagueGamePath(&valid));
    try std.testing.expect(!isLeagueGamePath(&invalid));
}

test "Windows INPUT layout includes the largest union member" {
    if (builtin.os.tag == .windows) try std.testing.expectEqual(@as(usize, 40), @sizeOf(windows.Input));
}

test "unicode input emits a complete down and up pair per UTF-16 unit" {
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

test "unicode chunks are capped at eight UTF-16 units" {
    const unit_count: usize = 13;
    try std.testing.expectEqual(@as(usize, 2), std.math.divCeil(usize, unit_count, text_chunk_utf16_units));
    try std.testing.expectEqual(@as(usize, 16), @min(text_chunk_utf16_units, unit_count) * 2);
    try std.testing.expectEqual(@as(usize, 10), (unit_count - text_chunk_utf16_units) * 2);
}

test "message interval is limited to the League-safe range" {
    try std.testing.expectEqual(@as(i64, 250), configuredMessageInterval(20));
    try std.testing.expectEqual(@as(i64, 1000), configuredMessageInterval(1000));
    try std.testing.expectEqual(@as(i64, 5000), configuredMessageInterval(9000));
}

test "reads the current Windows process elevation state" {
    if (builtin.os.tag == .windows) _ = try currentProcessIsElevated();
}
