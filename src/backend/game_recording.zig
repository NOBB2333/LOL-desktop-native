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
//! - 每局帧数上限 `max_frames_per_game`，只保留最近 `kept_games` 局，更早的连帧一起删掉。
//!   单帧约 1~3KB（十人各十几个字段）。默认间隔 5 秒 = 一局最多 720 帧 ≈ 1~2MB，
//!   三局上限约 3~6MB，所以**不需要定时清理**。
//! - 只落本地 SQLite（`gameReplay` / `gameReplayMeta`），跟战局文件、公网都无关。
const std = @import("std");
const native_sdk = @import("native_sdk");
const storage = @import("storage");
const backend = @import("../backend.zig");
const build_options = @import("build_options");

/// 默认采样间隔（秒）。用户明确要 **5 秒**（原先是 15 秒），并且要能在设置里自己调。
pub const default_interval_seconds: i64 = 5;
/// 允许的区间：比 5 秒更密没必要（一帧就是一次本地往返，2999 接口虽然便宜但也没必要更密，
/// 而且 `items[]` 差分只在装备变化上才有意义）；比 120 秒更疏就看不出走势了。
pub const min_interval_seconds: i64 = 5;
pub const max_interval_seconds: i64 = 120;
/// 一局最多存多少帧。间隔默认 5 秒，720 帧 = 60 分钟，够覆盖任何一局（超过 60 分钟的
/// 极端对局只保留前 60 分钟）；按用户把间隔调成 30 秒算，也就是 6 小时的余量。
pub const max_frames_per_game: usize = 720;
/// 只保留最近几局。多了磁盘会慢慢涨，而且旧局本来就没人看。
pub const kept_games: usize = 3;
/// 录制的保留期（天）。**0 = 永久保留**，默认 30 天——用户明确要求「老旧的录制自动清理，
/// 比如说一个月前」，同时又要能自己选 3 天 / 7 天 / 一个月 / 永久。与前端
/// `utils/config.ts` 的 `defaultRecordingRetentionDays` 必须一致。
pub const default_retention_days: i64 = 30;
/// 保留期的上限（10 年）。再大就等于永久，但没有 0 那种「一次都不清」的语义，
/// 这样界面给个超大的数字也不会把清理逻辑彻底关掉。
pub const max_retention_days: i64 = 3650;
/// 键类型名。存放格式：`gameReplay` / `<gameId>:<6 位序号>`，序号补零让字典序 = 时间序。
pub const replay_kind = "gameReplay";
pub const replay_meta_kind = "gameReplayMeta";
/// 一帧的 JSON 上限：十个人各十几个字段，实测 1~3KB，留足余量。
const frame_capacity: usize = 16 * 1024;

