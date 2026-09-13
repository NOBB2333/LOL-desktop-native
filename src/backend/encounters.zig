const std = @import("std");

/// 某位玩家在本地遭遇档案里的汇总：共遇到几次、最近一次是什么时候。
///
/// 原先放在 `recent_tags.zig`，那里同时还在产出「玩家标签」；标签体系迁到前端后
/// 该模块被整体删除，这个纯遭遇数据的结构就归到 encounters 这边。
pub const EncounterSummary = struct {
    count: usize = 0,
    latest: [32]u8 = undefined,
    latest_len: usize = 0,

    pub fn latestValue(self: *const EncounterSummary) []const u8 {
        return self.latest[0..self.latest_len];
    }
};

const EncounterKey = struct {
    game_id: i64,
    owner_hash: u64,
    player_hash: u64,
};

pub fn mergeArchive(existing_json: []const u8, newest_json: []const u8, owner_puuid: []const u8, cutoff_iso: []const u8, output: []u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const existing = std.json.parseFromSliceLeaky(std.json.Value, allocator, existing_json, .{}) catch std.json.Value{ .null = {} };
    const newest = std.json.parseFromSliceLeaky(std.json.Value, allocator, newest_json, .{}) catch return error.InvalidEncounterArchive;
    if (newest != .array) return error.InvalidEncounterArchive;

    var seen = std.AutoHashMap(EncounterKey, void).init(allocator);
    var writer = std.Io.Writer.fixed(output);
    try writer.writeByte('[');
    var emitted = false;
    for ([_]std.json.Value{ newest, existing }) |source| {
        if (source != .array) continue;
        for (source.array.items) |record| {
            if (record != .object) continue;
            const encountered_at = jsonField(record, "encounteredAt");
            if (cutoff_iso.len > 0 and (encountered_at.len == 0 or std.mem.order(u8, encountered_at, cutoff_iso) == .lt)) continue;
            const game_id = jsonInt(record, "gameId");
            const puuid = jsonField(record, "puuid");
            const record_owner = jsonField(record, "selfPuuid");
            if (game_id <= 0 or puuid.len == 0) continue;
            // 旧版本也归档过被查询玩家的历史，缺少本人身份的旧行无法确认归属。
            if (owner_puuid.len > 0 and !sameIdentity(record_owner, owner_puuid)) continue;
            const key = EncounterKey{
                .game_id = game_id,
                .owner_hash = std.hash.Wyhash.hash(0, record_owner),
                .player_hash = std.hash.Wyhash.hash(0, puuid),
            };
            const entry = try seen.getOrPut(key);
            if (entry.found_existing) continue;
            if (emitted) try writer.writeByte(',');
            emitted = true;
            var stringify = std.json.Stringify{ .writer = &writer, .options = .{} };
            try stringify.write(record);
        }
    }
    try writer.writeByte(']');
    return writer.buffered();
}

pub fn filterArchive(json: []const u8, owner_puuid: []const u8, cutoff_iso: []const u8, output: []u8) ![]const u8 {
    return mergeArchive(json, "[]", owner_puuid, cutoff_iso, output);
}

/// 返回目标参与的完整对局，保留其他参与者，供界面还原整局摘要。
pub fn queryArchive(json: []const u8, owner_puuid: []const u8, target_puuid: []const u8, cutoff_iso: []const u8, max_games: usize, output: []u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{}) catch return error.InvalidEncounterArchive;
    if (root != .array) return std.fmt.bufPrint(output, "[]", .{});
    return queryRecords(root.array.items, owner_puuid, target_puuid, cutoff_iso, max_games, 0, output);
}

