//! 好友工具 IPC handler：好友列表 / 最近一局 / 删除好友（单个与批量）/ 观战。
//!
//! 依赖 `backend.zig` 的共享基础设施（Runtime、LCU 客户端发现、JSON helper）。
//! `historyGames` / `unwrapHistoryGame` 属于跨模块的历史数据整形，仍留在共享层。
const std = @import("std");
const native_sdk = @import("native_sdk");
const lcu = @import("lcu");
const storage = @import("storage");
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
///
/// 删之前会先把**客户端当前的那条好友记录**抄进本地回收站（见 `archiveDeletedFriend`）：
/// 删除是不可逆的，一旦手滑，本地连「刚才删的是谁」都说不出来。
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
    // 必须在删除**之前**取：删完这条记录就没了，回收站也就没了内容。
    const friends_json = client.get("/lol-chat/v1/friends") catch null;
    defer if (friends_json) |value| std.heap.page_allocator.free(value);
    try backend.verifyActionAccount(self, client);
    const response = try client.delete(path);
    std.heap.page_allocator.free(response);
    archiveDeletedFriend(self, friends_json, payload.id);
    return std.fmt.bufPrint(output, "{{\"deleted\":true}}", .{});
}

/// 被删好友在本地库里的存放位置。
///
/// 复用 `storage.zig` 唯一那张 `(kind,key,value,updated_at)` 表：value 直接就是
/// 一条**已经拼好的 JSON 记录**，读的时候不需要再解析重组，也不怕字段漂移。
const deleted_friend_kind = "deletedFriend";

/// 回收站最多回给界面多少条（按删除时间新的在前）。
///
/// 只是防止删了几千个好友之后把 1MB 的结果缓冲塞满；真正的删除量远小于此数。
const deleted_friend_read_limit: usize = 300;

/// 把即将被删掉的好友整条记录写进回收站。
///
/// 记录来源是**客户端刚返回的好友列表**，而不是前端传上来的数据：删除不可逆，
/// 存档要是和真实好友对不上，这个回收站就成了假的后悔药。取不到列表（网络抖动）
/// 就只是没有存档，绝不因此拦住删除本身。
fn archiveDeletedFriend(self: *backend.Runtime, friends_json: ?[]const u8, id: []const u8) void {
    const raw = friends_json orelse return;
    const store = if (self.storage) |*value| value else return;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const friends = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), raw, .{}) catch return;
    if (friends != .array) return;
    for (friends.array.items) |friend| {
        if (friend != .object) continue;
        if (!std.mem.eql(u8, backend.jsonField(friend, "id"), id)) continue;
        var buffer: [1024]u8 = undefined;
        const record = deletedFriendRecord(&buffer, friend, backend.runtimeNowMillis(self)) catch return;
        store.put(deleted_friend_kind, id, record) catch {};
        return;
    }
}

/// 一条回收站记录：只留「这个人是谁 + 什么时候删的」。
///
/// 刻意**不**抄 `availability` / `gameStatus` 这类实时状态——它们在回收站里早就过期了，
/// 留着只会让人以为「显示游戏中，其实根本没在线」。
fn deletedFriendRecord(buffer: []u8, friend: std.json.Value, now_millis: i64) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writer.writeAll("{\"id\":");
    try backend.jsonString(&writer, backend.jsonField(friend, "id"));
    try writer.writeAll(",\"puuid\":");
    try backend.jsonString(&writer, backend.jsonField(friend, "puuid"));
    try writer.print(",\"summonerId\":{d},\"gameName\":", .{backend.jsonInt(friend, "summonerId")});
    try backend.jsonString(&writer, if (backend.jsonField(friend, "gameName").len > 0) backend.jsonField(friend, "gameName") else backend.jsonField(friend, "name"));
    try writer.writeAll(",\"gameTag\":");
    try backend.jsonString(&writer, backend.jsonField(friend, "gameTag"));
    try writer.print(",\"icon\":{d},\"groupId\":{d},\"deletedAt\":", .{ backend.jsonInt(friend, "icon"), backend.jsonInt(friend, "groupId") });
    try backend.writeIsoTimestamp(&writer, now_millis);
    try writer.writeByte('}');
    return writer.buffered();
}

