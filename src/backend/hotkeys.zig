const std = @import("std");
const builtin = @import("builtin");

const max_bindings: usize = 32;
const max_id_bytes: usize = 64;
const max_pending: usize = 32;
const max_events: usize = 32;

pub const Shortcut = struct {
    id: []const u8,
    key: []const u8,
};

const Binding = struct {
    id: [max_id_bytes]u8 = undefined,
    id_len: usize = 0,
    key: u32 = 0,
    control: bool = false,
    command_or_control: bool = false,
    shift: bool = false,
    alt: bool = false,
    win: bool = false,

    fn idSlice(self: *const Binding) []const u8 {
        return self.id[0..self.id_len];
    }
};

const QueuedId = struct {
    bytes: [max_id_bytes]u8 = undefined,
    len: usize = 0,

    fn set(self: *QueuedId, value: []const u8) void {
        self.len = @min(value.len, self.bytes.len);
        @memcpy(self.bytes[0..self.len], value[0..self.len]);
    }

    fn slice(self: *const QueuedId) []const u8 {
        return self.bytes[0..self.len];
    }
};

var binding_mutex: std.atomic.Mutex = .unlocked;
var bindings: [max_bindings]Binding = undefined;
var binding_count: usize = 0;
var queue_mutex: std.atomic.Mutex = .unlocked;
var event_queue: [max_events]QueuedId = undefined;
var event_count: usize = 0;
var sending_id: QueuedId = .{};
var capture_active: std.atomic.Value(bool) = .init(false);
var listener_started: std.atomic.Value(bool) = .init(false);

// The hook callback runs on its dedicated message-loop thread, so physical
// key and pending-release state do not need an additional lock.
var pressed: [256]bool = [_]bool{false} ** 256;
var pending: [max_pending]QueuedId = undefined;
var pending_count: usize = 0;

pub fn configure(shortcuts: []const Shortcut) !void {
    if (builtin.os.tag != .windows) return;
    lock(&binding_mutex);
    defer binding_mutex.unlock();
    binding_count = 0;
    for (shortcuts) |shortcut| {
        if (binding_count >= bindings.len) return error.TooManyShortcuts;
        const parsed = parseBinding(shortcut.id, shortcut.key) orelse continue;
        bindings[binding_count] = parsed;
        binding_count += 1;
    }
    pending_count = 0;
    try startListener();
}

pub fn setCapture(active: bool) void {
    capture_active.store(active, .release);
    if (active) pending_count = 0;
}

pub fn drainJson(output: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    try writer.writeByte('[');
    lock(&queue_mutex);
    defer queue_mutex.unlock();
    for (event_queue[0..event_count], 0..) |*entry, index| {
        if (index > 0) try writer.writeByte(',');
        var stringify = std.json.Stringify{ .writer = &writer, .options = .{} };
        try stringify.write(entry.slice());
    }
    event_count = 0;
    try writer.writeByte(']');
    return writer.buffered();
}

pub fn beginSend(id: []const u8) void {
    lock(&queue_mutex);
    defer queue_mutex.unlock();
    sending_id.set(id);
    var remaining: usize = 0;
    for (event_queue[0..event_count]) |entry| {
        if (std.mem.eql(u8, entry.slice(), id)) continue;
        event_queue[remaining] = entry;
        remaining += 1;
    }
    event_count = remaining;
}

pub fn endSend() void {
    lock(&queue_mutex);
    defer queue_mutex.unlock();
    sending_id.len = 0;
}

fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

fn startListener() !void {
    if (listener_started.swap(true, .acq_rel)) return;
    const thread = std.Thread.spawn(.{}, listenerMain, .{}) catch |err| {
        listener_started.store(false, .release);
        return err;
    };
    thread.detach();
}

fn listenerMain() void {
    if (builtin.os.tag != .windows) return;
    const hook = windows.SetWindowsHookExW(windows.wh_keyboard_ll, keyboardProc, null, 0) orelse {
        listener_started.store(false, .release);
        return;
    };
    defer _ = windows.UnhookWindowsHookEx(hook);
    var message: windows.Msg = std.mem.zeroes(windows.Msg);
    while (windows.GetMessageW(&message, null, 0, 0) > 0) {
        _ = windows.TranslateMessage(&message);
        _ = windows.DispatchMessageW(&message);
    }
}

