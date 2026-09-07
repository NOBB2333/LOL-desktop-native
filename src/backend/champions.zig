const std = @import("std");

/// Merge the localized LCU champion catalog with the ranked OP.GG snapshot.
/// Provider field names and position selection stay isolated from the bridge
/// runtime so this mapping can evolve without touching LCU/session handling.
pub const StatsStatus = struct {
    source: []const u8 = "opgg",
    stats_source: []const u8 = "opgg",
    fetched_at_millis: i64 = 0,
    expires_at_millis: ?i64 = null,
    is_stale: bool = false,
    error_message: ?[]const u8 = null,
};

pub fn hasRankedStats(stats_json: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), stats_json, .{}) catch return false;
    const data = if (root == .array)
        root
    else if (root == .object)
        root.object.get("data") orelse root
    else
        return false;
    if (data == .array) for (data.array.items) |champion| {
        const id = if (jsonInt(champion, "id") > 0) jsonInt(champion, "id") else jsonInt(champion, "champion_id");
        if (id > 0 and opggMainStats(champion) != null) return true;
    };
    if (data == .object) if (data.object.get("champions")) |champions| {
        if (champions == .object) {
            var iterator = champions.object.iterator();
            while (iterator.next()) |entry| if (opggMainStats(entry.value_ptr.*) != null) return true;
        }
    };
    return false;
}

pub fn dtoWithStats(catalog_json: []const u8, stats_json: ?[]const u8, status: StatsStatus, output: []u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, catalog_json, .{}) catch return error.LcuInvalidResponse;
    if (parsed != .array) return error.LcuInvalidResponse;
    const stats_root = if (stats_json) |value|
        std.json.parseFromSliceLeaky(std.json.Value, allocator, value, .{}) catch std.json.Value{ .null = {} }
    else
        std.json.Value{ .null = {} };

    var writer = std.Io.Writer.fixed(output);
    try writer.writeByte('[');
    var first = true;
    for (parsed.array.items) |champion| {
        if (champion != .object) continue;
        const id = jsonInt(champion, "id");
        if (id <= 0 or id >= 10_000) continue;
        if (!first) try writer.writeByte(',');
        first = false;

        const name = if (jsonField(champion, "name").len > 0) jsonField(champion, "name") else jsonField(champion, "displayName");
        const alias = jsonField(champion, "alias");
        const opgg = opggChampionStats(stats_root, id);
        const main_stats = if (opgg) |value| opggMainStats(value) else null;

        try writer.print("{{\"id\":{d},\"name\":", .{id});
        try jsonString(&writer, name);
        try writer.writeAll(",\"alias\":");
        try jsonString(&writer, alias);
        try writer.writeAll(",\"abilities\":");
        try writeStringArrayField(&writer, champion, "spells", "name");
        try writer.writeAll(",\"roles\":");
        if (opgg) |value| try writeOpggRoles(&writer, value) else try writeChampionRoles(&writer, champion);
        try writer.writeAll(",\"tier\":");
        if (main_stats) |value| {
            const tier = if (jsonInt(value, "tier") > 0) jsonInt(value, "tier") else nestedInt(value, "tier_data", "tier");
            if (tier > 0) try writer.print("\"T{d}\"", .{tier}) else try writer.writeAll("\"-\"");
        } else try writer.writeAll("\"-\"");
        try writer.writeAll(",\"winRate\":");
        try writer.print("{d:.6},\"pickRate\":{d:.6},\"banRate\":{d:.6},\"kda\":{d:.6},\"iconUrl\":", .{
            if (main_stats) |value| jsonFloatEither(value, "win_rate", "winRate") else 0,
            if (main_stats) |value| jsonFloatEither(value, "pick_rate", "pickRate") else 0,
            if (main_stats) |value| jsonFloatEither(value, "ban_rate", "banRate") else 0,
            if (main_stats) |value| jsonFloat(value, "kda") else 0,
        });
        var icon_url: [96]u8 = undefined;
        try jsonString(&writer, std.fmt.bufPrint(&icon_url, "lcu://champion/{d}", .{id}) catch "lcu://champion");
        try writer.writeAll(",\"baseSource\":\"lcu\",\"statsSource\":");
        try jsonString(&writer, if (main_stats != null) status.stats_source else "unavailable");
        try writer.writeAll(",\"dataStatus\":{\"source\":");
        try jsonString(&writer, if (main_stats != null) status.source else "lcu");
        try writer.writeAll(",\"fetchedAt\":");
        try writeIsoTimestamp(&writer, status.fetched_at_millis);
        try writer.writeAll(",\"expiresAt\":");
        if (status.expires_at_millis) |expires_at| try writeIsoTimestamp(&writer, expires_at) else try writer.writeAll("null");
        try writer.print(",\"isStale\":{},\"error\":", .{main_stats != null and status.is_stale});
        if (status.error_message) |message| try jsonString(&writer, message) else try writer.writeAll("null");
        try writer.writeAll("}}");
    }
    try writer.writeByte(']');
    return writer.buffered();
}

