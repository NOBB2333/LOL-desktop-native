//! 事件类 IPC handler：LCU 事件轮询与快捷键事件排空。
//!
//! 从 `backend.zig` 抽出的第一个 feature 模块，用来验证拆分形态：
//! - handler 只做参数解析 + 调用领域服务，不含业务规则；
//! - 需要 Runtime 状态时通过 `@import("../backend.zig")` 的 `runtime()` 取；
//! - 领域服务本身在 `backend/events.zig`、`backend/hotkeys.zig`。
const std = @import("std");
const native_sdk = @import("native_sdk");
const backend = @import("../backend.zig");
const lcu_events = @import("events.zig");
const hotkey_service = @import("hotkeys.zig");

/// `lol.get_lcu_events` —— 拉取一次 LCU 事件增量。非 live 模式直接返回空数组。
pub fn getLcuEvents(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    _ = invocation;
    const self = backend.runtime(context);
    if (self.mode != .live) return std.fmt.bufPrint(output, "[]", .{});
    if (self.io) |io| {
        var client = backend.discoverClient(self, io) catch return error.LcuNotRunning;
        defer client.deinit();
        return lcu_events.poll(&self.event_state, client, output);
    }
    return error.LcuNotRunning;
}

/// `lol.get_shortcut_events` —— 排空待发送的快捷键事件，不接触 Runtime。
pub fn getShortcutEvents(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    _ = context;
    _ = invocation;
    return hotkey_service.drainJson(output);
}