/// `lol.get_deleted_friends` —— 回收站内容（本地存档，不需要客户端在线）。
pub fn getDeletedFriends(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = backend.runtime(context);
    _ = invocation;
    const empty = "{\"friends\":[]}";
    const store = if (self.storage) |*value| value else return std.fmt.bufPrint(output, "{s}", .{empty});
    const entries = store.list(std.heap.page_allocator, deleted_friend_kind) catch return std.fmt.bufPrint(output, "{s}", .{empty});
    defer storage.Store.freeEntries(std.heap.page_allocator, entries);
    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll("{\"friends\":[");
    var first = true;
    for (entries) |entry| {
        if (!first and writer.buffered().len + entry.value.len + 3 > output.len) break;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.writeAll(entry.value);
    }
    try writer.writeAll("]}");
    return writer.buffered();
}

/// `lol.restore_friend` —— 回收站里的动作，两种语义由 `addBack` 决定：
///
/// - `addBack = false`：只把这条存档划掉（「我确认不要了」），不动客户端。
/// - `addBack = true`：先向对方发一条好友申请，成功后再划掉存档。
///
/// ⚠️ 这是**发好友申请**（`POST /lol-chat/v2/friend-requests`，body 抄 AK 的
/// `ChatHttpApi.friendRequests`：`{gameName, tagLine, gameTag}`），**不是**直接恢复好友关系。
/// 删除是单方面的，加回来必须对方同意；失败时存档保留，可以再试。
pub fn restoreFriend(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = backend.runtime(context);
    const parsed = backend.parsePayload(struct { id: []const u8 = "", add_back: bool = false }, invocation.request.payload) catch return error.InvalidRequest;
    defer parsed.deinit();
    const id = parsed.value.id;
    if (id.len == 0) return error.InvalidRequest;
    const store = if (self.storage) |*value| value else return error.StorageUnavailable;
    const stored = (store.get(deleted_friend_kind, id) catch null) orelse return error.FriendNotArchived;
    defer std.heap.page_allocator.free(stored);

    if (!parsed.value.add_back) {
        store.remove(deleted_friend_kind, id) catch return error.QueryFailed;
        return restoreResult(output, true, "", false, "", "");
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const record = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), stored, .{}) catch return error.LcuInvalidResponse;
    const game_name = backend.jsonField(record, "gameName");
    const game_tag = backend.jsonField(record, "gameTag");
    if (game_name.len == 0) return restoreResult(output, false, "这条存档里没有名字，无法发送好友申请", false, "", "");

    if (self.mode != .live) return restoreResult(output, false, "没连上客户端", false, game_name, game_tag);
    const io = self.io orelse return restoreResult(output, false, "没连上客户端", false, game_name, game_tag);
    var client = backend.discoverClient(self, io) catch return restoreResult(output, false, "没连上客户端", false, game_name, game_tag);
    defer client.deinit();
    var body_buffer: [1024]u8 = undefined;
    const body = friendRequestBody(&body_buffer, game_name, game_tag) catch return restoreResult(output, false, "名字过长", false, game_name, game_tag);
    const response = client.post("/lol-chat/v2/friend-requests", body) catch
        return restoreResult(output, false, "客户端拒绝了这条好友申请（可能对方已经是好友，或名字里有特殊字符）", false, game_name, game_tag);
    std.heap.page_allocator.free(response);
    store.remove(deleted_friend_kind, id) catch {};
    return restoreResult(output, true, "", true, game_name, game_tag);
}

/// 好友申请请求体。字段名对齐 AK 的 `ChatHttpApi.friendRequests`：
/// `tagLine` 与 `gameTag` 是同一个值的两个名字，两个都要给。
fn friendRequestBody(buffer: []u8, game_name: []const u8, tag_line: []const u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writer.writeAll("{\"gameName\":");
    try backend.jsonString(&writer, game_name);
    try writer.writeAll(",\"tagLine\":");
    try backend.jsonString(&writer, tag_line);
    try writer.writeAll(",\"gameTag\":");
    try backend.jsonString(&writer, tag_line);
    try writer.writeByte('}');
    return writer.buffered();
}

fn restoreResult(output: []u8, ok: bool, reason: []const u8, added: bool, game_name: []const u8, game_tag: []const u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    try writer.print("{{\"ok\":{s},\"reason\":", .{if (ok) "true" else "false"});
    try backend.jsonString(&writer, reason);
    try writer.print(",\"added\":{s},\"gameName\":", .{if (added) "true" else "false"});
    try backend.jsonString(&writer, game_name);
    try writer.writeAll(",\"gameTag\":");
    try backend.jsonString(&writer, game_tag);
    try writer.writeByte('}');
    return writer.buffered();
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
    // 整批只取一次好友列表，删之前取（删完这批记录就没了）。存档失败不影响删除。
    const friends_json = client.get("/lol-chat/v1/friends") catch null;
    defer if (friends_json) |value| std.heap.page_allocator.free(value);
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
        archiveDeletedFriend(self, friends_json, id);
        writeDeleteResult(&writer, &first, id, true, "");
        deleted += 1;
    }
    try writer.print("],\"deleted\":{d},\"failed\":{d}}}", .{ deleted, failed });
    return writer.buffered();
}