/// `providers.recording` 的解析结果。缺失即默认关。
pub const Settings = struct {
    enabled: bool = false,
    interval_seconds: i64 = default_interval_seconds,
    retention_days: i64 = default_retention_days,
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
    // ⚠️ 不能直接 `jsonInt`：它对**缺失字段**也返回 0，而 0 在这里是「永久保留」这个
    // 有意义的取值。老配置（v24 及以前）根本没有 `retentionDays`，必须落到默认的 30 天，
    // 而不是被当成「用户选了永久」。所以先判字段在不在。
    if (recording.object.get("retentionDays")) |raw| {
        const days: i64 = switch (raw) {
            .integer => |n| n,
            .float => |n| @intFromFloat(n),
            .string => |text| std.fmt.parseInt(i64, std.mem.trim(u8, text, " \t\r\n"), 10) catch default_retention_days,
            else => default_retention_days,
        };
        // 0 是合法的「永久」；负数当脏数据，退回**默认值**而不是夹成 1 天——
        // 「保留 1 天」等于把录制删光，不该是脏数据的归宿。
        settings.retention_days = if (days == 0) 0 else if (days < 0) default_retention_days else @min(max_retention_days, days);
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
        self.recording_retention_days = settings.retention_days;
        // 刚打开开关就先采一帧，不用干等一个间隔。
        self.recording_last_frame_ms = 0;
        // 配置一变（含开机第一跳）就立刻按新的保留期清一次。这样：
        // 「把保留期从 30 天改成 3 天」是**存下就生效**的，不用等打完下一局；
        // 「一个月前的老录制」在应用启动时就会被回收。开关关着也照清——保留期说的是
        // 「留多久」，跟「现在录不录」是两件事。
        pruneNow(self);
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

/// 按 `self.recording_retention_days` 立刻清一次。给 `captureTick` 的配置变更分支用。
fn pruneNow(self: *backend.Runtime) void {
    const store = if (self.storage) |*value| value else return;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    pruneRecordings(store, arena.allocator(), self.recording_retention_days, nowSeconds(self));
}

/// 当前 Unix 秒。`io` 没接上时返回 0 —— 那会让「已过期多久」算出负数，于是**不清理**
/// （宁可留着，也不要在时钟不可靠时误删用户的录制）。
fn nowSeconds(self: *backend.Runtime) i64 {
    return @divTrunc(backend.runtimeNowMillis(self), 1000);
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

    // 局号**必须**从 gameflow session 取：Live Client Data 的 `gameData` 里
    // **没有** gameId（只有 gameMode / gameTime / mapName / mapNumber / mapTerrain，
    // 官方文档与实测 payload 都是这五个）。而 gameflow session 的 `gameData.gameId`
    // 才是与战绩页**同一个**局号——界面就是拿那个号回来查帧的。
    // 每采样一次才拉一次，这个体积（几百 KB）摊在 15 秒的节拍上无所谓。
    const session_json = client.get("/lol-gameflow/v1/session") catch return false;
    defer std.heap.page_allocator.free(session_json);
    const game_id = sessionGameId(session_json);
    if (game_id <= 0) return false;

    // 英雄目录（名字 → id）用来给帧标上 `cid`，界面才画得出英雄头像。
    // `cachedGameAsset` 命中库里那份 24 小时的缓存，正常情况下不产生网络请求。
    const catalog = backend.cachedGameAsset(self, client, "champions", "/lol-game-data/assets/v1/champion-summary.json") catch null;
    defer if (catalog) |value| std.heap.page_allocator.free(value);

    var live_client = client;
    live_client.timeout_ms = @min(client.timeout_ms, build_options.lcu_live_probe_timeout_ms);
    const live = live_client.getLocalUrl(build_options.lcu_live_client_data_url) catch return false;
    defer std.heap.page_allocator.free(live);
    return appendFrame(self, live, catalog orelse "[]", game_id) catch false;
}

/// 从 gameflow session 里取局号（`gameData.gameId`）。
///
/// 刻意**只认这一条路径**，不复用 `backend.lobbyGameIdValue`：那个辅助函数会先看顶层
/// `id`（房间快照的语义），而 gameflow session 的顶层并没有「局号」意义的 `id`，
/// 混用容易把别的数字当成局号。
fn sessionGameId(session_json: []const u8) i64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), session_json, .{}) catch return 0;
    if (parsed != .object) return 0;
    const game_data = parsed.object.get("gameData") orelse return 0;
    if (game_data != .object) return 0;
    return backend.jsonInt(game_data, "gameId");
}

/// 解析一份 allgamedata，压成一帧存进 SQLite，并按局数上限回收旧局。
///
/// `game_id` 由调用方给（来自 gameflow session）——Live Client Data 里没有局号，
/// 见 `sessionGameId`。
fn appendFrame(self: *backend.Runtime, live_json: []const u8, catalog_json: []const u8, game_id: i64) !bool {
    if (game_id <= 0) return false;
    const store = if (self.storage) |*value| value else return false;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = std.json.parseFromSliceLeaky(std.json.Value, allocator, live_json, .{}) catch return false;
    if (root != .object) return false;
    // `gameData` 到这里只用来读 `gameTime` / `gameMode`，局号是参数传进来的。
    const game_data = root.object.get("gameData") orelse return false;
    if (game_data != .object) return false;

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

    pruneRecordings(store, allocator, self.recording_retention_days, nowSeconds(self));
    return true;
}

fn frameCountOf(meta_json: []const u8) usize {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), meta_json, .{}) catch return 0;
    const count = backend.jsonInt(parsed, "frameCount");
    return if (count > 0) @as(usize, @intCast(count)) else 0;
}

