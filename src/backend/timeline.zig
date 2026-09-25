//! 对局时间线：把 LCU 的 `game-timelines` 逐帧数据压成前端能直接画的形状。
//!
//! 与「打野路线图」读的是同一份数据（`/lol-match-history/v1/game-timelines/{gameId}`），
//! 但目的不同：路线图关心打野一个人去过哪儿，这里关心**整场的宏观走势**——
//! 双方经济/补刀曲线，以及什么时候拿了野怪、掉了塔。所以这里刻意不按玩家聚合，
//! 而是按「分钟帧」横向铺开，前端拿到就能直接画折线。
//!
//! 依赖 `backend.zig` 的共享基础设施（Runtime、LCU 客户端发现、payload 解析）。
const std = @import("std");
const native_sdk = @import("native_sdk");
const backend = @import("../backend.zig");

/// 一局最多画这么多分钟。重开局/超长局都会被截断，避免把输出缓冲塞满。
pub const max_minutes: usize = 90;
/// 只关心这四类事件。其余（技能加点、物品购买、回城……）对时间线是噪音。
const watched_events = [_][]const u8{ "CHAMPION_KILL", "ELITE_MONSTER_KILL", "BUILDING_KILL", "TURRET_PLATE_DESTROYED" };

const Participant = struct { team: i64 = 0, champion_id: i64 = 0 };

/// 落盘缓存键的版本前缀。**输出形状一变就要 +1。**
///
/// 缓存存的是整份输出 JSON 且没有版本字段，而这里的假设是「一局的逐帧数据打完就固定」——
/// 这只对**同一版输出形状**成立。v2 起 `damage` / `taken` 会用 SGP 的数据把本地裁剪版
/// 缺的伤害补上；v1 落盘的那些条目里这两项全是 0。不加前缀的话，用户之前看过的对局会
/// 一直读回全 0 的旧快照 —— 柱子永远是空的、**而且不报任何错**，看着像这次改动没生效。
/// 旧 key 不会清，但它们每条只有几百字节，且再也不会被读到。
const timeline_cache_prefix = "v2:";

/// `lol.get_match_timeline` —— 单局的分钟帧 + 关键事件。
///
/// payload：`{gameId, selfPuuid}`。`selfPuuid` 和 `get_jungle_path` 同义，只做账号
/// 归属校验（取的是本地客户端的战绩缓存，不该跨账号复用）。
pub fn getMatchTimeline(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = backend.runtime(context);
    const payload_json = backend.parsePayload(struct { gameId: i64 = 0, selfPuuid: []const u8 = "" }, invocation.request.payload) catch return error.InvalidRequest;
    defer payload_json.deinit();
    const payload = payload_json.value;
    if (payload.gameId <= 0) return error.InvalidRequest;
    if (self.mode != .live) return error.TimelineUnavailable;
    if (self.live_owner_puuid_len > 0 and !samePuuid(payload.selfPuuid, self.live_owner_puuid[0..self.live_owner_puuid_len])) return error.AccountChanged;

    var key_buffer: [32]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buffer, timeline_cache_prefix ++ "{d}", .{payload.gameId}) catch return error.TimelineUnavailable;
    // 一局的逐帧数据是不变的（打完就固定），所以落盘缓存可以直接当权威。
    // 但「不变」只在**同一版输出形状**下成立，所以键里带版本前缀，见 `timeline_cache_prefix`。
    if (self.storage) |*store| if (store.get("matchTimeline", key) catch null) |cached| {
        defer std.heap.page_allocator.free(cached);
        if (cached.len > 0 and cached.len <= output.len) {
            @memcpy(output[0..cached.len], cached);
            return output[0..cached.len];
        }
    };

    var client = backend.discoverClient(self, self.io orelse return error.LcuNotRunning) catch return error.LcuNotRunning;
    defer client.deinit();

    var timeline_path_buffer: [256]u8 = undefined;
    const timeline_path = std.fmt.bufPrint(&timeline_path_buffer, "/lol-match-history/v1/game-timelines/{d}", .{payload.gameId}) catch return error.TimelineUnavailable;
    const timeline = client.get(timeline_path) catch return error.TimelineUnavailable;
    defer std.heap.page_allocator.free(timeline);
    var game_path_buffer: [256]u8 = undefined;
    const game_path = std.fmt.bufPrint(&game_path_buffer, "/lol-match-history/v1/games/{d}", .{payload.gameId}) catch return error.TimelineUnavailable;
    const game_json = client.get(game_path) catch return error.TimelineUnavailable;
    defer std.heap.page_allocator.free(game_json);

    // 本地 `game-timelines` 是**裁剪版**：帧里没有伤害字段（实测 TENCENT）。
    // SGP 的 `DETAILS` 响应里嵌着 match-v5 的完整时间线，伤害/承伤只有那里有——
    // 观战面板那两条柱状图、以及「每波团输出 / 承伤」全靠它。取不到就照旧写 0，
    // 前端会把这两项降级成全场总账并把「本波」几个指标置灰（不会假装算得出来）。
    const details = backend.fetchSgpMatchDetails(client, game_json, payload.gameId);
    defer if (details) |value| std.heap.page_allocator.free(value);

    const json = try writeTimeline(game_json, timeline, details orelse "", output);
    if (self.storage) |*store| store.put("matchTimeline", key, json) catch {};
    return json;
}