fn queryRecords(records: []const std.json.Value, owner_puuid: []const u8, target_puuid: []const u8, cutoff_iso: []const u8, max_games: usize, excluded_game_id: i64, output: []u8) ![]const u8 {
    const SelectedGame = struct {
        id: i64,
        encountered_at: []const u8,
    };
    var selected: [100]SelectedGame = undefined;
    var selected_len: usize = 0;
    const limit = @min(@max(max_games, 1), selected.len);

    for (records) |record| {
        if (!recordInScope(record, owner_puuid, cutoff_iso)) continue;
        if (target_puuid.len > 0 and !sameIdentity(jsonField(record, "puuid"), target_puuid)) continue;
        const game_id = jsonInt(record, "gameId");
        if (game_id == excluded_game_id) continue;
        var duplicate = false;
        for (selected[0..selected_len]) |game| if (game.id == game_id) {
            duplicate = true;
            break;
        };
        if (duplicate) continue;
        const candidate = SelectedGame{ .id = game_id, .encountered_at = jsonField(record, "encounteredAt") };
        if (selected_len < limit) {
            selected[selected_len] = candidate;
            selected_len += 1;
            continue;
        }
        var oldest: usize = 0;
        for (selected[1..selected_len], 1..) |game, index| {
            if (std.mem.order(u8, game.encountered_at, selected[oldest].encountered_at) == .lt) oldest = index;
        }
        if (std.mem.order(u8, candidate.encountered_at, selected[oldest].encountered_at) == .gt) selected[oldest] = candidate;
    }

    std.mem.sort(SelectedGame, selected[0..selected_len], {}, struct {
        fn lessThan(_: void, a: SelectedGame, b: SelectedGame) bool {
            return std.mem.order(u8, a.encountered_at, b.encountered_at) == .gt;
        }
    }.lessThan);
    var writer = std.Io.Writer.fixed(output);
    try writer.writeByte('[');
    var emitted = false;
    for (selected[0..selected_len]) |game| for (records) |record| {
        if (!recordInScope(record, owner_puuid, cutoff_iso) or jsonInt(record, "gameId") != game.id) continue;
        if (emitted) try writer.writeByte(',');
        emitted = true;
        var stringify = std.json.Stringify{ .writer = &writer, .options = .{} };
        try stringify.write(record);
    };
    try writer.writeByte(']');
    return writer.buffered();
}

/// 一次构建的相遇记录索引。
///
/// 加载十名玩家时，每人的输入历史集合几乎完全相同（本人 + 当前阵容），
/// 只有目标的 puuid 不同。旧实现为每个玩家各跑一次 `fromHistories`，
/// 也就是各分配 4MB 并把十几份战绩重新解析一遍，代价随人数平方增长。
/// 索引只构建一次，之后每次查询只是对已解析记录的线性扫描。
pub const EncounterIndex = struct {
    arena: *std.heap.ArenaAllocator,
    records: std.array_list.Managed(std.json.Value),

    /// 记录里的所有 JSON 值都活在自己的 arena 里，一次释放干净，调用方
    /// 不需要再为索引准备一个活得够久的 allocator。
    pub fn deinit(self: *EncounterIndex) void {
        self.arena.deinit();
        std.heap.page_allocator.destroy(self.arena);
    }

    pub fn query(self: *const EncounterIndex, owner_puuid: []const u8, target_puuid: []const u8, max_games: usize, excluded_game_id: i64, output: []u8) ![]const u8 {
        return queryRecords(self.records.items, owner_puuid, target_puuid, "", @min(max_games, 40), excluded_game_id, output);
    }

    /// 直接统计某个对手的相遇次数与最近时间，不再经过 JSON 序列化与解析。
    /// 返回的 `latest` 借用索引内部字符串，索引存活期间有效。
    pub fn encounterWith(self: *const EncounterIndex, owner_puuid: []const u8, target_puuid: []const u8, excluded_game_id: i64) EncounterStat {
        var stat = EncounterStat{};
        if (target_puuid.len == 0) return stat;
        for (self.records.items) |record| {
            if (!recordInScope(record, owner_puuid, "")) continue;
            if (!sameIdentity(jsonField(record, "puuid"), target_puuid)) continue;
            if (jsonInt(record, "gameId") == excluded_game_id) continue;
            stat.count += 1;
            const stamp = jsonField(record, "encounteredAt");
            if (stamp.len > 0 and (stat.latest.len == 0 or std.mem.order(u8, stamp, stat.latest) == .gt)) stat.latest = stamp;
        }
        return stat;
    }
};

pub const EncounterStat = struct {
    count: usize = 0,
    latest: []const u8 = "",
};