/// `lol.spectate` —— 观战。
///
/// `POST /lol-spectator/v1/spectate/launch`，两条路线，**先试已证实可用的好友路线**：
///
/// 1. **好友路线**：body `{"puuid":..,"spectatorKey":..}`（对齐 AK
///    `SpectatorHttpApi.launchSpectator`，路径与字段名都别改）。`spectatorKey` 挂在
///    好友对象的 `lol.spectatorKey` 上，客户端只在好友「在线且正在游戏」时才下发
///    （AK 的 `isFriendSpectatable` 还额外要求 `availability === "dnd"`）。
/// 2. **观察者模式**：body 不带 `spectatorKey`，只给 `allowObserveMode: "ALL"`。
///    非好友、或好友不在局内时走这条——这正是「只输一个 ID 就能观战」的由来。
///    能否生效取决于对方是否允许被观战 + 区服策略，失败时按普通错误回报。
///
/// 入参二选一：`query`（`名字#标签`，先解析成 puuid）或 `puuid`（直接给）。
pub fn spectate(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = backend.runtime(context);
    const parsed = backend.parsePayload(struct { puuid: []const u8 = "", query: []const u8 = "" }, invocation.request.payload) catch return error.InvalidRequest;
    defer parsed.deinit();
    const query = std.mem.trim(u8, parsed.value.query, " \t\r\n");
    if (parsed.value.puuid.len == 0 and query.len == 0) return error.InvalidRequest;
    if (self.mode != .live) return spectateResult(output, false, "没连上客户端", "");
    const io = self.io orelse return spectateResult(output, false, "没连上客户端", "");
    var client = backend.discoverClient(self, io) catch return spectateResult(output, false, "没连上客户端", "");
    defer client.deinit();

    // 给了 `名字#标签` 就先在本大区解析成 puuid；直接给了 puuid 就跳过。
    var puuid_buffer: [256]u8 = undefined;
    const puuid = if (parsed.value.puuid.len > 0)
        parsed.value.puuid
    else
        resolveSummonerPuuid(client, query, &puuid_buffer) catch
            return spectateResult(output, false, "没找到这位召唤师：需要完整的「名字#标签」，且只能解析当前大区的玩家", "");

    const friends_json = client.get("/lol-chat/v1/friends") catch null;
    defer if (friends_json) |value| std.heap.page_allocator.free(value);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const friends = if (friends_json) |value|
        std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), value, .{}) catch std.json.Value{ .null = {} }
    else
        std.json.Value{ .null = {} };

    var body_buffer: [1024]u8 = undefined;
    switch (spectatorKeyFor(friends, puuid)) {
        // 好友且拿到了密钥 → 走这条（行为与改造前一致，是已验证能用的路线）。
        .key => |value| {
            const body = launchBody(&body_buffer, puuid, value) catch return spectateResult(output, false, "观战密钥过长", "");
            const response = client.post("/lol-spectator/v1/spectate/launch", body) catch
                return spectateResult(output, false, "客户端拒绝了观战请求", "");
            std.heap.page_allocator.free(response);
            return spectateResult(output, true, "", "buddy");
        },
        // 非好友，或好友但没密钥（在挂机/没在局内）→ 落到观察者模式再试一次。
        .no_key, .not_friend => {},
    }

    const observe_body = observeLaunchBody(&body_buffer, puuid) catch return spectateResult(output, false, "玩家标识过长", "");
    const rejected_reason = if (spectatorKeyFor(friends, puuid) == .no_key)
        "观察者模式未生效：这位好友现在不在对局中"
    else
        "观察者模式未生效：对方可能不在对局中，或未允许被观战";
    const response = client.post("/lol-spectator/v1/spectate/launch", observe_body) catch
        return spectateResult(output, false, rejected_reason, "observe");
    std.heap.page_allocator.free(response);
    return spectateResult(output, true, "", "observe");
}

