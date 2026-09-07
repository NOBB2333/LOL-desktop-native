const std = @import("std");
const lcu = @import("lcu");

const Endpoint = struct { uri: []const u8, slot: usize };

pub const State = struct {
    // Keep chat resources on their own slots. They are sampled less often
    // than gameflow endpoints so the normal event poll does not turn into a
    // request-per-tick friends refresh.
    hashes: [9]u64 = [_]u64{0} ** 9,
    observed: [9]bool = [_]bool{false} ** 9,
    friend_poll_ticks: u8 = 0,

    fn changed(self: *State, slot: usize, value: []const u8) bool {
        const hash = std.hash.Wyhash.hash(0, value);
        if (self.observed[slot] and self.hashes[slot] == hash) return false;
        self.hashes[slot] = hash;
        self.observed[slot] = true;
        return true;
    }

    fn refreshFriendsNow(self: *State) bool {
        const refresh = self.friend_poll_ticks == 0;
        self.friend_poll_ticks = if (self.friend_poll_ticks >= 9)
            0
        else
            self.friend_poll_ticks + 1;
        return refresh;
    }
};

/// Poll the same relevant LCU resources subscribed by the Rust WebSocket
/// bridge. The token remains in Zig; JavaScript receives URI change markers.
/// This is also the reconnect fallback when a platform WebSocket transport is
/// unavailable.
pub fn poll(state: *State, client: lcu.Client, output: []u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const phase_json = client.get("/lol-gameflow/v1/gameflow-phase") catch return error.LcuRequestFailed;
    defer std.heap.page_allocator.free(phase_json);
    const phase_value = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), phase_json, .{}) catch return error.LcuInvalidResponse;
    if (phase_value != .string) return error.LcuInvalidResponse;
    const phase = phase_value.string;

    var writer = std.Io.Writer.fixed(output);
    try writer.writeByte('[');
    var emitted = false;
    if (state.changed(0, phase_json)) try writeEvent(&writer, &emitted, "/lol-gameflow/v1/gameflow-phase", phase);

    try observeOptional(state, client, &writer, &emitted, .{ .uri = "/lol-gameflow/v1/session", .slot = 1 }, phase);
    if (std.mem.eql(u8, phase, "ChampSelect")) {
        try observeOptional(state, client, &writer, &emitted, .{ .uri = "/lol-champ-select/v1/session", .slot = 2 }, phase);
    }
    if (std.mem.eql(u8, phase, "Lobby") or std.mem.eql(u8, phase, "Matchmaking") or std.mem.eql(u8, phase, "ReadyCheck")) {
        try observeOptional(state, client, &writer, &emitted, .{ .uri = "/lol-lobby/v2/lobby", .slot = 3 }, phase);
    }
    if (std.mem.eql(u8, phase, "ReadyCheck")) {
        try observeOptional(state, client, &writer, &emitted, .{ .uri = "/lol-matchmaking/v1/ready-check", .slot = 4 }, phase);
    }
    if (std.mem.indexOf(u8, phase, "Watch") != null or std.mem.indexOf(u8, phase, "Spectat") != null) {
        try observeOptional(state, client, &writer, &emitted, .{ .uri = "/lol-spectator/v1/spectator/metadata", .slot = 5 }, phase);
        try observeOptional(state, client, &writer, &emitted, .{ .uri = "/lol-spectator/v1/spectator/game", .slot = 6 }, phase);
    }
    // Friend presence can change independently of gameflow. Sample it on the
    // first pass and then at a relaxed cadence (roughly 2.5s with the normal
    // 250ms native poll, or 10s with the idle 1s poll).
    if (state.refreshFriendsNow()) {
        try observeOptional(state, client, &writer, &emitted, .{ .uri = "/lol-chat/v1/friend-groups", .slot = 7 }, phase);
        try observeOptional(state, client, &writer, &emitted, .{ .uri = "/lol-chat/v1/friends", .slot = 8 }, phase);
    }
    try writer.writeByte(']');
    return writer.buffered();
}

fn observeOptional(state: *State, client: lcu.Client, writer: *std.Io.Writer, emitted: *bool, endpoint: Endpoint, phase: []const u8) !void {
    const value = client.get(endpoint.uri) catch return;
    defer std.heap.page_allocator.free(value);
    if (state.changed(endpoint.slot, value)) try writeEvent(writer, emitted, endpoint.uri, phase);
}

fn writeEvent(writer: *std.Io.Writer, emitted: *bool, uri: []const u8, phase: []const u8) !void {
    if (emitted.*) try writer.writeByte(',');
    emitted.* = true;
    try writer.writeAll("{\"uri\":");
    try writeJsonString(writer, uri);
    try writer.writeAll(",\"phase\":");
    try writeJsonString(writer, phase);
    try writer.writeByte('}');
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    var stringify = std.json.Stringify{ .writer = writer, .options = .{} };
    try stringify.write(value);
}

test "event state emits only content changes" {
    var state: State = .{};
    try std.testing.expect(state.changed(0, "ChampSelect"));
    try std.testing.expect(!state.changed(0, "ChampSelect"));
    try std.testing.expect(state.changed(0, "InProgress"));
}

test "friend resources refresh every ten polls" {
    var state: State = .{};
    try std.testing.expect(state.refreshFriendsNow());
    for (0..9) |_| try std.testing.expect(!state.refreshFriendsNow());
    try std.testing.expect(state.refreshFriendsNow());
}

test "event JSON contains independently encoded URI and phase strings" {
    var output: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try writer.writeByte('[');
    var emitted = false;
    try writeEvent(&writer, &emitted, "/lol/test", "ChampSelect");
    try writer.writeByte(']');
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, writer.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("ChampSelect", parsed.value.array.items[0].object.get("phase").?.string);
}