fn opggChampionStats(root: std.json.Value, champion_id: i64) ?std.json.Value {
    const data = if (root == .array)
        root
    else if (root == .object)
        root.object.get("data") orelse root
    else
        return null;
    if (data == .array) for (data.array.items) |champion| {
        const id = if (jsonInt(champion, "id") > 0) jsonInt(champion, "id") else jsonInt(champion, "champion_id");
        if (champion == .object and id == champion_id) return champion;
    };
    // Also accept the normalized snapshot shape used by the Rust cache.
    if (data == .object) {
        if (data.object.get("champions")) |champions| {
            if (champions == .object) {
                var id_buffer: [24]u8 = undefined;
                const key = std.fmt.bufPrint(&id_buffer, "{d}", .{champion_id}) catch return null;
                if (champions.object.get(key)) |values| {
                    if (values == .array and values.array.items.len > 0) return values;
                    if (values == .object) return values;
                }
            }
        }
    }
    return null;
}

fn opggMainStats(champion: std.json.Value) ?std.json.Value {
    if (champion == .array) {
        for (champion.array.items) |position| {
            if (jsonBoolEither(position, "is_main_position", "isMainPosition")) return position;
        }
        return if (champion.array.items.len > 0) champion.array.items[0] else null;
    }
    if (champion != .object) return null;
    if (champion.object.get("positions")) |positions| if (positions == .array and positions.array.items.len > 0) {
        var best: ?std.json.Value = null;
        var best_role: f64 = -1;
        for (positions.array.items) |position| {
            if (position != .object) continue;
            const stats = position.object.get("stats") orelse position;
            if (stats != .object) continue;
            const role_rate = if (jsonFloat(stats, "role_rate") != 0)
                jsonFloat(stats, "role_rate")
            else
                jsonFloatEither(position, "role_rate", "roleRate");
            if (best == null or role_rate > best_role) {
                best = stats;
                best_role = role_rate;
            }
        }
        if (best) |value| return value;
    };
    if (champion.object.get("average_stats")) |average| if (average == .object) return average;
    // A normalized ChampionMeta has its statistical fields at the root.
    if (champion.object.get("winRate") != null or champion.object.get("win_rate") != null) return champion;
    return null;
}

fn writeOpggRoles(writer: *std.Io.Writer, champion: std.json.Value) !void {
    try writer.writeByte('[');
    var first = true;
    if (champion == .array) for (champion.array.items) |position| {
        const raw = jsonField(position, "position");
        if (raw.len == 0) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try jsonString(writer, canonicalPosition(raw));
    };
    if (champion == .object) if (champion.object.get("positions")) |positions| if (positions == .array) for (positions.array.items) |position| {
        if (position != .object) continue;
        const raw = if (jsonField(position, "name").len > 0) jsonField(position, "name") else jsonField(position, "position");
        if (raw.len == 0) continue;
        const role = canonicalPosition(raw);
        if (!first) try writer.writeByte(',');
        first = false;
        try jsonString(writer, role);
    };
    try writer.writeByte(']');
}

