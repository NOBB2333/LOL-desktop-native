//! **可选**的对局录制：游戏进行中每 N 秒把 Live Client Data（本地 2999）的公开数据
//! 采一帧存下来，之后在对局页里按时间轴回放。
//!
//! 为什么要做：客户端只保留「最终装备 + 每局一条战绩汇总」，**中间过程看不到**——
//! 第 8 分钟谁多少刀、几个眼、几件装备，官方数据源里没有这些。本地 2999 接口在游戏
//! 进行中就能拿到（KDA、补刀、视野分、装备、等级、复活倒计时；本地玩家自己还有
//! `championStats` 的 AD/AP/护甲/血量），只要隔一段时间采一帧，打完就有一条时间轴。
//!
//! 拿不到的：**伤害**（接口里根本没有这个字段）、**装备购买的精确时刻**（没有
//! ITEM_PURCHASED / ITEM_SOLD 事件，只能靠轮询 `items[]` 做差分，精度就是采样间隔）。
//!
//! 风险与边界（用户要求「先做成可选的、默认不打开」）：
//! - **开关默认关**：关着时后台那一跳只比一次配置指纹，**不发任何请求**。
//! - 只在**真正在局内**（gameflow phase ∈ GameStart / InProgress / Reconnect）才采，
//!   采的是已有本地接口（实测 allgamedata 约 42ms / 70KB），**不走公网**。
//! - 每局帧数上限 `max_frames_per_game`（15s × 360 ≈ 90 分钟），只保留最近
//!   `kept_games` 局，更早的连帧一起删掉。单帧约 1~3KB。
//! - 只落本地 SQLite（`gameReplay` / `gameReplayMeta`），跟战局文件、公网都无关。
const std = @import("std");
const native_sdk = @import("native_sdk");
const storage = @import("storage");
const backend = @import("../backend.zig");
const build_options = @import("build_options");

/// 默认采样间隔（秒）。用户明确要 15 秒。
pub const default_interval_seconds: i64 = 15;
/// 允许的区间：比 5 秒更密没必要（一帧就是一次本地往返），比 120 秒更疏就看不出走势了。
pub const min_interval_seconds: i64 = 5;
pub const max_interval_seconds: i64 = 120;
/// 一局最多存多少帧。15 秒 × 360 = 90 分钟，够覆盖任何一局。
pub const max_frames_per_game: usize = 360;
/// 只保留最近几局。多了磁盘会慢慢涨，而且旧局本来就没人看。
pub const kept_games: usize = 3;
/// 键类型名。存放格式：`gameReplay` / `<gameId>:<6 位序号>`，序号补零让字典序 = 时间序。
pub const replay_kind = "gameReplay";
pub const replay_meta_kind = "gameReplayMeta";
/// 一帧的 JSON 上限：十个人各十几个字段，实测 1~3KB，留足余量。
const frame_capacity: usize = 16 * 1024;

/// `providers.recording` 的解析结果。缺失即默认关。
pub const Settings = struct {
    enabled: bool = false,
    interval_seconds: i64 = default_interval_seconds,
};

pub fn parseSettings(config_json: []const u8) Settings {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var settings = Settings{};
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), config_json, .{}) catch return settings;
    if (root != .object) return settings;
    const providers = root.object.get("providers") orelse return settings;
    if (providers != .object) return settings;
    const recording = providers.object.get("recording") orelse return settings;
    if (recording != .object) return settings;
    settings.enabled = backend.jsonBool(recording, "enabled");
    const interval = backend.jsonInt(recording, "intervalSeconds");
    if (interval > 0) {
        settings.interval_seconds = @max(min_interval_seconds, @min(max_interval_seconds, interval));
    }
    return settings;
}

