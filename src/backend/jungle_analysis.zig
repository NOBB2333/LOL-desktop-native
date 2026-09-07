const std = @import("std");

const analysis_minutes = 14;
const first_clear_frame = 1;
const kill_weight: f64 = 5;

const Camp = enum { blue, red, wolves, raptors };
const Side = enum { blue, red };
const Zone = enum { top, mid, bot };

const CampCount = struct {
    blue: usize = 0,
    red: usize = 0,
    wolves: usize = 0,
    raptors: usize = 0,

    fn increment(self: *CampCount, camp: Camp) void {
        switch (camp) {
            .blue => self.blue += 1,
            .red => self.red += 1,
            .wolves => self.wolves += 1,
            .raptors => self.raptors += 1,
        }
    }

    fn total(self: CampCount) usize {
        return self.blue + self.red + self.wolves + self.raptors;
    }
};

pub const Aggregate = struct {
    games: usize = 0,
    top_weight: f64 = 0,
    mid_weight: f64 = 0,
    bot_weight: f64 = 0,
    total_weight: f64 = 0,
    blue_games: usize = 0,
    red_games: usize = 0,
    blue_normal: CampCount = .{},
    blue_invade: CampCount = .{},
    red_normal: CampCount = .{},
    red_invade: CampCount = .{},
    level3_ganks: usize = 0,
    level4_ganks: usize = 0,
    first_dragon_samples: usize = 0,
    first_dragons: usize = 0,
    first_dragon_time_total: f64 = 0,
    first_dragon_time_count: usize = 0,
    dragons: usize = 0,
    voidgrubs: usize = 0,
    heralds: usize = 0,
    barons: usize = 0,

    pub fn addDetails(self: *Aggregate, details_json: []const u8, puuid: []const u8) bool {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const root = std.json.parseFromSliceLeaky(std.json.Value, allocator, details_json, .{}) catch return false;
        const payload = unwrapPayload(allocator, root) orelse return false;
        const frames = arrayField(payload, "frames") orelse return false;
        const participant_id = participantId(payload, puuid);
        if (participant_id <= 0) return false;
        self.addFrames(frames, participant_id);
        return true;
    }

    pub fn addTimeline(self: *Aggregate, timeline_json: []const u8, participant_id: i64) bool {
        if (participant_id <= 0) return false;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), timeline_json, .{}) catch return false;
        const frames = arrayField(root, "frames") orelse fallback: {
            const timeline = nestedObject(root, "timeline") orelse return false;
            break :fallback arrayField(timeline, "frames") orelse return false;
        };
        self.addFrames(frames, participant_id);
        return true;
    }

    fn addFrames(self: *Aggregate, frames: std.json.Value, participant_id: i64) void {
        const blue_side = participant_id <= 5;
        var top: f64 = 0;
        var mid: f64 = 0;
        var bot: f64 = 0;
        var total: f64 = 0;
        const path_limit = @min(frames.array.items.len, analysis_minutes + 1);
        var frame_index: usize = 1;
        while (frame_index < path_limit) : (frame_index += 1) {
            const frame = frames.array.items[frame_index];
            const participant_frame = participantFrame(frame, participant_id) orelse continue;
            const position = nestedObject(participant_frame, "position") orelse continue;
            total += 1;
            switch (classifyZone(jsonInt(position, "x"), jsonInt(position, "y"))) {
                .top => top += 1,
                .mid => mid += 1,
                .bot => bot += 1,
            }
        }

        var level3_kill = false;
        var level4_kill = false;
        var first_dragon_team: ?i64 = null;
        var our_first_dragon_time: ?f64 = null;
        const our_team: i64 = if (blue_side) 100 else 200;
        for (frames.array.items) |frame| {
            const events = arrayField(frame, "events") orelse continue;
            for (events.array.items) |event| {
                const timestamp = jsonInt(event, "timestamp");
                const event_type = jsonString(event, "type");
                if (std.mem.eql(u8, event_type, "CHAMPION_KILL") and involvedInKill(event, participant_id)) {
                    if (timestamp <= analysis_minutes * 60 * 1000) if (nestedObject(event, "position")) |position| {
                        total += kill_weight;
                        switch (classifyZone(jsonInt(position, "x"), jsonInt(position, "y"))) {
                            .top => top += kill_weight,
                            .mid => mid += kill_weight,
                            .bot => bot += kill_weight,
                        }
                    };
                    if (timestamp <= 180000) level3_kill = true else if (timestamp <= 240000) level4_kill = true;
                }
                if (!std.mem.eql(u8, event_type, "ELITE_MONSTER_KILL")) continue;
                const killer_id = jsonInt(event, "killerId");
                const killer_team = if (jsonInt(event, "killerTeamId") > 0) jsonInt(event, "killerTeamId") else if (killer_id >= 1 and killer_id <= 5) @as(i64, 100) else @as(i64, 200);
                const monster = jsonString(event, "monsterType");
                if (std.mem.eql(u8, monster, "DRAGON")) {
                    if (first_dragon_team == null) first_dragon_team = killer_team;
                    if (killer_team == our_team) {
                        self.dragons += 1;
                        if (our_first_dragon_time == null) our_first_dragon_time = @as(f64, @floatFromInt(timestamp)) / 1000.0;
                    }
                } else if (killer_team == our_team and std.mem.eql(u8, monster, "HORDE")) {
                    self.voidgrubs += 1;
                } else if (killer_team == our_team and std.mem.eql(u8, monster, "RIFTHERALD")) {
                    self.heralds += 1;
                } else if (killer_team == our_team and std.mem.eql(u8, monster, "BARON_NASHOR")) {
                    self.barons += 1;
                }
            }
        }

        self.games += 1;
        self.top_weight += top;
        self.mid_weight += mid;
        self.bot_weight += bot;
        self.total_weight += total;
        if (blue_side) self.blue_games += 1 else self.red_games += 1;

        if (frames.array.items.len > first_clear_frame) if (participantFrame(frames.array.items[first_clear_frame], participant_id)) |frame| if (nestedObject(frame, "position")) |position| {
            const start = detectStartCamp(jsonInt(position, "x"), jsonInt(position, "y"));
            if (blue_side) {
                if (start.side == .blue) self.blue_normal.increment(start.camp) else self.blue_invade.increment(start.camp);
            } else {
                if (start.side == .red) self.red_normal.increment(start.camp) else self.red_invade.increment(start.camp);
            }
        };

        const frame3 = if (frames.array.items.len > 3) participantFrame(frames.array.items[3], participant_id) else null;
        const frame4 = if (frames.array.items.len > 4) participantFrame(frames.array.items[4], participant_id) else null;
        var damage3: i64 = 0;
        if (frame3) |value| {
            const cs = jsonInt(value, "minionsKilled") + jsonInt(value, "jungleMinionsKilled");
            const damage = if (nestedObject(value, "damageStats")) |stats| jsonInt(stats, "totalDamageDoneToChampions") else 0;
            damage3 = damage;
            if (cs >= 12 and cs < 20 and jsonInt(value, "level") == 3 and (damage > 0 or level3_kill)) self.level3_ganks += 1;
        }
        if (frame4) |value| {
            const damage = if (nestedObject(value, "damageStats")) |stats| jsonInt(stats, "totalDamageDoneToChampions") else 0;
            if (damage > damage3 or level4_kill) self.level4_ganks += 1;
        }

        if (first_dragon_team) |team| {
            self.first_dragon_samples += 1;
            if (team == our_team) self.first_dragons += 1;
        }
        if (our_first_dragon_time) |time| {
            self.first_dragon_time_total += time;
            self.first_dragon_time_count += 1;
        }
    }

    pub fn writeText(self: Aggregate, writer: *std.Io.Writer, current_champion_selected: bool) !void {
        if (!current_champion_selected) return writer.writeAll("尚未选择英雄");
        if (self.games == 0) return writer.writeAll("近期没有本英雄打野记录");
        try writer.print("本英雄打野样本{d}场 ", .{self.games});
        try self.writeActivity(writer);
        try writer.writeByte(' ');
        try writeClearPattern(writer, "蓝方常规开", self.blue_normal, self.blue_games);
        try writer.writeByte(' ');
        try writeClearPattern(writer, "蓝方入侵开", self.blue_invade, self.blue_games);
        try writer.writeByte(' ');
        try writeClearPattern(writer, "红方常规开", self.red_normal, self.red_games);
        try writer.writeByte(' ');
        try writeClearPattern(writer, "红方入侵开", self.red_invade, self.red_games);
        try writer.print(" 3级抓{d:.0}% 4级抓{d:.0}% 一龙率{d:.0}%", .{
            rate(self.level3_ganks, self.games),
            rate(self.level4_ganks, self.games),
            rate(self.first_dragons, self.first_dragon_samples),
        });
        if (self.first_dragon_time_count > 0) {
            const seconds: i64 = @intFromFloat(@round(self.first_dragon_time_total / @as(f64, @floatFromInt(self.first_dragon_time_count))));
            const remaining = @mod(seconds, 60);
            try writer.print("，首龙均时{d}:", .{@divTrunc(seconds, 60)});
            if (remaining < 10) try writer.writeByte('0');
            try writer.print("{d}", .{remaining});
        }
        const games = @as(f64, @floatFromInt(self.games));
        try writer.print(" 场均小龙{d:.1} 野怪资源巢虫{d:.1}/先锋{d:.1}/大龙{d:.1}", .{
            @as(f64, @floatFromInt(self.dragons)) / games,
            @as(f64, @floatFromInt(self.voidgrubs)) / games,
            @as(f64, @floatFromInt(self.heralds)) / games,
            @as(f64, @floatFromInt(self.barons)) / games,
        });
    }

    fn writeActivity(self: Aggregate, writer: *std.Io.Writer) !void {
        const total = if (self.total_weight > 0) self.total_weight else 1;
        const values = [_]struct { label: []const u8, value: f64 }{
            .{ .label = "上", .value = self.top_weight / total },
            .{ .label = "中", .value = self.mid_weight / total },
            .{ .label = "下", .value = self.bot_weight / total },
        };
        var order = [_]usize{ 0, 1, 2 };
        if (values[order[1]].value > values[order[0]].value) std.mem.swap(usize, &order[0], &order[1]);
        if (values[order[2]].value > values[order[1]].value) std.mem.swap(usize, &order[1], &order[2]);
        if (values[order[1]].value > values[order[0]].value) std.mem.swap(usize, &order[0], &order[1]);
        if (values[order[0]].value == 0) {
            try writer.writeAll("前期偏好不明");
        } else if (values[order[1]].value >= values[order[0]].value * 0.65) {
            try writer.print("前期偏{s}{s}", .{ values[order[0]].label, values[order[1]].label });
        } else {
            try writer.print("前期偏{s}", .{values[order[0]].label});
        }
        try writer.print("，上{d:.0}%中{d:.0}%下{d:.0}%", .{ values[0].value * 100, values[1].value * 100, values[2].value * 100 });
    }
};

