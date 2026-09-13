//! 玩家信号：后端对某位玩家 `recentMatches` 的派生结论。
//!
//! ## 为什么需要这个模块
//!
//! 卡片标签（`frontend/src/tags/definitions/`）渲染在前端，而**快捷消息变量**
//! （`shortcuts.zig` 的 `{tag}` / `{streak}` / `{risk}`）与**队伍小结**
//! （`writeLiveTeamSummary` 的 strengths / risks）跑在后端。两边读的是同一份
//! `recentMatches`，所以后端必须自己也能得出结论。
//!
//! 为了避免再出现「同一个概念两套说法」，这里的**阈值与中文文案与卡片标签逐条一致**：
//!
//! | 信号 | 对应前端定义 |
//! |---|---|
//! | `极高胜率` | `definitions/performance.ts` `HIGH_WIN_RATE_TAG` |
//! | `N 连胜` / `N 连败` | 同上 `WINNING_STREAK_TAG` / `LOSING_STREAK_TAG` |
//! | `好抓` / `非常好抓` / `难抓` | `definitions/playstyle.ts` `EASY_GANK_TAG` |
//! | `N 单杀` | 同上 `SOLO_KILLS_TAG` |
//! | `伤害 N%` | 同上 `DAMAGE_SHARE_TAG` |
//! | `分均补刀 N` | 同上 `CS_PER_MINUTE_TAG` |
//! | `阵亡偏多` / `生存稳健` | 同上 `DEATHS_TAG` |
//! | `参团积极` / `参团偏低` | 同上 `PARTICIPATION_TAG` |
//! | `英雄池集中` | 同上 `POOL_CONCENTRATION_TAG` |
//!
//! **改任一侧的阈值或文案，必须同步另一侧。** 前端侧的断言在
//! `frontend/src/tags/tags.test.ts`，后端侧的断言在本文件末尾。
//!
//! 本模块只写 `std.Io.Writer`，不分配内存 —— 快捷消息的渲染路径没有 arena。

const std = @import("std");

/// 信号倾向。队伍小结按此分到 strengths / risks。
pub const Tone = enum {
    /// 正向信号
    positive,
    /// 负向信号
    negative,
    /// 中性事实（与 `positive` 同进 strengths，但语义上只是陈述）
    neutral,
};

/// 队伍小结 / 快捷消息变量要取的那一档。
pub const Bucket = enum {
    strengths,
    risks,

    fn accepts(self: Bucket, tone: Tone) bool {
        return switch (self) {
            .strengths => tone != .negative,
            .risks => tone == .negative,
        };
    }
};

/// 单次最多产出的信号数。
pub const max_signals = 12;

// ── 阈值：与前端 `definitions/` 逐条对齐 ──
const streak_threshold: usize = 3;
const high_death_threshold: f64 = 6;
const low_death_threshold: f64 = 3;
const high_participation_threshold: f64 = 0.62;
const low_participation_threshold: f64 = 0.4;
const damage_core_threshold: f64 = 0.27;
const strong_farm_threshold: f64 = 7.2;
const pool_concentration_threshold: f64 = 0.7;
const high_win_rate_min_sample: usize = 16;
const high_win_rate_threshold: f64 = 0.85;
/// 场均类判定的样本下限（前端 `AVERAGE_MIN_SAMPLE`）。
const average_min_sample: usize = 5;
/// 单杀判定的精确数据样本下限（前端 `SOLO_KILL_MIN_SAMPLE`）。
const solo_kill_min_sample: usize = 3;
/// 好抓判定：`> 2` 非常好抓、`>= 1.5` 好抓、`[1, 1.5)` 不标注、`< 1` 难抓。
const gank_very_easy_threshold: f64 = 2;
const gank_easy_threshold: f64 = 1.5;