/// 纯函数：`game_json` 只用来查 participantId → 阵营/英雄，逐帧数据全在 `timeline_json`。
///
/// `sgp_json` 是 SGP `DETAILS` 的响应原文（拿不到就传空串）。本地那份时间线没有伤害字段，
/// 而伤害要从 SGP 里那份**完整**时间线补进来 —— 见 `sgpTimelineFrames`。
pub fn writeTimeline(game_json: []const u8, timeline_json: []const u8, sgp_json: []const u8, output: []u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const game = std.json.parseFromSliceLeaky(std.json.Value, allocator, game_json, .{}) catch return error.TimelineUnavailable;
    const root = std.json.parseFromSliceLeaky(std.json.Value, allocator, timeline_json, .{}) catch return error.TimelineUnavailable;
    const frames = arrayField(root, "frames") orelse return error.TimelineUnavailable;
    if (frames != .array or frames.array.items.len == 0) return error.TimelineUnavailable;
    const sgp_frames = sgpTimelineFrames(allocator, sgp_json);

    const participants = participantsOf(game);
    const game_id = intField(game, "gameId");
    const duration = durationSeconds(game, frames);

    var writer = std.Io.Writer.fixed(output);
    try writer.print("{{\"gameId\":{d},\"durationSeconds\":{d},\"participants\":[", .{ game_id, duration });
    for (participants, 0..) |participant, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.print("{{\"participantId\":{d},\"team\":{d},\"championId\":{d}}}", .{ index + 1, participant.team, participant.champion_id });
    }
    try writer.writeAll("],\"frames\":[");
    try writeFrames(&writer, frames, sgp_frames);
    try writer.writeAll("],\"events\":[");
    try writeEvents(&writer, frames, participants);
    try writer.writeAll("]}");
    return writer.buffered();
}

/// 从 SGP `DETAILS` 的响应里掏出**完整**时间线的 `frames`。
///
/// 为什么要多这一跳：LCU 本地的 `/lol-match-history/v1/game-timelines/{id}` 是裁剪版。
/// TENCENT 实机实测（ARAM 2400 与 SR 440 两种都测过），每个 `participantFrame` 只有
/// `currentGold` / `level` / `minionsKilled` / `jungleMinionsKilled` / `position` /
/// `totalGold` / `xp` —— **没有任何伤害字段**（既无扁平的 `totalDamageDoneToChampions`，
/// 也没有嵌套的 `damageStats`），事件里也只有 `CHAMPION_KILL` 与 `BUILDING_KILL`。
/// 而 SGP 的 `DETAILS` 里嵌着 match-v5 的完整时间线：每个座位带
/// `damageStats.totalDamageDoneToChampions` / `totalDamageTaken`，事件里还有
/// `ITEM_PURCHASED` / `SKILL_LEVEL_UP` / `WARD_PLACED` 等等。
///
/// 两份能直接对齐，实测同一局：**帧数相同（30 比 30）、逐帧时间戳完全相同**
/// （0 / 60022 / 120028 / …）、十个座位的 `level` 逐座位比对全等 —— 说明座位号
/// （participantId）在两份里指的是同一个人，按下标或时间戳配对都成立。
///
/// 外层形状是 `{"json":<时间线>,"metadata":{...}}`。
///
/// ⚠️ `json` 这里是**嵌进去的对象**，不是转义过的字符串 —— 真机核对过：直接把响应体读成
/// 字节，`"json"` 后面紧跟的是 `{`（TENCENT / NJ100，2026-09）。早期探针先 `json.dumps`
/// 再打印，看到的永远是转义形式，据此很容易把这里写成「只认字符串」，那样真机上会一路
/// 返回 null：伤害恒 0、**不报错**，柱状图静悄悄地永远画不出来。两种形状都认。
fn sgpTimelineFrames(allocator: std.mem.Allocator, sgp_json: []const u8) ?std.json.Value {
    if (sgp_json.len == 0) return null;
    const outer = std.json.parseFromSliceLeaky(std.json.Value, allocator, sgp_json, .{}) catch return null;
    if (outer != .object) return null;
    const raw = outer.object.get("json") orelse return null;
    const inner = switch (raw) {
        .object, .array => raw,
        .string => |text| std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{}) catch return null,
        else => return null,
    };
    return arrayField(inner, "frames");
}

/// 按**时间戳**找 SGP 里对应的那一帧。
///
/// 刻意不按下标：两份帧数组目前长度一致，但哪天差了一项（掉帧、重开），下标对齐会让
/// 整条伤害曲线错位一格，而错位一格在界面上只表现为「数字有点怪」，很难查。
/// 帧数最多 `max_minutes`（90），逐帧线性找一共几千次比较，不值得为它建哈希表。
fn sgpFrameAt(sgp_frames: ?std.json.Value, timestamp: i64) ?std.json.Value {
    const list = sgp_frames orelse return null;
    if (list != .array) return null;
    for (list.array.items) |candidate| {
        if (intField(candidate, "timestamp") == timestamp) return candidate;
    }
    return null;
}

/// 某个座位在 SGP 帧里的一个 `damageStats` 字段；缺任何一层都给 0。
fn sgpSeatStat(sgp_frame: ?std.json.Value, seat_key: []const u8, field: []const u8) i64 {
    const frame = sgp_frame orelse return 0;
    const seats = nestedObject(frame, "participantFrames") orelse return 0;
    if (seats != .object) return 0;
    const seat = seats.object.get(seat_key) orelse return 0;
    const stats = nestedObject(seat, "damageStats") orelse return 0;
    return intField(stats, field);
}

/// 本地帧里带伤害就用自己的（同一份数据，少一层间接），没有才取 SGP 的。
/// 「>0」而不是「非 null」是因为本地帧里那两项在裁剪版上是**恒为 0 的整数**，不是缺字段。
fn preferPositive(local: i64, fallback: i64) i64 {
    return if (local > 0) local else fallback;
}