/// LeagueAkari's easy-gank label is based on exact pre-15-minute deaths where
/// the enemy jungler was the killer or an assister. SUMMARY data cannot
/// provide this metric, so callers pass a cached DETAILS/timeline payload.
pub fn earlyDeathsFromDetails(details_json: []const u8, puuid: []const u8) ?usize {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = std.json.parseFromSliceLeaky(std.json.Value, allocator, details_json, .{}) catch return null;
    const payload = unwrapPayload(allocator, root) orelse return null;
    const frames = arrayField(payload, "frames") orelse return null;
    return earlyDeathsWithEnemyJungler(payload, frames, puuid);
}

pub fn earlyDeathsFromTimeline(timeline_json: []const u8, game_json: []const u8, puuid: []const u8) ?usize {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const timeline_root = std.json.parseFromSliceLeaky(std.json.Value, allocator, timeline_json, .{}) catch return null;
    const game_root = std.json.parseFromSliceLeaky(std.json.Value, allocator, game_json, .{}) catch return null;
    const payload = unwrapPayload(allocator, game_root) orelse return null;
    const frames = arrayField(timeline_root, "frames") orelse fallback: {
        const timeline = nestedObject(timeline_root, "timeline") orelse return null;
        break :fallback arrayField(timeline, "frames") orelse return null;
    };
    return earlyDeathsWithEnemyJungler(payload, frames, puuid);
}

