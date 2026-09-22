//! 好友工具 IPC handler：好友列表 / 最近一局 / 删除好友（单个与批量）/ 观战。
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
        // 观战密钥只在这位好友「在线且正在对局中」时下发（对齐 AK 的 `isFriendSpectatable`：
        // `availability === "dnd"` 且 `lol.gameStatus === "ingame"` 才有 `lol.spectatorKey`）。
        // 界面靠 `canSpectate` 决定「观战」按钮亮不亮，省得点下去才知道不行。
        const chat = at(friend, "lol");
        try writer.writeAll(",\"gameStatus\":");
        try backend.jsonString(&writer, backend.jsonField(chat, "gameStatus"));
        try writer.writeAll(",\"canSpectate\":");
        try writer.writeAll(if (backend.jsonField(chat, "spectatorKey").len > 0) "true" else "false");
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

/// 一次批量最多删多少个。好友列表本身是几百的量级，给上限免得单个请求把界面卡住
/// （每条的回报只有几十字节，输出缓冲不是瓶颈，纯粹是别让一次点击跑太久）。
const friend_delete_limit: usize = 200;

/// `lol.delete_friends` —— 批量删除好友。
///
/// 逐条删、逐条回报：一条失败不打断其余，前端能把「哪几个没删掉、为什么」列出来。
/// 删除**不可逆**，所以进循环前先整体校验一次账号归属——只校验**一次**而不是每条一次：
/// 一次就够，而且少几轮往返就少几个失败点。
pub fn deleteFriends(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = backend.runtime(context);
    const parsed = backend.parsePayload(struct { ids: []const []const u8 = &.{} }, invocation.request.payload) catch return error.InvalidRequest;
    defer parsed.deinit();
    const ids = parsed.value.ids;
    if (ids.len == 0) return error.InvalidRequest;
    if (self.mode != .live) return error.LcuNotRunning;
    const io = self.io orelse return error.LcuNotRunning;
    var client = backend.discoverClient(self, io) catch return error.LcuNotRunning;
    defer client.deinit();
    try backend.verifyActionAccount(self, client);
    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll("{\"results\":[");
    var first = true;
    var deleted: usize = 0;
    var failed: usize = 0;
    for (ids) |id| {
        if (deleted + failed >= friend_delete_limit) break;
        // id 会直接拼进 URL，含分隔符的一律不认。
        if (id.len == 0 or std.mem.indexOfScalar(u8, id, '/') != null) {
            writeDeleteResult(&writer, &first, id, false, "好友 id 不合法");
            failed += 1;
            continue;
        }
        var path_buffer: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buffer, "/lol-chat/v1/friends/{s}", .{id}) catch {
            writeDeleteResult(&writer, &first, id, false, "好友 id 过长");
            failed += 1;
            continue;
        };
        const response = client.delete(path) catch {
            writeDeleteResult(&writer, &first, id, false, "客户端拒绝了这个请求");
            failed += 1;
            continue;
        };
        std.heap.page_allocator.free(response);
        writeDeleteResult(&writer, &first, id, true, "");
        deleted += 1;
    }
    try writer.print("],\"deleted\":{d},\"failed\":{d}}}", .{ deleted, failed });
    return writer.buffered();
}