fn keyboardProc(code: i32, message: usize, data: isize) callconv(.winapi) isize {
    if (code >= 0 and data != 0) {
        const event: *const windows.KeyboardEvent = @ptrFromInt(@as(usize, @bitCast(data)));
        if ((event.flags & windows.llkhf_injected) == 0) {
            if (message == windows.wm_keydown or message == windows.wm_syskeydown) {
                handleKeyDown(event.vk_code);
            } else if (message == windows.wm_keyup or message == windows.wm_syskeyup) {
                handleKeyUp(event.vk_code);
            }
        }
    }
    return windows.CallNextHookEx(null, code, message, data);
}

fn handleKeyDown(key: u32) void {
    if (key >= pressed.len) return;
    const first_press = !pressed[key];
    pressed[key] = true;
    if (!first_press or capture_active.load(.acquire)) return;
    const state = modifierState(&pressed);

    lock(&binding_mutex);
    defer binding_mutex.unlock();
    for (bindings[0..binding_count]) |*binding| {
        if (binding.key != key or !bindingMatches(binding.*, state)) continue;
        appendPending(binding.idSlice());
    }
}

fn handleKeyUp(key: u32) void {
    if (key < pressed.len) pressed[key] = false;
    for (pressed) |is_pressed| if (is_pressed) return;
    if (capture_active.load(.acquire)) {
        pending_count = 0;
        return;
    }
    for (pending[0..pending_count]) |*entry| enqueue(entry.slice());
    pending_count = 0;
}

const ModifierState = struct { control: bool, shift: bool, alt: bool, win: bool };

fn modifierState(keys: *const [256]bool) ModifierState {
    return .{
        .control = keys[windows.vk_control] or keys[windows.vk_lcontrol] or keys[windows.vk_rcontrol],
        .shift = keys[windows.vk_shift] or keys[windows.vk_lshift] or keys[windows.vk_rshift],
        .alt = keys[windows.vk_menu] or keys[windows.vk_lmenu] or keys[windows.vk_rmenu],
        .win = keys[windows.vk_lwin] or keys[windows.vk_rwin],
    };
}

fn bindingMatches(binding: Binding, state: ModifierState) bool {
    const control_match = if (binding.command_or_control)
        state.control or state.win
    else
        state.control == binding.control and state.win == binding.win;
    return control_match and state.shift == binding.shift and state.alt == binding.alt;
}

fn appendPending(id: []const u8) void {
    for (pending[0..pending_count]) |*entry| if (std.mem.eql(u8, entry.slice(), id)) return;
    if (pending_count >= pending.len) return;
    pending[pending_count].set(id);
    pending_count += 1;
}

fn enqueue(id: []const u8) void {
    lock(&queue_mutex);
    defer queue_mutex.unlock();
    // 当前发送及尚未读取的同一快捷键只保留一次，避免发送结束后重放。
    if (std.mem.eql(u8, sending_id.slice(), id)) return;
    for (event_queue[0..event_count]) |*entry| if (std.mem.eql(u8, entry.slice(), id)) return;
    if (event_count == event_queue.len) {
        for (event_queue[1..], 0..) |entry, index| event_queue[index] = entry;
        event_count -= 1;
    }
    event_queue[event_count].set(id);
    event_count += 1;
}

fn parseBinding(id: []const u8, value: []const u8) ?Binding {
    if (id.len == 0 or id.len > max_id_bytes) return null;
    var result: Binding = .{};
    result.id_len = id.len;
    @memcpy(result.id[0..id.len], id);
    var key_name: []const u8 = "";
    var parts = std.mem.splitScalar(u8, value, '+');
    while (parts.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t\r\n");
        if (part.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(part, "CommandOrControl") or std.ascii.eqlIgnoreCase(part, "CmdOrCtrl") or std.ascii.eqlIgnoreCase(part, "Command-Or-Control")) {
            result.command_or_control = true;
        } else if (std.ascii.eqlIgnoreCase(part, "Control") or std.ascii.eqlIgnoreCase(part, "Ctrl")) {
            result.control = true;
        } else if (std.ascii.eqlIgnoreCase(part, "Command") or std.ascii.eqlIgnoreCase(part, "Meta") or std.ascii.eqlIgnoreCase(part, "Win") or std.ascii.eqlIgnoreCase(part, "Windows") or std.ascii.eqlIgnoreCase(part, "Super")) {
            result.win = true;
        } else if (std.ascii.eqlIgnoreCase(part, "Alt") or std.ascii.eqlIgnoreCase(part, "Option")) {
            result.alt = true;
        } else if (std.ascii.eqlIgnoreCase(part, "Shift")) {
            result.shift = true;
        } else if (key_name.len == 0) {
            key_name = part;
        } else return null;
    }
    result.key = virtualKey(key_name) orelse return null;
    return result;
}