/// 汇总后的指标。
pub const Metrics = struct {
    sample: usize = 0,
    wins: usize = 0,
    deaths_total: i64 = 0,
    participation_total: f64 = 0,
    damage_share_total: f64 = 0,
    cs_per_minute_total: f64 = 0,
    solo_count: usize = 0,
    solo_total: f64 = 0,
    gank_count: usize = 0,
    gank_total: f64 = 0,
    winning_streak: usize = 0,
    losing_streak: usize = 0,
    concentration: f64 = 0,
    is_jungler: bool = false,

    pub fn winRate(self: Metrics) f64 {
        if (self.sample == 0) return 0;
        return @as(f64, @floatFromInt(self.wins)) / @as(f64, @floatFromInt(self.sample));
    }

    pub fn averageDeaths(self: Metrics) f64 {
        if (self.sample == 0) return 0;
        return @as(f64, @floatFromInt(self.deaths_total)) / @as(f64, @floatFromInt(self.sample));
    }

    pub fn averageParticipation(self: Metrics) f64 {
        if (self.sample == 0) return 0;
        return self.participation_total / @as(f64, @floatFromInt(self.sample));
    }

    pub fn averageDamageShare(self: Metrics) f64 {
        if (self.sample == 0) return 0;
        return self.damage_share_total / @as(f64, @floatFromInt(self.sample));
    }

    pub fn averageCsPerMinute(self: Metrics) f64 {
        if (self.sample == 0) return 0;
        return self.cs_per_minute_total / @as(f64, @floatFromInt(self.sample));
    }

    pub fn averageSoloKills(self: Metrics) ?f64 {
        if (self.solo_count == 0) return null;
        return self.solo_total / @as(f64, @floatFromInt(self.solo_count));
    }

    pub fn averageEarlyDeathsWithJungler(self: Metrics) ?f64 {
        if (self.gank_count == 0) return null;
        return self.gank_total / @as(f64, @floatFromInt(self.gank_count));
    }
};

/// 只统计已结束的对局（`durationMinutes > 0`），与前端 `facts.ts` 的 `finished` 一致。
pub fn analyze(player: std.json.Value) Metrics {
    var metrics = Metrics{ .is_jungler = isJungler(player) };
    const recent = nestedArray(player, "recentMatches") orelse return metrics;

    // 连胜/连败：未结束的对局按前端口径「先过滤、再从头扫描」，即跳过而非打断。
    metrics.winning_streak = leadingStreak(recent, true);
    metrics.losing_streak = leadingStreak(recent, false);

    var champion_ids: [32]i64 = .{0} ** 32;
    var champion_counts: [32]usize = .{0} ** 32;
    var distinct: usize = 0;
    var best: usize = 0;
    var champion_sample: usize = 0;

    for (recent) |match| {
        if (match != .object) continue;
        const minutes = jsonInt(match, "durationMinutes");
        if (minutes <= 0) continue;
        metrics.sample += 1;
        if (jsonBool(match, "win")) metrics.wins += 1;
        metrics.deaths_total += jsonInt(match, "deaths");
        metrics.participation_total += jsonFloat(match, "killParticipation");
        metrics.damage_share_total += jsonFloat(match, "damageShare");
        metrics.cs_per_minute_total += @as(f64, @floatFromInt(jsonInt(match, "cs"))) /
            @as(f64, @floatFromInt(@max(minutes, 1)));
        if (jsonOptionalFloat(match, "soloKills")) |value| {
            metrics.solo_count += 1;
            metrics.solo_total += value;
        }
        if (jsonOptionalFloat(match, "earlyDeathsWithEnemyJungler")) |value| {
            metrics.gank_count += 1;
            metrics.gank_total += value;
        }

        // 缺 `championId` 的对局不进英雄池统计：否则「全部缺失」会被当成
        // 「全是同一个英雄」，凭空造出一条「英雄池集中」。
        if (hasField(match, "championId")) {
            champion_sample += 1;
            const champion_id = jsonInt(match, "championId");
            var slot: ?usize = null;
            for (champion_ids[0..distinct], 0..) |known, index| if (known == champion_id) {
                slot = index;
                break;
            };
            if (slot) |index| {
                champion_counts[index] += 1;
                best = @max(best, champion_counts[index]);
            } else if (distinct < champion_ids.len) {
                champion_ids[distinct] = champion_id;
                champion_counts[distinct] = 1;
                distinct += 1;
                best = @max(best, 1);
            }
        }
    }

    if (champion_sample > 0) {
        metrics.concentration = @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(champion_sample));
    }
    return metrics;
}