/// 分钟帧：第 0 帧是开局快照，画曲线时没有信息量，直接跳过。
///
/// 除金币/补刀外，每帧还带 `level`（十人的英雄等级）与 `positions`（十人的地图位置）。
/// 这两样是观战式时间轴的原料：等级给「头像上的等级徽标」，位置给「小人到处跑」的
/// 走位点（60 秒一帧很粗，但足够看出谁在哪片活动）。帧里没有 position 时写 0/0，
/// 前端按「位置未知」处理（0/0 在本图域是真实坐标，判空必须 x>0 || y>0）。
fn writeFrames(writer: *std.Io.Writer, frames: std.json.Value, sgp_frames: ?std.json.Value) !void {
    var written: usize = 0;
    for (frames.array.items) |frame| {
        const timestamp = intField(frame, "timestamp");
        const minute = @divTrunc(timestamp, 60_000);
        if (minute <= 0) continue;
        if (minute > max_minutes) break;
        const participant_frames = nestedObject(frame, "participantFrames") orelse continue;
        if (participant_frames != .object) continue;
        // 同一时刻的 SGP 帧（带伤害的那一份）。缺了就全靠本地字段，也就是 0。
        const sgp_frame = sgpFrameAt(sgp_frames, timestamp);

        var gold = [_]i64{0} ** 10;
        var level = [_]i64{0} ** 10;
        var damage = [_]i64{0} ** 10;
        var taken = [_]i64{0} ** 10;
        var pos_x = [_]i64{0} ** 10;
        var pos_y = [_]i64{0} ** 10;
        var blue_gold: i64 = 0;
        var red_gold: i64 = 0;
        var blue_cs: i64 = 0;
        var red_cs: i64 = 0;
        var id: i64 = 1;
        while (id <= 10) : (id += 1) {
            var key_buffer: [4]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buffer, "{d}", .{id}) catch continue;
            const entry = participant_frames.object.get(key) orelse continue;
            const total_gold = intField(entry, "totalGold");
            const cs = intField(entry, "minionsKilled") + intField(entry, "jungleMinionsKilled");
            gold[@intCast(id - 1)] = total_gold;
            level[@intCast(id - 1)] = intField(entry, "level");
            // 累计对英雄伤害：团战伤害 = 团后帧 - 团前帧的差值。本地帧（LCU 裁剪版）里
            // **没有**这两个字段，所以实测真机上是恒 0 —— 真正的来源是同一时刻的 SGP 帧
            // （`damageStats`），这里补进来。两边都拿不到才落到 0，前端据此降级。
            damage[@intCast(id - 1)] = preferPositive(intField(entry, "totalDamageDoneToChampions"), sgpSeatStat(sgp_frame, key, "totalDamageDoneToChampions"));
            // 累计承受伤害：同一套差值算法，团战的「承伤」指标用。
            taken[@intCast(id - 1)] = preferPositive(intField(entry, "totalDamageTaken"), sgpSeatStat(sgp_frame, key, "totalDamageTaken"));
            if (nestedObject(entry, "position")) |position| {
                pos_x[@intCast(id - 1)] = intField(position, "x");
                pos_y[@intCast(id - 1)] = intField(position, "y");
            }
            if (id <= 5) {
                blue_gold += total_gold;
                blue_cs += cs;
            } else {
                red_gold += total_gold;
                red_cs += cs;
            }
        }

        if (written > 0) try writer.writeByte(',');
        written += 1;
        try writer.print("{{\"minute\":{d},\"blueGold\":{d},\"redGold\":{d},\"goldDiff\":{d},\"blueCs\":{d},\"redCs\":{d},\"gold\":[", .{ minute, blue_gold, red_gold, blue_gold - red_gold, blue_cs, red_cs });
        for (gold, 0..) |value, index| {
            if (index > 0) try writer.writeByte(',');
            try writer.print("{d}", .{value});
        }
        try writer.writeAll("],\"level\":[");
        for (level, 0..) |value, index| {
            if (index > 0) try writer.writeByte(',');
            try writer.print("{d}", .{value});
        }
        try writer.writeAll("],\"damage\":[");
        for (damage, 0..) |value, index| {
            if (index > 0) try writer.writeByte(',');
            try writer.print("{d}", .{value});
        }
        try writer.writeAll("],\"taken\":[");
        for (taken, 0..) |value, index| {
            if (index > 0) try writer.writeByte(',');
            try writer.print("{d}", .{value});
        }
        try writer.writeAll("],\"positions\":[");
        for (pos_x, 0..) |value, index| {
            if (index > 0) try writer.writeByte(',');
            try writer.print("{{\"x\":{d},\"y\":{d}}}", .{ value, pos_y[index] });
        }
        try writer.writeAll("]}");
    }
}