/// 把若干份战绩展开成去重后的相遇记录集合。索引自带 arena，`deinit` 一次性释放。
pub fn buildIndex(histories: []const []const u8, self_puuid: []const u8, catalog_json: []const u8, excluded_game_id: i64) !EncounterIndex {
    const arena = try std.heap.page_allocator.create(std.heap.ArenaAllocator);
    errdefer std.heap.page_allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    var records: std.array_list.Managed(std.json.Value) = .init(allocator);
    if (self_puuid.len == 0) return .{ .arena = arena, .records = records };
    const buffer = try std.heap.page_allocator.alloc(u8, 4 * 1024 * 1024);
    defer std.heap.page_allocator.free(buffer);
    var seen = std.AutoHashMap(EncounterKey, usize).init(allocator);
    for (histories) |history| {
        const json = fromHistory(history, self_puuid, catalog_json, buffer) catch continue;
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{ .allocate = .alloc_always });
        for (parsed.array.items) |record| {
            const game_id = jsonInt(record, "gameId");
            if (game_id == excluded_game_id) continue;
            var hash = std.hash.Wyhash.init(0);
            for (std.mem.trim(u8, jsonField(record, "puuid"), " \t\r\n")) |byte| hash.update(&.{std.ascii.toLower(byte)});
            const key = EncounterKey{ .game_id = game_id, .owner_hash = 0, .player_hash = hash.final() };
            const entry = try seen.getOrPut(key);
            if (!entry.found_existing) {
                entry.value_ptr.* = records.items.len;
                try records.append(record);
            } else if (record.object.contains("win") and !records.items[entry.value_ptr.*].object.contains("win")) {
                records.items[entry.value_ptr.*] = record;
            }
        }
    }
    return .{ .arena = arena, .records = records };
}

/// 仅使用已加载的战绩派生共同对局，不建立长期相遇档案。
pub fn fromHistories(histories: []const []const u8, self_puuid: []const u8, target_puuid: []const u8, catalog_json: []const u8, max_games: usize, excluded_game_id: i64, output: []u8) ![]const u8 {
    var index = try buildIndex(histories, self_puuid, catalog_json, excluded_game_id);
    defer index.deinit();
    if (self_puuid.len == 0) return std.fmt.bufPrint(output, "[]", .{});
    return index.query(self_puuid, target_puuid, max_games, excluded_game_id, output);
}

fn recordInScope(record: std.json.Value, owner_puuid: []const u8, cutoff_iso: []const u8) bool {
    if (record != .object or jsonInt(record, "gameId") <= 0 or jsonField(record, "puuid").len == 0) return false;
    if (owner_puuid.len > 0 and !sameIdentity(jsonField(record, "selfPuuid"), owner_puuid)) return false;
    const encountered_at = jsonField(record, "encounteredAt");
    return cutoff_iso.len == 0 or (encountered_at.len > 0 and std.mem.order(u8, encountered_at, cutoff_iso) != .lt);
}