/// 把 `名字#标签` 解析成 puuid（**只在当前大区**，本地没有跨区索引）。
///
/// ⚠️ LCU 的 `summoners?name=` 遇到解析不了的输入**会忽略参数、直接返回当前登录账号**，
/// 所以拿到结果后必须把 `gameName` / `tagLine` 跟原始查询比对一次，
/// 不匹配就当作「查无此人」——否则会把「搜不到」误判成「就是你自己」。
fn resolveSummonerPuuid(client: lcu.Client, query: []const u8, output: []u8) ![]const u8 {
    var encoded_buffer: [1536]u8 = undefined;
    const encoded = try backend.percentEncodeQuery(query, &encoded_buffer);
    var path_buffer: [1792]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/lol-summoner/v1/summoners?name={s}", .{encoded});
    const response = try client.get(path);
    defer std.heap.page_allocator.free(response);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), response, .{}) catch return error.LcuInvalidResponse;
    const summoner = if (root == .array and root.array.items.len > 0) root.array.items[0] else root;
    if (summoner != .object) return error.SummonerNotFound;
    const game_name = backend.jsonField(summoner, "gameName");
    if (game_name.len == 0) return error.SummonerNotFound;
    const tag_line = backend.jsonField(summoner, "tagLine");
    // 没给标签时（`名字` 直接查）只比名字，够用且不会误伤。
    const wants_tag = std.mem.indexOfScalar(u8, query, '#') != null;
    if (!std.ascii.eqlIgnoreCase(game_name, gameNamePart(query))) return error.SummonerNotFound;
    if (wants_tag and !std.ascii.eqlIgnoreCase(tag_line, tagLinePart(query))) return error.SummonerNotFound;
    const puuid = backend.jsonField(summoner, "puuid");
    if (puuid.len == 0 or puuid.len > output.len) return error.SummonerNotFound;
    @memcpy(output[0..puuid.len], puuid);
    return output[0..puuid.len];
}

fn gameNamePart(query: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, query, '#')) |index| return std.mem.trim(u8, query[0..index], " \t");
    return std.mem.trim(u8, query, " \t");
}

fn tagLinePart(query: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, query, '#')) |index| return std.mem.trim(u8, query[index + 1 ..], " \t");
    return "";
}

/// 观察者模式的启动体：**不带 `spectatorKey`**，所以不要求对方是好友。
///
/// 取自开源项目 `mayiflex/LeagueSpectator`（C#，按「名字#标签」观战）：
/// `{"allowObserveMode":"ALL","dropInSpectateGameId":"","gameQueueType":"","puuid":...}`。
fn observeLaunchBody(buffer: []u8, puuid: []const u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writer.writeAll("{\"allowObserveMode\":\"ALL\",\"dropInSpectateGameId\":\"\",\"gameQueueType\":\"\",\"puuid\":");
    try backend.jsonString(&writer, puuid);
    try writer.writeByte('}');
    return writer.buffered();
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

/// `route` 告诉界面这次是哪条路成功的：`"buddy"`（好友密钥）/ `"observe"`（观察者模式）/
/// `""`（失败时无意义）。界面用它给一句「走的是观察者模式」之类的提示。
fn spectateResult(output: []u8, ok: bool, reason: []const u8, route: []const u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    try writer.print("{{\"ok\":{s},\"reason\":", .{if (ok) "true" else "false"});
    try backend.jsonString(&writer, reason);
    try writer.writeAll(",\"route\":");
    try backend.jsonString(&writer, route);
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

test "观察者模式启动体不带 spectatorKey，字段与 LeagueSpectator 一致" {
    var buffer: [256]u8 = undefined;
    const body = try observeLaunchBody(&buffer, "puuid-2");
    try std.testing.expectEqualStrings(
        "{\"allowObserveMode\":\"ALL\",\"dropInSpectateGameId\":\"\",\"gameQueueType\":\"\",\"puuid\":\"puuid-2\"}",
        body,
    );
    // 这是它和好友路线的唯一区别：没有密钥，所以不要求对方是好友。
    try std.testing.expect(std.mem.indexOf(u8, body, "spectatorKey") == null);
}

test "名字#标签 按第一个 # 切分，缺标签时只认名字" {
    try std.testing.expectEqualStrings("张三", gameNamePart("张三#CN1"));
    try std.testing.expectEqualStrings("CN1", tagLinePart("张三#CN1"));
    // 名字里带空格要保留首尾裁剪后的内容
    try std.testing.expectEqualStrings("Long Name", gameNamePart(" Long Name #TAG "));
    try std.testing.expectEqualStrings("TAG", tagLinePart(" Long Name #TAG "));
    // 只给名字：标签为空 → 调用方据此跳过标签比对
    try std.testing.expectEqualStrings("张三", gameNamePart("张三"));
    try std.testing.expectEqualStrings("", tagLinePart("张三"));
    // 名字本身含 # 时只按第一个切（Riot ID 不允许，但别静默出错）
    try std.testing.expectEqualStrings("a", gameNamePart("a#b#c"));
    try std.testing.expectEqualStrings("b#c", tagLinePart("a#b#c"));
}

test "观战结果带上走的哪条路线" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"ok\":true,\"reason\":\"\",\"route\":\"observe\"}",
        try spectateResult(&buffer, true, "", "observe"),
    );
    var buffer2: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"ok\":false,\"reason\":\"没连上客户端\",\"route\":\"\"}",
        try spectateResult(&buffer2, false, "没连上客户端", ""),
    );
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