/// 关键事件。事件的 `team` 一律表示**做这件事的一方**（推塔/拿龙/击杀方），
/// 这样前端只需要一个「我方/敌方」的判断；丢失方由对面推出来，不必依赖
/// Riot 对 `teamId` 的含糊定义。能查到 killerId 就用它，否则按 raw `teamId` 反推。
///
/// 每条事件带 `posX/posY` 与助攻**名单**（`assistIds`）。前者是地图定位的唯一来源，
/// 后者用来把「谁参与了这波」按人去重——「每波团」这个概念 Riot 没有现成字段，
/// 是靠击杀事件在时间与位置上聚类出来的（前端 `matches/teamfights.ts`），
/// 所以这两项必须原样带出来，不能在后端就压成计数。
fn writeEvents(writer: *std.Io.Writer, frames: std.json.Value, participants: [10]Participant) !void {
    var written: usize = 0;
    for (frames.array.items) |frame| {
        const events = arrayField(frame, "events") orelse continue;
        if (events != .array) continue;
        for (events.array.items) |event| {
            const event_type = stringField(event, "type");
            if (!isWatched(event_type)) continue;
            const killer_id = intField(event, "killerId");
            var team = teamOfKiller(killer_id, participants);
            if (team == 0 and intField(event, "killerTeamId") > 0) {
                team = intField(event, "killerTeamId");
            }
            if (team == 0) {
                // 没有击杀者（比如被小兵推掉）：Riot 的 teamId 是**建筑所有方**，反推摧毁方。
                const owner = intField(event, "teamId");
                if (owner == 100 or owner == 200) team = 300 - owner;
            }

            if (written > 0) try writer.writeByte(',');
            written += 1;
            try writer.print("{{\"type\":", .{});
            try writeString(writer, event_type);
            try writer.print(",\"seconds\":{d},\"team\":{d},\"killerId\":{d},\"victimId\":{d},\"assistCount\":{d}", .{
                @divTrunc(intField(event, "timestamp"), 1000),
                team,
                killer_id,
                intField(event, "victimId"),
                arrayLength(event, "assistingParticipantIds"),
            });
            try writer.writeAll(",\"killerChampionId\":");
            try writer.print("{d}", .{championOf(killer_id, participants)});
            try writer.writeAll(",\"victimChampionId\":");
            try writer.print("{d}", .{championOf(intField(event, "victimId"), participants)});
            // 助攻**名单**（不只是个数）：「这波团谁在」要按人去重，光有总数算不出来。
            try writer.writeAll(",\"assistIds\":");
            try writeIntArray(writer, event, "assistingParticipantIds");
            // 事件发生的位置。击杀/拿龙/推塔事件都带 `position`，是「这波团打在哪」的
            // 唯一来源——帧里也有 `position`，但那是 60 秒一帧，粒度太粗指不了团战。
            // 个别事件没有 position（例如被小兵推掉的塔），写 0 由前端当「位置未知」。
            const position = nestedObject(event, "position");
            try writer.writeAll(",\"posX\":");
            try writer.print("{d}", .{if (position) |value| intField(value, "x") else 0});
            try writer.writeAll(",\"posY\":");
            try writer.print("{d}", .{if (position) |value| intField(value, "y") else 0});
            try writer.writeAll(",\"monsterType\":");
            try writeString(writer, stringField(event, "monsterType"));
            try writer.writeAll(",\"monsterSubType\":");
            try writeString(writer, stringField(event, "monsterSubType"));
            try writer.writeAll(",\"buildingType\":");
            try writeString(writer, stringField(event, "buildingType"));
            try writer.writeAll(",\"towerType\":");
            try writeString(writer, stringField(event, "towerType"));
            try writer.writeAll(",\"laneType\":");
            try writeString(writer, stringField(event, "laneType"));
            try writer.writeByte('}');
        }
    }
}

fn isWatched(event_type: []const u8) bool {
    for (watched_events) |candidate| if (std.mem.eql(u8, candidate, event_type)) return true;
    return false;
}

/// 从 game 里取 participantId → {阵营, 英雄}。取不到就留 0，前端按「未知」渲染。
fn participantsOf(game: std.json.Value) [10]Participant {
    var result = [_]Participant{.{}} ** 10;
    const list = participantsList(game) orelse return result;
    if (list != .array) return result;
    for (list.array.items) |entry| {
        const id = intField(entry, "participantId");
        if (id < 1 or id > 10) continue;
        result[@intCast(id - 1)] = .{ .team = intField(entry, "teamId"), .champion_id = intField(entry, "championId") };
    }
    return result;
}

/// `participants` 是**数组**，所以这里必须走 `arrayField`——`nestedObject` 只认对象，
/// 用错会静默拿到全 0 的座位表（曾经因此让所有英雄图标都变成问号）。
fn participantsList(game: std.json.Value) ?std.json.Value {
    if (arrayField(game, "participants")) |value| return value;
    if (nestedObject(game, "game")) |inner| return arrayField(inner, "participants");
    return null;
}

fn durationSeconds(game: std.json.Value, frames: std.json.Value) i64 {
    const declared = intField(game, "gameDuration");
    if (declared > 0) return declared;
    return @divTrunc(intField(frames.array.items[frames.array.items.len - 1], "timestamp"), 1000);
}

fn teamOfKiller(killer_id: i64, participants: [10]Participant) i64 {
    if (killer_id < 1 or killer_id > 10) return 0;
    const participant = participants[@intCast(killer_id - 1)];
    if (participant.team > 0) return participant.team;
    return if (killer_id <= 5) 100 else 200;
}

fn championOf(participant_id: i64, participants: [10]Participant) i64 {
    if (participant_id < 1 or participant_id > 10) return 0;
    return participants[@intCast(participant_id - 1)].champion_id;
}

fn samePuuid(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0 or left.len != right.len) return false;
    return std.ascii.eqlIgnoreCase(left, right);
}

fn writeString(writer: *std.Io.Writer, value: []const u8) !void {
    var stringify = std.json.Stringify{ .writer = writer, .options = .{} };
    try stringify.write(value);
}

fn arrayField(value: std.json.Value, name: []const u8) ?std.json.Value {
    if (value != .object) return null;
    const field = value.object.get(name) orelse return null;
    if (field != .array) return null;
    return field;
}