pub fn fromHistory(history_json: []const u8, self_puuid: []const u8, catalog_json: []const u8, output: []u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = std.json.parseFromSliceLeaky(std.json.Value, allocator, history_json, .{}) catch return error.InvalidMatchHistory;
    const catalog = std.json.parseFromSliceLeaky(std.json.Value, allocator, catalog_json, .{}) catch std.json.Value{ .null = {} };
    const list = historyGames(root) orelse return std.fmt.bufPrint(output, "[]", .{});

    var writer = std.Io.Writer.fixed(output);
    try writer.writeByte('[');
    var first = true;
    for (list.array.items) |entry| {
        const game = decodedGame(allocator, entry) orelse continue;
        const game_id = jsonInt(game, "gameId");
        if (game_id <= 0) continue;
        const participants = game.object.get("participants") orelse continue;
        if (participants != .array) continue;
        const self_participant = participantForPuuid(game, participants, self_puuid);
        if (self_participant == .null) continue;
        const self_identity = participantIdentity(game, self_participant);
        const self_name = participantName(self_participant, self_identity, "未知玩家");
        const self_tag = participantTag(self_participant, self_identity);
        const self_team_id = jsonInt(self_participant, "teamId");
        const self_subteam_id = statInt(self_participant, "playerSubteamId");
        const self_side = jsonField(self_participant, "side");
        const self_win = statBool(self_participant, "win");
        const self_champion_id = jsonInt(self_participant, "championId");
        const self_champion_name = championName(catalog, self_champion_id, jsonField(self_participant, "championName"));
        const self_position = participantPosition(self_participant);
        const queue = nestedObject(game, "queue") orelse std.json.Value{ .null = {} };
        const queue_id = if (jsonInt(game, "queueId") > 0) jsonInt(game, "queueId") else jsonInt(queue, "id");
        const queue_name = firstString(&.{
            jsonField(game, "queueName"),
            jsonField(game, "gameMode"),
            jsonField(queue, "name"),
        }, "对局");

        for (participants.array.items) |participant| {
            if (participant != .object) continue;
            const identity = participantIdentity(game, participant);
            const puuid = participantPuuid(participant, identity);
            if (puuid.len == 0 or sameIdentity(puuid, self_puuid)) continue;
            if (!first) try writer.writeByte(',');
            first = false;
            const participant_side = jsonField(participant, "side");
            const side = if (self_subteam_id > 0 and statInt(participant, "playerSubteamId") > 0)
                if (self_subteam_id == statInt(participant, "playerSubteamId")) "ally" else "enemy"
            else if (participant_side.len > 0 and self_side.len > 0)
                if (std.ascii.eqlIgnoreCase(participant_side, self_side)) "ally" else "enemy"
            else if (jsonInt(participant, "teamId") > 0 and self_team_id > 0)
                if (jsonInt(participant, "teamId") == self_team_id) "ally" else "enemy"
            else
                "unknown";
            const target_champion_id = jsonInt(participant, "championId");
            const target_champion_name = championName(catalog, target_champion_id, jsonField(participant, "championName"));

            try writer.print("{{\"gameId\":{d},\"queueId\":{d},\"queueName\":", .{ game_id, queue_id });
            try jsonString(&writer, queue_name);
            try writer.writeAll(",\"selfPuuid\":");
            try jsonString(&writer, self_puuid);
            try writer.writeAll(",\"selfGameName\":");
            try jsonString(&writer, self_name);
            try writer.writeAll(",\"selfTagLine\":");
            try jsonString(&writer, self_tag);
            try writer.print(",\"selfChampionId\":{d},\"selfChampionName\":", .{self_champion_id});
            try jsonString(&writer, self_champion_name);
            try writer.writeAll(",\"selfPosition\":");
            try jsonString(&writer, self_position);
            try writeStats(&writer, self_participant, true);
            try writer.writeAll(",\"puuid\":");
            try jsonString(&writer, puuid);
            try writer.writeAll(",\"gameName\":");
            try jsonString(&writer, participantName(participant, identity, "未知玩家"));
            try writer.writeAll(",\"tagLine\":");
            try jsonString(&writer, participantTag(participant, identity));
            try writer.print(",\"championId\":{d},\"championName\":", .{target_champion_id});
            try jsonString(&writer, target_champion_name);
            try writer.writeAll(",\"side\":");
            try jsonString(&writer, side);
            try writer.writeAll(",\"position\":");
            try jsonString(&writer, participantPosition(participant));
            try writeStats(&writer, participant, false);
            try writer.writeAll(",\"result\":");
            const recorded_result = jsonField(game, "result");
            if (recorded_result.len > 0) try jsonString(&writer, recorded_result) else if (hasStat(self_participant, "win")) {
                try jsonString(&writer, if (self_win) "胜利" else "失败");
            } else try writer.writeAll("null");
            try writer.writeAll(",\"encounteredAt\":");
            const played_at = jsonField(game, "playedAt");
            if (played_at.len > 0) {
                try jsonString(&writer, played_at);
            } else {
                const timestamp = if (jsonInt(game, "gameEndTimestamp") > 0) jsonInt(game, "gameEndTimestamp") else jsonInt(game, "gameCreation");
                try writeIsoTimestamp(&writer, timestamp);
            }
            try writer.writeByte('}');
        }
    }
    try writer.writeByte(']');
    return writer.buffered();
}