/// 信号发射器：按注册表顺序遍历，命中 `bucket` 的信号写进 `writer`。
const Emitter = struct {
    writer: *std.Io.Writer,
    /// `null` 表示不按档位过滤（`{tag}` 取第一条）。
    bucket: ?Bucket = null,
    separator: []const u8 = "、",
    limit: usize = max_signals,
    count: usize = 0,

    fn accepts(self: *const Emitter, tone: Tone) bool {
        if (self.count >= self.limit) return false;
        const bucket = self.bucket orelse return self.count == 0;
        return bucket.accepts(tone);
    }

    fn emit(self: *Emitter, tone: Tone, comptime format: []const u8, args: anytype) !void {
        if (!self.accepts(tone)) return;
        if (self.count > 0) try self.writer.writeAll(self.separator);
        try self.writer.print(format, args);
        self.count += 1;
    }
};

/// 按卡片标签的注册表顺序产出信号，命中 `bucket` 的写进 `writer`。
/// 返回写出的条数（0 表示没有信号）。
pub fn writeBucket(
    writer: *std.Io.Writer,
    player: std.json.Value,
    bucket: Bucket,
    separator: []const u8,
    limit: usize,
) !usize {
    var emitter = Emitter{ .writer = writer, .bucket = bucket, .separator = separator, .limit = limit };
    try emitAll(&emitter, player);
    return emitter.count;
}

/// 写出第一条命中的信号标签（`{tag}`）。
pub fn writeFirst(
    writer: *std.Io.Writer,
    player: std.json.Value,
    separator: []const u8,
    limit: usize,
) !usize {
    var emitter = Emitter{ .writer = writer, .bucket = null, .separator = separator, .limit = limit };
    try emitAll(&emitter, player);
    return emitter.count;
}

/// 写出 `{streak}`：连胜 / 连败 / 状态稳定。与卡片标签同文案。
pub fn writeStreak(writer: *std.Io.Writer, player: std.json.Value) !void {
    const metrics = analyze(player);
    if (metrics.winning_streak >= streak_threshold) {
        return writer.print("{d} 连胜", .{metrics.winning_streak});
    }
    if (metrics.losing_streak >= streak_threshold) {
        return writer.print("{d} 连败", .{metrics.losing_streak});
    }
    return writer.writeAll("状态稳定");
}

/// 遍历全部信号。顺序对齐 `frontend/src/tags/registry.ts`。
fn emitAll(emitter: *Emitter, player: std.json.Value) !void {
    const metrics = analyze(player);
    if (metrics.sample == 0) return;

    if (metrics.sample >= high_win_rate_min_sample and metrics.winRate() >= high_win_rate_threshold) {
        try emitter.emit(.positive, "极高胜率", .{});
    }
    if (metrics.winning_streak >= streak_threshold) {
        try emitter.emit(.positive, "{d} 连胜", .{metrics.winning_streak});
    }
    if (metrics.losing_streak >= streak_threshold) {
        try emitter.emit(.negative, "{d} 连败", .{metrics.losing_streak});
    }
    if (!metrics.is_jungler) {
        if (metrics.averageEarlyDeathsWithJungler()) |times| {
            if (times > gank_very_easy_threshold) {
                try emitter.emit(.negative, "非常好抓", .{});
            } else if (times >= gank_easy_threshold) {
                try emitter.emit(.negative, "好抓", .{});
            } else if (times < 1) {
                try emitter.emit(.positive, "难抓", .{});
            }
        }
    }
    if (metrics.solo_count >= solo_kill_min_sample) {
        if (metrics.averageSoloKills()) |average| {
            if (average > 0) try emitter.emit(.neutral, "{d:.1} 单杀", .{average});
        }
    }
    if (metrics.sample >= average_min_sample) {
        const damage_share = metrics.averageDamageShare();
        if (damage_share >= damage_core_threshold) {
            try emitter.emit(.positive, "伤害 {d:.0}%", .{damage_share * 100});
        }
        const cs = metrics.averageCsPerMinute();
        if (cs >= strong_farm_threshold) {
            try emitter.emit(.neutral, "分均补刀 {d:.1}", .{cs});
        }
        const deaths = metrics.averageDeaths();
        if (deaths >= high_death_threshold) {
            try emitter.emit(.negative, "阵亡偏多", .{});
        } else if (deaths <= low_death_threshold) {
            try emitter.emit(.positive, "生存稳健", .{});
        }
        const participation = metrics.averageParticipation();
        if (participation >= high_participation_threshold) {
            try emitter.emit(.positive, "参团积极", .{});
        } else if (participation > 0 and participation <= low_participation_threshold) {
            try emitter.emit(.negative, "参团偏低", .{});
        }
    }
    if (metrics.concentration >= pool_concentration_threshold) {
        try emitter.emit(.negative, "英雄池集中", .{});
    }
}