/// 库里现有多少局录制（`gameReplayMeta` 的条数）。给「区分两种空」用，见 `getGameRecording`。
fn recordedGameCount(store: *storage.Store, allocator: std.mem.Allocator) usize {
    const entries = store.list(allocator, replay_meta_kind) catch return 0;
    defer storage.Store.freeEntries(allocator, entries);
    return entries.len;
}

/// 回收录制：**两条规则一起判**，命中任一就删（连它的帧一起删）。
///
/// 1. **超出局数**：只留最近 `kept_games` 局（`list` 已经是「写入时间新的在前」，
///    所以尾部就是要回收的旧局）。
/// 2. **超出保留期**：`retention_days > 0` 时，`updated_at` 早于
///    `now_seconds - retention_days × 86400` 的一律删掉；`retention_days == 0`
///    表示永久保留，这一条不生效（用户选项里的「永久」）。
///
/// 两条都在这里做的原因：局数上限防的是「连着打十把」，保留期防的是「三个月没打、
/// 但库里躺着三局占地方」。只做前者的话，长时间不玩就永远留着那三局。
///
/// `now_seconds` 显式传进来（不在这里读时钟）是为了可测：用例可以直接指定「现在」。
fn pruneRecordings(store: *storage.Store, allocator: std.mem.Allocator, retention_days: i64, now_seconds: i64) void {
    const entries = store.list(allocator, replay_meta_kind) catch return;
    // `freeEntries` 是命名空间上的静态函数（没有 self），必须走类型名调用。
    defer storage.Store.freeEntries(allocator, entries);
    const cutoff: i64 = if (retention_days > 0) now_seconds - retention_days * 86400 else 0;
    for (entries, 0..) |entry, index| {
        const too_many = index >= kept_games;
        // `cutoff == 0` = 永久保留；`now_seconds == 0`（时钟没接上）时过期量算出来是负数，
        // 一律判为「没过期」——宁可多留，也不要在时钟不可靠时误删。
        const too_old = cutoff > 0 and now_seconds > 0 and entry.updated_at < cutoff;
        if (!too_many and !too_old) continue;
        const frame_count = frameCountOf(entry.value);
        var frame_index: usize = 0;
        while (frame_index < frame_count) : (frame_index += 1) {
            var key_buffer: [96]u8 = undefined;
            const frame_key = std.fmt.bufPrint(&key_buffer, "{s}:{d:0>6}", .{ entry.key, frame_index }) catch continue;
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

/// `lol.get_game_recording` —— payload：`{gameId}` → `{gameId, intervalSeconds, frames[], recordedGames}`。
///
/// 没录到就是空数组，不是错误：这个功能是可选开关，界面只要据此决定要不要画时间轴。
///
/// `recordedGames` = 本机库里现有多少局录制。**专门用来区分两种「空」**：
/// 「开关没生效 / 客户端没开着（一局都没录过）」和「这个功能好好的，只是这一局没录」。
/// 没有它的话这两种情况长得一模一样，用户只能猜。
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
    try writer.print("{{\"gameId\":{d},\"intervalSeconds\":{d},\"recordedGames\":{d},\"frames\":[", .{
        game_id,
        interval_seconds,
        recordedGameCount(store, allocator),
    });
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
    // ⚠️ `gameData` 刻意写成**真实形状**——Live Client Data 里没有 gameId，
    // 帧的局号是从 gameflow session 传进来的（见 `sessionGameId` 那条用例）。
    const live =
        "{\"gameData\":{\"gameTime\":312.5,\"gameMode\":\"KIWI\",\"mapName\":\"Map11\",\"mapNumber\":11,\"mapTerrain\":\"Default\"}," ++
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
    try writeFrame(&writer, &state, root, game_data, 901079838957, "[{\"id\":50,\"name\":\"斯维因\",\"alias\":\"Swain\"}]");    const frame = writer.buffered();
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

test "局号从 gameflow session 的 gameData.gameId 取（Live Client Data 里没有）" {
    const session = "{\"phase\":\"InProgress\",\"gameData\":{\"gameId\":901079838957,\"gameMode\":\"CLASSIC\",\"queue\":{\"id\":420}},\"map\":{\"id\":11}}";
    try testing.expectEqual(@as(i64, 901079838957), sessionGameId(session));
    // 拿不到局号就**不采**：宁可漏采，也不要写一个界面永远查不回来的键。
    try testing.expectEqual(@as(i64, 0), sessionGameId("{\"phase\":\"ChampSelect\"}"));
    try testing.expectEqual(@as(i64, 0), sessionGameId("{}"));
    try testing.expectEqual(@as(i64, 0), sessionGameId("[]"));
}

test "真实形状的 allgamedata（gameData 没有 gameId）也能落库并按局号读回" {
    // 这条是「开了开关打了几把、一帧都没录到」那次事故的回归。
    // 当初 `appendFrame` 自己去读 `gameData.gameId`，而真实 payload 里**没有**这个字段
    // （只有 gameMode / gameTime / mapName / mapNumber / mapTerrain）→ 永远 0 → 一帧不存。
    var store = try storage.Store.open(testing.allocator, testing.io, ":memory:");
    defer store.deinit();
    var state = backend.Runtime.init();
    state.storage = store;
    // 一开始一局都没有——这正是「开关没生效 / 从没采到过」的那个状态。
    try testing.expectEqual(@as(usize, 0), recordedGameCount(&store, testing.allocator));

    const game_id: i64 = 901079838957;
    const live =
        "{\"gameData\":{\"gameTime\":95.5,\"gameMode\":\"CLASSIC\",\"mapName\":\"Map11\",\"mapNumber\":11,\"mapTerrain\":\"Default\"}," ++
        "\"activePlayer\":{\"riotId\":\"我#0001\",\"currentGold\":1500,\"level\":6," ++
        "\"championStats\":{\"attackDamage\":80.5,\"abilityPower\":0,\"armor\":40,\"magicResist\":32,\"moveSpeed\":350,\"currentHealth\":1200,\"maxHealth\":1300}}," ++
        "\"allPlayers\":[{\"puuid\":\"self\",\"riotId\":\"我#0001\",\"team\":\"ORDER\",\"championName\":\"锐雯\",\"position\":\"TOP\"," ++
        "\"level\":6,\"isDead\":false,\"respawnTimer\":0,\"isBot\":false," ++
        "\"scores\":{\"kills\":3,\"deaths\":1,\"assists\":5,\"creepScore\":120,\"wardScore\":7}," ++
        "\"items\":[{\"itemID\":3153,\"count\":1,\"slot\":0}]," ++
        "\"summonerSpells\":{\"summonerSpellOne\":{\"displayName\":\"闪现\"},\"summonerSpellTwo\":{\"displayName\":\"点燃\"}}}]}";
    try testing.expect(try appendFrame(&state, live, "[]", game_id));

    // `recordedGames` 就是拿这个数：界面上「这一局没录」和「这功能从没生效过」靠它区分。
    try testing.expectEqual(@as(usize, 1), recordedGameCount(&store, testing.allocator));
    const frame = (try store.get(replay_kind, "901079838957:000000")).?;
    defer testing.allocator.free(frame);
    try testing.expect(std.mem.indexOf(u8, frame, "\"k\":3") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "\"cs\":120") != null);
    // 帧里必须带上局号，界面靠它回查。
    try testing.expect(std.mem.indexOf(u8, frame, "\"gameId\":901079838957") != null);
    const meta = (try store.get(replay_meta_kind, "901079838957")).?;
    defer testing.allocator.free(meta);
    try testing.expect(std.mem.indexOf(u8, meta, "\"frameCount\":1") != null);
    // 局号非法时什么都不该落盘。
    try testing.expect(!try appendFrame(&state, live, "[]", 0));
}

test "默认配置下采集一跳不发任何请求（开关关着）" {
    // ⚠️ 这条首先是个**编译护栏**，别删。
    //
    // `captureTick` 这条链路（captureTick → captureFrame → appendFrame → writeFrame /
    // pruneOldGames）原本**只有 `main.zig` 的自动化守护线程**会引用，测试构建根本走不到它。
    // Zig 是惰性分析——没被引用到的函数完全不做语义检查，于是出现过：
    // 后端 243 用例全绿，`zig build package` 却挂在 `store.freeEntries(...)`
    // （静态函数被当成方法调用）。真调一次 `captureTick`，把整条链路钉进测试构建的分析图。
    var state = backend.Runtime.init();
    try testing.expect(!captureTick(&state, testing.io));
    // 开关默认关：连节拍都不该推，下一跳仍然是「不比就返回」。
    try testing.expectEqual(@as(i64, 0), state.recording_last_frame_ms);
}

test "只保留最近几局：回收旧局时连它的帧一起删" {
    var store = try storage.Store.open(testing.allocator, testing.io, ":memory:");
    defer store.deinit();
    const frames_per_game: usize = 2;
    const total_games = kept_games + 2;
    for (0..total_games) |game| {
        const game_id: i64 = @intCast(game + 1);
        var meta_buffer: [32]u8 = undefined;
        const meta_key = try std.fmt.bufPrint(&meta_buffer, "{d}", .{game_id});
        var meta_json_buffer: [128]u8 = undefined;
        const meta_json = try std.fmt.bufPrint(&meta_json_buffer, "{{\"gameId\":{d},\"frameCount\":{d}}}", .{ game_id, frames_per_game });
        try store.put(replay_meta_kind, meta_key, meta_json);
        for (0..frames_per_game) |frame| {
            var frame_buffer: [64]u8 = undefined;
            const frame_key = try std.fmt.bufPrint(&frame_buffer, "{d}:{d:0>6}", .{ game_id, frame });
            try store.put(replay_kind, frame_key, "{\"t\":0}");
        }
    }
    const before = try store.list(testing.allocator, replay_meta_kind);
    try testing.expectEqual(@as(usize, total_games), before.len);
    storage.Store.freeEntries(testing.allocator, before);

    // 保留期传 0 = 永久、now 传 0 → 这条只验「局数」那一条规则（另一条由下面的用例管）。
    pruneRecordings(&store, testing.allocator, 0, 0);

    const after = try store.list(testing.allocator, replay_meta_kind);
    defer storage.Store.freeEntries(testing.allocator, after);
    try testing.expectEqual(@as(usize, kept_games), after.len);
    // 被回收那几局的帧必须一起没：否则磁盘只增不减，而没人再会读到它们。
    const frames = try store.list(testing.allocator, replay_kind);
    defer storage.Store.freeEntries(testing.allocator, frames);
    try testing.expectEqual(@as(usize, kept_games) * frames_per_game, frames.len);
}

/// 往库里塞一局（meta + N 帧）。`updated_at` 由 `Store.put` 写成**当前**时间，
/// 所以按时间判断的用例要改「现在」而不是改写入时间——见下面那两条。
fn seedGame(store: *storage.Store, game_id: i64, frame_count: usize) !void {
    var meta_key_buffer: [32]u8 = undefined;
    const meta_key = try std.fmt.bufPrint(&meta_key_buffer, "{d}", .{game_id});
    var meta_json_buffer: [128]u8 = undefined;
    const meta_json = try std.fmt.bufPrint(&meta_json_buffer, "{{\"gameId\":{d},\"frameCount\":{d}}}", .{ game_id, frame_count });
    try store.put(replay_meta_kind, meta_key, meta_json);
    for (0..frame_count) |frame| {
        var frame_key_buffer: [64]u8 = undefined;
        const frame_key = try std.fmt.bufPrint(&frame_key_buffer, "{d}:{d:0>6}", .{ game_id, frame });
        try store.put(replay_kind, frame_key, "{\"t\":0}");
    }
}

const day_seconds: i64 = 86400;

test "保留期到了就自动连着帧一起清掉，没到就一局不动" {
    var store = try storage.Store.open(testing.allocator, testing.io, ":memory:");
    defer store.deinit();
    const frames_per_game: usize = 2;
    try seedGame(&store, 1, frames_per_game);
    try seedGame(&store, 2, frames_per_game);
    const written_at = (try store.getUpdatedAt(replay_meta_kind, "1")).?;

    // 保留 30 天、「现在」= 写入后第 10 天 → 谁都没过期（局数也没超）→ 一局都不能少。
    pruneRecordings(&store, testing.allocator, default_retention_days, written_at + 10 * day_seconds);
    const fresh = try store.list(testing.allocator, replay_meta_kind);
    defer storage.Store.freeEntries(testing.allocator, fresh);
    try testing.expectEqual(@as(usize, 2), fresh.len);

    // 保留 3 天、「现在」= 写入后第 10 天 → 两局都超期，连帧一起回收。
    pruneRecordings(&store, testing.allocator, 3, written_at + 10 * day_seconds);
    const expired = try store.list(testing.allocator, replay_meta_kind);
    defer storage.Store.freeEntries(testing.allocator, expired);
    try testing.expectEqual(@as(usize, 0), expired.len);
    const frames = try store.list(testing.allocator, replay_kind);
    defer storage.Store.freeEntries(testing.allocator, frames);
    try testing.expectEqual(@as(usize, 0), frames.len);
}

test "保留期 0 = 永久：再老也不清，但局数上限仍然生效" {
    var store = try storage.Store.open(testing.allocator, testing.io, ":memory:");
    defer store.deinit();
    try seedGame(&store, 1, 1);
    try seedGame(&store, 2, 1);
    const written_at = (try store.getUpdatedAt(replay_meta_kind, "1")).?;

    // 一年后再来清，两局都应该还在（没有超期这一说）。
    pruneRecordings(&store, testing.allocator, 0, written_at + 365 * day_seconds);
    const kept = try store.list(testing.allocator, replay_meta_kind);
    defer storage.Store.freeEntries(testing.allocator, kept);
    try testing.expectEqual(@as(usize, 2), kept.len);
}

test "保留期 0 也不是「什么都不管」：局数上限照样只留最近几局" {
    var store = try storage.Store.open(testing.allocator, testing.io, ":memory:");
    defer store.deinit();
    const total_games = kept_games + 2;
    for (0..total_games) |game| try seedGame(&store, @intCast(game + 1), 1);

    pruneRecordings(&store, testing.allocator, 0, 0);
    const after = try store.list(testing.allocator, replay_meta_kind);
    defer storage.Store.freeEntries(testing.allocator, after);
    try testing.expectEqual(@as(usize, kept_games), after.len);
}

test "时钟没接上（now = 0）时绝不按时间清——宁可多留也不能误删" {
    var store = try storage.Store.open(testing.allocator, testing.io, ":memory:");
    defer store.deinit();
    try seedGame(&store, 1, 1);
    // `runtimeNowMillis` 在 io 未接上时返回 0，于是「过期多久」会算成负数。
    pruneRecordings(&store, testing.allocator, 30, 0);
    const kept = try store.list(testing.allocator, replay_meta_kind);
    defer storage.Store.freeEntries(testing.allocator, kept);
    try testing.expectEqual(@as(usize, 1), kept.len);
}

test "retentionDays：缺失落默认 30 天，显式 0 才是永久，负数当脏数据" {
    // ⚠️ 关键点：`jsonInt` 对**缺失字段**也返回 0，而 0 在这里是「永久保留」这个有意义的
    // 取值。不判字段在不在的话，所有老配置（v24 及以前没有这个字段）都会被静默升级成
    // 「永久不清理」，用户要的「自动清理老旧录制」就永远不会发生。
    try testing.expectEqual(default_retention_days, parseSettings("{}").retention_days);
    try testing.expectEqual(default_retention_days, parseSettings("{\"providers\":{\"recording\":{\"enabled\":true}}}").retention_days);
    try testing.expectEqual(@as(i64, 0), parseSettings("{\"providers\":{\"recording\":{\"retentionDays\":0}}}").retention_days);
    try testing.expectEqual(@as(i64, 3), parseSettings("{\"providers\":{\"recording\":{\"retentionDays\":3}}}").retention_days);
    try testing.expectEqual(@as(i64, 7), parseSettings("{\"providers\":{\"recording\":{\"retentionDays\":\"7\"}}}").retention_days);
    try testing.expectEqual(max_retention_days, parseSettings("{\"providers\":{\"recording\":{\"retentionDays\":99999}}}").retention_days);
    // 负数不能默默变成「永久」。
    try testing.expectEqual(default_retention_days, parseSettings("{\"providers\":{\"recording\":{\"retentionDays\":-5}}}").retention_days);
}