/// 后台跑一跳。返回本跳是否真的存下了一帧。
///
/// 调用方是既有的自动化守护线程（约 1s 一次），节流在内部做，外部不用关心采样频率。
/// 开关关着时这一跳的全部成本 = 复制一次配置 + 算一次哈希。
pub fn captureTick(self: *backend.Runtime, io: std.Io) bool {
    if (self.mode != .live) return false;
    var config_buffer: [65536]u8 = undefined;
    const config_len = copyConfig(self, &config_buffer);
    const hash = std.hash.Wyhash.hash(0, config_buffer[0..config_len]);
    if (hash != self.recording_config_hash) {
        const settings = parseSettings(config_buffer[0..config_len]);
        self.recording_config_hash = hash;
        self.recording_wanted = settings.enabled;
        self.recording_interval_ms = settings.interval_seconds * 1000;
        // 刚打开开关就先采一帧，不用干等一个间隔。
        self.recording_last_frame_ms = 0;
    }
    if (!self.recording_wanted) return false;

    const now = backend.runtimeMonotonicMillis(self);
    if (self.recording_last_frame_ms > 0 and now - self.recording_last_frame_ms < self.recording_interval_ms) {
        return false;
    }
    // 无论采没采到都把节拍推一格：不在局内时每一跳都去问一次 LCU 是白花钱。
    self.recording_last_frame_ms = now;
    return captureFrame(self, io) catch false;
}

fn copyConfig(self: *backend.Runtime, buffer: []u8) usize {
    backend.lockBackendMutex(&self.command_mutex);
    defer self.command_mutex.unlock();
    const length = @min(self.config_len, buffer.len);
    @memcpy(buffer[0..length], self.config[0..length]);
    return length;
}

/// gameflow 里算「这一局真的在跑」的阶段。房间/选人都还没有 2999 可采。
fn isRecordingPhase(phase_json: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), phase_json, .{}) catch return false;
    if (parsed != .string) return false;
    for ([_][]const u8{ "GameStart", "InProgress", "Reconnect" }) |phase| {
        if (std.mem.eql(u8, parsed.string, phase)) return true;
    }
    return false;
}

fn captureFrame(self: *backend.Runtime, io: std.Io) !bool {
    var client = backend.discoverClient(self, io) catch return false;
    defer client.deinit();
    // 走 SSH 隧道时本地 2999 不在本机，采不到也没必要采。
    if (backend.runtimeConnectionIsSsh(self)) return false;
    const phase_json = client.get("/lol-gameflow/v1/gameflow-phase") catch return false;
    defer std.heap.page_allocator.free(phase_json);
    if (!isRecordingPhase(phase_json)) return false;

    // 英雄目录（名字 → id）用来给帧标上 `cid`，界面才画得出英雄头像。
    // `cachedGameAsset` 命中库里那份 24 小时的缓存，正常情况下不产生网络请求。
    const catalog = backend.cachedGameAsset(self, client, "champions", "/lol-game-data/assets/v1/champion-summary.json") catch null;
    defer if (catalog) |value| std.heap.page_allocator.free(value);

    var live_client = client;
    live_client.timeout_ms = @min(client.timeout_ms, build_options.lcu_live_probe_timeout_ms);
    const live = live_client.getLocalUrl(build_options.lcu_live_client_data_url) catch return false;
    defer std.heap.page_allocator.free(live);
    return appendFrame(self, live, catalog orelse "[]") catch false;
}