test "回收站记录只留身份与删除时间，不抄实时状态" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const friend = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\{"id":"fid-1","puuid":"puuid-1","summonerId":42,"gameName":"张三","gameTag":"CN1","icon":3494,
        \\ "groupId":7,"availability":"dnd","lol":{"gameStatus":"ingame","spectatorKey":"KEY"}}
    , .{});
    var buffer: [512]u8 = undefined;
    const record = try deletedFriendRecord(&buffer, friend, 1625159473123);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, record, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("张三", parsed.value.object.get("gameName").?.string);
    try std.testing.expectEqualStrings("CN1", parsed.value.object.get("gameTag").?.string);
    try std.testing.expectEqual(@as(i64, 3494), parsed.value.object.get("icon").?.integer);
    try std.testing.expectEqualStrings("2021-07-01T17:11:13.123Z", parsed.value.object.get("deletedAt").?.string);
    // 实时状态不该进存档：它明天就是错的。
    try std.testing.expect(parsed.value.object.get("availability") == null);
    try std.testing.expect(parsed.value.object.get("gameStatus") == null);
}

test "好友申请请求体与 AK 的 ChatHttpApi.friendRequests 一致" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"gameName\":\"张三\",\"tagLine\":\"CN1\",\"gameTag\":\"CN1\"}",
        try friendRequestBody(&buffer, "张三", "CN1"),
    );
    // 名字里有引号/反斜杠时必须转义，否则客户端会 400。
    var quoted: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"gameName\":\"a\\\"b\",\"tagLine\":\"T\",\"gameTag\":\"T\"}",
        try friendRequestBody(&quoted, "a\"b", "T"),
    );
}

test "回收站：写入后能列出、能单条移除，且只影响被删的那条" {
    var state = backend.Runtime.init();
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, ":memory:");
    defer store.deinit();
    state.storage = store;
    defer state.storage = null;

    const friends =
        \\[{"id":"fid-1","puuid":"puuid-1","summonerId":41,"gameName":"甲","gameTag":"CN1","icon":1,"groupId":7},
        \\ {"id":"fid-2","puuid":"puuid-2","summonerId":42,"gameName":"乙","gameTag":"CN2","icon":2,"groupId":7}]
    ;
    archiveDeletedFriend(&state, friends, "fid-1");
    archiveDeletedFriend(&state, friends, "fid-2");
    // 名单里没有的 id 不该凭空造出记录。
    archiveDeletedFriend(&state, friends, "fid-9");
    archiveDeletedFriend(&state, null, "fid-1");

    var output: [2048]u8 = undefined;
    const listed = try getDeletedFriends(&state, undefined, &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, listed, .{});
    defer parsed.deinit();
    const items = parsed.value.object.get("friends").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), items.len);

    try store.remove(deleted_friend_kind, "fid-1");
    var second_output: [2048]u8 = undefined;
    const after = try getDeletedFriends(&state, undefined, &second_output);
    const after_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, after, .{});
    defer after_parsed.deinit();
    const remaining = after_parsed.value.object.get("friends").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), remaining.len);
    try std.testing.expectEqualStrings("乙", remaining[0].object.get("gameName").?.string);
}

test "回收站：没有本地库时回空列表而不是报错" {
    var state = backend.Runtime.init();
    var output: [128]u8 = undefined;
    try std.testing.expectEqualStrings("{\"friends\":[]}", try getDeletedFriends(&state, undefined, &output));
}

test "恢复结果 DTO 带上名字与是否真的发出了好友申请" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"ok\":true,\"reason\":\"\",\"added\":true,\"gameName\":\"甲\",\"gameTag\":\"CN1\"}",
        try restoreResult(&buffer, true, "", true, "甲", "CN1"),
    );
    var buffer2: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"ok\":false,\"reason\":\"没连上客户端\",\"added\":false,\"gameName\":\"甲\",\"gameTag\":\"CN1\"}",
        try restoreResult(&buffer2, false, "没连上客户端", false, "甲", "CN1"),
    );
}
