//! 好友工具 IPC handler：好友列表 / 最近一局 / 删除好友。
//!
//! 依赖 `backend.zig` 的共享基础设施（Runtime、LCU 客户端发现、JSON helper）。
//! `historyGames` / `unwrapHistoryGame` 属于跨模块的历史数据整形，仍留在共享层。
const std = @import("std");
const native_sdk = @import("native_sdk");
const backend = @import("../backend.zig");

/// `lol.get_friends` —— 好友分组 + 好友列表（含送礼时间与缓存到的最近一局）。
pub fn getFriends(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = backend.runtime(context);
    _ = invocation;
    if (self.mode != .live) return std.fmt.bufPrint(output, "{{\"groups\":[],\"friends\":[]}}", .{});
    const io = self.io orelse return error.LcuNotRunning;
    var client = backend.discoverClient(self, io) catch return error.LcuNotRunning;
    defer client.deinit();
    const groups_json = client.get("/lol-chat/v1/friend-groups") catch return error.LcuRequestFailed;
    defer std.heap.page_allocator.free(groups_json);
    const friends_json = client.get("/lol-chat/v1/friends") catch return error.LcuRequestFailed;
    defer std.heap.page_allocator.free(friends_json);
    const giftable_json = client.get("/lol-store/v1/giftablefriends") catch null;
    defer if (giftable_json) |value| std.heap.page_allocator.free(value);
    return friendToolsDto(self, groups_json, friends_json, giftable_json orelse "[]", output);
}

fn friendToolsDto(self: *backend.Runtime, groups_json: []const u8, friends_json: []const u8, giftable_json: []const u8, output: []u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const groups = std.json.parseFromSliceLeaky(std.json.Value, allocator, groups_json, .{}) catch return error.LcuInvalidResponse;
    const friends = std.json.parseFromSliceLeaky(std.json.Value, allocator, friends_json, .{}) catch return error.LcuInvalidResponse;
    const giftable = std.json.parseFromSliceLeaky(std.json.Value, allocator, giftable_json, .{}) catch std.json.Value{ .null = {} };
    if (groups != .array or friends != .array) return error.LcuInvalidResponse;
    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll("{\"groups\":[");
    var first = true;
    for (groups.array.items) |group| {
        if (group != .object) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.print("{{\"id\":{d},\"name\":", .{backend.jsonInt(group, "id")});
        try backend.jsonString(&writer, backend.jsonField(group, "name"));
        try writer.print(",\"priority\":{d}}}", .{backend.jsonInt(group, "priority")});
    }
    try writer.writeAll("],\"friends\":[");
    first = true;
    for (friends.array.items) |friend| {
        if (friend != .object) continue;
        const id = backend.jsonField(friend, "id");
        const puuid = backend.jsonField(friend, "puuid");
        if (id.len == 0 or puuid.len == 0) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.writeAll("{\"id\":");
        try backend.jsonString(&writer, id);
        try writer.writeAll(",\"puuid\":");
        try backend.jsonString(&writer, puuid);
        try writer.print(",\"summonerId\":{d},\"gameName\":", .{backend.jsonInt(friend, "summonerId")});
        try backend.jsonString(&writer, if (backend.jsonField(friend, "gameName").len > 0) backend.jsonField(friend, "gameName") else backend.jsonField(friend, "name"));
        try writer.writeAll(",\"gameTag\":");
        try backend.jsonString(&writer, backend.jsonField(friend, "gameTag"));
        try writer.print(",\"icon\":{d},\"groupId\":{d},\"availability\":", .{ backend.jsonInt(friend, "icon"), backend.jsonInt(friend, "groupId") });
        try backend.jsonString(&writer, backend.jsonField(friend, "availability"));
        try writer.writeAll(",\"friendsSince\":");
        if (giftableFriendSince(giftable, backend.jsonInt(friend, "summonerId"))) |since| try backend.jsonString(&writer, since) else try writer.writeAll("null");
        try writer.writeAll(",\"lastGameAt\":");
        if (cachedFriendLastGame(self, puuid)) |cached| {
            defer std.heap.page_allocator.free(cached);
            const cached_value = std.json.parseFromSliceLeaky(std.json.Value, allocator, cached, .{}) catch std.json.Value{ .null = {} };
            const last_game = backend.jsonField(cached_value, "lastGameAt");
            if (last_game.len > 0) try backend.jsonString(&writer, last_game) else try writer.writeAll("null");
        } else try writer.writeAll("null");
        try writer.writeByte('}');
    }
    try writer.writeAll("]}");
    return writer.buffered();
}

fn giftableFriendSince(giftable: std.json.Value, summoner_id: i64) ?[]const u8 {
    if (giftable != .array or summoner_id <= 0) return null;
    for (giftable.array.items) |friend| if (backend.jsonInt(friend, "summonerId") == summoner_id) {
        const value = backend.jsonField(friend, "friendsSince");
        if (value.len > 0) return value;
    };
    return null;
}

fn cachedFriendLastGame(self: *backend.Runtime, puuid: []const u8) ?[]u8 {
    const store = if (self.storage) |*value| value else return null;
    return store.get("friendLastGame", puuid) catch null;
}