/// 解析一份 allgamedata，压成一帧存进 SQLite，并按局数上限回收旧局。
fn appendFrame(self: *backend.Runtime, live_json: []const u8, catalog_json: []const u8) !bool {
    const store = if (self.storage) |*value| value else return false;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = std.json.parseFromSliceLeaky(std.json.Value, allocator, live_json, .{}) catch return false;
    if (root != .object) return false;
    const game_data = root.object.get("gameData") orelse return false;
    if (game_data != .object) return false;
    const game_id = backend.jsonInt(game_data, "gameId");
    if (game_id <= 0) return false;

    const frame_buffer = try allocator.alloc(u8, frame_capacity);
    var writer = std.Io.Writer.fixed(frame_buffer);
    try writeFrame(&writer, self, root, game_data, game_id, catalog_json);
    const frame = writer.buffered();
    if (frame.len == 0) return false;

    // 序号按「这一局已经存了几帧」推，不按时间算：中途漏采也不会出现空洞。
    const meta_key = try std.fmt.allocPrint(allocator, "{d}", .{game_id});
    const existing_meta = store.get(replay_meta_kind, meta_key) catch null;
    defer if (existing_meta) |value| std.heap.page_allocator.free(value);
    const frame_count = if (existing_meta) |value| frameCountOf(value) else 0;
    if (frame_count >= max_frames_per_game) return false;

    const frame_key = try std.fmt.allocPrint(allocator, "{d}:{d:0>6}", .{ game_id, frame_count });
    store.put(replay_kind, frame_key, frame) catch return false;

    var meta_buffer: [1024]u8 = undefined;
    var meta_writer = std.Io.Writer.fixed(&meta_buffer);
    try meta_writer.print("{{\"gameId\":{d},\"frameCount\":{d},\"intervalSeconds\":{d},\"gameMode\":", .{
        game_id,
        frame_count + 1,
        @divTrunc(self.recording_interval_ms, 1000),
    });
    try backend.jsonString(&meta_writer, backend.jsonField(game_data, "gameMode"));
    try meta_writer.writeAll(",\"updatedAt\":");
    try backend.writeIsoTimestamp(&meta_writer, backend.runtimeNowMillis(self));
    try meta_writer.writeByte('}');
    store.put(replay_meta_kind, meta_key, meta_writer.buffered()) catch {};

    pruneOldGames(store, allocator);
    return true;
}

fn frameCountOf(meta_json: []const u8) usize {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), meta_json, .{}) catch return 0;
    const count = backend.jsonInt(parsed, "frameCount");
    return if (count > 0) @as(usize, @intCast(count)) else 0;
}

/// 只保留最近 `kept_games` 局：多出来的按「写入时间最旧」回收，连同它的帧一起删。
fn pruneOldGames(store: *storage.Store, allocator: std.mem.Allocator) void {
    const entries = store.list(allocator, replay_meta_kind) catch return;
    defer store.freeEntries(allocator, entries);
    if (entries.len <= kept_games) return;
    // `list` 已经是「写入时间新的在前」，所以尾部就是要回收的旧局。
    for (entries[kept_games..]) |entry| {
        const frame_count = frameCountOf(entry.value);
        var index: usize = 0;
        while (index < frame_count) : (index += 1) {
            var key_buffer: [96]u8 = undefined;
            const frame_key = std.fmt.bufPrint(&key_buffer, "{s}:{d:0>6}", .{ entry.key, index }) catch continue;
            store.remove(replay_kind, frame_key) catch {};
        }
        store.remove(replay_meta_kind, entry.key) catch {};
    }
}

fn writeFrame(writer: *std.Io.Writer, self: *backend.Runtime, root: std.json.Value, game_data: std.json.Value, game_id: i64, catalog_json: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const catalog = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), catalog_json, .{}) catch std.json.Value{ .null = {} };
    const players = root.object.get("allPlayers") orelse return;
    if (players != .array) return;

    try writer.writeAll("{\"t\":");
    try writeNumber(writer, game_data, "gameTime");
    try writer.print(",\"gameId\":{d},\"sampledAt\":", .{game_id});
    try backend.writeIsoTimestamp(writer, backend.runtimeNowMillis(self));
    try writer.writeAll(",\"players\":[");
    var written: usize = 0;
    for (players.array.items) |player| {
        if (player != .object) continue;
        if (written > 0) try writer.writeByte(',');
        try writeFramePlayer(writer, player, catalog);
        written += 1;
    }
    try writer.writeAll("],\"me\":");
    try writeActivePlayer(writer, root);
    try writer.writeByte('}');
}