fn earlyDeathsWithEnemyJungler(payload: std.json.Value, frames: std.json.Value, puuid: []const u8) ?usize {
    if (jsonInt(payload, "mapId") > 0 and jsonInt(payload, "mapId") != 11) return null;
    const game_mode = jsonString(payload, "gameMode");
    if (game_mode.len > 0 and !std.ascii.eqlIgnoreCase(game_mode, "CLASSIC")) return null;
    const game_type = jsonString(payload, "gameType");
    if (game_type.len > 0 and !std.ascii.eqlIgnoreCase(game_type, "MATCHED_GAME")) return null;

    const participants = arrayField(payload, "participants") orelse return null;
    const self_id = participantId(payload, puuid);
    if (self_id <= 0) return null;
    const self_participant = participantById(participants, self_id) orelse return null;
    if (isJungler(self_participant)) return null;
    const self_team = participantTeam(self_participant, self_id);

    var enemy_junglers: [5]i64 = undefined;
    var enemy_count: usize = 0;
    for (participants.array.items) |participant| {
        const id = jsonInt(participant, "participantId");
        if (id <= 0 or participantTeam(participant, id) == self_team or !positionIsJungle(participant)) continue;
        enemy_junglers[enemy_count] = id;
        enemy_count += 1;
        if (enemy_count == enemy_junglers.len) break;
    }
    if (enemy_count == 0) for (participants.array.items) |participant| {
        const id = jsonInt(participant, "participantId");
        if (id <= 0 or participantTeam(participant, id) == self_team or !hasSmite(participant)) continue;
        enemy_junglers[enemy_count] = id;
        enemy_count += 1;
        if (enemy_count == enemy_junglers.len) break;
    };
    if (enemy_count == 0) return null;

    var deaths: usize = 0;
    for (frames.array.items) |frame| {
        const events = arrayField(frame, "events") orelse continue;
        for (events.array.items) |event| {
            if (!std.mem.eql(u8, jsonString(event, "type"), "CHAMPION_KILL") or
                jsonInt(event, "timestamp") > 15 * 60 * 1000 or
                jsonInt(event, "victimId") != self_id) continue;
            if (idInList(jsonInt(event, "killerId"), enemy_junglers[0..enemy_count]) or
                assistContainsAny(event, enemy_junglers[0..enemy_count])) deaths += 1;
        }
    }
    return deaths;
}