fn nestedObject(value: std.json.Value, name: []const u8) ?std.json.Value {
    if (value != .object) return null;
    const field = value.object.get(name) orelse return null;
    if (field != .object) return null;
    return field;
}

fn intField(value: std.json.Value, name: []const u8) i64 {
    if (value != .object) return 0;
    const field = value.object.get(name) orelse return 0;
    return switch (field) {
        .integer => |number| number,
        .float => |number| @intFromFloat(number),
        .string => |text| std.fmt.parseInt(i64, text, 10) catch 0,
        else => 0,
    };
}

fn stringField(value: std.json.Value, name: []const u8) []const u8 {
    if (value != .object) return "";
    const field = value.object.get(name) orelse return "";
    return switch (field) {
        .string => |text| text,
        else => "",
    };
}

fn arrayLength(value: std.json.Value, name: []const u8) i64 {
    const field = arrayField(value, name) orelse return 0;
    return @intCast(field.array.items.len);
}

/// 把整数数组原样写出去（目前只用于 `assistingParticipantIds`）。
/// 取不到或不是数组时写 `[]`——前端只依赖「是数组」这一条，不用再判空。
fn writeIntArray(writer: *std.Io.Writer, value: std.json.Value, name: []const u8) !void {
    const field = arrayField(value, name) orelse return writer.writeAll("[]");
    try writer.writeByte('[');
    for (field.array.items, 0..) |entry, index| {
        if (index > 0) try writer.writeByte(',');
        const number: i64 = switch (entry) {
            .integer => |item| item,
            .float => |item| @intFromFloat(item),
            .string => |text| std.fmt.parseInt(i64, text, 10) catch 0,
            else => 0,
        };
        try writer.print("{d}", .{number});
    }
    try writer.writeByte(']');
}

// ---- 测试 ----------------------------------------------------------------

const game_fixture =
    \\{"gameId":7001,"gameDuration":1860,"participants":[
    \\{"participantId":1,"teamId":100,"championId":64},
    \\{"participantId":2,"teamId":100,"championId":103},
    \\{"participantId":6,"teamId":200,"championId":12},
    \\{"participantId":7,"teamId":200,"championId":222}]}
;

fn timelineFixture() []const u8 {
    return
        \\{"frames":[
        \\{"timestamp":0,"participantFrames":{"1":{"totalGold":500,"minionsKilled":0,"jungleMinionsKilled":0},"6":{"totalGold":500,"minionsKilled":0,"jungleMinionsKilled":0}},"events":[]},
        \\{"timestamp":60000,"participantFrames":{"1":{"totalGold":1500,"minionsKilled":10,"jungleMinionsKilled":2,"level":6,"totalDamageDoneToChampions":2300,"totalDamageTaken":1100,"position":{"x":3200,"y":1800}},"2":{"totalGold":1200,"minionsKilled":5,"jungleMinionsKilled":0},"6":{"totalGold":1400,"minionsKilled":12,"jungleMinionsKilled":0,"level":5,"totalDamageDoneToChampions":1800,"totalDamageTaken":1600,"position":{"x":9800,"y":7400}},"7":{"totalGold":900,"minionsKilled":3,"jungleMinionsKilled":0}},"events":[]},
        \\{"timestamp":120000,"participantFrames":{"1":{"totalGold":2600,"minionsKilled":20,"jungleMinionsKilled":4,"level":8,"position":{"x":3450,"y":1900}},"2":{"totalGold":2100,"minionsKilled":12,"jungleMinionsKilled":0},"6":{"totalGold":2500,"minionsKilled":24,"jungleMinionsKilled":0,"level":7},"7":{"totalGold":1600,"minionsKilled":8,"jungleMinionsKilled":0}},"events":[
        \\{"type":"CHAMPION_KILL","timestamp":115000,"killerId":1,"victimId":7,"assistingParticipantIds":[2],"position":{"x":7500,"y":4200}},
        \\{"type":"ELITE_MONSTER_KILL","timestamp":118000,"killerId":6,"killerTeamId":200,"monsterType":"DRAGON","monsterSubType":"FIRE_DRAGON","position":{"x":9900,"y":4400}},
        \\{"type":"BUILDING_KILL","timestamp":119000,"killerId":1,"teamId":200,"buildingType":"TOWER_BUILDING","towerType":"OUTER_TURRET","laneType":"BOT_LANE"},
        \\{"type":"SKILL_LEVEL_UP","timestamp":119500,"participantId":1,"skillSlot":1}]}]}
    ;
}

/// 测试里解析输出的 JSON。用 `parseFromSlice` 而不是 leaky 版本——leaky 分配在
/// `std.testing.allocator` 下一样会被记成内存泄漏。
fn parseForTest(json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
}

