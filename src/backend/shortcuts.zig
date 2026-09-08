const std = @import("std");

pub fn chatMessageBody(lines: std.json.Value, allocator: std.mem.Allocator) ![]const u8 {
    if (lines != .array) return error.InvalidMessage;
    var joined: std.array_list.Managed(u8) = .init(allocator);
    defer joined.deinit();
    for (lines.array.items) |line| {
        if (line != .string) continue;
        const text = std.mem.trim(u8, line.string, " \t\r\n");
        if (text.len == 0) continue;
        if (joined.items.len > 0) try joined.append('\n');
        try joined.appendSlice(text);
    }
    if (joined.items.len == 0) return error.NoMessages;
    return std.json.Stringify.valueAlloc(allocator, .{ .body = joined.items, .type = "chat" }, .{});
}

test "选人消息一次提交并保留换行与引号" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "[\"第一条\",\"  \",\"带有\\\"引号\\\"的第二条\"]", .{});
    defer parsed.deinit();
    const body = try chatMessageBody(parsed.value, std.testing.allocator);
    defer std.testing.allocator.free(body);
    const result = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("第一条\n带有\"引号\"的第二条", result.value.object.get("body").?.string);
    try std.testing.expectEqualStrings("chat", result.value.object.get("type").?.string);
}

const max_chat_line_chars = 120;
const max_premade_players = 16;
const premade_inference_match_threshold = 5;
const template_fields = [_][]const u8{
    "name",             "tag",            "position",          "rank",
    "lp",               "score",          "recent_wins",       "recent_losses",
    "recent_win_rate",  "recent_games",   "streak",            "kda",
    "current_champion", "champion_games", "champion_win_rate", "top_champions",
    "premade",          "risk",           "jungle_preference", "team",
    "horse",            "encounter",
};

const validation_player =
    "{\"gameName\":\"示例玩家\",\"championId\":103,\"championName\":\"九尾妖狐\",\"assignedPosition\":\"MIDDLE\"," ++
    "\"rankTier\":\"EMERALD\",\"rankDivision\":\"II\",\"leaguePoints\":63,\"score\":{\"total\":82}," ++
    "\"recentMatches\":[{\"championName\":\"九尾妖狐\",\"position\":\"MIDDLE\",\"kills\":8,\"deaths\":2,\"assists\":7,\"durationMinutes\":28,\"win\":true}]," ++
    "\"topChampions\":[{\"championName\":\"九尾妖狐\",\"winRate\":0.61}],\"tags\":[{\"key\":\"hot\",\"label\":\"状态火热\"}]," ++
    "\"currentChampionGames\":6,\"currentChampionWinRate\":0.67,\"premadeWith\":[]," ++
    "\"junglePreference\":{\"sampleSize\":8,\"currentChampionGames\":6,\"evidence\":\"前期偏中下\",\"averageKda\":4.2,\"averageObjectiveTakedowns\":2.1,\"averageEnemyJungleMonsters\":3.4}}";

pub const BuildOptions = struct {
    require_enabled: bool = true,
    sample_when_empty: bool = false,
    premade_side: ?[]const u8 = null,
};

pub fn buildLines(
    config_json: []const u8,
    shortcut_id: []const u8,
    lobby_json: []const u8,
    phase: []const u8,
    options: BuildOptions,
    output: []u8,
) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const config = std.json.parseFromSliceLeaky(std.json.Value, allocator, config_json, .{}) catch return error.InvalidConfig;
    const lobby = std.json.parseFromSliceLeaky(std.json.Value, allocator, lobby_json, .{}) catch return error.InvalidLobby;
    const automation = nestedObject(config, "automation") orelse return error.InvalidConfig;
    const shortcuts = arrayField(automation, "shortcuts") orelse return error.ShortcutNotFound;
    var shortcut: ?std.json.Value = null;
    for (shortcuts.array.items) |candidate| {
        if (candidate == .object and std.mem.eql(u8, jsonStringField(candidate, "id"), shortcut_id)) {
            shortcut = candidate;
            break;
        }
    }
    const selected = shortcut orelse return error.ShortcutNotFound;
    if (options.require_enabled and !jsonBoolField(selected, "enabled")) return error.ShortcutDisabled;
    const template = jsonStringField(selected, "template");
    if (!templateValid(template)) return error.InvalidTemplate;
    // The built-in jungle shortcut is a semantic target, not a generic
    // "custom" first-player action.  Older persisted configs used `custom`,
    // which silently selected the first ally in the array.  Keep that legacy
    // config working by normalizing this reserved shortcut id at runtime.
    const configured_target = jsonStringField(selected, "target");
    // `{jungle_preference}` is a semantic player selector. Older configs
    // stored the built-in shortcut as `custom`, whose legacy behavior was
    // "first ally"; infer the intended jungle target from the placeholder so
    // renamed/copied shortcuts cannot silently message the wrong player.
    const target = if (std.mem.eql(u8, shortcut_id, "jungle-preference") or
        (std.mem.eql(u8, configured_target, "custom") and std.mem.indexOf(u8, template, "{jungle_preference}") != null))
        "jungle"
    else
        configured_target;
    const recent_game_count: usize = @intCast(std.math.clamp(jsonIntField(automation, "shortcutRecentGameCount", 5), @as(i64, 1), @as(i64, 10)));

    var writer = std.Io.Writer.fixed(output);
    try writer.writeByte('[');
    var emitted = false;
    if (std.mem.eql(u8, target, "premade")) {
        var line_buffer: [16 * 1024]u8 = undefined;
        var line = std.Io.Writer.fixed(&line_buffer);
        if (options.premade_side == null or std.mem.eql(u8, options.premade_side.?, "enemy")) {
            try line.writeAll("敌方开黑：");
            try writePremadeGroups(&line, arrayField(lobby, "enemy"));
            try writeChatLine(&writer, &emitted, line.buffered());
        }
        if (options.premade_side == null or std.mem.eql(u8, options.premade_side.?, "ally")) {
            line = std.Io.Writer.fixed(&line_buffer);
            try line.writeAll("我方开黑：");
            try writePremadeGroups(&line, arrayField(lobby, "ally"));
            try writeChatLine(&writer, &emitted, line.buffered());
        }
    } else if (std.mem.eql(u8, target, "ally")) {
        try writePlayers(&writer, &emitted, template, arrayField(lobby, "ally"), "我方", phase, recent_game_count);
    } else if (std.mem.eql(u8, target, "enemy")) {
        try writePlayers(&writer, &emitted, template, arrayField(lobby, "enemy"), "敌方", phase, recent_game_count);
    } else if (std.mem.eql(u8, target, "jungle")) {
        try writeJunglePlayers(&writer, &emitted, template, arrayField(lobby, "ally"), "我方", phase, recent_game_count);
        try writeJunglePlayers(&writer, &emitted, template, arrayField(lobby, "enemy"), "敌方", phase, recent_game_count);
    } else if (std.mem.eql(u8, target, "lobby")) {
        try writePlayers(&writer, &emitted, template, arrayField(lobby, "ally"), "我方", phase, recent_game_count);
        try writePlayers(&writer, &emitted, template, arrayField(lobby, "enemy"), "敌方", phase, recent_game_count);
    } else if (std.mem.eql(u8, target, "custom")) {
        if (arrayField(lobby, "ally")) |players| {
            if (players.array.items.len > 0) try writePlayerTemplateLines(&writer, &emitted, template, players.array.items[0], "我方", phase, recent_game_count);
        }
    } else {
        return error.UnknownTarget;
    }

    if (!emitted and options.sample_when_empty and !std.mem.eql(u8, target, "premade")) {
        const sample = std.json.parseFromSliceLeaky(std.json.Value, allocator, validation_player, .{}) catch return error.InvalidLobby;
        if (std.mem.eql(u8, target, "jungle")) {
            try writePlayerTemplateSingleLine(&writer, &emitted, template, sample, "我方", phase, recent_game_count);
        } else {
            try writePlayerTemplateLines(&writer, &emitted, template, sample, "我方", phase, recent_game_count);
        }
    }
    try writer.writeByte(']');
    return writer.buffered();
}

/// Build the Ctrl+F8 message from the local encounter archive. The archive
/// contains one row per encountered player and game, so no network request is
/// needed while sending a shortcut.
pub fn buildEncounterLines(archive_json: []const u8, lobby_json: []const u8, output: []u8) ![]const u8 {
    return buildEncounterLinesOwned(archive_json, lobby_json, "", output);
}