fn historyGames(root: std.json.Value) ?std.json.Value {
    if (root == .array) return root;
    if (root != .object) return null;
    const value = root.object.get("games") orelse return null;
    if (value == .array) return value;
    if (value == .object) {
        const nested = value.object.get("games") orelse return null;
        if (nested == .array) return nested;
    }
    return null;
}

fn decodedGame(allocator: std.mem.Allocator, entry: std.json.Value) ?std.json.Value {
    if (entry != .object) return null;
    const payload = entry.object.get("json") orelse return entry;
    return switch (payload) {
        .string => |encoded| std.json.parseFromSliceLeaky(std.json.Value, allocator, encoded, .{}) catch null,
        .object => payload,
        else => entry,
    };
}

fn participantForPuuid(game: std.json.Value, participants: std.json.Value, puuid: []const u8) std.json.Value {
    if (participants != .array) return .{ .null = {} };
    for (participants.array.items) |participant| {
        if (participant != .object) continue;
        const identity = participantIdentity(game, participant);
        if (sameIdentity(participantPuuid(participant, identity), puuid)) return participant;
    }
    return .{ .null = {} };
}

fn participantIdentity(game: std.json.Value, participant: std.json.Value) std.json.Value {
    const direct = nestedObject(participant, "identity") orelse std.json.Value{ .null = {} };
    if (direct != .null) return nestedObject(direct, "player") orelse direct;
    if (game != .object) return .{ .null = {} };
    const participant_id = jsonInt(participant, "participantId");
    const identities = game.object.get("participantIdentities") orelse return .{ .null = {} };
    if (identities != .array) return .{ .null = {} };
    for (identities.array.items) |identity| {
        if (identity == .object and jsonInt(identity, "participantId") == participant_id) return nestedObject(identity, "player") orelse identity;
    }
    return .{ .null = {} };
}

fn participantPuuid(participant: std.json.Value, identity: std.json.Value) []const u8 {
    return firstString(&.{
        jsonField(participant, "puuid"),
        jsonField(participant, "playerPuuid"),
        jsonField(identity, "puuid"),
    }, "");
}

fn participantName(participant: std.json.Value, identity: std.json.Value, fallback: []const u8) []const u8 {
    const explicit = firstString(&.{
        jsonField(participant, "gameName"),
        jsonField(participant, "riotIdGameName"),
        splitRiotId(jsonField(participant, "riotId")).name,
        jsonField(participant, "summonerName"),
        jsonField(identity, "gameName"),
        jsonField(identity, "riotIdGameName"),
        splitRiotId(jsonField(identity, "riotId")).name,
        jsonField(identity, "summonerName"),
    }, "");
    return if (explicit.len > 0) explicit else fallback;
}

fn participantTag(participant: std.json.Value, identity: std.json.Value) []const u8 {
    return firstString(&.{
        jsonField(participant, "tagLine"),
        jsonField(participant, "gameTag"),
        jsonField(participant, "riotIdTagLine"),
        jsonField(participant, "riotIdTagline"),
        splitRiotId(jsonField(participant, "riotId")).tag,
        jsonField(identity, "tagLine"),
        jsonField(identity, "gameTag"),
        jsonField(identity, "riotIdTagLine"),
        splitRiotId(jsonField(identity, "riotId")).tag,
    }, "");
}

const RiotId = struct { name: []const u8 = "", tag: []const u8 = "" };

fn splitRiotId(value: []const u8) RiotId {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    const separator = std.mem.lastIndexOfScalar(u8, trimmed, '#') orelse return .{ .name = trimmed };
    return .{
        .name = std.mem.trim(u8, trimmed[0..separator], " \t\r\n"),
        .tag = std.mem.trim(u8, trimmed[separator + 1 ..], " \t\r\n"),
    };
}

fn championName(catalog: std.json.Value, champion_id: i64, fallback: []const u8) []const u8 {
    if (catalog == .array and champion_id > 0) for (catalog.array.items) |champion| {
        if (champion == .object and jsonInt(champion, "id") == champion_id and jsonField(champion, "name").len > 0) return jsonField(champion, "name");
    };
    return if (fallback.len > 0) fallback else "未知英雄";
}