/// 单一英雄在样本中的最大占比；未结束或缺 `championId` 的对局不计入。
/// 一份都没有 `championId` 时返回 0 —— 与前端读 `championPoolConcentration` 的表现一致
/// （字段缺失就是没有结论，不能当成「英雄池 100% 集中」）。
pub fn concentrationOf(matches: []const std.json.Value) f64 {
    if (matches.len == 0) return 0;
    var champion_counts: [32]usize = .{0} ** 32;
    var champion_ids: [32]i64 = .{0} ** 32;
    var champion_len: usize = 0;
    var champion_sample: usize = 0;
    for (matches) |match| {
        if (match != .object) continue;
        if (jsonInt(match, "durationMinutes") <= 0) continue;
        if (!hasField(match, "championId")) continue;
        champion_sample += 1;
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
    if (champion_sample == 0) return 0;
    var best: usize = 0;
    for (champion_counts[0..champion_len]) |count| best = @max(best, count);
    return @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(champion_sample));
}

/// Smite（惩戒）的法术 id。与前端 `facts.ts` 的 `SMITE_SPELL_ID` 一致。
const smite_spell_id: i64 = 11;

/// 是否打野。与前端 `isJungler` 同口径：先看分路，再看有没有带惩戒
/// —— 选人阶段分路常常还没公开，只看分路会把惩戒打野误判成「好抓」。
pub fn isJungler(player: std.json.Value) bool {
    if (isJunglePosition(jsonField(player, "assignedPosition"))) return true;
    const spells = nestedArray(player, "summonerSpells") orelse return false;
    for (spells) |spell| {
        if (spell != .object) continue;
        if (jsonInt(spell, "id") == smite_spell_id) return true;
    }
    return false;
}

pub fn isJunglePosition(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "JUNGLE") or std.ascii.eqlIgnoreCase(value, "JUG");
}

fn leadingStreak(matches: []const std.json.Value, win: bool) usize {
    var count: usize = 0;
    for (matches) |match| {
        if (match != .object) continue;
        if (jsonInt(match, "durationMinutes") <= 0) continue;
        if (jsonBool(match, "win") != win) break;
        count += 1;
    }
    return count;
}

fn nestedArray(value: std.json.Value, name: []const u8) ?[]const std.json.Value {
    if (value != .object) return null;
    const item = value.object.get(name) orelse return null;
    return if (item == .array) item.array.items else null;
}

fn hasField(value: std.json.Value, name: []const u8) bool {
    if (value != .object) return false;
    return value.object.get(name) != null;
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

// ── 测试：与前端 `tags.test.ts` 的阈值断言互为镜像 ──

fn writeBucketToBuf(
    output: []u8,
    player_json: []const u8,
    bucket: Bucket,
) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const player = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), player_json, .{}) catch std.json.Value{ .null = {} };
    var writer = std.Io.Writer.fixed(output);
    _ = try writeBucket(&writer, player, bucket, "、", max_signals);
    return writer.buffered();
}