pub fn buildEncounterLinesOwned(archive_json: []const u8, lobby_json: []const u8, owner_puuid: []const u8, output: []u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const archive = std.json.parseFromSliceLeaky(std.json.Value, allocator, archive_json, .{}) catch return error.InvalidLobby;
    const lobby = std.json.parseFromSliceLeaky(std.json.Value, allocator, lobby_json, .{}) catch return error.InvalidLobby;
    if (archive != .array or lobby != .object) return std.fmt.bufPrint(output, "[]", .{});
    var owner_player: ?std.json.Value = null;
    var owner_side: []const u8 = "";
    if (owner_puuid.len > 0) {
        for ([_][]const u8{ "ally", "enemy" }) |side| {
            const players = arrayField(lobby, side) orelse continue;
            for (players.array.items) |player| {
                if (player == .object and std.ascii.eqlIgnoreCase(jsonStringField(player, "puuid"), owner_puuid)) {
                    owner_player = player;
                    owner_side = side;
                    break;
                }
            }
            if (owner_player != null) break;
        }
    }
    var writer = std.Io.Writer.fixed(output);
    try writer.writeByte('[');
    var emitted = false;
    var sent: usize = 0;
    const current_game_id = jsonIntField(lobby, "id", 0);
    for ([_][]const u8{ "ally", "enemy" }) |side| {
        const players = arrayField(lobby, side) orelse continue;
        for (players.array.items) |player| {
            if (player != .object) continue;
            const puuid = jsonStringField(player, "puuid");
            if (puuid.len == 0) continue;
            if (owner_player) |owner| {
                if (std.mem.eql(u8, side, owner_side) and
                    (samePremadeGroup(owner, player) or
                        referencesPremadePlayer(owner, player, players.array.items) or
                        referencesPremadePlayer(player, owner, players.array.items)))
                {
                    continue;
                }
            }
            for (archive.array.items) |record| {
                if (record != .object or !std.mem.eql(u8, jsonStringField(record, "puuid"), puuid)) continue;
                if (owner_puuid.len > 0 and !std.ascii.eqlIgnoreCase(jsonStringField(record, "selfPuuid"), owner_puuid)) continue;
                if (current_game_id > 0 and jsonIntField(record, "gameId", 0) == current_game_id) continue;
                if (sent >= 20) break;
                var line_buffer: [16 * 1024]u8 = undefined;
                var line = std.Io.Writer.fixed(&line_buffer);
                try line.writeAll("遇到过：");
                try writeEncounterTime(&line, jsonStringField(record, "encounteredAt"));
                try line.writeAll("，我（");
                try writeEncounterRiotId(&line, jsonStringField(record, "selfGameName"), jsonStringField(record, "selfTagLine"), "未知玩家");
                try line.writeAll("）使用 ");
                try line.writeAll(fallback(jsonStringField(record, "selfChampionName"), "未知英雄"));
                try line.writeByte(' ');
                try writeEncounterPerformance(&line, record, true);
                try line.writeAll(if (std.mem.eql(u8, jsonStringField(record, "side"), "ally")) "；队友（" else "；对方（");
                try writeEncounterRiotId(&line, jsonStringField(record, "gameName"), jsonStringField(record, "tagLine"), "未知玩家");
                try line.writeAll("）使用 ");
                try line.writeAll(fallback(jsonStringField(record, "championName"), "未知英雄"));
                try line.writeByte(' ');
                try writeEncounterPerformance(&line, record, false);
                try writeChatLine(&writer, &emitted, line.buffered());
                sent += 1;
            }
        }
    }
    try writer.writeByte(']');
    return writer.buffered();
}

fn writeEncounterRiotId(writer: *std.Io.Writer, name: []const u8, tag: []const u8, default_name: []const u8) !void {
    try writer.writeAll(fallback(name, default_name));
    if (tag.len > 0) {
        try writer.writeByte('#');
        try writer.writeAll(tag);
    }
}

fn writeEncounterPerformance(writer: *std.Io.Writer, record: std.json.Value, self: bool) !void {
    const kills_name = if (self) "selfKills" else "kills";
    const deaths_name = if (self) "selfDeaths" else "deaths";
    const assists_name = if (self) "selfAssists" else "assists";
    const win_name = if (self) "selfWin" else "win";
    if (record.object.get(kills_name) == null or record.object.get(deaths_name) == null or record.object.get(assists_name) == null) {
        try writer.writeAll("战绩待结算");
        return;
    }
    try writer.print("{d}/{d}/{d}", .{ jsonIntField(record, kills_name, 0), jsonIntField(record, deaths_name, 0), jsonIntField(record, assists_name, 0) });
    if (record.object.get(win_name) != null) try writer.writeAll(if (jsonBoolField(record, win_name)) " 胜" else " 负");
}

fn writeEncounterTime(writer: *std.Io.Writer, value: []const u8) !void {
    if (value.len >= 16 and value[4] == '-' and value[7] == '-') {
        try writer.writeAll(value[5..7]);
        try writer.writeAll("月");
        try writer.writeAll(value[8..10]);
        try writer.writeAll("日 ");
        try writer.writeAll(value[11..16]);
    } else try writer.writeAll(if (value.len > 0) value else "未知时间");
}

pub fn validationDto(template: []const u8, output: []u8) ![]const u8 {
    var errors: [32][]const u8 = undefined;
    var error_len: usize = 0;
    const trimmed = std.mem.trim(u8, template, " \t\r\n");
    if (trimmed.len == 0) {
        errors[error_len] = "模板不能为空";
        error_len += 1;
    }
    const balanced = countByte(template, '{') == countByte(template, '}');
    if (!balanced) {
        errors[error_len] = "占位符括号没有闭合";
        error_len += 1;
    } else {
        var rest = template;
        while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
            const after = rest[open + 1 ..];
            const close = std.mem.indexOfScalar(u8, after, '}') orelse break;
            const field = after[0..close];
            if (!knownField(field)) {
                var duplicate = false;
                for (errors[0..error_len]) |existing| {
                    if (std.mem.eql(u8, existing, field)) {
                        duplicate = true;
                        break;
                    }
                }
                if (!duplicate and error_len < errors.len) {
                    errors[error_len] = field;
                    error_len += 1;
                }
            }
            rest = after[close + 1 ..];
        }
    }

    var preview_buffer: [16 * 1024]u8 = undefined;
    var preview: []const u8 = "";
    if (error_len == 0) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const player = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), validation_player, .{}) catch return error.InvalidLobby;
        preview = try renderTemplate(template, player, "我方", "ChampSelect", 5, &preview_buffer);
    }

    var writer = std.Io.Writer.fixed(output);
    try writer.print("{{\"valid\":{},\"errors\":[", .{error_len == 0});
    for (errors[0..error_len], 0..) |item, index| {
        if (index > 0) try writer.writeByte(',');
        if (std.mem.startsWith(u8, item, "模板") or std.mem.startsWith(u8, item, "占位符")) {
            try writeJsonString(&writer, item);
        } else {
            var message_buffer: [512]u8 = undefined;
            const message = std.fmt.bufPrint(&message_buffer, "未知占位符：{{{s}}}", .{item}) catch "未知占位符";
            try writeJsonString(&writer, message);
        }
    }
    try writer.writeAll("],\"preview\":");
    try writeJsonString(&writer, preview);
    try writer.writeByte('}');
    return writer.buffered();
}

pub fn renderTemplate(
    template: []const u8,
    player: std.json.Value,
    team: []const u8,
    phase: []const u8,
    recent_game_count: usize,
    output: []u8,
) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    var cursor: usize = 0;
    const current_unselected = jsonIntField(player, "championId", 0) <= 0 or std.mem.eql(u8, jsonStringField(player, "championName"), "等待选择");
    const joined_fields = "{position}-{current_champion}";
    while (cursor < template.len) {
        if (current_unselected and std.mem.startsWith(u8, template[cursor..], joined_fields)) {
            try writeTemplateValue(&writer, "position", player, team, phase, recent_game_count);
            cursor += joined_fields.len;
            continue;
        }
        const open = std.mem.indexOfScalarPos(u8, template, cursor, '{') orelse {
            try writer.writeAll(template[cursor..]);
            break;
        };
        try writer.writeAll(template[cursor..open]);
        const close = std.mem.indexOfScalarPos(u8, template, open + 1, '}') orelse {
            try writer.writeAll(template[open..]);
            break;
        };
        const key = template[open + 1 .. close];
        if (knownField(key)) {
            try writeTemplateValue(&writer, key, player, team, phase, recent_game_count);
        } else {
            try writer.writeAll(template[open .. close + 1]);
        }
        cursor = close + 1;
    }
    return writer.buffered();
}

fn writePlayers(
    writer: *std.Io.Writer,
    emitted: *bool,
    template: []const u8,
    players: ?std.json.Value,
    team: []const u8,
    phase: []const u8,
    recent_game_count: usize,
) !void {
    const values = players orelse return;
    for (values.array.items) |player| {
        if (player != .object) continue;
        try writePlayerTemplateLines(writer, emitted, template, player, team, phase, recent_game_count);
    }
}