fn participantPosition(participant: std.json.Value) []const u8 {
    for ([_][]const u8{ "teamPosition", "individualPosition", "positionAssignedByMatchmaking", "assignedPosition", "position", "lane" }) |field| {
        const value = jsonField(participant, field);
        if (value.len > 0 and !std.ascii.eqlIgnoreCase(value, "NONE") and !std.ascii.eqlIgnoreCase(value, "INVALID")) return value;
    }
    if (nestedObject(participant, "timeline")) |timeline| {
        const lane = jsonField(timeline, "lane");
        const role = jsonField(timeline, "role");
        if (std.ascii.eqlIgnoreCase(lane, "BOTTOM") and std.ascii.eqlIgnoreCase(role, "DUO_SUPPORT")) return "UTILITY";
        if (lane.len > 0 and !std.ascii.eqlIgnoreCase(lane, "NONE") and !std.ascii.eqlIgnoreCase(lane, "INVALID")) return lane;
    }
    return "";
}

fn firstString(values: []const []const u8, fallback: []const u8) []const u8 {
    for (values) |value| if (value.len > 0) return value;
    return fallback;
}

fn nestedObject(value: std.json.Value, name: []const u8) ?std.json.Value {
    if (value != .object) return null;
    const item = value.object.get(name) orelse return null;
    return if (item == .object) item else null;
}

fn jsonField(value: std.json.Value, name: []const u8) []const u8 {
    if (value != .object) return "";
    const item = value.object.get(name) orelse return "";
    return if (item == .string) item.string else "";
}

fn jsonInt(value: std.json.Value, name: []const u8) i64 {
    if (value != .object) return 0;
    const item = value.object.get(name) orelse return 0;
    return switch (item) {
        .integer => |number| number,
        .float => |number| @intFromFloat(number),
        .string => |text| std.fmt.parseInt(i64, text, 10) catch 0,
        else => 0,
    };
}

fn jsonBool(value: std.json.Value, name: []const u8) bool {
    if (value != .object) return false;
    const item = value.object.get(name) orelse return false;
    return switch (item) {
        .bool => |boolean| boolean,
        .integer => |number| number != 0,
        .string => |text| std.ascii.eqlIgnoreCase(text, "true") or std.mem.eql(u8, text, "1"),
        else => false,
    };
}

fn statInt(value: std.json.Value, name: []const u8) i64 {
    if (nestedObject(value, "stats")) |stats| if (stats.object.get(name) != null) return jsonInt(stats, name);
    return jsonInt(value, name);
}

fn hasStat(value: std.json.Value, name: []const u8) bool {
    const stats = nestedObject(value, "stats") orelse value;
    if (stats != .object) return false;
    const item = stats.object.get(name) orelse return false;
    return item != .null;
}

fn writeStats(writer: *std.Io.Writer, value: std.json.Value, self: bool) !void {
    inline for (.{ "kills", "deaths", "assists", "win" }, .{ "selfKills", "selfDeaths", "selfAssists", "selfWin" }) |key, self_key| {
        if (hasStat(value, key)) {
            try writer.print(",\"{s}\":", .{if (self) self_key else key});
            if (comptime std.mem.eql(u8, key, "win")) try writer.print("{}", .{statBool(value, key)}) else try writer.print("{d}", .{statInt(value, key)});
        }
    }
}

fn statBool(value: std.json.Value, name: []const u8) bool {
    if (nestedObject(value, "stats")) |stats| if (stats.object.get(name) != null) return jsonBool(stats, name);
    return jsonBool(value, name);
}

fn sameIdentity(left: []const u8, right: []const u8) bool {
    return left.len > 0 and right.len > 0 and std.ascii.eqlIgnoreCase(std.mem.trim(u8, left, " \t\r\n"), std.mem.trim(u8, right, " \t\r\n"));
}

fn jsonString(writer: *std.Io.Writer, value: []const u8) !void {
    var stringify = std.json.Stringify{ .writer = writer, .options = .{} };
    try stringify.write(value);
}