test "writes minute frames with per-team gold, cs and a per-player gold array" {
    var buffer: [16384]u8 = undefined;
    const json = try writeTimeline(game_fixture, timelineFixture(), "", &buffer);
    var parsed = try parseForTest(json);
    defer parsed.deinit();
    const root = parsed.value;
    try std.testing.expectEqual(@as(i64, 7001), intField(root, "gameId"));
    try std.testing.expectEqual(@as(i64, 1860), intField(root, "durationSeconds"));

    const frames = arrayField(root, "frames") orelse return error.MissingFrames;
    // 第 0 帧（开局快照）被跳过，只留 1、2 两分钟。
    try std.testing.expectEqual(@as(usize, 2), frames.array.items.len);
    const first = frames.array.items[0];
    try std.testing.expectEqual(@as(i64, 1), intField(first, "minute"));
    try std.testing.expectEqual(@as(i64, 2700), intField(first, "blueGold"));
    try std.testing.expectEqual(@as(i64, 2300), intField(first, "redGold"));
    try std.testing.expectEqual(@as(i64, 400), intField(first, "goldDiff"));
    try std.testing.expectEqual(@as(i64, 17), intField(first, "blueCs"));
    try std.testing.expectEqual(@as(i64, 15), intField(first, "redCs"));
    const gold = arrayField(first, "gold") orelse return error.MissingGold;
    try std.testing.expectEqual(@as(usize, 10), gold.array.items.len);
    try std.testing.expectEqual(@as(i64, 1500), gold.array.items[0].integer);
    try std.testing.expectEqual(@as(i64, 1400), gold.array.items[5].integer);
    // 没出现在帧里的座位补 0，位置不能错位。
    try std.testing.expectEqual(@as(i64, 0), gold.array.items[9].integer);

    // 观战时间轴的原料：每帧十人的英雄等级 + 地图位置。缺的座位补 0（位置 0/0 = 未知）。
    const level = arrayField(first, "level") orelse return error.MissingLevel;
    try std.testing.expectEqual(@as(usize, 10), level.array.items.len);
    try std.testing.expectEqual(@as(i64, 6), level.array.items[0].integer);
    try std.testing.expectEqual(@as(i64, 5), level.array.items[5].integer);
    try std.testing.expectEqual(@as(i64, 0), level.array.items[9].integer);
    const positions = arrayField(first, "positions") orelse return error.MissingPositions;
    try std.testing.expectEqual(@as(usize, 10), positions.array.items.len);
    const first_position = positions.array.items[0];
    try std.testing.expectEqual(@as(i64, 3200), intField(first_position, "x"));
    try std.testing.expectEqual(@as(i64, 1800), intField(first_position, "y"));
    // 第二分钟队伍 1 的位置变了，且 6 号没带 position 的那一帧要落回 0/0（未知）。
    const second = frames.array.items[1];
    const second_positions = arrayField(second, "positions") orelse return error.MissingPositions;
    try std.testing.expectEqual(@as(i64, 3450), intField(second_positions.array.items[0], "x"));
    try std.testing.expectEqual(@as(i64, 0), intField(second_positions.array.items[5], "x"));

    // 每帧十人的累计对英雄伤害（团战伤害 = 两帧差值）。没写这个字段的座位补 0。
    const damage = arrayField(first, "damage") orelse return error.MissingDamage;
    try std.testing.expectEqual(@as(usize, 10), damage.array.items.len);
    try std.testing.expectEqual(@as(i64, 2300), damage.array.items[0].integer);
    try std.testing.expectEqual(@as(i64, 1800), damage.array.items[5].integer);
    try std.testing.expectEqual(@as(i64, 0), damage.array.items[9].integer);

    // 同构的承伤数组（团战「本波承伤」指标）。
    const taken = arrayField(first, "taken") orelse return error.MissingTaken;
    try std.testing.expectEqual(@as(usize, 10), taken.array.items.len);
    try std.testing.expectEqual(@as(i64, 1100), taken.array.items[0].integer);
    try std.testing.expectEqual(@as(i64, 1600), taken.array.items[5].integer);
    try std.testing.expectEqual(@as(i64, 0), taken.array.items[9].integer);
}