fn canonicalPosition(raw: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(raw, "MID") or std.ascii.eqlIgnoreCase(raw, "MIDDLE")) return "MIDDLE";
    if (std.ascii.eqlIgnoreCase(raw, "ADC") or std.ascii.eqlIgnoreCase(raw, "BOT") or std.ascii.eqlIgnoreCase(raw, "BOTTOM")) return "BOTTOM";
    if (std.ascii.eqlIgnoreCase(raw, "SUPPORT") or std.ascii.eqlIgnoreCase(raw, "UTILITY")) return "UTILITY";
    if (std.ascii.eqlIgnoreCase(raw, "JUNGLE")) return "JUNGLE";
    if (std.ascii.eqlIgnoreCase(raw, "TOP")) return "TOP";
    return raw;
}

fn writeChampionRoles(writer: *std.Io.Writer, champion: std.json.Value) !void {
    try writer.writeByte('[');
    var first = true;
    if (champion == .object) if (champion.object.get("roles")) |value| if (value == .array) {
        for (value.array.items) |item| {
            const raw = if (item == .string) item.string else if (item == .object) jsonField(item, "name") else "";
            if (raw.len == 0) continue;
            const label = if (std.ascii.eqlIgnoreCase(raw, "fighter")) "战士" else if (std.ascii.eqlIgnoreCase(raw, "assassin")) "刺客" else if (std.ascii.eqlIgnoreCase(raw, "mage")) "法师" else if (std.ascii.eqlIgnoreCase(raw, "marksman")) "射手" else if (std.ascii.eqlIgnoreCase(raw, "support")) "辅助" else if (std.ascii.eqlIgnoreCase(raw, "tank")) "坦克" else raw;
            if (!first) try writer.writeByte(',');
            first = false;
            try jsonString(writer, label);
        }
    };
    try writer.writeByte(']');
}

fn writeStringArrayField(writer: *std.Io.Writer, object: std.json.Value, field: []const u8, object_item: ?[]const u8) !void {
    try writer.writeByte('[');
    var first = true;
    if (object == .object) if (object.object.get(field)) |array_value| if (array_value == .array) {
        for (array_value.array.items) |item| {
            const text = if (object_item) |name| jsonField(item, name) else if (item == .string) item.string else "";
            if (text.len == 0) continue;
            if (!first) try writer.writeByte(',');
            first = false;
            try jsonString(writer, text);
        }
    };
    try writer.writeByte(']');
}

fn nestedInt(value: std.json.Value, nested: []const u8, name: []const u8) i64 {
    if (value != .object) return 0;
    const object = value.object.get(nested) orelse return 0;
    return jsonInt(object, name);
}

fn jsonInt(value: std.json.Value, name: []const u8) i64 {
    if (value != .object) return 0;
    const item = value.object.get(name) orelse return 0;
    return switch (item) {
        .integer => |number| number,
        .float => |number| @intFromFloat(number),
        .string => |text| std.fmt.parseInt(i64, std.mem.trim(u8, text, " \t\r\n"), 10) catch 0,
        else => 0,
    };
}

fn jsonFloat(value: std.json.Value, name: []const u8) f64 {
    if (value != .object) return 0;
    const item = value.object.get(name) orelse return 0;
    return switch (item) {
        .integer => |number| @floatFromInt(number),
        .float => |number| number,
        .string => |text| std.fmt.parseFloat(f64, text) catch 0,
        else => 0,
    };
}

fn jsonFloatEither(value: std.json.Value, snake_name: []const u8, camel_name: []const u8) f64 {
    if (value != .object) return 0;
    const raw = if (value.object.get(snake_name) != null) jsonFloat(value, snake_name) else jsonFloat(value, camel_name);
    // OP.GG snapshots have appeared in both ratio (0.52) and percentage
    // (52) forms. The frontend consistently renders ratios, so normalize at
    // the bridge boundary instead of making every view guess the provider's
    // encoding.
    return if (raw > 1.0 and raw <= 100.0) raw / 100.0 else raw;
}