fn writePlayerTemplateSingleLine(
    writer: *std.Io.Writer,
    emitted: *bool,
    template: []const u8,
    player: std.json.Value,
    team: []const u8,
    phase: []const u8,
    recent_game_count: usize,
) !void {
    var rendered_buffer: [64 * 1024]u8 = undefined;
    const rendered = try renderTemplate(template, player, team, phase, recent_game_count, &rendered_buffer);
    var normalized_buffer: [64 * 1024]u8 = undefined;
    var normalized = std.Io.Writer.fixed(&normalized_buffer);
    try writeSingleLine(&normalized, rendered);
    const line = std.mem.trim(u8, normalized.buffered(), " ");
    if (line.len > 0) try writeLine(writer, emitted, line);
}

fn writeJunglePlayers(
    writer: *std.Io.Writer,
    emitted: *bool,
    template: []const u8,
    players: ?std.json.Value,
    team: []const u8,
    phase: []const u8,
    recent_game_count: usize,
) !void {
    const values = players orelse return;
    // During champ-select position fields can be copied from the first seat
    // while summoner spells already contain the real loadout. If any player
    // in this team exposes Smite, use that authoritative signal for the whole
    // team instead of allowing a stale JUNGLE position to select seat one.
    var smite_count: usize = 0;
    for (values.array.items) |player| {
        if (player == .object and hasSmite(player)) smite_count += 1;
    }
    const use_smite = smite_count > 0;
    for (values.array.items) |player| {
        if (player != .object) continue;
        if (use_smite) {
            if (!hasSmite(player)) continue;
        } else if (!isJunglePosition(playerPosition(player))) {
            continue;
        }
        try writePlayerTemplateSingleLine(writer, emitted, template, player, team, phase, recent_game_count);
    }
}

fn writePlayerTemplateLines(
    writer: *std.Io.Writer,
    emitted: *bool,
    template: []const u8,
    player: std.json.Value,
    team: []const u8,
    phase: []const u8,
    recent_game_count: usize,
) !void {
    var rendered_buffer: [64 * 1024]u8 = undefined;
    const rendered = try renderTemplate(template, player, team, phase, recent_game_count, &rendered_buffer);
    var lines = std.mem.splitScalar(u8, rendered, '\n');
    while (lines.next()) |line| try writeChatLine(writer, emitted, line);
}

fn writeChatLine(writer: *std.Io.Writer, emitted: *bool, raw_line: []const u8) !void {
    const line = std.mem.trim(u8, raw_line, " \t\r");
    if (line.len == 0) return;
    var chunk_start: usize = 0;
    var cursor: usize = 0;
    var characters: usize = 0;
    while (cursor < line.len) {
        if (characters == max_chat_line_chars) {
            try writeLine(writer, emitted, line[chunk_start..cursor]);
            chunk_start = cursor;
            characters = 0;
        }
        const sequence_len: usize = std.unicode.utf8ByteSequenceLength(line[cursor]) catch 1;
        cursor += @min(sequence_len, line.len - cursor);
        characters += 1;
    }
    if (chunk_start < line.len) try writeLine(writer, emitted, line[chunk_start..]);
}

fn writeLine(writer: *std.Io.Writer, emitted: *bool, line: []const u8) !void {
    if (emitted.*) try writer.writeByte(',');
    emitted.* = true;
    try writeJsonString(writer, line);
}

fn writeTemplateValue(writer: *std.Io.Writer, key: []const u8, player: std.json.Value, team: []const u8, phase: []const u8, recent_game_count: usize) !void {
    if (std.mem.eql(u8, key, "name")) return writer.writeAll(fallback(jsonStringField(player, "gameName"), "未知玩家"));
    if (std.mem.eql(u8, key, "tag")) return writer.writeAll(firstTagLabel(player));
    if (std.mem.eql(u8, key, "position")) return writer.writeAll(shortcutPositionLabel(player, phase));
    if (std.mem.eql(u8, key, "rank")) {
        try writer.writeAll(rankLabel(jsonStringField(player, "rankTier")));
        const division = jsonStringField(player, "rankDivision");
        if (division.len > 0) {
            try writer.writeByte(' ');
            try writer.writeAll(division);
        }
        return;
    }
    if (std.mem.eql(u8, key, "lp")) return writer.print("{d}", .{jsonIntField(player, "leaguePoints", 0)});
    if (std.mem.eql(u8, key, "score")) {
        const score = nestedObject(player, "score") orelse std.json.Value{ .null = {} };
        return writer.print("{d:.0}", .{jsonFloatField(score, "total", 0)});
    }
    const recent = recentStats(player);
    if (std.mem.eql(u8, key, "recent_wins")) return writer.print("{d}", .{recent.wins});
    if (std.mem.eql(u8, key, "recent_losses")) return writer.print("{d}", .{recent.losses});
    if (std.mem.eql(u8, key, "recent_win_rate")) return writer.print("{d:.0}%", .{@as(f64, @floatFromInt(recent.wins)) / @as(f64, @floatFromInt(@max(@as(usize, 1), recent.wins + recent.losses))) * 100.0});
    if (std.mem.eql(u8, key, "recent_games")) return writeRecentGames(writer, player, recent_game_count);
    if (std.mem.eql(u8, key, "streak")) return writer.writeAll(streakLabel(player));
    if (std.mem.eql(u8, key, "kda")) return writer.print("{d:.2}", .{recent.average_kda});
    if (std.mem.eql(u8, key, "current_champion")) {
        const name = jsonStringField(player, "championName");
        return writer.writeAll(if (jsonIntField(player, "championId", 0) <= 0 or std.mem.eql(u8, name, "等待选择")) "未选择" else fallback(name, "未选择"));
    }
    if (std.mem.eql(u8, key, "champion_games")) return writer.print("{d}", .{jsonIntField(player, "currentChampionGames", 0)});
    if (std.mem.eql(u8, key, "champion_win_rate")) return writer.print("{d:.0}%", .{jsonFloatField(player, "currentChampionWinRate", 0) * 100.0});
    if (std.mem.eql(u8, key, "top_champions")) return writeTopChampions(writer, player);
    if (std.mem.eql(u8, key, "premade")) {
        if (arrayField(player, "premadePositions")) |positions| if (positions.array.items.len > 0) {
            return writeStringArray(writer, positions, "、", "无");
        };
        return writeStringArray(writer, arrayField(player, "premadeWith"), "、", "无");
    }
    if (std.mem.eql(u8, key, "risk")) return writeTagLabels(writer, player);
    if (std.mem.eql(u8, key, "jungle_preference")) return writeJunglePreference(writer, player);
    if (std.mem.eql(u8, key, "team")) return writer.writeAll(team);
    if (std.mem.eql(u8, key, "horse")) return writer.writeAll(horseLabel(player, recent));
    if (std.mem.eql(u8, key, "encounter")) return writer.writeAll("暂无本地遇到记录");
}

fn writeJunglePreference(writer: *std.Io.Writer, player: std.json.Value) !void {
    const detailed = jsonStringField(player, "jungleShortcutText");
    if (detailed.len > 0) return writeSingleLine(writer, detailed);
    const preference = nestedObject(player, "junglePreference") orelse return writer.writeAll(if (jsonIntField(player, "championId", 0) > 0) "近期没有本英雄打野记录" else "尚未选择英雄");
    const sample_size = jsonIntField(preference, "sampleSize", 0);
    const champion_games = jsonIntField(preference, "currentChampionGames", 0);
    try writer.print("本英雄打野样本{d}场", .{if (champion_games > 0) champion_games else sample_size});
    const evidence = jsonStringField(preference, "evidence");
    if (evidence.len > 0) {
        try writer.writeByte(' ');
        try writeSingleLine(writer, evidence);
    }
    try writer.print(" KDA {d:.1}", .{jsonFloatField(preference, "averageKda", 0)});
    if (optionalFloatField(preference, "averageObjectiveTakedowns")) |value| try writer.print(" 场均资源参与 {d:.1}", .{value});
    if (optionalFloatField(preference, "averageEnemyJungleMonsters")) |value| try writer.print(" 场均反野 {d:.1}", .{value});
}

fn optionalFloatField(value: std.json.Value, field: []const u8) ?f64 {
    if (value != .object) return null;
    const item = value.object.get(field) orelse return null;
    return switch (item) {
        .integer => |number| @floatFromInt(number),
        .float => |number| number,
        else => null,
    };
}

fn isJunglePosition(position: []const u8) bool {
    return std.ascii.eqlIgnoreCase(position, "JUNGLE") or std.ascii.eqlIgnoreCase(position, "JUG");
}