fn participantById(participants: std.json.Value, participant_id: i64) ?std.json.Value {
    for (participants.array.items) |participant| {
        if (jsonInt(participant, "participantId") == participant_id) return participant;
    }
    return null;
}

fn participantTeam(participant: std.json.Value, participant_id: i64) i64 {
    const team_id = jsonInt(participant, "teamId");
    if (team_id > 0) return team_id;
    return if (participant_id <= 5) 100 else 200;
}

fn isJungler(participant: std.json.Value) bool {
    return positionIsJungle(participant) or hasSmite(participant);
}

fn positionIsJungle(participant: std.json.Value) bool {
    for ([_][]const u8{ "teamPosition", "individualPosition", "position", "lane" }) |field| {
        if (std.ascii.eqlIgnoreCase(jsonString(participant, field), "JUNGLE")) return true;
    }
    return false;
}

fn hasSmite(participant: std.json.Value) bool {
    if (jsonInt(participant, "spell1Id") == 11 or jsonInt(participant, "spell2Id") == 11) return true;
    const spells = arrayField(participant, "spells") orelse return false;
    for (spells.array.items) |spell| {
        const id = switch (spell) {
            .integer => |value| value,
            .float => |value| @as(i64, @intFromFloat(value)),
            else => 0,
        };
        if (id == 11) return true;
    }
    return false;
}