test "strengths 与 risks 按卡片标签的阈值分档" {
    var output: [512]u8 = undefined;
    const player_json =
        "{\"assignedPosition\":\"MIDDLE\",\"recentMatches\":[" ++
        "{\"durationMinutes\":30,\"win\":true,\"deaths\":2,\"killParticipation\":0.7,\"damageShare\":0.3,\"cs\":240}," ++
        "{\"durationMinutes\":30,\"win\":true,\"deaths\":2,\"killParticipation\":0.7,\"damageShare\":0.3,\"cs\":240}," ++
        "{\"durationMinutes\":30,\"win\":true,\"deaths\":2,\"killParticipation\":0.7,\"damageShare\":0.3,\"cs\":240}," ++
        "{\"durationMinutes\":30,\"win\":true,\"deaths\":2,\"killParticipation\":0.7,\"damageShare\":0.3,\"cs\":240}," ++
        "{\"durationMinutes\":30,\"win\":false,\"deaths\":2,\"killParticipation\":0.7,\"damageShare\":0.3,\"cs\":240}" ++
        "]}";

    const strengths = try writeBucketToBuf(&output, player_json, .strengths);
    try std.testing.expect(std.mem.indexOf(u8, strengths, "4 连胜") != null);
    try std.testing.expect(std.mem.indexOf(u8, strengths, "伤害 30%") != null);
    try std.testing.expect(std.mem.indexOf(u8, strengths, "分均补刀 8.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, strengths, "生存稳健") != null);
    try std.testing.expect(std.mem.indexOf(u8, strengths, "参团积极") != null);

    // 同一份数据没有任何负向信号。
    try std.testing.expectEqualStrings("", try writeBucketToBuf(&output, player_json, .risks));

    // 颜色/文案与前端定义一致：极高胜率要 16 场 85%，这里只有 4 场。
    try std.testing.expect(std.mem.indexOf(u8, strengths, "极高胜率") == null);
}

test "连胜连败阈值与状态稳定回退" {
    var output: [256]u8 = undefined;
    const short_losses =
        "{\"recentMatches\":[{\"durationMinutes\":20,\"win\":false},{\"durationMinutes\":20,\"win\":false},{\"durationMinutes\":20,\"win\":true}]}";
    {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const player = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), short_losses, .{});
        var writer = std.Io.Writer.fixed(&output);
        try writeStreak(&writer, player);
        try std.testing.expectEqualStrings("状态稳定", writer.buffered());
    }

    const long_losses =
        "{\"recentMatches\":[{\"durationMinutes\":20,\"win\":false},{\"durationMinutes\":20,\"win\":false},{\"durationMinutes\":20,\"win\":false}]}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const player = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), long_losses, .{});
    var writer = std.Io.Writer.fixed(&output);
    try writeStreak(&writer, player);
    try std.testing.expectEqualStrings("3 连败", writer.buffered());
}

test "未结束的对局既不进样本也不打断连胜" {
    var output: [256]u8 = undefined;
    const player_json =
        "{\"recentMatches\":[" ++
        "{\"durationMinutes\":0,\"win\":false,\"deaths\":9,\"damageShare\":0,\"cs\":0}," ++
        "{\"durationMinutes\":25,\"win\":true,\"deaths\":2,\"killParticipation\":0.7,\"damageShare\":0.3,\"cs\":240}," ++
        "{\"durationMinutes\":25,\"win\":true,\"deaths\":2,\"killParticipation\":0.7,\"damageShare\":0.3,\"cs\":240}" ++
        "]}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const player = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), player_json, .{});

    const metrics = analyze(player);
    try std.testing.expectEqual(@as(usize, 2), metrics.sample);
    try std.testing.expectEqual(@as(usize, 2), metrics.winning_streak);
    // 未结束那局的 9 次阵亡不能把场均拉到「阵亡偏多」。
    var writer = std.Io.Writer.fixed(&output);
    _ = try writeBucket(&writer, player, .risks, "、", max_signals);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "阵亡偏多") == null);

    // 全部未结束 → 一条信号都不出。
    const empty_json = "{\"recentMatches\":[{\"durationMinutes\":0,\"win\":true}]}";
    const empty_player = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), empty_json, .{});
    var empty_writer = std.Io.Writer.fixed(&output);
    try std.testing.expectEqual(@as(usize, 0), try writeBucket(&empty_writer, empty_player, .strengths, "、", max_signals));
}