fn playerPosition(player: std.json.Value) []const u8 {
    for ([_][]const u8{ "assignedPosition", "position", "botPosition", "teamPosition", "role" }) |field| {
        const value = jsonStringField(player, field);
        if (value.len > 0 and !isUnknownPosition(value)) return value;
    }
    return "";
}

fn isUnknownPosition(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t\r\n"), "NONE") or
        std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t\r\n"), "UNKNOWN") or
        std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t\r\n"), "UNASSIGNED");
}

/// Identify a jungler from the strongest signal available in the LCU roster.
/// Smite is the authoritative loadout signal; position is only a fallback for
/// early champ-select payloads that do not expose summoner spells yet.
pub fn isJunglePlayer(player: std.json.Value) bool {
    if (player != .object) return false;
    if (hasSmite(player)) return true;
    return isJunglePosition(playerPosition(player));
}

fn hasSmite(player: std.json.Value) bool {
    for ([_][]const u8{
        "summonerSpellOneId",
        "summonerSpellTwoId",
        "spell1Id",
        "spell2Id",
        "summonerSpell1Id",
        "summonerSpell2Id",
        "spell1",
        "spell2",
        "summonerSpellOne",
        "summonerSpellTwo",
    }) |field| {
        if (spellValueIsSmite(player.object.get(field) orelse continue)) return true;
    }
    for ([_][]const u8{ "summonerSpells", "spells" }) |field| {
        if (player.object.get(field)) |value| if (spellValueIsSmite(value)) return true;
    }
    for ([_][]const u8{ "summoner", "player" }) |field| {
        if (nestedObject(player, field)) |nested| if (hasSmite(nested)) return true;
    }
    if (player.object.get("playerSlots")) |slots| if (slots == .array) {
        for (slots.array.items) |slot| if (hasSmite(slot)) return true;
    };
    return false;
}

/// Expose the raw Smite signal to the lobby enrichment layer so it can apply
/// the same team-level preference as shortcut rendering.
pub fn hasSmitePlayer(player: std.json.Value) bool {
    return player == .object and hasSmite(player);
}

fn spellValueIsSmite(value: std.json.Value) bool {
    switch (value) {
        .integer => |number| return number == 11,
        .float => |number| return @as(i64, @intFromFloat(number)) == 11,
        .string => |text| {
            const trimmed = std.mem.trim(u8, text, " \t\r\n");
            if (std.fmt.parseInt(i64, trimmed, 10) catch null) |id| return id == 11;
            return std.ascii.eqlIgnoreCase(trimmed, "SMITE") or
                std.ascii.eqlIgnoreCase(trimmed, "SUMMONERSMITE") or
                std.mem.eql(u8, trimmed, "惩戒");
        },
        .array => |items| {
            for (items.items) |item| if (spellValueIsSmite(item)) return true;
            return false;
        },
        .object => {
            for ([_][]const u8{
                "id",
                "spellId",
                "summonerSpellId",
                "spell1Id",
                "spell2Id",
                "summonerSpellOneId",
                "summonerSpellTwoId",
                "summonerSpell1Id",
                "summonerSpell2Id",
                "key",
                "name",
                "rawName",
                "displayName",
                "spellName",
            }) |field| {
                if (value.object.get(field)) |item| if (spellValueIsSmite(item)) return true;
            }
            return false;
        },
        else => return false,
    }
}

fn playerIsJungle(player: std.json.Value) bool {
    return isJunglePlayer(player);
}

fn writeSingleLine(writer: *std.Io.Writer, value: []const u8) !void {
    var pending_space = false;
    var emitted = false;
    for (value) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            pending_space = emitted;
            continue;
        }
        if (pending_space) try writer.writeByte(' ');
        try writer.writeByte(byte);
        pending_space = false;
        emitted = true;
    }
}

const RecentStats = struct { games: usize = 0, wins: usize = 0, losses: usize = 0, average_kda: f64 = 0 };

fn recentStats(player: std.json.Value) RecentStats {
    const recent = arrayField(player, "recentMatches") orelse return .{};
    var stats = RecentStats{};
    var kda_sum: f64 = 0;
    for (recent.array.items) |game| {
        if (stats.games == 10) break;
        if (game != .object or jsonIntField(game, "durationMinutes", 0) <= 0) continue;
        if (jsonBoolField(game, "win")) stats.wins += 1 else stats.losses += 1;
        const kills = jsonIntField(game, "kills", 0);
        const deaths = @max(@as(i64, 1), jsonIntField(game, "deaths", 0));
        const assists = jsonIntField(game, "assists", 0);
        kda_sum += @as(f64, @floatFromInt(kills + assists)) / @as(f64, @floatFromInt(deaths));
        stats.games += 1;
    }
    if (stats.games > 0) stats.average_kda = kda_sum / @as(f64, @floatFromInt(stats.games));
    return stats;
}

fn horseLabel(player: std.json.Value, recent: RecentStats) []const u8 {
    // A tiny sample is intentionally neutral. With enough games, combine the
    // existing recent-performance score with win rate and KDA so rank does not
    // decide the label.
    if (recent.games < 3) return "中等马";
    const win_rate = @as(f64, @floatFromInt(recent.wins)) / @as(f64, @floatFromInt(recent.games));
    const score_value = nestedObject(player, "score") orelse std.json.Value{ .null = {} };
    const score = jsonFloatField(score_value, "total", 0);
    if (score >= 75 or (score == 0 and win_rate >= 0.65 and recent.average_kda >= 3)) return "上等马";
    if ((score > 0 and score < 55) or (score == 0 and win_rate <= 0.35 and recent.average_kda < 2)) return "下等马";
    return "中等马";
}

fn writeRecentGames(writer: *std.Io.Writer, player: std.json.Value, requested: usize) !void {
    const recent = arrayField(player, "recentMatches") orelse return writer.writeAll("暂无近期对局");
    var count: usize = 0;
    for (recent.array.items) |game| {
        if (game != .object or count == std.math.clamp(requested, @as(usize, 1), @as(usize, 10))) break;
        if (jsonIntField(game, "durationMinutes", 0) <= 0) continue;
        if (count == 0) try writer.print("近{d}场：", .{std.math.clamp(requested, @as(usize, 1), @as(usize, 10))}) else try writer.writeAll("；");
        try writer.writeAll(if (jsonBoolField(game, "win")) "胜 " else "负 ");
        try writer.writeAll(fallback(jsonStringField(game, "championName"), "未知英雄"));
        try writer.print(" {d}/{d}/{d}", .{ jsonIntField(game, "kills", 0), jsonIntField(game, "deaths", 0), jsonIntField(game, "assists", 0) });
        count += 1;
    }
    if (count == 0) try writer.writeAll("暂无近期对局");
}

fn writeTopChampions(writer: *std.Io.Writer, player: std.json.Value) !void {
    const champions = arrayField(player, "topChampions") orelse return;
    var emitted = false;
    for (champions.array.items) |champion| {
        if (champion != .object) continue;
        if (emitted) try writer.writeAll("、");
        emitted = true;
        try writer.writeAll(fallback(jsonStringField(champion, "championName"), "未知英雄"));
        try writer.print(" {d:.0}%", .{jsonFloatField(champion, "winRate", 0) * 100.0});
    }
}

fn writeTagLabels(writer: *std.Io.Writer, player: std.json.Value) !void {
    const tags = arrayField(player, "tags") orelse return;
    var emitted = false;
    for (tags.array.items) |tag| {
        const label = jsonStringField(tag, "label");
        if (label.len == 0) continue;
        if (emitted) try writer.writeAll("、");
        emitted = true;
        try writer.writeAll(label);
    }
}

fn firstTagLabel(player: std.json.Value) []const u8 {
    const tags = arrayField(player, "tags") orelse return "";
    if (tags.array.items.len == 0) return "";
    return jsonStringField(tags.array.items[0], "label");
}

fn streakLabel(player: std.json.Value) []const u8 {
    const tags = arrayField(player, "tags") orelse return "状态稳定";
    var first: []const u8 = "";
    for (tags.array.items) |tag| {
        const label = jsonStringField(tag, "label");
        if (first.len == 0 and label.len > 0) first = label;
        const key = jsonStringField(tag, "key");
        for ([_][]const u8{ "hot", "slump", "win-streak", "loss-streak" }) |preferred| {
            if (std.mem.eql(u8, key, preferred)) return fallback(label, "状态稳定");
        }
    }
    return fallback(first, "状态稳定");
}

fn shortcutPositionLabel(player: std.json.Value, phase: []const u8) []const u8 {
    const assigned = positionLabel(playerPosition(player));
    if (!std.mem.eql(u8, assigned, "待定")) return assigned;
    if (recentPrimaryPosition(player)) |recent| return recent;
    const champion_selected = jsonIntField(player, "championId", 0) > 0 and !std.mem.eql(u8, jsonStringField(player, "championName"), "等待选择");
    if (champion_selected or isSelectedPhase(phase)) return "待定";
    return "等待选择";
}