/// `lol.spectate` —— 观战。
///
/// 本地只有一条路：`POST /lol-spectator/v1/spectate/launch`，body 形如
/// `{"puuid":..,"spectatorKey":..}`（对齐 AK `SpectatorHttpApi.launchSpectator`，
/// 路径和字段名都别改）。
///
/// **`spectatorKey` 不是随时都有**：它挂在好友对象的 `lol.spectatorKey` 上，
/// 客户端只在好友「在线且正在游戏」时才下发（AK 的 `isFriendSpectatable` 还额外要求
/// `availability === "dnd"`）。所以「历史里遇到的玩家」「已经下线的朋友」基本都拿不到 key，
/// 这里就直说「观战不可用」，而不是硬发一个没有 key 的请求让客户端报错。
pub fn spectate(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = backend.runtime(context);
    const parsed = backend.parsePayload(struct { puuid: []const u8 = "" }, invocation.request.payload) catch return error.InvalidRequest;
    defer parsed.deinit();
    const puuid = parsed.value.puuid;
    if (puuid.len == 0) return error.InvalidRequest;
    if (self.mode != .live) return spectateResult(output, false, "没连上客户端");
    const io = self.io orelse return spectateResult(output, false, "没连上客户端");
    var client = backend.discoverClient(self, io) catch return spectateResult(output, false, "没连上客户端");
    defer client.deinit();
    const friends_json = client.get("/lol-chat/v1/friends") catch return spectateResult(output, false, "读不到好友列表");
    defer std.heap.page_allocator.free(friends_json);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const friends = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), friends_json, .{}) catch
        return spectateResult(output, false, "好友列表格式不认识");
    const spectator_key = switch (spectatorKeyFor(friends, puuid)) {
        .key => |value| value,
        .no_key => return spectateResult(output, false, "这位好友现在不在选人也不在对局中，拿不到观战密钥"),
        .not_friend => return spectateResult(output, false, "只能观战好友，这位不在好友列表里"),
    };
    var body_buffer: [1024]u8 = undefined;
    const body = launchBody(&body_buffer, puuid, spectator_key) catch return spectateResult(output, false, "观战密钥过长");
    const response = client.post("/lol-spectator/v1/spectate/launch", body) catch return spectateResult(output, false, "客户端拒绝了观战请求");
    std.heap.page_allocator.free(response);
    return spectateResult(output, true, "");
}

const SpectateLookup = union(enum) {
    key: []const u8,
    no_key,
    not_friend,
};

/// 从好友列表里找这位玩家的观战密钥。
///
/// 好友的 puuid 可能落在顶层 `puuid`，也可能只有 `lol.puuid`
/// （AK 的 `isFriendSpectatable` 就是 `puuid || lol.puuid` 两个都看）。
/// 「是好友但没 key」和「压根不是好友」要分开——界面上的说法不一样。
fn spectatorKeyFor(friends: std.json.Value, puuid: []const u8) SpectateLookup {
    if (friends != .array) return .not_friend;
    for (friends.array.items) |friend| {
        if (friend != .object) continue;
        const chat = at(friend, "lol");
        const friend_puuid = backend.jsonField(friend, "puuid");
        const resolved = if (friend_puuid.len > 0) friend_puuid else backend.jsonField(chat, "puuid");
        if (!std.mem.eql(u8, resolved, puuid)) continue;
        const spectator_key = backend.jsonField(chat, "spectatorKey");
        if (spectator_key.len > 0) return .{ .key = spectator_key };
        return .no_key;
    }
    return .not_friend;
}

fn at(value: std.json.Value, name: []const u8) std.json.Value {
    if (value != .object) return .{ .null = {} };
    return value.object.get(name) orelse .{ .null = {} };
}

fn launchBody(buffer: []u8, puuid: []const u8, spectator_key: []const u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writer.writeAll("{\"puuid\":");
    try backend.jsonString(&writer, puuid);
    try writer.writeAll(",\"spectatorKey\":");
    try backend.jsonString(&writer, spectator_key);
    try writer.writeByte('}');
    return writer.buffered();
}

fn spectateResult(output: []u8, ok: bool, reason: []const u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    try writer.print("{{\"ok\":{s},\"reason\":", .{if (ok) "true" else "false"});
    try backend.jsonString(&writer, reason);
    try writer.writeByte('}');
    return writer.buffered();
}

fn writeDeleteResult(writer: *std.Io.Writer, first: *bool, id: []const u8, ok: bool, reason: []const u8) void {
    if (!first.*) writer.writeByte(',') catch return;
    first.* = false;
    writer.writeAll("{\"id\":") catch return;
    backend.jsonString(writer, id) catch return;
    writer.print(",\"ok\":{s},\"reason\":", .{if (ok) "true" else "false"}) catch return;
    backend.jsonString(writer, reason) catch return;
    writer.writeByte('}') catch return;
}