// 真机上 LCU 本地那份时间线是**裁剪版**：帧里根本没有伤害字段。伤害唯一来源是同一局的
// SGP `DETAILS`（里面嵌着 match-v5 的完整时间线）。这条用例把那条合并路径钉死，
// 免得哪天有人「顺手清理」掉 `sgp_json` 参数——那会让观战面板的柱状图悄悄退回全 0。
test "borrows per-minute damage from the SGP timeline when the local frames omit it" {
    var buffer: [16384]u8 = undefined;
    // 本地帧 = 真机形状：只有金币 / 等级 / 位置，一格伤害都没有。
    const stripped =
        \\{"frames":[
        \\{"timestamp":0,"participantFrames":{"1":{"totalGold":500,"level":1}},"events":[]},
        \\{"timestamp":60000,"participantFrames":{"1":{"totalGold":1500,"level":6,"position":{"x":3200,"y":1800}},"6":{"totalGold":1400,"level":5}},"events":[]},
        \\{"timestamp":120000,"participantFrames":{"1":{"totalGold":2600,"level":8},"6":{"totalGold":2500,"level":7}},"events":[]}]}
    ;
    // SGP 响应：外层 `{"json":<时间线>,"metadata":{…}}`。`json` 那一段**两种形状都出现过**：
    // 真机核对下来是「嵌进去的对象」（见 `sgpTimelineFrames` 的注释），历史探针里则见过
    // 转义字符串形式，所以两种都得测，免得哪天真机上那种形状被漏掉。
    const sgp_nested =
        \\{"json":{"frames":[{"timestamp":60000,"participantFrames":{"1":{"damageStats":{"totalDamageDoneToChampions":2300,"totalDamageTaken":1100}},"6":{"damageStats":{"totalDamageDoneToChampions":1800,"totalDamageTaken":1600}}}},{"timestamp":120000,"participantFrames":{"1":{"damageStats":{"totalDamageDoneToChampions":7700,"totalDamageTaken":3100}}}}]},"metadata":{"product":"lol"}}
    ;
    const sgp_escaped =
        \\{"json":"{\"frames\":[{\"timestamp\":60000,\"participantFrames\":{\"1\":{\"damageStats\":{\"totalDamageDoneToChampions\":2300,\"totalDamageTaken\":1100}},\"6\":{\"damageStats\":{\"totalDamageDoneToChampions\":1800,\"totalDamageTaken\":1600}}}},{\"timestamp\":120000,\"participantFrames\":{\"1\":{\"damageStats\":{\"totalDamageDoneToChampions\":7700,\"totalDamageTaken\":3100}}}}]}","metadata":{"product":"lol"}}
    ;
    // 真机形状（对象）必须先过 —— 它就摆在前面，因为它才是实际会出现的那一种。
    for ([_][]const u8{ sgp_nested, sgp_escaped }) |sgp| {
        const json = try writeTimeline(game_fixture, stripped, sgp, &buffer);
        var parsed = try parseForTest(json);
        defer parsed.deinit();
        const frames = arrayField(parsed.value, "frames") orelse return error.MissingFrames;
        // 第 0 帧（开局快照）被跳过，剩下两帧。
        try std.testing.expectEqual(@as(usize, 2), frames.array.items.len);

        const first = frames.array.items[0];
        try std.testing.expectEqual(@as(i64, 1), intField(first, "minute"));
        const damage = arrayField(first, "damage") orelse return error.MissingDamage;
        try std.testing.expectEqual(@as(i64, 2300), damage.array.items[0].integer);
        try std.testing.expectEqual(@as(i64, 1800), damage.array.items[5].integer);
        // 本地与 SGP 都没有的座位写 0（不是缺字段）——前端按「这个人此刻 0 伤害」处理。
        try std.testing.expectEqual(@as(i64, 0), damage.array.items[1].integer);
        const taken = arrayField(first, "taken") orelse return error.MissingTaken;
        try std.testing.expectEqual(@as(i64, 1100), taken.array.items[0].integer);
        try std.testing.expectEqual(@as(i64, 1600), taken.array.items[5].integer);

        // 第二帧按**时间戳**（不是下标）配对，所以这里能取到 120000 那一帧的值。
        const second = frames.array.items[1];
        const second_damage = arrayField(second, "damage") orelse return error.MissingDamage;
        try std.testing.expectEqual(@as(i64, 7700), second_damage.array.items[0].integer);
    }

    // 本地帧自带伤害时以本地为准：SGP 缺席不该把本地已经有的值抹掉。
    const local = try writeTimeline(game_fixture, timelineFixture(), "", &buffer);
    var local_parsed = try parseForTest(local);
    defer local_parsed.deinit();
    const local_frames = arrayField(local_parsed.value, "frames") orelse return error.MissingFrames;
    const local_damage = arrayField(local_frames.array.items[0], "damage") orelse return error.MissingDamage;
    try std.testing.expectEqual(@as(i64, 2300), local_damage.array.items[0].integer);
}

// SGP 缺席（离线 / 区服不在白名单 / 没有 entitlement）时不能把整条时间线带崩：
// 伤害写 0，其余字段照常，前端据此降级成全场总账。
test "a missing or malformed SGP payload degrades to zero damage instead of failing" {
    var buffer: [16384]u8 = undefined;
    const empty = try writeTimeline(game_fixture, timelineFixture(), "", &buffer);
    var empty_parsed = try parseForTest(empty);
    defer empty_parsed.deinit();
    const empty_frames = arrayField(empty_parsed.value, "frames") orelse return error.MissingFrames;
    try std.testing.expectEqual(@as(usize, 2), empty_frames.array.items.len);

    for ([_][]const u8{ "{}", "not json", "{\"json\":\"\"}", "{\"json\":\"{\\\"frames\\\":\\\"nope\\\"}\"}", "{\"json\":{\"frames\":\"nope\"}}", "{\"json\":[1,2]}", "[]" }) |broken| {
        const json = try writeTimeline(game_fixture, timelineFixture(), broken, &buffer);
        var parsed = try parseForTest(json);
        defer parsed.deinit();
        const frames = arrayField(parsed.value, "frames") orelse return error.MissingFrames;
        // 本地 fixture 有伤害，所以这里仍然拿得到本地值 —— 关键是**没有报错、帧数不丢**。
        try std.testing.expectEqual(@as(usize, 2), frames.array.items.len);
        const damage = arrayField(frames.array.items[0], "damage") orelse return error.MissingDamage;
        try std.testing.expectEqual(@as(usize, 10), damage.array.items.len);
    }
}