fn recentPrimaryPosition(player: std.json.Value) ?[]const u8 {
    const recent = arrayField(player, "recentMatches") orelse return null;
    var counts = [_]usize{0} ** 5;
    for (recent.array.items[0..@min(recent.array.items.len, 20)]) |game| {
        const index = positionIndex(jsonStringField(game, "position")) orelse continue;
        counts[index] += 1;
    }
    var best_index: usize = 0;
    var best_count: usize = 0;
    for (counts, 0..) |count, index| {
        if (count > best_count) {
            best_count = count;
            best_index = index;
        }
    }
    return if (best_count > 0) ([_][]const u8{ "上路", "打野", "中路", "下路", "辅助" })[best_index] else null;
}

fn positionIndex(position: []const u8) ?usize {
    if (std.ascii.eqlIgnoreCase(position, "TOP")) return 0;
    if (std.ascii.eqlIgnoreCase(position, "JUNGLE") or std.ascii.eqlIgnoreCase(position, "JUG")) return 1;
    if (std.ascii.eqlIgnoreCase(position, "MIDDLE") or std.ascii.eqlIgnoreCase(position, "MID")) return 2;
    if (std.ascii.eqlIgnoreCase(position, "BOTTOM") or std.ascii.eqlIgnoreCase(position, "BOT") or std.ascii.eqlIgnoreCase(position, "ADC")) return 3;
    if (std.ascii.eqlIgnoreCase(position, "UTILITY") or std.ascii.eqlIgnoreCase(position, "SUPPORT") or std.ascii.eqlIgnoreCase(position, "SUP")) return 4;
    return null;
}

fn positionLabel(position: []const u8) []const u8 {
    const index = positionIndex(std.mem.trim(u8, position, " \t\r\n")) orelse return "待定";
    return ([_][]const u8{ "上路", "打野", "中路", "下路", "辅助" })[index];
}

fn rankLabel(tier: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(tier, "CHALLENGER")) return "王者";
    if (std.ascii.eqlIgnoreCase(tier, "GRANDMASTER")) return "宗师";
    if (std.ascii.eqlIgnoreCase(tier, "MASTER")) return "大师";
    if (std.ascii.eqlIgnoreCase(tier, "DIAMOND")) return "钻石";
    if (std.ascii.eqlIgnoreCase(tier, "EMERALD")) return "翡翠";
    if (std.ascii.eqlIgnoreCase(tier, "PLATINUM")) return "铂金";
    if (std.ascii.eqlIgnoreCase(tier, "GOLD")) return "黄金";
    if (std.ascii.eqlIgnoreCase(tier, "SILVER")) return "白银";
    if (std.ascii.eqlIgnoreCase(tier, "BRONZE")) return "青铜";
    if (std.ascii.eqlIgnoreCase(tier, "IRON")) return "黑铁";
    if (tier.len == 0 or std.ascii.eqlIgnoreCase(tier, "UNRANKED")) return "未定级";
    return tier;
}

fn isSelectedPhase(phase: []const u8) bool {
    for ([_][]const u8{ "GameStart", "InProgress", "EndOfGame", "PreEndOfGame", "WatchInProgress", "Spectating", "Watching" }) |candidate| {
        if (std.mem.eql(u8, phase, candidate)) return true;
    }
    return false;
}

const PremadeGroup = struct {
    names: [max_premade_players][]const u8 = undefined,
    len: usize = 0,
};

fn writePremadeGroups(writer: *std.Io.Writer, players: ?std.json.Value) !void {
    const values = players orelse return writer.writeAll("[]");
    const player_count = @min(values.array.items.len, max_premade_players);
    var parents: [max_premade_players]usize = undefined;
    for (parents[0..player_count], 0..) |*parent, index| parent.* = index;

    for (0..player_count) |left_index| {
        const left = values.array.items[left_index];
        if (left != .object) continue;
        for (left_index + 1..player_count) |right_index| {
            const right = values.array.items[right_index];
            if (right != .object) continue;
            if (samePremadeGroup(left, right) or
                referencesPremadePlayer(left, right, values.array.items[0..player_count]) or
                referencesPremadePlayer(right, left, values.array.items[0..player_count]) or
                sharesRecentMatches(left, right))
            {
                unionPremadePlayers(&parents, left_index, right_index);
            }
        }
    }

    var member_counts = [_]usize{0} ** max_premade_players;
    for (0..player_count) |index| member_counts[premadeRoot(&parents, index)] += 1;

    var groups: [max_premade_players]PremadeGroup = undefined;
    var group_len: usize = 0;
    for (0..player_count) |root| {
        if (premadeRoot(&parents, root) != root or member_counts[root] < 2 or group_len == groups.len) continue;
        var group = PremadeGroup{};
        for (values.array.items[0..player_count], 0..) |player, index| {
            if (premadeRoot(&parents, index) != root) continue;
            appendUniqueName(&group, premadeMemberDisplayName(values.array.items[0..player_count], &parents, root, index, player));
        }
        sortNames(&group);
        if (group.len < 2) continue;
        groups[group_len] = group;
        group_len += 1;
    }
    sortGroups(groups[0..group_len]);
    if (group_len == 0) return writer.writeAll("[]");
    for (groups[0..group_len], 0..) |group, group_index| {
        if (group_index > 0) try writer.writeAll("；");
        try writer.writeByte('[');
        for (group.names[0..group.len], 0..) |name, name_index| {
            if (name_index > 0) try writer.writeAll("、");
            try writer.writeAll(name);
        }
        try writer.writeByte(']');
    }
}

fn premadeRoot(parents: *const [max_premade_players]usize, start: usize) usize {
    var current = start;
    while (parents[current] != current) current = parents[current];
    return current;
}

fn unionPremadePlayers(parents: *[max_premade_players]usize, left: usize, right: usize) void {
    const left_root = premadeRoot(parents, left);
    const right_root = premadeRoot(parents, right);
    if (left_root != right_root) parents[right_root] = left_root;
}

fn samePremadeGroup(left: std.json.Value, right: std.json.Value) bool {
    const left_group = std.mem.trim(u8, jsonStringField(left, "premadeGroup"), " \t\r\n");
    const right_group = std.mem.trim(u8, jsonStringField(right, "premadeGroup"), " \t\r\n");
    return left_group.len > 0 and !std.mem.eql(u8, left_group, "0") and std.mem.eql(u8, left_group, right_group);
}

fn referencesPremadePlayer(source: std.json.Value, target: std.json.Value, team: []const std.json.Value) bool {
    const target_name = jsonStringField(target, "gameName");
    if (target_name.len == 0 or !teamNameIsUnique(team, target_name)) return false;
    const names = arrayField(source, "premadeWith") orelse return false;
    for (names.array.items) |name| {
        if (name == .string and playerNamesEqual(name.string, target_name)) return true;
    }
    return false;
}

fn teamNameIsUnique(team: []const std.json.Value, name: []const u8) bool {
    var count: usize = 0;
    for (team) |player| {
        if (player == .object and playerNamesEqual(jsonStringField(player, "gameName"), name)) count += 1;
    }
    return count == 1;
}

fn playerNamesEqual(left_value: []const u8, right_value: []const u8) bool {
    var left = std.mem.trim(u8, left_value, " \t\r\n");
    var right = std.mem.trim(u8, right_value, " \t\r\n");
    if (std.mem.indexOfScalar(u8, left, '#')) |separator| left = left[0..separator];
    if (std.mem.indexOfScalar(u8, right, '#')) |separator| right = right[0..separator];
    return left.len > 0 and std.ascii.eqlIgnoreCase(left, right);
}