fn idInList(id: i64, ids: []const i64) bool {
    for (ids) |candidate| if (candidate == id) return true;
    return false;
}

fn assistContainsAny(event: std.json.Value, ids: []const i64) bool {
    const assists = arrayField(event, "assistingParticipantIds") orelse return false;
    for (assists.array.items) |value| {
        const id = switch (value) {
            .integer => |number| number,
            .float => |number| @as(i64, @intFromFloat(number)),
            else => 0,
        };
        if (idInList(id, ids)) return true;
    }
    return false;
}

fn writeClearPattern(writer: *std.Io.Writer, label: []const u8, camps: CampCount, side_games: usize) !void {
    const count = camps.total();
    if (side_games == 0) return writer.print("{s}-", .{label});
    try writer.print("{s}{d:.0}%", .{ label, rate(count, side_games) });
    if (count == 0) return;
    try writer.writeByte('[');
    const entries = [_]struct { label: []const u8, count: usize }{
        .{ .label = "蓝Buff", .count = camps.blue },
        .{ .label = "红Buff", .count = camps.red },
        .{ .label = "三狼", .count = camps.wolves },
        .{ .label = "F6", .count = camps.raptors },
    };
    var used = [_]bool{false} ** entries.len;
    var emitted: usize = 0;
    while (emitted < entries.len) {
        var best: ?usize = null;
        for (entries, 0..) |entry, index| {
            if (used[index] or entry.count == 0) continue;
            if (best == null or entry.count > entries[best.?].count) best = index;
        }
        const index = best orelse break;
        used[index] = true;
        if (emitted > 0) try writer.writeAll("，");
        try writer.print("{s}{d:.0}%", .{ entries[index].label, rate(entries[index].count, count) });
        emitted += 1;
    }
    try writer.writeByte(']');
}

fn rate(numerator: usize, denominator: usize) f64 {
    if (denominator == 0) return 0;
    return @as(f64, @floatFromInt(numerator)) / @as(f64, @floatFromInt(denominator)) * 100;
}

fn participantId(payload: std.json.Value, puuid: []const u8) i64 {
    const participants = arrayField(payload, "participants") orelse return 0;
    for (participants.array.items) |participant| {
        const candidate = if (jsonString(participant, "puuid").len > 0) jsonString(participant, "puuid") else jsonString(participant, "playerPuuid");
        if (std.mem.eql(u8, candidate, puuid)) return jsonInt(participant, "participantId");
    }
    const identities = arrayField(payload, "participantIdentities") orelse return 0;
    for (identities.array.items) |identity| {
        const player = nestedObject(identity, "player") orelse identity;
        if (std.mem.eql(u8, jsonString(player, "puuid"), puuid)) return jsonInt(identity, "participantId");
    }
    return 0;
}

fn participantFrame(frame: std.json.Value, participant_id: i64) ?std.json.Value {
    const frames = if (frame == .object) frame.object.get("participantFrames") orelse return null else return null;
    if (frames == .object) {
        var key_buffer: [16]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buffer, "{d}", .{participant_id}) catch return null;
        return frames.object.get(key);
    }
    if (frames == .array and participant_id > 0) {
        const index: usize = @intCast(participant_id - 1);
        return if (index < frames.array.items.len) frames.array.items[index] else null;
    }
    return null;
}

