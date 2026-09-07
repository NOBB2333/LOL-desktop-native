const std = @import("std");

pub const EncounterSummary = struct {
    count: usize = 0,
    latest: [32]u8 = undefined,
    latest_len: usize = 0,

    pub fn latestValue(self: *const EncounterSummary) []const u8 {
        return self.latest[0..self.latest_len];
    }
};

pub fn championConcentration(json: []const u8) f64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{}) catch return 0;
    if (root != .array or root.array.items.len == 0) return 0;
    var champion_counts: [32]usize = .{0} ** 32;
    var champion_ids: [32]i64 = .{0} ** 32;
    var champion_len: usize = 0;
    for (root.array.items) |match| {
        if (match != .object) continue;
        const id = jsonInt(match, "championId");
        var found: ?usize = null;
        for (champion_ids[0..champion_len], 0..) |known, index| if (known == id) {
            found = index;
            break;
        };
        if (found) |index| champion_counts[index] += 1 else if (champion_len < champion_ids.len) {
            champion_ids[champion_len] = id;
            champion_counts[champion_len] = 1;
            champion_len += 1;
        }
    }
    var best: usize = 0;
    for (champion_counts[0..champion_len]) |count| best = @max(best, count);
    return @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(root.array.items.len));
}

pub fn write(writer: *std.Io.Writer, json: []const u8, assigned_position: []const u8, current_champion_id: i64, encounter: EncounterSummary) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{}) catch {
        try writeEncounterOnly(writer, encounter);
        return;
    };
    if (root != .array or root.array.items.len == 0) {
        try writeEncounterOnly(writer, encounter);
        return;
    }

    var sample: usize = 0;
    var wins: usize = 0;
    var deaths_total: i64 = 0;
    var participation_total: f64 = 0;
    var damage_share_total: f64 = 0;
    var cs_per_minute_total: f64 = 0;
    var solo_count: usize = 0;
    var solo_total: f64 = 0;
    var gank_count: usize = 0;
    var gank_total: f64 = 0;
    var role_games: usize = 0;
    var current_games: usize = 0;
    var current_wins: usize = 0;
    for (root.array.items) |match| {
        if (match != .object or jsonInt(match, "durationMinutes") <= 0) continue;
        sample += 1;
        if (jsonBool(match, "win")) wins += 1;
        deaths_total += jsonInt(match, "deaths");
        participation_total += jsonFloat(match, "killParticipation");
        damage_share_total += jsonFloat(match, "damageShare");
        cs_per_minute_total += @as(f64, @floatFromInt(jsonInt(match, "cs"))) /
            @as(f64, @floatFromInt(@max(jsonInt(match, "durationMinutes"), 1)));
        if (jsonOptionalFloat(match, "soloKills")) |value| {
            solo_count += 1;
            solo_total += value;
        }
        if (jsonOptionalFloat(match, "earlyDeathsWithEnemyJungler")) |value| {
            gank_count += 1;
            gank_total += value;
        }
        if (samePosition(jsonField(match, "position"), assigned_position)) role_games += 1;
        if (current_champion_id > 0 and jsonInt(match, "championId") == current_champion_id) {
            current_games += 1;
            if (jsonBool(match, "win")) current_wins += 1;
        }
    }
    if (sample == 0) {
        try writeEncounterOnly(writer, encounter);
        return;
    }

    try writer.writeByte('[');
    var tag_count: usize = 0;
    var evidence: [256]u8 = undefined;
    if (encounter.count > 0) {
        const text = try std.fmt.bufPrint(&evidence, "最近在 {s} 遇到过该玩家，共遇到过 {d} 次（最近一年本地记录）", .{ encounter.latestValue(), encounter.count });
        try writeTag(writer, &tag_count, "met", "遇到过", "info", text);
    }
    if (solo_count >= 3) {
        const average = solo_total / @as(f64, @floatFromInt(solo_count));
        if (average >= 0.4) {
            const text = try std.fmt.bufPrint(&evidence, "{d}场有精确数据，场均单杀 {d:.1} 次", .{ solo_count, average });
            try writeTag(writer, &tag_count, "soloThreat", if (average >= 0.8) "单杀威胁" else "有单杀能力", "danger", text);
        }
    }
    if (gank_count > 0 and !isJunglePosition(assigned_position)) {
        const average = gank_total / @as(f64, @floatFromInt(gank_count));
        if (average > 2) {
            const text = try std.fmt.bufPrint(&evidence, "{d}场时间线中，15分钟前场均被敌方打野参与击杀 {d:.1} 次", .{ gank_count, average });
            try writeTag(writer, &tag_count, "veryEasyGank", "非常好抓", "danger", text);
        } else if (average >= 1.5) {
            const text = try std.fmt.bufPrint(&evidence, "{d}场时间线中，15分钟前场均被敌方打野参与击杀 {d:.1} 次", .{ gank_count, average });
            try writeTag(writer, &tag_count, "easyGank", "好抓", "danger", text);
        } else if (average < 1) {
            const text = try std.fmt.bufPrint(&evidence, "{d}场时间线中，15分钟前场均被敌方打野参与击杀 {d:.1} 次", .{ gank_count, average });
            try writeTag(writer, &tag_count, "hardGank", "难抓", "success", text);
        }
    }
    const sample_float = @as(f64, @floatFromInt(sample));
    if (sample >= 5) {
        const average_deaths = @as(f64, @floatFromInt(deaths_total)) / sample_float;
        if (average_deaths >= 6) {
            const text = try std.fmt.bufPrint(&evidence, "最近{d}场场均阵亡 {d:.1} 次", .{ sample, average_deaths });
            try writeTag(writer, &tag_count, "highDeaths", "阵亡偏多", "warning", text);
        } else if (average_deaths <= 3) {
            const text = try std.fmt.bufPrint(&evidence, "最近{d}场场均阵亡 {d:.1} 次", .{ sample, average_deaths });
            try writeTag(writer, &tag_count, "survivor", "生存稳健", "success", text);
        }
        const average_participation = participation_total / sample_float;
        if (average_participation >= 0.62) {
            const text = try std.fmt.bufPrint(&evidence, "最近{d}场平均参团率 {d:.0}%", .{ sample, average_participation * 100 });
            try writeTag(writer, &tag_count, "highParticipation", "参团积极", "success", text);
        } else if (average_participation > 0 and average_participation <= 0.4) {
            const text = try std.fmt.bufPrint(&evidence, "最近{d}场平均参团率 {d:.0}%", .{ sample, average_participation * 100 });
            try writeTag(writer, &tag_count, "lowParticipation", "参团偏低", "warning", text);
        }
        const average_damage_share = damage_share_total / sample_float;
        if (average_damage_share >= 0.27) {
            const text = try std.fmt.bufPrint(&evidence, "最近{d}场平均团队伤害占比 {d:.0}%", .{ sample, average_damage_share * 100 });
            try writeTag(writer, &tag_count, "damageCore", "输出核心", "success", text);
        }
        const average_cs = cs_per_minute_total / sample_float;
        if (average_cs >= 7.2) {
            const text = try std.fmt.bufPrint(&evidence, "最近{d}场分均补刀 {d:.1}", .{ sample, average_cs });
            try writeTag(writer, &tag_count, "strongFarm", "发育能力强", "info", text);
        }
    }
    const win_rate = @as(f64, @floatFromInt(wins)) / sample_float;
    if (win_rate >= 0.65 and sample >= 8) {
        const text = try std.fmt.bufPrint(&evidence, "最近{d}场胜率 {d:.0}%", .{ sample, win_rate * 100 });
        try writeTag(writer, &tag_count, "hot", "状态火热", "success", text);
    } else if (win_rate <= 0.35 and sample >= 8) {
        const text = try std.fmt.bufPrint(&evidence, "最近{d}场胜率 {d:.0}%", .{ sample, win_rate * 100 });
        try writeTag(writer, &tag_count, "slump", "近期低迷", "danger", text);
    }
    const role_rate = @as(f64, @floatFromInt(role_games)) / sample_float;
    if (role_rate < 0.35 and sample >= 8) {
        const text = try std.fmt.bufPrint(&evidence, "同位置占比 {d:.0}%", .{role_rate * 100});
        try writeTag(writer, &tag_count, "autofill", "可能补位", "warning", text);
    }
    const current_rate = if (current_games > 0) @as(f64, @floatFromInt(current_wins)) / @as(f64, @floatFromInt(current_games)) else 0;
    if (current_games >= 5 and current_rate >= 0.6) {
        const text = try std.fmt.bufPrint(&evidence, "{d}场胜率 {d:.0}%", .{ current_games, current_rate * 100 });
        try writeTag(writer, &tag_count, "signature", "当前英雄熟练", "success", text);
    } else if (current_games <= 1 and sample >= 8) {
        const text = try std.fmt.bufPrint(&evidence, "近期仅 {d} 场，不代表账号总熟练度", .{current_games});
        try writeTag(writer, &tag_count, "recentChampionSample", "近10场较少使用当前英雄", "info", text);
    }
    if (championConcentration(json) >= 0.5) {
        try writeTag(writer, &tag_count, "narrowPool", "英雄池集中", "info", "单一英雄占样本一半以上");
    }
    try writer.writeByte(']');
}