fn sharesRecentMatches(left: std.json.Value, right: std.json.Value) bool {
    const left_matches = arrayField(left, "recentMatches") orelse return false;
    const right_matches = arrayField(right, "recentMatches") orelse return false;
    var shared: usize = 0;
    for (left_matches.array.items, 0..) |left_match, left_index| {
        const left_id = gameIdValue(left_match) orelse continue;
        var duplicate = false;
        for (left_matches.array.items[0..left_index]) |earlier_match| {
            const earlier_id = gameIdValue(earlier_match) orelse continue;
            if (gameIdsEqual(left_id, earlier_id)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        for (right_matches.array.items) |right_match| {
            const right_id = gameIdValue(right_match) orelse continue;
            if (!gameIdsEqual(left_id, right_id)) continue;
            shared += 1;
            if (shared >= premade_inference_match_threshold) return true;
            break;
        }
    }
    return false;
}

fn gameIdValue(match: std.json.Value) ?std.json.Value {
    if (match != .object) return null;
    const value = match.object.get("gameId") orelse return null;
    return switch (value) {
        .integer => |number| if (number != 0) value else null,
        .float => |number| if (number != 0) value else null,
        .string => |text| if (text.len > 0 and !std.mem.eql(u8, text, "0")) value else null,
        else => null,
    };
}

fn gameIdsEqual(left: std.json.Value, right: std.json.Value) bool {
    if (left == .string and right == .string) return std.mem.eql(u8, left.string, right.string);
    const left_number: ?i64 = switch (left) {
        .integer => |number| number,
        .float => |number| @intFromFloat(number),
        .string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        else => null,
    };
    const right_number: ?i64 = switch (right) {
        .integer => |number| number,
        .float => |number| @intFromFloat(number),
        .string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        else => null,
    };
    return left_number != null and right_number != null and left_number.? == right_number.?;
}

fn premadeMemberDisplayName(
    team: []const std.json.Value,
    parents: *const [max_premade_players]usize,
    root: usize,
    player_index: usize,
    player: std.json.Value,
) []const u8 {
    const champion = std.mem.trim(u8, jsonStringField(player, "championName"), " \t\r\n");
    if (championNameAvailable(player, champion)) {
        var duplicate = false;
        for (team, 0..) |candidate, index| {
            if (index == player_index or premadeRoot(parents, index) != root) continue;
            const other = std.mem.trim(u8, jsonStringField(candidate, "championName"), " \t\r\n");
            if (championNameAvailable(candidate, other) and std.mem.eql(u8, champion, other)) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) return champion;
    }
    const role = positionLabel(playerPosition(player));
    if (!std.mem.eql(u8, role, "待定")) return role;
    return fallback(std.mem.trim(u8, jsonStringField(player, "gameName"), " \t\r\n"), "未知玩家");
}

fn championNameAvailable(player: std.json.Value, name: []const u8) bool {
    if (jsonIntField(player, "championId", 0) <= 0 or name.len == 0) return false;
    for ([_][]const u8{ "等待选择", "未知英雄", "未选择", "Unknown" }) |unavailable| {
        if (std.ascii.eqlIgnoreCase(name, unavailable)) return false;
    }
    return true;
}

fn appendUniqueName(group: *PremadeGroup, name: []const u8) void {
    if (name.len == 0 or group.len == group.names.len) return;
    for (group.names[0..group.len]) |existing| if (std.mem.eql(u8, existing, name)) return;
    group.names[group.len] = name;
    group.len += 1;
}

fn sortNames(group: *PremadeGroup) void {
    var index: usize = 1;
    while (index < group.len) : (index += 1) {
        const current = group.names[index];
        var slot = index;
        while (slot > 0 and std.mem.order(u8, current, group.names[slot - 1]) == .lt) : (slot -= 1) group.names[slot] = group.names[slot - 1];
        group.names[slot] = current;
    }
}

fn sortGroups(groups: []PremadeGroup) void {
    var index: usize = 1;
    while (index < groups.len) : (index += 1) {
        const current = groups[index];
        var slot = index;
        while (slot > 0 and std.mem.order(u8, current.names[0], groups[slot - 1].names[0]) == .lt) : (slot -= 1) groups[slot] = groups[slot - 1];
        groups[slot] = current;
    }
}

fn writeStringArray(writer: *std.Io.Writer, value: ?std.json.Value, separator: []const u8, empty: []const u8) !void {
    const array = value orelse return writer.writeAll(empty);
    var emitted = false;
    for (array.array.items) |item| {
        if (item != .string or item.string.len == 0) continue;
        if (emitted) try writer.writeAll(separator);
        emitted = true;
        try writer.writeAll(item.string);
    }
    if (!emitted) try writer.writeAll(empty);
}

fn templateValid(template: []const u8) bool {
    if (std.mem.trim(u8, template, " \t\r\n").len == 0 or countByte(template, '{') != countByte(template, '}')) return false;
    var rest = template;
    while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
        const after = rest[open + 1 ..];
        const close = std.mem.indexOfScalar(u8, after, '}') orelse return false;
        if (!knownField(after[0..close])) return false;
        rest = after[close + 1 ..];
    }
    return true;
}

fn knownField(field: []const u8) bool {
    for (template_fields) |candidate| if (std.mem.eql(u8, candidate, field)) return true;
    return false;
}

fn countByte(value: []const u8, needle: u8) usize {
    var count: usize = 0;
    for (value) |byte| if (byte == needle) {
        count += 1;
    };
    return count;
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

fn jsonStringField(value: std.json.Value, field: []const u8) []const u8 {
    if (value != .object) return "";
    const item = value.object.get(field) orelse return "";
    return if (item == .string) item.string else "";
}

fn jsonBoolField(value: std.json.Value, field: []const u8) bool {
    if (value != .object) return false;
    const item = value.object.get(field) orelse return false;
    return item == .bool and item.bool;
}

fn jsonIntField(value: std.json.Value, field: []const u8, default: i64) i64 {
    if (value != .object) return default;
    const item = value.object.get(field) orelse return default;
    return switch (item) {
        .integer => |number| number,
        .float => |number| @intFromFloat(number),
        .string => |text| std.fmt.parseInt(i64, text, 10) catch default,
        else => default,
    };
}

fn jsonFloatField(value: std.json.Value, field: []const u8, default: f64) f64 {
    if (value != .object) return default;
    const item = value.object.get(field) orelse return default;
    return switch (item) {
        .integer => |number| @floatFromInt(number),
        .float => |number| number,
        .string => |text| std.fmt.parseFloat(f64, text) catch default,
        else => default,
    };
}

fn fallback(value: []const u8, default: []const u8) []const u8 {
    return if (value.len > 0) value else default;
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    var stringify = std.json.Stringify{ .writer = writer, .options = .{} };
    try stringify.write(value);
}

test "renders all shortcut fields from enriched lobby players" {
    const config = "{\"automation\":{\"shortcutRecentGameCount\":1,\"shortcuts\":[{\"id\":\"all\",\"target\":\"lobby\",\"template\":\"{team} {name} {tag} {position} {rank} {lp} {score} {recent_wins}/{recent_losses} {recent_win_rate} {recent_games} {streak} {kda} {current_champion} {champion_games} {champion_win_rate} {top_champions} {premade} {risk} {horse}\",\"enabled\":true}]}}";
    const lobby = "{\"ally\":[" ++ validation_player ++ "],\"enemy\":[" ++ validation_player ++ "]}";
    var output: [32 * 1024]u8 = undefined;
    const result = try buildLines(config, "all", lobby, "ChampSelect", .{}, &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
    try std.testing.expect(std.mem.indexOf(u8, result, "我方 示例玩家 状态火热 中路 翡翠 II 63 82") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "近1场：胜 九尾妖狐 8/2/7") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, result, '{') == null);
}

test "horse template field classifies recent performance with a neutral small sample" {
    const games = "[{\"durationMinutes\":25,\"win\":true,\"kills\":8,\"deaths\":2,\"assists\":6},{\"durationMinutes\":26,\"win\":true,\"kills\":6,\"deaths\":2,\"assists\":7},{\"durationMinutes\":27,\"win\":false,\"kills\":4,\"deaths\":3,\"assists\":5}]";
    var player_buffer: [4096]u8 = undefined;
    var output: [64]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const upper_json = try std.fmt.bufPrint(&player_buffer, "{{\"score\":{{\"total\":80}},\"recentMatches\":{s}}}", .{games});
    const upper = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), upper_json, .{});
    try std.testing.expectEqualStrings("上等马", try renderTemplate("{horse}", upper, "我方", "ChampSelect", 5, &output));

    const middle_json = try std.fmt.bufPrint(&player_buffer, "{{\"score\":{{\"total\":65}},\"recentMatches\":{s}}}", .{games});
    const middle = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), middle_json, .{});
    try std.testing.expectEqualStrings("中等马", try renderTemplate("{horse}", middle, "我方", "ChampSelect", 5, &output));

    const lower_games = "[{\"durationMinutes\":25,\"win\":false,\"kills\":1,\"deaths\":8,\"assists\":2},{\"durationMinutes\":26,\"win\":false,\"kills\":2,\"deaths\":7,\"assists\":3},{\"durationMinutes\":27,\"win\":true,\"kills\":2,\"deaths\":6,\"assists\":2}]";
    const lower_json = try std.fmt.bufPrint(&player_buffer, "{{\"score\":{{\"total\":50}},\"recentMatches\":{s}}}", .{lower_games});
    const lower = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), lower_json, .{});
    try std.testing.expectEqualStrings("下等马", try renderTemplate("{horse}", lower, "我方", "ChampSelect", 5, &output));

    const small = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"score\":{\"total\":90},\"recentMatches\":[{\"durationMinutes\":25,\"win\":true},{\"durationMinutes\":25,\"win\":true}]}", .{});
    try std.testing.expectEqualStrings("中等马", try renderTemplate("{horse}", small, "我方", "ChampSelect", 5, &output));
}