fn jsonBoolEither(value: std.json.Value, snake_name: []const u8, camel_name: []const u8) bool {
    if (value != .object) return false;
    const item = value.object.get(snake_name) orelse value.object.get(camel_name) orelse return false;
    return switch (item) {
        .bool => |flag| flag,
        .integer => |number| number != 0,
        .string => |text| std.ascii.eqlIgnoreCase(text, "true") or std.mem.eql(u8, text, "1"),
        else => false,
    };
}

fn jsonField(value: std.json.Value, name: []const u8) []const u8 {
    if (value != .object) return "";
    const item = value.object.get(name) orelse return "";
    return if (item == .string) item.string else "";
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

test "maps current OP.GG ranked fields and position aliases" {
    const catalog = "[{\"id\":103,\"name\":\"阿狸\",\"alias\":\"Ahri\",\"roles\":[\"mage\"]}]";
    const opgg = "{\"data\":[{\"id\":103,\"average_stats\":{\"kda\":2.5},\"positions\":[{\"name\":\"SUPPORT\",\"stats\":{\"role_rate\":0.1,\"tier_data\":{\"tier\":4}}},{\"name\":\"MID\",\"stats\":{\"win_rate\":0.52,\"pick_rate\":0.08,\"ban_rate\":0.03,\"kda\":3.25,\"role_rate\":0.9,\"tier_data\":{\"tier\":2}}}]}]}";
    var output: [4096]u8 = undefined;
    const result = try dtoWithStats(catalog, opgg, .{ .fetched_at_millis = 1_625_159_473_123 }, &output);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"roles\":[\"UTILITY\",\"MIDDLE\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"tier\":\"T2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"kda\":3.250000") != null);
    try std.testing.expect(hasRankedStats(opgg));
    try std.testing.expect(!hasRankedStats("{\"data\":[],\"message\":\"rate limited\"}"));
}

test "accepts normalized champion ids and position aliases" {
    const catalog = "[{\"id\":103,\"name\":\"阿狸\",\"alias\":\"Ahri\",\"roles\":[\"mage\"]}]";
    const opgg = "{\"data\":[{\"champion_id\":103,\"positions\":[{\"name\":\"BOT\",\"stats\":{\"win_rate\":0.51,\"role_rate\":1,\"tier\":3}}]}]}";
    var output: [4096]u8 = undefined;
    const result = try dtoWithStats(catalog, opgg, .{ .source = "sqlite-fresh", .stats_source = "sqlite", .fetched_at_millis = 1_625_159_473_123 }, &output);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"roles\":[\"BOTTOM\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"statsSource\":\"sqlite\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "1970-01-01") == null);
}

test "maps Rust normalized OP.GG snapshots with camel-case fields and main position" {
    const catalog = "[{\"id\":103,\"name\":\"阿狸\",\"alias\":\"Ahri\",\"roles\":[\"mage\"]}]";
    const snapshot = "{\"mode\":\"ranked\",\"champions\":{\"103\":[{\"championId\":103,\"position\":\"UTILITY\",\"tier\":4,\"winRate\":0.48,\"pickRate\":0.01,\"banRate\":0.02,\"roleRate\":0.1,\"isMainPosition\":false},{\"championId\":103,\"position\":\"MIDDLE\",\"tier\":2,\"winRate\":0.53,\"pickRate\":0.09,\"banRate\":0.04,\"roleRate\":0.9,\"isMainPosition\":true}]}}";
    var output: [4096]u8 = undefined;
    const result = try dtoWithStats(catalog, snapshot, .{ .source = "sqlite-fresh", .stats_source = "sqlite", .fetched_at_millis = 1_625_159_473_123 }, &output);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"roles\":[\"UTILITY\",\"MIDDLE\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"tier\":\"T2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"winRate\":0.530000") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"pickRate\":0.090000") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"banRate\":0.040000") != null);
}
