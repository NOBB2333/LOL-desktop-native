//! LCU event subscription boundary.
//!
//! Riot's WebSocket endpoint uses the same lockfile credentials as REST. The
//! Native host keeps the subscription state here; when a platform WebSocket
//! implementation is unavailable it falls back to the documented gameflow
//! polling endpoints so the UI still receives deterministic change events.
const std = @import("std");

pub const Event = struct {
    uri: []const u8,
    payload: []const u8 = "null",
};

/// LCU's websocket handshake payload. The frame is deliberately generated in
/// the native layer so the renderer never learns the subscription protocol.
pub fn subscriptionFrame(output: []u8, uri: []const u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll("[5,\"OnJsonApiEvent\",{\"uri\":");
    var stringify = std.json.Stringify{ .writer = &writer, .options = .{} };
    try stringify.write(uri);
    try writer.writeAll("}]");
    return writer.buffered();
}

/// Decode one LCU `OnJsonApiEvent` message. Unknown event shapes are ignored
/// by returning `error.InvalidFrame`; callers can safely continue polling.
pub fn parseFrame(frame: []const u8) !Event {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, std.heap.page_allocator, frame, .{}) catch return error.InvalidFrame;
    if (parsed != .array or parsed.array.items.len < 3) return error.InvalidFrame;
    const kind = parsed.array.items[1];
    if (kind != .string or !std.mem.eql(u8, kind.string, "OnJsonApiEvent")) return error.InvalidFrame;
    const event = parsed.array.items[2];
    if (event != .object) return error.InvalidFrame;
    const uri = event.object.get("uri") orelse return error.InvalidFrame;
    if (uri != .string or uri.string.len == 0) return error.InvalidFrame;
    const payload = event.object.get("data") orelse return .{ .uri = uri.string };
    return .{ .uri = uri.string, .payload = stringifyValue(payload) };
}

fn stringifyValue(value: std.json.Value) []const u8 {
    // Event payloads are consumed as change markers by the poller. Scalar
    // values can be represented without another allocation; object payloads
    // are refreshed through the corresponding REST endpoint.
    return switch (value) {
        .null => "null",
        .bool => |item| if (item) "true" else "false",
        .integer => |item| std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{item}) catch "null",
        .float => |item| std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{item}) catch "null",
        .string => |item| item,
        else => "[object]",
    };
}

pub const Poller = struct {
    last_phase: [64]u8 = undefined,
    last_phase_len: usize = 0,

    pub fn changed(self: *Poller, phase: []const u8) bool {
        if (phase.len > self.last_phase.len) return false;
        if (phase.len == self.last_phase_len and std.mem.eql(u8, self.last_phase[0..phase.len], phase)) return false;
        @memcpy(self.last_phase[0..phase.len], phase);
        self.last_phase_len = phase.len;
        return true;
    }
};

test "poller emits only phase transitions" {
    var poller: Poller = .{};
    try std.testing.expect(poller.changed("ChampSelect"));
    try std.testing.expect(!poller.changed("ChampSelect"));
    try std.testing.expect(poller.changed("InProgress"));
}

test "builds and parses LCU event frames" {
    var frame: [256]u8 = undefined;
    try std.testing.expectEqualStrings("[5,\"OnJsonApiEvent\",{\"uri\":\"/lol-gameflow/v1/gameflow-phase\"}]", try subscriptionFrame(&frame, "/lol-gameflow/v1/gameflow-phase"));
    const event = try parseFrame("[8,\"OnJsonApiEvent\",{\"uri\":\"/lol-gameflow/v1/gameflow-phase\",\"data\":\"ChampSelect\"}]");
    try std.testing.expectEqualStrings("/lol-gameflow/v1/gameflow-phase", event.uri);
    try std.testing.expectEqualStrings("ChampSelect", event.payload);
}