test "jungle shortcut targets only assigned junglers" {
    const config = "{\"automation\":{\"shortcuts\":[{\"id\":\"jungle\",\"target\":\"jungle\",\"template\":\"{name}：{jungle_preference}\",\"enabled\":true}]}}";
    const lobby = "{\"ally\":[{\"gameName\":\"打野一\",\"assignedPosition\":\"JUNGLE\",\"championId\":103,\"jungleShortcutText\":\"精确分析一\"},{\"gameName\":\"中路\",\"assignedPosition\":\"MIDDLE\"}],\"enemy\":[{\"gameName\":\"打野二\",\"assignedPosition\":\"JUG\",\"championId\":64,\"jungleShortcutText\":\"精确分析二\"}]}";
    var output: [4096]u8 = undefined;
    try std.testing.expectEqualStrings("[\"打野一：精确分析一\",\"打野二：精确分析二\"]", try buildLines(config, "jungle", lobby, "ChampSelect", .{}, &output));
}

test "jungle shortcut maps alternate position fields and flattens preference text" {
    const config = "{\"automation\":{\"shortcuts\":[{\"id\":\"jungle\",\"target\":\"jungle\",\"template\":\"{name}：{jungle_preference}\",\"enabled\":true}]}}";
    const lobby = "{\"ally\":[{\"gameName\":\"我方打野\",\"position\":\"JUNGLE\",\"jungleShortcutText\":\"首龙均时6:12\\n场均小龙1.9\"}],\"enemy\":[{\"gameName\":\"敌方打野\",\"botPosition\":\"JUG\",\"jungleShortcutText\":\"反野偏好\\r\\n红方开局\"}]}";
    var output: [4096]u8 = undefined;
    const result = try buildLines(config, "jungle", lobby, "ChampSelect", .{}, &output);
    try std.testing.expectEqualStrings("[\"我方打野：首龙均时6:12 场均小龙1.9\",\"敌方打野：反野偏好 红方开局\"]", result);
}

test "jungle preference fallback also stays on one chat line" {
    const config = "{\"automation\":{\"shortcuts\":[{\"id\":\"jungle\",\"target\":\"jungle\",\"template\":\"{name}：{jungle_preference}\",\"enabled\":true}]}}";
    const lobby = "{\"ally\":[{\"gameName\":\"打野\",\"assignedPosition\":\"JUNGLE\",\"championId\":64,\"junglePreference\":{\"sampleSize\":4,\"evidence\":\"首龙均时 6:12\\n场均小龙 1.9\",\"averageKda\":3.2}}],\"enemy\":[]}";
    var output: [4096]u8 = undefined;
    const result = try buildLines(config, "jungle", lobby, "ChampSelect", .{}, &output);
    try std.testing.expectEqualStrings("[\"打野：本英雄打野样本4场 首龙均时 6:12 场均小龙 1.9 KDA 3.2\"]", result);
}

test "jungle shortcut keeps long normalized output in one message" {
    var long_text: [130]u8 = undefined;
    @memset(&long_text, 'a');
    var lobby_buffer: [2048]u8 = undefined;
    const lobby = try std.fmt.bufPrint(&lobby_buffer, "{{\"ally\":[{{\"gameName\":\"打野\",\"assignedPosition\":\"JUNGLE\",\"jungleShortcutText\":\"首龙均时 6:12\\r\\n{s}\"}}],\"enemy\":[]}}", .{long_text});
    const config = "{\"automation\":{\"shortcuts\":[{\"id\":\"jungle\",\"target\":\"jungle\",\"template\":\"{name}：{jungle_preference}\",\"enabled\":true}]}}";
    var output: [4096]u8 = undefined;
    const result = try buildLines(config, "jungle", lobby, "ChampSelect", .{}, &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    const line = parsed.value.array.items[0].string;
    try std.testing.expect(std.mem.indexOfAny(u8, line, "\r\n") == null);
    try std.testing.expect(try std.unicode.utf8CountCodepoints(line) > max_chat_line_chars);
}

test "jungle shortcut falls through an unassigned primary position" {
    const config = "{\"automation\":{\"shortcuts\":[{\"id\":\"jungle\",\"target\":\"jungle\",\"template\":\"{name}\",\"enabled\":true}]}}";
    const lobby = "{\"ally\":[{\"gameName\":\"打野\",\"assignedPosition\":\"NONE\",\"teamPosition\":\"JUNGLE\"}],\"enemy\":[]}";
    var output: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("[\"打野\"]", try buildLines(config, "jungle", lobby, "ChampSelect", .{}, &output));
}

test "jungle shortcut identifies smite when position is unavailable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const smite_player = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"gameName\":\"惩戒打野\",\"assignedPosition\":\"NONE\",\"summonerSpells\":[{\"id\":11,\"name\":\"\"},{\"id\":4,\"name\":\"闪现\"}]}", .{});
    const lane_player = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"gameName\":\"中路\",\"assignedPosition\":\"NONE\",\"spell1Id\":4,\"spell2Id\":14}", .{});
    try std.testing.expect(isJunglePlayer(smite_player));
    try std.testing.expect(!isJunglePlayer(lane_player));
}

test "jungle shortcut prefers smite over a stale first-seat position" {
    const config = "{\"automation\":{\"shortcuts\":[{\"id\":\"jungle\",\"target\":\"jungle\",\"template\":\"{name}\",\"enabled\":true}]}}";
    const lobby = "{\"ally\":[{\"gameName\":\"错误首位\",\"assignedPosition\":\"JUNGLE\",\"spell1Id\":4,\"spell2Id\":14},{\"gameName\":\"真实打野\",\"assignedPosition\":\"NONE\",\"spell1Id\":11,\"spell2Id\":4}],\"enemy\":[]}";
    var output: [4096]u8 = undefined;
    try std.testing.expectEqualStrings("[\"真实打野\"]", try buildLines(config, "jungle", lobby, "ChampSelect", .{}, &output));
}

test "built-in jungle preference ignores legacy custom target" {
    const config = "{\"automation\":{\"shortcuts\":[{\"id\":\"jungle-preference\",\"target\":\"custom\",\"template\":\"{name}\",\"enabled\":true}]}}";
    const lobby = "{\"ally\":[{\"gameName\":\"上路\",\"assignedPosition\":\"TOP\"},{\"gameName\":\"打野\",\"assignedPosition\":\"NONE\",\"spell1Id\":11}],\"enemy\":[{\"gameName\":\"敌方打野\",\"assignedPosition\":\"NONE\",\"summonerSpellTwoId\":11}]}";
    var output: [4096]u8 = undefined;
    try std.testing.expectEqualStrings("[\"打野\",\"敌方打野\"]", try buildLines(config, "jungle-preference", lobby, "ChampSelect", .{}, &output));
}

test "jungle shortcut emits every smite holder on both teams" {
    const config = "{\"automation\":{\"shortcuts\":[{\"id\":\"jungle\",\"target\":\"jungle\",\"template\":\"{name}\",\"enabled\":true}]}}";
    const lobby = "{\"ally\":[{\"gameName\":\"我方上路\",\"assignedPosition\":\"TOP\",\"summonerSpells\":[{\"id\":4}]},{\"gameName\":\"我方打野\",\"assignedPosition\":\"NONE\",\"summonerSpells\":[{\"id\":11}]}],\"enemy\":[{\"gameName\":\"敌方打野\",\"assignedPosition\":\"NONE\",\"spell1Id\":4,\"spell2Id\":11}]}";
    var output: [4096]u8 = undefined;
    try std.testing.expectEqualStrings("[\"我方打野\",\"敌方打野\"]", try buildLines(config, "jungle", lobby, "ChampSelect", .{}, &output));
}

test "jungle placeholder upgrades a renamed legacy custom shortcut" {
    const config = "{\"automation\":{\"shortcuts\":[{\"id\":\"custom-jungle\",\"target\":\"custom\",\"template\":\"{name}：{jungle_preference}\",\"enabled\":true}]}}";
    const lobby = "{\"ally\":[{\"gameName\":\"上路\",\"assignedPosition\":\"TOP\"},{\"gameName\":\"我方打野\",\"assignedPosition\":\"JUNGLE\"}],\"enemy\":[{\"gameName\":\"敌方打野\",\"assignedPosition\":\"JUNGLE\"}]}";
    var output: [4096]u8 = undefined;
    const result = try buildLines(config, "custom-jungle", lobby, "ChampSelect", .{}, &output);
    try std.testing.expectEqualStrings("[\"我方打野：尚未选择英雄\",\"敌方打野：尚未选择英雄\"]", result);
}