fn involvedInKill(event: std.json.Value, participant_id: i64) bool {
    if (jsonInt(event, "killerId") == participant_id) return true;
    const assists = arrayField(event, "assistingParticipantIds") orelse return false;
    for (assists.array.items) |value| if (value == .integer and value.integer == participant_id) return true;
    return false;
}

fn classifyZone(x: i64, y: i64) Zone {
    if (x < 5000 and y > 9000) return .top;
    if (x > 9000 and y < 5000) return .bot;
    if (@abs(y - x) <= 3500) return .mid;
    return if (y > x) .top else .bot;
}

fn detectStartCamp(x: i64, y: i64) struct { camp: Camp, side: Side } {
    const camps = [_]struct { x: i64, y: i64, camp: Camp, side: Side }{
        .{ .x = 3830, .y = 7880, .camp = .blue, .side = .blue },
        .{ .x = 3800, .y = 6440, .camp = .wolves, .side = .blue },
        .{ .x = 7760, .y = 4010, .camp = .red, .side = .blue },
        .{ .x = 6970, .y = 5460, .camp = .raptors, .side = .blue },
        .{ .x = 10990, .y = 7000, .camp = .blue, .side = .red },
        .{ .x = 11020, .y = 8440, .camp = .wolves, .side = .red },
        .{ .x = 7060, .y = 10870, .camp = .red, .side = .red },
        .{ .x = 7850, .y = 9420, .camp = .raptors, .side = .red },
    };
    var best = camps[0];
    var best_distance: i128 = std.math.maxInt(i128);
    for (camps) |camp| {
        const dx: i128 = x - camp.x;
        const dy: i128 = y - camp.y;
        const distance = dx * dx + dy * dy;
        if (distance < best_distance) {
            best = camp;
            best_distance = distance;
        }
    }
    return .{ .camp = best.camp, .side = best.side };
}

fn unwrapPayload(allocator: std.mem.Allocator, root: std.json.Value) ?std.json.Value {
    if (root != .object) return null;
    const wrapped = root.object.get("json") orelse return root;
    return switch (wrapped) {
        .object => wrapped,
        .string => |encoded| std.json.parseFromSliceLeaky(std.json.Value, allocator, encoded, .{}) catch null,
        else => null,
    };
}

fn arrayField(value: std.json.Value, field: []const u8) ?std.json.Value {
    if (value != .object) return null;
    const item = value.object.get(field) orelse return null;
    return if (item == .array) item else null;
}

fn nestedObject(value: std.json.Value, field: []const u8) ?std.json.Value {
    if (value != .object) return null;
    const item = value.object.get(field) orelse return null;
    return if (item == .object) item else null;
}

fn jsonString(value: std.json.Value, field: []const u8) []const u8 {
    if (value != .object) return "";
    const item = value.object.get(field) orelse return "";
    return if (item == .string) item.string else "";
}

fn jsonInt(value: std.json.Value, field: []const u8) i64 {
    if (value != .object) return 0;
    const item = value.object.get(field) orelse return 0;
    return switch (item) {
        .integer => |number| number,
        .float => |number| @intFromFloat(number),
        .string => |text| std.fmt.parseInt(i64, text, 10) catch 0,
        else => 0,
    };
}