fn writeIsoTimestamp(writer: *std.Io.Writer, epoch_millis: i64) !void {
    if (epoch_millis <= 0) return writer.writeAll("\"1970-01-01T00:00:00.000Z\"");
    const seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(@divTrunc(epoch_millis, 1000)) };
    const day = seconds.getEpochDay().calculateYearDay();
    const month = day.calculateMonthDay();
    const clock = seconds.getDaySeconds();
    const millis: u16 = @intCast(@mod(epoch_millis, 1000));
    try writer.print("\"{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z\"", .{
        day.year,
        @intFromEnum(month.month),
        month.day_index + 1,
        clock.getHoursIntoDay(),
        clock.getMinutesIntoHour(),
        clock.getSecondsIntoMinute(),
        millis,
    });
}

test "战绩派生记录保留双方身份和整局参与者" {
    const input = "{\"games\":{\"games\":[{\"gameId\":9,\"gameCreation\":1625159473123,\"participantIdentities\":[{\"participantId\":1,\"player\":{\"puuid\":\"self\",\"gameName\":\"本人\",\"tagLine\":\"ME\"}},{\"participantId\":2,\"player\":{\"puuid\":\"enemy\",\"gameName\":\"对手\",\"gameTag\":\"CN1\"}}],\"participants\":[{\"participantId\":1,\"teamId\":100,\"championId\":103,\"teamPosition\":\"MIDDLE\",\"stats\":{\"kills\":8,\"deaths\":2,\"assists\":7,\"win\":true}},{\"participantId\":2,\"teamId\":200,\"championId\":64,\"teamPosition\":\"JUNGLE\",\"stats\":{\"kills\":3,\"deaths\":5,\"assists\":6,\"win\":false}}]}]}}";
    const catalog = "[{\"id\":103,\"name\":\"九尾妖狐\"},{\"id\":64,\"name\":\"盲僧\"}]";
    var output: [8192]u8 = undefined;
    const result = try fromHistory(input, "self", catalog, &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    const record = parsed.value.array.items[0];
    try std.testing.expectEqualStrings("self", jsonField(record, "selfPuuid"));
    try std.testing.expectEqualStrings("本人", jsonField(record, "selfGameName"));
    try std.testing.expectEqualStrings("ME", jsonField(record, "selfTagLine"));
    try std.testing.expectEqualStrings("九尾妖狐", jsonField(record, "selfChampionName"));
    try std.testing.expectEqualStrings("对手", jsonField(record, "gameName"));
    try std.testing.expectEqualStrings("CN1", jsonField(record, "tagLine"));
    try std.testing.expectEqualStrings("盲僧", jsonField(record, "championName"));
}

test "按本人归属合并时排除身份不明的旧记录" {
    const existing = "[{\"gameId\":1,\"puuid\":\"legacy\",\"encounteredAt\":\"2026-01-01T00:00:00.000Z\"},{\"gameId\":2,\"selfPuuid\":\"other-owner\",\"puuid\":\"wrong\",\"encounteredAt\":\"2026-01-01T00:00:00.000Z\"}]";
    const newest = "[{\"gameId\":3,\"selfPuuid\":\"self\",\"puuid\":\"kept\",\"encounteredAt\":\"2026-01-01T00:00:00.000Z\"}]";
    var output: [4096]u8 = undefined;
    const result = try mergeArchive(existing, newest, "self", "2025-01-01T00:00:00.000Z", &output);
    try std.testing.expect(std.mem.indexOf(u8, result, "kept") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "legacy") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "wrong") == null);
}

test "查询返回目标参与的最近完整对局" {
    const archive =
        "[{\"gameId\":1,\"selfPuuid\":\"self\",\"puuid\":\"target\",\"gameName\":\"旧目标\",\"encounteredAt\":\"2026-01-01T00:00:00.000Z\"}," ++
        "{\"gameId\":2,\"selfPuuid\":\"self\",\"puuid\":\"target\",\"gameName\":\"新目标\",\"encounteredAt\":\"2026-02-01T00:00:00.000Z\"}," ++
        "{\"gameId\":2,\"selfPuuid\":\"self\",\"puuid\":\"teammate\",\"gameName\":\"完整阵容成员\",\"encounteredAt\":\"2026-02-01T00:00:00.000Z\"}," ++
        "{\"gameId\":3,\"selfPuuid\":\"self\",\"puuid\":\"other\",\"gameName\":\"无关对局\",\"encounteredAt\":\"2026-03-01T00:00:00.000Z\"}," ++
        "{\"gameId\":2,\"selfPuuid\":\"another-account\",\"puuid\":\"target\",\"gameName\":\"其他账号\",\"encounteredAt\":\"2026-02-01T00:00:00.000Z\"}]";
    var output: [8192]u8 = undefined;
    const result = try queryArchive(archive, "self", "target", "2025-01-01T00:00:00.000Z", 1, &output);
    try std.testing.expect(std.mem.indexOf(u8, result, "新目标") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "完整阵容成员") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "旧目标") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "无关对局") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "其他账号") == null);
}