test "renders and deduplicates premade summary groups" {
    const config = "{\"automation\":{\"shortcuts\":[{\"id\":\"premade\",\"target\":\"premade\",\"template\":\"{name}\",\"enabled\":true}]}}";
    const lobby = "{\"ally\":[{\"gameName\":\"乙\",\"championId\":103,\"championName\":\"阿狸\",\"isPremade\":true,\"premadeWith\":[\"甲\"]},{\"gameName\":\"甲\",\"championId\":64,\"championName\":\"盲僧\",\"isPremade\":true,\"premadeWith\":[\"乙\"]}],\"enemy\":[]}";
    var output: [4096]u8 = undefined;
    const result = try buildLines(config, "premade", lobby, "ChampSelect", .{}, &output);
    try std.testing.expectEqualStrings("[\"敌方开黑：[]\",\"我方开黑：[盲僧、阿狸]\"]", result);
}

test "builds encounter shortcut lines for current lobby players" {
    const archive = "[{\"gameId\":7,\"selfPuuid\":\"self\",\"selfGameName\":\"本人\",\"selfTagLine\":\"ME\",\"puuid\":\"enemy\",\"gameName\":\"对手\",\"tagLine\":\"CN1\",\"championName\":\"盲僧\",\"side\":\"enemy\",\"encounteredAt\":\"2026-09-06T21:35:00.000Z\",\"kills\":3,\"deaths\":5,\"assists\":6,\"win\":false,\"selfChampionName\":\"九尾妖狐\",\"selfKills\":8,\"selfDeaths\":2,\"selfAssists\":7,\"selfWin\":true}]";
    const lobby = "{\"ally\":[],\"enemy\":[{\"puuid\":\"enemy\"}]}";
    var output: [4096]u8 = undefined;
    const result = try buildEncounterLinesOwned(archive, lobby, "self", &output);
    try std.testing.expectEqualStrings("[\"遇到过：09月06日 21:35，我（本人#ME）使用 九尾妖狐 8/2/7 胜；对方（对手#CN1）使用 盲僧 3/5/6 负\"]", result);
}

test "encounter shortcut excludes another owner and the current game" {
    const archive = "[{\"gameId\":8,\"selfPuuid\":\"self\",\"puuid\":\"enemy\",\"gameName\":\"本局\",\"encounteredAt\":\"2026-09-07T10:00:00.000Z\"},{\"gameId\":7,\"selfPuuid\":\"other\",\"puuid\":\"enemy\",\"gameName\":\"错误账号\",\"encounteredAt\":\"2026-09-06T10:00:00.000Z\"}]";
    const lobby = "{\"id\":\"8\",\"ally\":[],\"enemy\":[{\"puuid\":\"enemy\"}]}";
    var output: [4096]u8 = undefined;
    try std.testing.expectEqualStrings("[]", try buildEncounterLinesOwned(archive, lobby, "self", &output));
}

test "encounter shortcut excludes the local player's current premade" {
    const archive = "[{\"gameId\":7,\"selfPuuid\":\"self\",\"puuid\":\"party\",\"gameName\":\"开黑队友\",\"encounteredAt\":\"2026-09-06T10:00:00.000Z\"},{\"gameId\":6,\"selfPuuid\":\"self\",\"puuid\":\"random\",\"gameName\":\"随机队友\",\"encounteredAt\":\"2026-09-05T10:00:00.000Z\"},{\"gameId\":5,\"selfPuuid\":\"self\",\"puuid\":\"enemy\",\"gameName\":\"随机对手\",\"encounteredAt\":\"2026-09-04T10:00:00.000Z\"}]";
    const lobby = "{\"ally\":[{\"puuid\":\"self\",\"gameName\":\"本人\",\"premadeGroup\":\"party-a\"},{\"puuid\":\"party\",\"gameName\":\"开黑队友\",\"premadeGroup\":\"party-a\"},{\"puuid\":\"random\",\"gameName\":\"随机队友\"}],\"enemy\":[{\"puuid\":\"enemy\",\"gameName\":\"随机对手\"}]}";
    var output: [4096]u8 = undefined;
    const result = try buildEncounterLinesOwned(archive, lobby, "self", &output);
    try std.testing.expect(std.mem.indexOf(u8, result, "开黑队友") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "随机队友") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "随机对手") != null);
}

test "premade summary joins one inferred party in a single bracket" {
    const config = "{\"automation\":{\"shortcuts\":[{\"id\":\"premade\",\"target\":\"premade\",\"template\":\"{name}\",\"enabled\":true}]}}";
    const matches = "[{\"gameId\":1},{\"gameId\":2},{\"gameId\":3},{\"gameId\":4},{\"gameId\":5}]";
    var lobby_buffer: [8192]u8 = undefined;
    const lobby = try std.fmt.bufPrint(
        &lobby_buffer,
        "{{\"ally\":[{{\"gameName\":\"玩家甲\",\"championId\":1,\"championName\":\"剑魔\",\"isPremade\":true,\"premadeWith\":[],\"recentMatches\":{s}}},{{\"gameName\":\"玩家乙\",\"championId\":2,\"championName\":\"狐狸\",\"isPremade\":true,\"premadeWith\":[],\"recentMatches\":{s}}},{{\"gameName\":\"玩家丙\",\"championId\":3,\"championName\":\"加里奥\",\"isPremade\":true,\"premadeWith\":[],\"recentMatches\":{s}}}],\"enemy\":[]}}",
        .{ matches, matches, matches },
    );
    var output: [4096]u8 = undefined;
    const result = try buildLines(config, "premade", lobby, "ChampSelect", .{}, &output);
    try std.testing.expectEqualStrings("[\"敌方开黑：[]\",\"我方开黑：[剑魔、加里奥、狐狸]\"]", result);
}

test "premade summary uses group ids and omits an unlinked single marker" {
    const config = "{\"automation\":{\"shortcuts\":[{\"id\":\"premade\",\"target\":\"premade\",\"template\":\"{name}\",\"enabled\":true}]}}";
    const lobby = "{\"ally\":[{\"gameName\":\"未选一\",\"championId\":0,\"championName\":\"等待选择\",\"premadeGroup\":\"party-a\"},{\"gameName\":\"未选二\",\"championId\":0,\"premadeGroup\":\"party-a\"},{\"gameName\":\"单人标记\",\"isPremade\":true}],\"enemy\":[]}";
    var output: [4096]u8 = undefined;
    const result = try buildLines(config, "premade", lobby, "ChampSelect", .{}, &output);
    try std.testing.expectEqualStrings("[\"敌方开黑：[]\",\"我方开黑：[未选一、未选二]\"]", result);
}

test "splits rendered chat lines by unicode character count" {
    var long_name: [121 * 3]u8 = undefined;
    for (0..121) |index| @memcpy(long_name[index * 3 ..][0..3], "中");
    var lobby_buffer: [2048]u8 = undefined;
    const lobby = try std.fmt.bufPrint(&lobby_buffer, "{{\"ally\":[{{\"gameName\":\"{s}\"}}],\"enemy\":[]}}", .{long_name});
    const config = "{\"automation\":{\"shortcuts\":[{\"id\":\"long\",\"target\":\"ally\",\"template\":\"{name}\",\"enabled\":true}]}}";
    var output: [4096]u8 = undefined;
    const result = try buildLines(config, "long", lobby, "ChampSelect", .{}, &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
    try std.testing.expectEqual(@as(usize, 120), try std.unicode.utf8CountCodepoints(parsed.value.array.items[0].string));
    try std.testing.expectEqual(@as(usize, 1), try std.unicode.utf8CountCodepoints(parsed.value.array.items[1].string));
}

test "validates templates and allows disabled preview builds" {
    var validation_output: [4096]u8 = undefined;
    const validation = try validationDto("{unknown} {unknown}", &validation_output);
    try std.testing.expect(std.mem.indexOf(u8, validation, "\"valid\":false") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, validation, "未知占位符"));
    const config = "{\"automation\":{\"shortcuts\":[{\"id\":\"off\",\"target\":\"custom\",\"template\":\"{position}-{current_champion}\",\"enabled\":false}]}}";
    const lobby = "{\"ally\":[{\"gameName\":\"玩家\",\"championId\":0,\"championName\":\"等待选择\",\"assignedPosition\":\"MIDDLE\"}],\"enemy\":[]}";
    var output: [4096]u8 = undefined;
    try std.testing.expectError(error.ShortcutDisabled, buildLines(config, "off", lobby, "ChampSelect", .{}, &output));
    try std.testing.expectEqualStrings("[\"中路\"]", try buildLines(config, "off", lobby, "ChampSelect", .{ .require_enabled = false }, &output));
}