fn writeFramePlayer(writer: *std.Io.Writer, player: std.json.Value, catalog: std.json.Value) !void {
    const scores = player.object.get("scores") orelse std.json.Value{ .null = {} };
    try writer.writeAll("{\"puuid\":");
    try backend.jsonString(writer, backend.jsonField(player, "puuid"));
    try writer.writeAll(",\"rid\":");
    try backend.jsonString(writer, backend.jsonField(player, "riotId"));
    try writer.writeAll(",\"team\":");
    try backend.jsonString(writer, backend.jsonField(player, "team"));
    try writer.writeAll(",\"champ\":");
    try backend.jsonString(writer, backend.jsonField(player, "championName"));
    // 数字 id 给界面画头像用：Live Client 只给名字，靠目录反查一次。
    try writer.print(",\"cid\":{d}", .{backend.liveChampionId(player, catalog)});
    try writer.writeAll(",\"pos\":");
    try backend.jsonString(writer, backend.jsonField(player, "position"));
    try writer.print(",\"lvl\":{d},\"k\":{d},\"d\":{d},\"a\":{d},\"cs\":{d},\"ward\":", .{
        backend.jsonInt(player, "level"),
        backend.jsonInt(scores, "kills"),
        backend.jsonInt(scores, "deaths"),
        backend.jsonInt(scores, "assists"),
        backend.jsonInt(scores, "creepScore"),
    });
    try writeNumber(writer, scores, "wardScore");
    try writer.print(",\"dead\":{s},\"respawn\":", .{if (backend.jsonBool(player, "isDead")) "true" else "false"});
    try writeNumber(writer, player, "respawnTimer");
    try writer.print(",\"bot\":{s}", .{if (backend.jsonBool(player, "isBot")) "true" else "false"});
    try writer.writeAll(",\"items\":[");
    if (player.object.get("items")) |items| if (items == .array) {
        var first = true;
        for (items.array.items) |item| {
            const id = backend.jsonInt(item, "itemID");
            // 空槽位的 itemID/count 都是 0；只有 count > 0 才是真的戴着这件装备。
            if (id <= 0 or backend.jsonInt(item, "count") <= 0) continue;
            if (!first) try writer.writeByte(',');
            try writer.print("{d}", .{id});
            first = false;
        }
    };
    try writer.writeAll("],\"spells\":[");
    if (player.object.get("summonerSpells")) |spells| if (spells == .object) {
        var first = true;
        for ([_][]const u8{ "summonerSpellOne", "summonerSpellTwo" }) |slot| {
            const spell = spells.object.get(slot) orelse continue;
            if (spell != .object) continue;
            if (!first) try writer.writeByte(',');
            try backend.jsonString(writer, backend.jsonField(spell, "displayName"));
            first = false;
        }
    };
    try writer.writeAll("]}");
}

/// 本地玩家自己那份：`activePlayer.championStats` 里有 AD/AP/护甲/血量这些
/// **只有本人**才拿得到的字段，顺手一起存下来。
fn writeActivePlayer(writer: *std.Io.Writer, root: std.json.Value) !void {
    const active = root.object.get("activePlayer") orelse std.json.Value{ .null = {} };
    if (active != .object) {
        try writer.writeAll("null");
        return;
    }
    const stats = active.object.get("championStats") orelse std.json.Value{ .null = {} };
    try writer.writeAll("{\"rid\":");
    try backend.jsonString(writer, backend.jsonField(active, "riotId"));
    try writer.writeAll(",\"gold\":");
    try writeNumber(writer, active, "currentGold");
    try writer.print(",\"lvl\":{d}", .{backend.jsonInt(active, "level")});
    try writer.writeAll(",\"ad\":");
    try writeNumber(writer, stats, "attackDamage");
    try writer.writeAll(",\"ap\":");
    try writeNumber(writer, stats, "abilityPower");
    try writer.writeAll(",\"armor\":");
    try writeNumber(writer, stats, "armor");
    try writer.writeAll(",\"mr\":");
    try writeNumber(writer, stats, "magicResist");
    try writer.writeAll(",\"ms\":");
    try writeNumber(writer, stats, "moveSpeed");
    try writer.writeAll(",\"hp\":");
    try writeNumber(writer, stats, "currentHealth");
    try writer.writeAll(",\"maxHp\":");
    try writeNumber(writer, stats, "maxHealth");
    try writer.writeByte('}');
}