test "好抓判定复用 LeagueAkari 四档阈值" {
    var output: [256]u8 = undefined;
    const cases = [_]struct {
        /// 每场「前期被敌方打野抓死次数」，取平均后再分档。
        early_deaths: [2]i64,
        position: []const u8 = "TOP",
        expected: ?[]const u8,
    }{
        .{ .early_deaths = .{ 3, 2 }, .expected = "非常好抓" }, // 2.5 > 2
        .{ .early_deaths = .{ 2, 1 }, .expected = "好抓" }, // 1.5
        .{ .early_deaths = .{ 1, 1 }, .expected = null }, // 1.0：不标注
        .{ .early_deaths = .{ 0, 1 }, .expected = "难抓" }, // 0.5 < 1
        .{ .early_deaths = .{ 3, 3 }, .position = "JUNGLE", .expected = null },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const json = try std.fmt.allocPrint(
            arena.allocator(),
            "{{\"assignedPosition\":\"{s}\",\"recentMatches\":[" ++
                "{{\"durationMinutes\":20,\"win\":true,\"earlyDeathsWithEnemyJungler\":{d}}}," ++
                "{{\"durationMinutes\":20,\"win\":true,\"earlyDeathsWithEnemyJungler\":{d}}}]}}",
            .{ case.position, case.early_deaths[0], case.early_deaths[1] },
        );
        const player = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{});
        var writer = std.Io.Writer.fixed(&output);
        _ = try writeBucket(&writer, player, .risks, "、", max_signals);
        const risks = writer.buffered();
        if (case.expected) |expected| {
            const negative = std.mem.indexOf(u8, risks, expected) != null;
            if (std.mem.eql(u8, expected, "难抓")) {
                // 难抓是正向信号，不该出现在 risks 里。
                try std.testing.expect(!negative);
                var strength_writer = std.Io.Writer.fixed(&output);
                _ = try writeBucket(&strength_writer, player, .strengths, "、", max_signals);
                try std.testing.expect(std.mem.indexOf(u8, strength_writer.buffered(), "难抓") != null);
            } else {
                try std.testing.expect(negative);
            }
        } else {
            try std.testing.expect(std.mem.indexOf(u8, risks, "好抓") == null);
        }
    }
}

test "英雄池集中阈值以卡片标签为准（0.7，而非旧的 0.5）" {
    var output: [256]u8 = undefined;
    // 2/3 = 0.667 < 0.7 → 不出信号。
    const below = "{\"recentMatches\":[" ++
        "{\"durationMinutes\":20,\"win\":true,\"championId\":1}," ++
        "{\"durationMinutes\":20,\"win\":true,\"championId\":1}," ++
        "{\"durationMinutes\":20,\"win\":true,\"championId\":2}]}";
    try std.testing.expectEqualStrings("", try writeBucketToBuf(&output, below, .risks));

    // 4/5 = 0.8 >= 0.7 → 出信号，且归入 risks。
    const above = "{\"recentMatches\":[" ++
        "{\"durationMinutes\":20,\"win\":true,\"championId\":1}," ++
        "{\"durationMinutes\":20,\"win\":true,\"championId\":1}," ++
        "{\"durationMinutes\":20,\"win\":true,\"championId\":1}," ++
        "{\"durationMinutes\":20,\"win\":true,\"championId\":1}," ++
        "{\"durationMinutes\":20,\"win\":true,\"championId\":2}]}";
    try std.testing.expectEqualStrings("英雄池集中", try writeBucketToBuf(&output, above, .risks));
}

test "缺少 championId 不能凭空凑出英雄池集中" {
    var output: [256]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const no_champion = "{\"recentMatches\":[" ++
        "{\"durationMinutes\":20,\"win\":true}," ++
        "{\"durationMinutes\":20,\"win\":true}," ++
        "{\"durationMinutes\":20,\"win\":true}]}";
    try std.testing.expectEqualStrings("", try writeBucketToBuf(&output, no_champion, .risks));

    const player = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), no_champion, .{});
    const matches = nestedArray(player, "recentMatches") orelse &.{};
    try std.testing.expectEqual(@as(f64, 0), concentrationOf(matches));
}

test "writeFirst 只输出第一条命中信号" {
    var output: [256]u8 = undefined;
    const player_json =
        "{\"recentMatches\":[" ++
        "{\"durationMinutes\":30,\"win\":false,\"deaths\":9,\"killParticipation\":0.2,\"damageShare\":0.1,\"cs\":100}," ++
        "{\"durationMinutes\":30,\"win\":false,\"deaths\":9,\"killParticipation\":0.2,\"damageShare\":0.1,\"cs\":100}," ++
        "{\"durationMinutes\":30,\"win\":false,\"deaths\":9,\"killParticipation\":0.2,\"damageShare\":0.1,\"cs\":100}" ++
        "]}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const player = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), player_json, .{});
    var writer = std.Io.Writer.fixed(&output);
    const count = try writeFirst(&writer, player, "、", max_signals);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings("3 连败", writer.buffered());
}