test "观战密钥：只有好友的 lol.spectatorKey 才算拿到" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const friends = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\[
        \\  {"puuid":"p-in-game","lol":{"puuid":"p-in-game","spectatorKey":"KEY-1"}},
        \\  {"puuid":"p-idle","lol":{"puuid":"p-idle"}},
        \\  {"lol":{"puuid":"p-nested"}}
        \\]
    , .{});
    try std.testing.expectEqualStrings("KEY-1", spectatorKeyFor(friends, "p-in-game").key);
    // 是好友但在挂机 → 有明确说法，不是「不是好友」。
    try std.testing.expect(spectatorKeyFor(friends, "p-idle") == .no_key);
    // 顶层没有 puuid、只有 lol.puuid 的也要能对上，同样是「没 key」。
    try std.testing.expect(spectatorKeyFor(friends, "p-nested") == .no_key);
    try std.testing.expect(spectatorKeyFor(friends, "p-stranger") == .not_friend);
}

test "观战启动请求体与 AK 一致" {
    var buffer: [256]u8 = undefined;
    const body = try launchBody(&buffer, "puuid-1", "key-1");
    try std.testing.expectEqualStrings("{\"puuid\":\"puuid-1\",\"spectatorKey\":\"key-1\"}", body);
}

test "批量删除逐条回报，失败的带上原因" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writer.writeAll("{\"results\":[");
    var first = true;
    writeDeleteResult(&writer, &first, "a", true, "");
    writeDeleteResult(&writer, &first, "b", false, "客户端拒绝了这个请求");
    try writer.writeAll("]}");
    try std.testing.expectEqualStrings(
        "{\"results\":[{\"id\":\"a\",\"ok\":true,\"reason\":\"\"},{\"id\":\"b\",\"ok\":false,\"reason\":\"客户端拒绝了这个请求\"}]}",
        writer.buffered(),
    );
}

// 就地测试：这两个 DTO 是本模块私有的，搬到这里才能继续被 zig test 收集。
test "normalizes friend groups, friend-since dates and the spectate hint" {
    var state = backend.Runtime.init();
    const groups = "[{\"id\":7,\"name\":\"双排\",\"priority\":2}]";
    const friends =
        \\[{"id":"friend-id","puuid":"friend-puuid","summonerId":42,"gameName":"好友","gameTag":"CN1","icon":12,"groupId":7,"availability":"chat"},
        \\ {"id":"playing-id","puuid":"playing-puuid","summonerId":43,"gameName":"游戏中","gameTag":"CN1","icon":13,"groupId":7,"availability":"dnd","lol":{"gameStatus":"ingame","spectatorKey":"KEY-9"}}]
    ;
    const giftable = "[{\"summonerId\":42,\"friendsSince\":\"2025-08-29T10:00:00.000Z\"}]";
    var output: [4096]u8 = undefined;
    const result = try friendToolsDto(&state, groups, friends, giftable, &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.get("groups").?.array.items.len);
    const items = parsed.value.object.get("friends").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    const friend = items[0];
    try std.testing.expectEqualStrings("好友", friend.object.get("gameName").?.string);
    try std.testing.expectEqual(@as(i64, 7), friend.object.get("groupId").?.integer);
    try std.testing.expectEqualStrings("2025-08-29T10:00:00.000Z", friend.object.get("friendsSince").?.string);
    // 没有 `lol.spectatorKey` → 界面不该点亮「观战」。
    try std.testing.expectEqual(false, friend.object.get("canSpectate").?.bool);
    try std.testing.expectEqualStrings("", friend.object.get("gameStatus").?.string);
    // 在线且正在对局的好友才有密钥，观战按钮才有意义。
    const playing = items[1];
    try std.testing.expectEqual(true, playing.object.get("canSpectate").?.bool);
    try std.testing.expectEqualStrings("ingame", playing.object.get("gameStatus").?.string);
}

test "extracts the latest friend match timestamp" {
    var output: [1024]u8 = undefined;
    const result = try friendLastGameDto("friend-puuid", "{\"games\":[{\"gameCreation\":1625159473123}]}", &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("friend-puuid", parsed.value.object.get("puuid").?.string);
    try std.testing.expectEqualStrings("2021-07-01T17:11:13.123Z", parsed.value.object.get("lastGameAt").?.string);
}