fn writeEncounterOnly(writer: *std.Io.Writer, encounter: EncounterSummary) !void {
    if (encounter.count == 0) return writer.writeAll("[]");
    var evidence: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&evidence, "最近在 {s} 遇到过该玩家，共遇到过 {d} 次（最近一年本地记录）", .{ encounter.latestValue(), encounter.count });
    var count: usize = 0;
    try writer.writeByte('[');
    try writeTag(writer, &count, "met", "遇到过", "info", text);
    try writer.writeByte(']');
}

fn writeTag(writer: *std.Io.Writer, count: *usize, key: []const u8, label: []const u8, tone: []const u8, evidence: []const u8) !void {
    if (count.* >= 5) return;
    if (count.* > 0) try writer.writeByte(',');
    try writer.writeAll("{\"key\":");
    try writeJsonString(writer, key);
    try writer.writeAll(",\"label\":");
    try writeJsonString(writer, label);
    try writer.writeAll(",\"tone\":");
    try writeJsonString(writer, tone);
    try writer.writeAll(",\"evidence\":");
    try writeJsonString(writer, evidence);
    try writer.writeByte('}');
    count.* += 1;
}

fn samePosition(left: []const u8, right: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(left, right)) return true;
    if ((std.ascii.eqlIgnoreCase(left, "MIDDLE") or std.ascii.eqlIgnoreCase(left, "MID")) and
        (std.ascii.eqlIgnoreCase(right, "MIDDLE") or std.ascii.eqlIgnoreCase(right, "MID"))) return true;
    if ((std.ascii.eqlIgnoreCase(left, "BOTTOM") or std.ascii.eqlIgnoreCase(left, "BOT") or std.ascii.eqlIgnoreCase(left, "ADC")) and
        (std.ascii.eqlIgnoreCase(right, "BOTTOM") or std.ascii.eqlIgnoreCase(right, "BOT") or std.ascii.eqlIgnoreCase(right, "ADC"))) return true;
    return (std.ascii.eqlIgnoreCase(left, "UTILITY") or std.ascii.eqlIgnoreCase(left, "SUPPORT")) and
        (std.ascii.eqlIgnoreCase(right, "UTILITY") or std.ascii.eqlIgnoreCase(right, "SUPPORT"));
}