fn virtualKey(value: []const u8) ?u32 {
    if (value.len >= 2 and (value[0] == 'f' or value[0] == 'F')) {
        const number = std.fmt.parseInt(u32, value[1..], 10) catch 0;
        if (number >= 1 and number <= 24) return 0x6f + number;
    }
    if (value.len == 1) {
        const byte = value[0];
        if (std.ascii.isAlphabetic(byte)) return std.ascii.toUpper(byte);
        if (std.ascii.isDigit(byte)) return byte;
    }
    if (std.ascii.eqlIgnoreCase(value, "Space")) return 0x20;
    if (std.ascii.eqlIgnoreCase(value, "Enter") or std.ascii.eqlIgnoreCase(value, "Return")) return 0x0d;
    if (std.ascii.eqlIgnoreCase(value, "Esc") or std.ascii.eqlIgnoreCase(value, "Escape")) return 0x1b;
    if (std.ascii.eqlIgnoreCase(value, "Tab")) return 0x09;
    if (std.ascii.eqlIgnoreCase(value, "Backspace")) return 0x08;
    if (std.ascii.eqlIgnoreCase(value, "OemTilde") or std.mem.eql(u8, value, "`")) return 0xc0;
    if (std.ascii.eqlIgnoreCase(value, "Minus")) return 0xbd;
    if (std.ascii.eqlIgnoreCase(value, "Equal") or std.mem.eql(u8, value, "=")) return 0xbb;
    if (std.ascii.eqlIgnoreCase(value, "Left") or std.ascii.eqlIgnoreCase(value, "ArrowLeft")) return 0x25;
    if (std.ascii.eqlIgnoreCase(value, "Up") or std.ascii.eqlIgnoreCase(value, "ArrowUp")) return 0x26;
    if (std.ascii.eqlIgnoreCase(value, "Right") or std.ascii.eqlIgnoreCase(value, "ArrowRight")) return 0x27;
    if (std.ascii.eqlIgnoreCase(value, "Down") or std.ascii.eqlIgnoreCase(value, "ArrowDown")) return 0x28;
    if (std.ascii.eqlIgnoreCase(value, "Delete")) return 0x2e;
    if (std.ascii.eqlIgnoreCase(value, "Home")) return 0x24;
    if (std.ascii.eqlIgnoreCase(value, "End")) return 0x23;
    if (std.ascii.eqlIgnoreCase(value, "PageUp")) return 0x21;
    if (std.ascii.eqlIgnoreCase(value, "PageDown")) return 0x22;
    if (std.ascii.eqlIgnoreCase(value, "Insert")) return 0x2d;
    if (std.mem.eql(u8, value, "-")) return 0xbd;
    if (std.mem.eql(u8, value, "+") or std.mem.eql(u8, value, "=")) return 0xbb;
    if (std.mem.eql(u8, value, ",")) return 0xbc;
    if (std.mem.eql(u8, value, ".")) return 0xbe;
    if (std.mem.eql(u8, value, "/")) return 0xbf;
    if (std.mem.eql(u8, value, ";")) return 0xba;
    if (std.mem.eql(u8, value, "'")) return 0xde;
    if (std.mem.eql(u8, value, "[")) return 0xdb;
    if (std.mem.eql(u8, value, "]")) return 0xdd;
    if (std.mem.eql(u8, value, "\\")) return 0xdc;
    return null;
}