test "formats the LeagueAkari jungle preset metrics" {
    const aggregate = Aggregate{
        .games = 16,
        .top_weight = 22,
        .mid_weight = 46,
        .bot_weight = 32,
        .total_weight = 100,
        .blue_games = 4,
        .red_games = 4,
        .blue_normal = .{ .red = 2, .blue = 1 },
        .blue_invade = .{ .blue = 1 },
        .red_normal = .{ .blue = 3, .red = 1 },
        .level3_ganks = 5,
        .level4_ganks = 8,
        .first_dragon_samples = 16,
        .first_dragons = 10,
        .first_dragon_time_total = 3720,
        .first_dragon_time_count = 10,
        .dragons = 30,
        .voidgrubs = 38,
        .heralds = 8,
        .barons = 5,
    };
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try aggregate.writeText(&writer, true);
    try std.testing.expectEqualStrings(
        "本英雄打野样本16场 前期偏中下，上22%中46%下32% 蓝方常规开75%[红Buff67%，蓝Buff33%] 蓝方入侵开25%[蓝Buff100%] 红方常规开100%[蓝Buff75%，红Buff25%] 红方入侵开0% 3级抓31% 4级抓50% 一龙率63%，首龙均时6:12 场均小龙1.9 野怪资源巢虫2.4/先锋0.5/大龙0.3",
        writer.buffered(),
    );
}

test "counts only early deaths involving the enemy jungler" {
    const details =
        "{\"mapId\":11,\"gameMode\":\"CLASSIC\",\"gameType\":\"MATCHED_GAME\",\"participants\":[" ++
        "{\"puuid\":\"target\",\"participantId\":1,\"teamId\":100,\"teamPosition\":\"TOP\",\"spell1Id\":4,\"spell2Id\":12}," ++
        "{\"puuid\":\"enemy-jungle\",\"participantId\":6,\"teamId\":200,\"teamPosition\":\"JUNGLE\",\"spell1Id\":11,\"spell2Id\":4}," ++
        "{\"puuid\":\"enemy-mid\",\"participantId\":7,\"teamId\":200,\"teamPosition\":\"MIDDLE\"}],\"frames\":[{\"events\":[" ++
        "{\"type\":\"CHAMPION_KILL\",\"timestamp\":300000,\"victimId\":1,\"killerId\":7,\"assistingParticipantIds\":[6]}," ++
        "{\"type\":\"CHAMPION_KILL\",\"timestamp\":500000,\"victimId\":1,\"killerId\":7,\"assistingParticipantIds\":[]}," ++
        "{\"type\":\"CHAMPION_KILL\",\"timestamp\":950000,\"victimId\":1,\"killerId\":6,\"assistingParticipantIds\":[]}]}]}";
    try std.testing.expectEqual(@as(?usize, 1), earlyDeathsFromDetails(details, "target"));
}

test "counts easy-gank evidence from separate LCU game and timeline payloads" {
    const game =
        "{\"mapId\":11,\"gameMode\":\"CLASSIC\",\"gameType\":\"MATCHED_GAME\",\"participants\":[" ++
        "{\"puuid\":\"target\",\"participantId\":2,\"teamId\":100,\"teamPosition\":\"MIDDLE\"}," ++
        "{\"puuid\":\"enemy-jungle\",\"participantId\":7,\"teamId\":200,\"teamPosition\":\"JUNGLE\",\"spell1Id\":11}]}";
    const timeline =
        "{\"frames\":[{\"events\":[" ++
        "{\"type\":\"CHAMPION_KILL\",\"timestamp\":600000,\"victimId\":2,\"killerId\":8,\"assistingParticipantIds\":[7]}," ++
        "{\"type\":\"CHAMPION_KILL\",\"timestamp\":700000,\"victimId\":2,\"killerId\":8,\"assistingParticipantIds\":[]}" ++
        "]}]}";
    try std.testing.expectEqual(@as(?usize, 1), earlyDeathsFromTimeline(timeline, game, "target"));
}

test "does not calculate easy-gank evidence for a jungler" {
    const details = "{\"mapId\":11,\"gameMode\":\"CLASSIC\",\"gameType\":\"MATCHED_GAME\",\"participants\":[{\"puuid\":\"target\",\"participantId\":1,\"teamId\":100,\"teamPosition\":\"JUNGLE\",\"spell1Id\":11},{\"participantId\":6,\"teamId\":200,\"teamPosition\":\"JUNGLE\"}],\"frames\":[]}";
    try std.testing.expect(earlyDeathsFromDetails(details, "target") == null);
}