/// `lol.get_friend_last_game` —— 好友最近一局的开始时间，带 6 小时缓存。
pub fn getFriendLastGame(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = backend.runtime(context);
    const payload_json = backend.parsePayload(struct { puuid: []const u8 = "", force: bool = false }, invocation.request.payload) catch return error.InvalidRequest;
    defer payload_json.deinit();
    const payload = payload_json.value;
    if (payload.puuid.len == 0) return error.InvalidRequest;
    if (!payload.force) if (self.storage) |*store| {
        const updated_at = store.getUpdatedAt("friendLastGame", payload.puuid) catch null;
        const now_seconds = @divTrunc(backend.runtimeNowMillis(self), std.time.ms_per_s);
        if (updated_at != null and now_seconds - updated_at.? < 6 * std.time.s_per_hour) if (cachedFriendLastGame(self, payload.puuid)) |cached| {
            defer std.heap.page_allocator.free(cached);
            return backend.copyJson(cached, output);
        };
    };
    if (self.mode != .live) return friendLastGameDto(payload.puuid, "[]", output);
    const io = self.io orelse return error.LcuNotRunning;
    var client = backend.discoverClient(self, io) catch return error.LcuNotRunning;
    defer client.deinit();
    var path_buffer: [768]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "/lol-match-history/v1/products/lol/{s}/matches?begIndex=0&endIndex=0", .{payload.puuid}) catch return error.InvalidRequest;
    const lcu_history = client.get(path) catch null;
    defer if (lcu_history) |value| std.heap.page_allocator.free(value);
    var history = lcu_history orelse "{}";
    var sgp_history: ?[]u8 = null;
    defer if (sgp_history) |value| std.heap.page_allocator.free(value);
    if (!backend.historyHasGames(history)) {
        const current_json = client.get("/lol-summoner/v1/current-summoner") catch null;
        defer if (current_json) |value| std.heap.page_allocator.free(value);
        if (current_json) |value| {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const current = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), value, .{}) catch std.json.Value{ .null = {} };
            sgp_history = backend.fetchSgpHistory(client, current, history, payload.puuid, 0, 1) catch null;
            if (sgp_history) |sgp| {
                if (backend.historyHasGames(sgp)) history = sgp;
            }
        }
    }
    const result = try friendLastGameDto(payload.puuid, history, output);
    if (self.storage) |*store| store.put("friendLastGame", payload.puuid, result) catch {};
    return result;
}

fn friendLastGameDto(puuid: []const u8, history_json: []const u8, output: []u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), history_json, .{}) catch std.json.Value{ .null = {} };
    const list = backend.historyGames(root);
    var timestamp: i64 = 0;
    if (list) |games| if (games.array.items.len > 0) {
        const game = backend.unwrapHistoryGame(arena.allocator(), games.array.items[0]) orelse std.json.Value{ .null = {} };
        timestamp = if (backend.jsonInt(game, "gameCreation") > 0) backend.jsonInt(game, "gameCreation") else backend.jsonInt(game, "gameStartTimestamp");
    };
    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll("{\"puuid\":");
    try backend.jsonString(&writer, puuid);
    try writer.writeAll(",\"lastGameAt\":");
    if (timestamp > 0) try backend.writeIsoTimestamp(&writer, timestamp) else try writer.writeAll("null");
    try writer.writeByte('}');
    return writer.buffered();
}

/// `lol.delete_friend` —— 删除好友。先校验当前账号，避免切号后误删。
pub fn deleteFriend(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = backend.runtime(context);
    const payload_json = backend.parsePayload(struct { id: []const u8 = "" }, invocation.request.payload) catch return error.InvalidRequest;
    defer payload_json.deinit();
    const payload = payload_json.value;
    if (self.mode != .live or payload.id.len == 0 or std.mem.indexOfScalar(u8, payload.id, '/') != null) return error.InvalidRequest;
    const io = self.io orelse return error.LcuNotRunning;
    var client = backend.discoverClient(self, io) catch return error.LcuNotRunning;
    defer client.deinit();
    var path_buffer: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "/lol-chat/v1/friends/{s}", .{payload.id}) catch return error.InvalidRequest;
    try backend.verifyActionAccount(self, client);
    const response = try client.delete(path);
    defer std.heap.page_allocator.free(response);
    return std.fmt.bufPrint(output, "{{\"deleted\":true}}", .{});
}

// 就地测试：这两个 DTO 是本模块私有的，搬到这里才能继续被 zig test 收集。
test "normalizes friend groups and friend-since dates" {
    var state = backend.Runtime.init();
    const groups = "[{\"id\":7,\"name\":\"双排\",\"priority\":2}]";
    const friends = "[{\"id\":\"friend-id\",\"puuid\":\"friend-puuid\",\"summonerId\":42,\"gameName\":\"好友\",\"gameTag\":\"CN1\",\"icon\":12,\"groupId\":7,\"availability\":\"chat\"}]";
    const giftable = "[{\"summonerId\":42,\"friendsSince\":\"2025-08-29T10:00:00.000Z\"}]";
    var output: [4096]u8 = undefined;
    const result = try friendToolsDto(&state, groups, friends, giftable, &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.get("groups").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.get("friends").?.array.items.len);
    const friend = parsed.value.object.get("friends").?.array.items[0];
    try std.testing.expectEqualStrings("好友", friend.object.get("gameName").?.string);
    try std.testing.expectEqual(@as(i64, 7), friend.object.get("groupId").?.integer);
    try std.testing.expectEqualStrings("2025-08-29T10:00:00.000Z", friend.object.get("friendsSince").?.string);
}

test "extracts the latest friend match timestamp" {
    var output: [1024]u8 = undefined;
    const result = try friendLastGameDto("friend-puuid", "{\"games\":[{\"gameCreation\":1625159473123}]}", &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("friend-puuid", parsed.value.object.get("puuid").?.string);
    try std.testing.expectEqualStrings("2021-07-01T17:11:13.123Z", parsed.value.object.get("lastGameAt").?.string);
}