/// 数字字段：整数按整数写，小数保留一位（`gameTime` 是小数、`wardScore` 也可能是）。
fn writeNumber(writer: *std.Io.Writer, value: std.json.Value, name: []const u8) !void {
    if (value != .object) return writer.writeAll("0");
    const field = value.object.get(name) orelse return writer.writeAll("0");
    switch (field) {
        .integer => |number| try writer.print("{d}", .{number}),
        .float => |number| try writer.print("{d:.1}", .{number}),
        .number_string => |text| try writer.writeAll(text),
        else => try writer.writeAll("0"),
    }
}

/// `lol.get_game_recording` —— payload：`{gameId}` → `{gameId, intervalSeconds, frames[]}`。
///
/// 没录到就是空数组，不是错误：这个功能是可选开关，界面只要据此决定要不要画时间轴。
pub fn getGameRecording(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = backend.runtime(context);
    const payload_json = backend.parsePayload(struct { gameId: i64 = 0 }, invocation.request.payload) catch return error.InvalidRequest;
    defer payload_json.deinit();
    const game_id = payload_json.value.gameId;
    if (game_id <= 0) return error.InvalidRequest;
    const store = if (self.storage) |*value| value else return error.StorageUnavailable;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const meta_key = std.fmt.allocPrint(allocator, "{d}", .{game_id}) catch return error.OutOfMemory;
    const meta = store.get(replay_meta_kind, meta_key) catch null;
    defer if (meta) |value| std.heap.page_allocator.free(value);

    var frame_count: usize = 0;
    var interval_seconds: i64 = default_interval_seconds;
    if (meta) |value| {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, value, .{}) catch std.json.Value{ .null = {} };
        const count = backend.jsonInt(parsed, "frameCount");
        if (count > 0) frame_count = @min(@as(usize, @intCast(count)), max_frames_per_game);
        const interval = backend.jsonInt(parsed, "intervalSeconds");
        if (interval > 0) interval_seconds = interval;
    }

    var writer = std.Io.Writer.fixed(output);
    try writer.print("{{\"gameId\":{d},\"intervalSeconds\":{d},\"frames\":[", .{ game_id, interval_seconds });
    var written: usize = 0;
    var index: usize = 0;
    while (index < frame_count) : (index += 1) {
        var key_buffer: [96]u8 = undefined;
        const frame_key = std.fmt.bufPrint(&key_buffer, "{d}:{d:0>6}", .{ game_id, index }) catch continue;
        const frame = store.get(replay_kind, frame_key) catch null orelse continue;
        defer std.heap.page_allocator.free(frame);
        if (frame.len == 0) continue;
        if (written > 0) try writer.writeByte(',');
        try writer.writeAll(frame);
        written += 1;
    }
    try writer.writeAll("]}");
    return writer.buffered();
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "录制开关默认关，字段缺失一律当关" {
    try testing.expect(!parseSettings("{}").enabled);
    try testing.expect(!parseSettings("{\"providers\":{}}").enabled);
    try testing.expect(!parseSettings("{\"providers\":{\"recording\":{}}}").enabled);
    try testing.expect(!parseSettings("{\"providers\":{\"recording\":{\"enabled\":false}}}").enabled);
    try testing.expectEqual(default_interval_seconds, parseSettings("{}").interval_seconds);
    try testing.expect(parseSettings("{\"providers\":{\"recording\":{\"enabled\":true}}}").enabled);
}