test "keeps only timeline-relevant events and derives the acting team" {
    var buffer: [16384]u8 = undefined;
    const json = try writeTimeline(game_fixture, timelineFixture(), "", &buffer);
    var parsed = try parseForTest(json);
    defer parsed.deinit();
    const events = arrayField(parsed.value, "events") orelse return error.MissingEvents;
    // SKILL_LEVEL_UP 属于噪音，必须被丢掉。
    try std.testing.expectEqual(@as(usize, 3), events.array.items.len);

    const kill = events.array.items[0];
    try std.testing.expectEqualStrings("CHAMPION_KILL", stringField(kill, "type"));
    try std.testing.expectEqual(@as(i64, 115), intField(kill, "seconds"));
    try std.testing.expectEqual(@as(i64, 100), intField(kill, "team"));
    try std.testing.expectEqual(@as(i64, 64), intField(kill, "killerChampionId"));
    try std.testing.expectEqual(@as(i64, 222), intField(kill, "victimChampionId"));
    try std.testing.expectEqual(@as(i64, 1), intField(kill, "assistCount"));
    // 助攻名单要原样带出来：团战聚类按人去重，只靠 assistCount 算不出参战名单。
    const assists = arrayField(kill, "assistIds") orelse return error.MissingAssists;
    try std.testing.expectEqual(@as(usize, 1), assists.array.items.len);
    try std.testing.expectEqual(@as(i64, 2), assists.array.items[0].integer);
    try std.testing.expectEqual(@as(i64, 7500), intField(kill, "posX"));
    try std.testing.expectEqual(@as(i64, 4200), intField(kill, "posY"));

    const monster = events.array.items[1];
    try std.testing.expectEqualStrings("ELITE_MONSTER_KILL", stringField(monster, "type"));
    try std.testing.expectEqual(@as(i64, 200), intField(monster, "team"));
    try std.testing.expectEqualStrings("FIRE_DRAGON", stringField(monster, "monsterSubType"));
    try std.testing.expectEqual(@as(i64, 9900), intField(monster, "posX"));
    try std.testing.expectEqual(@as(i64, 4400), intField(monster, "posY"));

    const building = events.array.items[2];
    try std.testing.expectEqualStrings("BUILDING_KILL", stringField(building, "type"));
    // 推塔方是 1 号（蓝方），哪怕 raw teamId 写的是 200（被推的一方）。
    try std.testing.expectEqual(@as(i64, 100), intField(building, "team"));
    try std.testing.expectEqualStrings("OUTER_TURRET", stringField(building, "towerType"));
    // 没有 position 的事件写 0（前端当「位置未知」），助攻同理写空数组。
    try std.testing.expectEqual(@as(i64, 0), intField(building, "posX"));
    try std.testing.expectEqual(@as(i64, 0), intField(building, "posY"));
    try std.testing.expectEqual(@as(usize, 0), arrayField(building, "assistIds").?.array.items.len);
}

test "dirty position and assist fields never break an event" {
    // 真实数据里 `position` 有时是 null、`assistingParticipantIds` 有时整个键都没有。
    // 这两种都不能让事件写坏或少写字段——前端只依赖「字段一定在」。
    var buffer: [4096]u8 = undefined;
    const timeline =
        \\{"frames":[{"timestamp":60000,"participantFrames":{"1":{"totalGold":1,"minionsKilled":0,"jungleMinionsKilled":0}},"events":[
        \\{"type":"CHAMPION_KILL","timestamp":61000,"killerId":1,"victimId":6,"assistingParticipantIds":"oops","position":null}]}]}
    ;
    const json = try writeTimeline(game_fixture, timeline, "", &buffer);
    var parsed = try parseForTest(json);
    defer parsed.deinit();
    const events = arrayField(parsed.value, "events") orelse return error.MissingEvents;
    try std.testing.expectEqual(@as(usize, 1), events.array.items.len);
    const kill = events.array.items[0];
    try std.testing.expectEqual(@as(usize, 0), arrayField(kill, "assistIds").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 0), intField(kill, "posX"));
    try std.testing.expectEqual(@as(i64, 0), intField(kill, "posY"));
}

test "falls back to the raw teamId's opposite when no champion destroyed the building" {
    var buffer: [16384]u8 = undefined;
    const timeline =
        \\{"frames":[{"timestamp":60000,"participantFrames":{"1":{"totalGold":1,"minionsKilled":0,"jungleMinionsKilled":0}},"events":[
        \\{"type":"BUILDING_KILL","timestamp":61000,"killerId":0,"teamId":100,"buildingType":"INHIBITOR_BUILDING"}]}]}
    ;
    const json = try writeTimeline(game_fixture, timeline, "", &buffer);
    var parsed = try parseForTest(json);
    defer parsed.deinit();
    const events = arrayField(parsed.value, "events") orelse return error.MissingEvents;
    try std.testing.expectEqual(@as(usize, 1), events.array.items.len);
    // teamId 是 100（水晶所有方）→ 摧毁方是红方。
    try std.testing.expectEqual(@as(i64, 200), intField(events.array.items[0], "team"));
}

test "rejects a payload without frames" {    var buffer: [1024]u8 = undefined;
    try std.testing.expectError(error.TimelineUnavailable, writeTimeline(game_fixture, "{\"frames\":[]}", "", &buffer));
    try std.testing.expectError(error.TimelineUnavailable, writeTimeline(game_fixture, "{}", "", &buffer));
}

test "falls back to the last frame timestamp when gameDuration is missing" {
    var buffer: [4096]u8 = undefined;
    const game =
        \\{"gameId":9,"participants":[{"participantId":1,"teamId":100,"championId":1}]}
    ;
    const timeline =
        \\{"frames":[{"timestamp":60000,"participantFrames":{"1":{"totalGold":10,"minionsKilled":1,"jungleMinionsKilled":0}},"events":[]},
        \\{"timestamp":1234567,"participantFrames":{"1":{"totalGold":20,"minionsKilled":2,"jungleMinionsKilled":0}},"events":[]}]}
    ;
    const json = try writeTimeline(game, timeline, "", &buffer);
    var parsed = try parseForTest(json);
    defer parsed.deinit();
    const root = parsed.value;
    try std.testing.expectEqual(@as(i64, 1234), intField(root, "durationSeconds"));
    const participants = arrayField(root, "participants") orelse return error.MissingParticipants;
    try std.testing.expectEqual(@as(usize, 10), participants.array.items.len);
    try std.testing.expectEqual(@as(i64, 1), intField(participants.array.items[0], "championId"));
    try std.testing.expectEqual(@as(i64, 0), intField(participants.array.items[9], "championId"));
}