const windows = if (builtin.os.tag == .windows) struct {
    const wh_keyboard_ll: i32 = 13;
    const llkhf_injected: u32 = 0x10;
    const wm_keydown: usize = 0x0100;
    const wm_keyup: usize = 0x0101;
    const wm_syskeydown: usize = 0x0104;
    const wm_syskeyup: usize = 0x0105;
    const vk_shift: usize = 0x10;
    const vk_control: usize = 0x11;
    const vk_menu: usize = 0x12;
    const vk_lshift: usize = 0xa0;
    const vk_rshift: usize = 0xa1;
    const vk_lcontrol: usize = 0xa2;
    const vk_rcontrol: usize = 0xa3;
    const vk_lmenu: usize = 0xa4;
    const vk_rmenu: usize = 0xa5;
    const vk_lwin: usize = 0x5b;
    const vk_rwin: usize = 0x5c;

    const Point = extern struct { x: i32, y: i32 };
    const Msg = extern struct {
        hwnd: ?*anyopaque,
        message: u32,
        wparam: usize,
        lparam: isize,
        time: u32,
        point: Point,
        private: u32,
    };
    const KeyboardEvent = extern struct {
        vk_code: u32,
        scan_code: u32,
        flags: u32,
        time: u32,
        extra_info: usize,
    };
    const HookProc = *const fn (i32, usize, isize) callconv(.winapi) isize;

    extern "user32" fn SetWindowsHookExW(id_hook: i32, callback: HookProc, module: ?*anyopaque, thread_id: u32) callconv(.winapi) ?*anyopaque;
    extern "user32" fn UnhookWindowsHookEx(hook: *anyopaque) callconv(.winapi) i32;
    extern "user32" fn CallNextHookEx(hook: ?*anyopaque, code: i32, wparam: usize, lparam: isize) callconv(.winapi) isize;
    extern "user32" fn GetMessageW(message: *Msg, window: ?*anyopaque, min: u32, max: u32) callconv(.winapi) i32;
    extern "user32" fn TranslateMessage(message: *const Msg) callconv(.winapi) i32;
    extern "user32" fn DispatchMessageW(message: *const Msg) callconv(.winapi) isize;
} else struct {
    const vk_shift: usize = 0x10;
    const vk_control: usize = 0x11;
    const vk_menu: usize = 0x12;
    const vk_lshift: usize = 0xa0;
    const vk_rshift: usize = 0xa1;
    const vk_lcontrol: usize = 0xa2;
    const vk_rcontrol: usize = 0xa3;
    const vk_lmenu: usize = 0xa4;
    const vk_rmenu: usize = 0xa5;
    const vk_lwin: usize = 0x5b;
    const vk_rwin: usize = 0x5c;
};

test "parses Rust-compatible shortcut bindings" {
    const ctrl = parseBinding("enemy", "Ctrl+F11").?;
    try std.testing.expectEqual(@as(u32, 0x7a), ctrl.key);
    try std.testing.expect(ctrl.control);
    try std.testing.expect(!ctrl.command_or_control);
    const open_game = parseBinding("open-game", "Ctrl+F1").?;
    try std.testing.expectEqual(@as(u32, 0x70), open_game.key);
    try std.testing.expect(open_game.control);
    try std.testing.expect(!open_game.shift);
}

test "matches exact modifiers and command-or-control" {
    const ctrl = parseBinding("enemy", "Ctrl+F11").?;
    try std.testing.expect(bindingMatches(ctrl, .{ .control = true, .shift = false, .alt = false, .win = false }));
    try std.testing.expect(!bindingMatches(ctrl, .{ .control = true, .shift = true, .alt = false, .win = false }));
    const open_game = parseBinding("open", "Ctrl+F1").?;
    try std.testing.expect(bindingMatches(open_game, .{ .control = true, .shift = false, .alt = false, .win = false }));
}

test "发送中的重复快捷键不会积压重放" {
    event_count = 0;
    enqueue("我方");
    beginSend("我方");
    enqueue("我方");
    enqueue("敌方");
    enqueue("敌方");
    endSend();
    var buffer: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("[\"敌方\"]", try drainJson(&buffer));
    enqueue("我方");
    try std.testing.expectEqualStrings("[\"我方\"]", try drainJson(&buffer));
}

test "快捷键事件只读取一次并返回规范数据" {
    event_count = 0;
    enqueue("enemy");
    enqueue("open-game");
    var output: [256]u8 = undefined;
    try std.testing.expectEqualStrings("[\"enemy\",\"open-game\"]", try drainJson(&output));
    try std.testing.expectEqualStrings("[]", try drainJson(&output));
}