test "忽略格式无效的嵌套战绩" {
    var output: [128]u8 = undefined;
    try std.testing.expectEqualStrings("[]", try fromHistory("{\"games\":{\"games\":{}}}", "self", "[]", &output));
}

test "共同对局要求双方真实身份且不按年份截断" {
    const shared =
        \\[{"gameId":1,"gameCreation":1625159473123,"participants":[{"puuid":"self","teamId":100,"kills":4,"deaths":1,"assists":2,"win":true},{"puuid":"target","teamId":200,"kills":1,"deaths":4,"assists":3,"win":false}]}]
    ;
    const unrelated =
        \\[{"gameId":2,"participantId":1,"participants":[{"participantId":1,"puuid":"target"}]}]
    ;
    var output: [8192]u8 = undefined;
    const json = try fromHistories(&.{ unrelated, shared, shared }, "self", "target", "[]", 40, 0, &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    try std.testing.expectEqual(@as(i64, 1), jsonInt(parsed.value.array.items[0], "gameId"));
    try std.testing.expect(std.mem.startsWith(u8, jsonField(parsed.value.array.items[0], "encounteredAt"), "2021-"));
    try std.testing.expectEqualStrings("[]", try fromHistories(&.{shared}, "self", "target", "[]", 40, 1, &output));
    try std.testing.expectEqualStrings("[]", try fromHistories(&.{shared}, "another-account", "target", "[]", 40, 0, &output));
}

test "派生对局倒序排列且最多四十局并保留全部参与者" {
    var history_buffer: [32 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&history_buffer);
    try writer.writeByte('[');
    for (0..45) |index| {
        if (index > 0) try writer.writeByte(',');
        try writer.print("{{\"gameId\":{d},\"gameCreation\":{d},\"participants\":[{{\"puuid\":\"self\"}},{{\"puuid\":\"target\"}},{{\"puuid\":\"third\"}}]}}", .{ index + 1, 1_625_159_473_123 + index * 60_000 });
    }
    try writer.writeByte(']');
    const output = try std.testing.allocator.alloc(u8, 256 * 1024);
    defer std.testing.allocator.free(output);
    const json = try fromHistories(&.{writer.buffered()}, "self", "target", "[]", 100, 0, output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 80), parsed.value.array.items.len);
    try std.testing.expectEqual(@as(i64, 45), jsonInt(parsed.value.array.items[0], "gameId"));
    try std.testing.expectEqual(@as(i64, 6), jsonInt(parsed.value.array.items[79], "gameId"));
    try std.testing.expect(!parsed.value.array.items[0].object.contains("kills"));
    try std.testing.expect(!parsed.value.array.items[0].object.contains("selfWin"));
}

test "竞技场比较小队且完整结算替换重复的缺失记录" {
    const pending =
        \\[{"gameId":1,"participants":[{"puuid":"self","teamId":100,"playerSubteamId":1},{"puuid":"TARGET","teamId":100,"playerSubteamId":2}]}]
    ;
    const settled =
        \\[{"gameId":1,"participants":[{"puuid":"self","teamId":100,"playerSubteamId":1,"win":true},{"puuid":"target","teamId":100,"playerSubteamId":2,"kills":3,"win":false}]}]
    ;
    var output: [8192]u8 = undefined;
    const json = try fromHistories(&.{ pending, settled }, "self", "target", "[]", 40, 0, &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    const record = parsed.value.array.items[0];
    try std.testing.expectEqualStrings("enemy", jsonField(record, "side"));
    try std.testing.expectEqual(@as(i64, 3), jsonInt(record, "kills"));
    try std.testing.expect(record.object.contains("win"));
}
