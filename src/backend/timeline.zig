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
    const key = std.fmt.bufPrint(&key_buffer, "{d}", .{payload.gameId}) catch return error.TimelineUnavailable;
    // 一局的逐帧数据是不变的（打完就固定），所以落盘缓存可以直接当权威。
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

    const json = try writeTimeline(game_json, timeline, output);
    if (self.storage) |*store| store.put("matchTimeline", key, json) catch {};
    return json;
}

/// 纯函数：`game_json` 只用来查 participantId → 阵营/英雄，逐帧数据全在 `timeline_json`。
pub fn writeTimeline(game_json: []const u8, timeline_json: []const u8, output: []u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const game = std.json.parseFromSliceLeaky(std.json.Value, allocator, game_json, .{}) catch return error.TimelineUnavailable;
    const root = std.json.parseFromSliceLeaky(std.json.Value, allocator, timeline_json, .{}) catch return error.TimelineUnavailable;
    const frames = arrayField(root, "frames") orelse return error.TimelineUnavailable;
    if (frames != .array or frames.array.items.len == 0) return error.TimelineUnavailable;

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
    try writeFrames(&writer, frames);
    try writer.writeAll("],\"events\":[");
    try writeEvents(&writer, frames, participants);
    try writer.writeAll("]}");
    return writer.buffered();
}

/// 分钟帧：第 0 帧是开局快照，画曲线时没有信息量，直接跳过。
fn writeFrames(writer: *std.Io.Writer, frames: std.json.Value) !void {
    var written: usize = 0;
    for (frames.array.items) |frame| {
        const timestamp = intField(frame, "timestamp");
        const minute = @divTrunc(timestamp, 60_000);
        if (minute <= 0) continue;
        if (minute > max_minutes) break;
        const participant_frames = nestedObject(frame, "participantFrames") orelse continue;
        if (participant_frames != .object) continue;

        var gold = [_]i64{0} ** 10;
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
        try writer.writeAll("]}");
    }
}

/// 关键事件。事件的 `team` 一律表示**做这件事的一方**（推塔/拿龙/击杀方），
/// 这样前端只需要一个「我方/敌方」的判断；丢失方由对面推出来，不必依赖
/// Riot 对 `teamId` 的含糊定义。能查到 killerId 就用它，否则按 raw `teamId` 反推。
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
        \\{"timestamp":60000,"participantFrames":{"1":{"totalGold":1500,"minionsKilled":10,"jungleMinionsKilled":2},"2":{"totalGold":1200,"minionsKilled":5,"jungleMinionsKilled":0},"6":{"totalGold":1400,"minionsKilled":12,"jungleMinionsKilled":0},"7":{"totalGold":900,"minionsKilled":3,"jungleMinionsKilled":0}},"events":[]},
        \\{"timestamp":120000,"participantFrames":{"1":{"totalGold":2600,"minionsKilled":20,"jungleMinionsKilled":4},"2":{"totalGold":2100,"minionsKilled":12,"jungleMinionsKilled":0},"6":{"totalGold":2500,"minionsKilled":24,"jungleMinionsKilled":0},"7":{"totalGold":1600,"minionsKilled":8,"jungleMinionsKilled":0}},"events":[
        \\{"type":"CHAMPION_KILL","timestamp":115000,"killerId":1,"victimId":7,"assistingParticipantIds":[2]},
        \\{"type":"ELITE_MONSTER_KILL","timestamp":118000,"killerId":6,"killerTeamId":200,"monsterType":"DRAGON","monsterSubType":"FIRE_DRAGON"},
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
    const json = try writeTimeline(game_fixture, timelineFixture(), &buffer);
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
}

test "keeps only timeline-relevant events and derives the acting team" {
    var buffer: [16384]u8 = undefined;
    const json = try writeTimeline(game_fixture, timelineFixture(), &buffer);
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

    const monster = events.array.items[1];
    try std.testing.expectEqualStrings("ELITE_MONSTER_KILL", stringField(monster, "type"));
    try std.testing.expectEqual(@as(i64, 200), intField(monster, "team"));
    try std.testing.expectEqualStrings("FIRE_DRAGON", stringField(monster, "monsterSubType"));

    const building = events.array.items[2];
    try std.testing.expectEqualStrings("BUILDING_KILL", stringField(building, "type"));
    // 推塔方是 1 号（蓝方），哪怕 raw teamId 写的是 200（被推的一方）。
    try std.testing.expectEqual(@as(i64, 100), intField(building, "team"));
    try std.testing.expectEqualStrings("OUTER_TURRET", stringField(building, "towerType"));
}

test "falls back to the raw teamId's opposite when no champion destroyed the building" {
    var buffer: [16384]u8 = undefined;
    const timeline =
        \\{"frames":[{"timestamp":60000,"participantFrames":{"1":{"totalGold":1,"minionsKilled":0,"jungleMinionsKilled":0}},"events":[
        \\{"type":"BUILDING_KILL","timestamp":61000,"killerId":0,"teamId":100,"buildingType":"INHIBITOR_BUILDING"}]}]}
    ;
    const json = try writeTimeline(game_fixture, timeline, &buffer);
    var parsed = try parseForTest(json);
    defer parsed.deinit();
    const events = arrayField(parsed.value, "events") orelse return error.MissingEvents;
    try std.testing.expectEqual(@as(usize, 1), events.array.items.len);
    // teamId 是 100（水晶所有方）→ 摧毁方是红方。
    try std.testing.expectEqual(@as(i64, 200), intField(events.array.items[0], "team"));
}

test "rejects a payload without frames" {
    var buffer: [1024]u8 = undefined;
    try std.testing.expectError(error.TimelineUnavailable, writeTimeline(game_fixture, "{\"frames\":[]}", &buffer));
    try std.testing.expectError(error.TimelineUnavailable, writeTimeline(game_fixture, "{}", &buffer));
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
    const json = try writeTimeline(game, timeline, &buffer);
    var parsed = try parseForTest(json);
    defer parsed.deinit();
    const root = parsed.value;
    try std.testing.expectEqual(@as(i64, 1234), intField(root, "durationSeconds"));
    const participants = arrayField(root, "participants") orelse return error.MissingParticipants;
    try std.testing.expectEqual(@as(usize, 10), participants.array.items.len);
    try std.testing.expectEqual(@as(i64, 1), intField(participants.array.items[0], "championId"));
    try std.testing.expectEqual(@as(i64, 0), intField(participants.array.items[9], "championId"));
}