fn isJunglePosition(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "JUNGLE") or std.ascii.eqlIgnoreCase(value, "JUG");
}

fn jsonField(value: std.json.Value, name: []const u8) []const u8 {
    if (value != .object) return "";
    const item = value.object.get(name) orelse return "";
    return if (item == .string) item.string else "";
}

fn jsonBool(value: std.json.Value, name: []const u8) bool {
    if (value != .object) return false;
    const item = value.object.get(name) orelse return false;
    return item == .bool and item.bool;
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

fn jsonOptionalFloat(value: std.json.Value, name: []const u8) ?f64 {
    if (value != .object) return null;
    const item = value.object.get(name) orelse return null;
    const number: f64 = switch (item) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        .string => |text| std.fmt.parseFloat(f64, text) catch return null,
        else => return null,
    };
    return if (std.math.isFinite(number) and number >= 0) number else null;
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    var stringify = std.json.Stringify{ .writer = writer, .options = .{} };
    try stringify.write(value);
}

test "position aliases are equivalent" {
    try std.testing.expect(samePosition("MID", "MIDDLE"));
    try std.testing.expect(samePosition("ADC", "BOTTOM"));
    try std.testing.expect(samePosition("SUPPORT", "UTILITY"));
    try std.testing.expect(!samePosition("TOP", "JUNGLE"));
}

test "champion concentration uses the largest recent sample" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), championConcentration("[{\"championId\":103},{\"championId\":103},{\"championId\":103},{\"championId\":1}]"), 0.0001);
}