test "采样间隔被夹在允许区间内" {
    try testing.expectEqual(min_interval_seconds, parseSettings("{\"providers\":{\"recording\":{\"intervalSeconds\":1}}}").interval_seconds);
    try testing.expectEqual(@as(i64, 30), parseSettings("{\"providers\":{\"recording\":{\"intervalSeconds\":30}}}").interval_seconds);
    try testing.expectEqual(max_interval_seconds, parseSettings("{\"providers\":{\"recording\":{\"intervalSeconds\":9999}}}").interval_seconds);
}

test "帧里只收 KDA/视野/装备/等级这些能拿到的字段，不编造伤害" {
    const live =
        "{\"gameData\":{\"gameId\":901079838957,\"gameTime\":312.5,\"gameMode\":\"KIWI\"}," ++
        "\"activePlayer\":{\"riotId\":\"我#0001\",\"currentGold\":1234.7,\"level\":11," ++
        "\"championStats\":{\"attackDamage\":123.4,\"abilityPower\":0,\"armor\":55.5,\"magicResist\":32.1,\"moveSpeed\":380,\"currentHealth\":1500.5,\"maxHealth\":2100}}," ++
        "\"allPlayers\":[{\"puuid\":\"self\",\"riotId\":\"我#0001\",\"team\":\"CHAOS\",\"championName\":\"Swain\",\"position\":\"MIDDLE\"," ++
        "\"level\":11,\"isDead\":false,\"respawnTimer\":0,\"isBot\":false," ++
        "\"scores\":{\"kills\":3,\"deaths\":1,\"assists\":5,\"creepScore\":120,\"wardScore\":7}," ++
        "\"items\":[{\"itemID\":3153,\"count\":1,\"slot\":0},{\"itemID\":0,\"count\":0,\"slot\":1}]," ++
        "\"summonerSpells\":{\"summonerSpellOne\":{\"displayName\":\"闪现\"},\"summonerSpellTwo\":{\"displayName\":\"点燃\"}}}]}";
    var state = backend.Runtime.init();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, allocator, live, .{});
    const game_data = root.object.get("gameData").?;
    const buffer = try allocator.alloc(u8, frame_capacity);
    var writer = std.Io.Writer.fixed(buffer);
    const catalog = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "[{\"id\":50,\"name\":\"Swain\",\"alias\":\"Swain\"}]", .{});
    _ = catalog;
    try writeFrame(&writer, &state, root, game_data, 901079838957, "[{\"id\":50,\"name\":\"斯维因\",\"alias\":\"Swain\"}]");
    const frame = writer.buffered();
    // 该有的都有。
    try testing.expect(std.mem.indexOf(u8, frame, "\"t\":312.5") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "\"rid\":\"我#0001\"") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "\"k\":3,\"d\":1,\"a\":5,\"cs\":120,\"ward\":7") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "\"items\":[3153]") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "\"spells\":[\"闪现\",\"点燃\"]") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "\"champ\":\"Swain\"") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "\"cid\":50") != null);
    // 只有本地玩家才有 championStats。
    try testing.expect(std.mem.indexOf(u8, frame, "\"ad\":123.4") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "\"maxHp\":2100") != null);
    // 空槽位不能被当成装备写进时间轴。
    try testing.expect(std.mem.indexOf(u8, frame, "3153,0") == null);
    // 伤害字段接口里没有，绝不能凭空造一个。
    try testing.expect(std.mem.indexOf(u8, frame, "damage") == null);
}

test "局外的阶段不采" {
    try testing.expect(isRecordingPhase("\"InProgress\""));
    try testing.expect(isRecordingPhase("\"GameStart\""));
    try testing.expect(isRecordingPhase("\"Reconnect\""));
    try testing.expect(!isRecordingPhase("\"Lobby\""));
    try testing.expect(!isRecordingPhase("\"Matchmaking\""));
    try testing.expect(!isRecordingPhase("\"ChampSelect\""));
    try testing.expect(!isRecordingPhase("\"EndOfGame\""));
    try testing.expect(!isRecordingPhase("\"None\""));
    try testing.expect(!isRecordingPhase("{}"));
}
