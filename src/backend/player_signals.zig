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
//! | `极高胜率` | `definitions/basic.ts` `HIGH_WIN_RATE_TAG` |
//! | `N 连胜` / `N 连败` | 同上 `WINNING_STREAK_TAG` / `LOSING_STREAK_TAG` |
//! | `好抓` / `非常好抓` / `难抓` | 同上 `EASY_GANK_TAG` |
//! | `击杀伤害转化高` / `击杀伤害转化低` | 同上 `AVERAGE_KILL_DAMAGE_EFFICIENCY_TAG` |
//! | `闪现位置可疑` | `definitions/suspicious-flash-position.ts` |
//! | `N 单杀` | `definitions/basic.ts` `SOLO_KILLS_TAG` |
//!
//! 只保留 LeagueAkari 有的那几档。本项目自创的「阵亡偏多 / 参团偏低 / 英雄池集中」
//! 以及「伤害占比 / 分均补刀」两条陈述已随标签系统一并删除 —— 它们只报数值、
//! 不做判断的同类留在了卡片标签里，不再进 `{tag}` / `{risk}` 快捷消息。
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

// ── 阈值：与前端 `definitions/basic.ts` 逐条对齐 ──
const streak_threshold: usize = 3;
const high_win_rate_min_sample: usize = 16;
const high_win_rate_threshold: f64 = 0.85;
/// 单杀判定的精确数据样本下限（前端 `SOLO_KILL_MIN_SAMPLE`）。
const solo_kill_min_sample: usize = 3;
/// 好抓判定：`> 2` 非常好抓、`>= 1.5` 好抓、`[1, 1.5)` 不标注、`< 1` 难抓。
const gank_very_easy_threshold: f64 = 2;
const gank_easy_threshold: f64 = 1.5;
/// 击杀伤害转化分档：`> 1.35` 高、`< 0.65` 低（前端 `KILL_DAMAGE_EFFICIENCY_*`）。
const kill_damage_high_threshold: f64 = 1.35;
const kill_damage_low_threshold: f64 = 0.65;
/// 闪现（Flash）的法术 id。与前端 `facts.ts` 的 `FLASH_SPELL_ID` 一致。
const flash_spell_id: i64 = 4;

/// 汇总后的指标。
pub const Metrics = struct {
    sample: usize = 0,
    wins: usize = 0,
    /// 逐局「击杀伤害转化」之和：`kills / teamKills / damageShare`，退化局记 1。
    kill_damage_efficiency_total: f64 = 0,
    solo_count: usize = 0,
    solo_total: f64 = 0,
    gank_count: usize = 0,
    gank_total: f64 = 0,
    winning_streak: usize = 0,
    losing_streak: usize = 0,
    /// 闪现放在 D / F 位的对局数。
    flash_on_d: usize = 0,
    flash_on_f: usize = 0,
    is_jungler: bool = false,

    pub fn winRate(self: Metrics) f64 {
        if (self.sample == 0) return 0;
        return @as(f64, @floatFromInt(self.wins)) / @as(f64, @floatFromInt(self.sample));
    }

    /// 空样本按 1（对齐前端 `avgOrOne`，也只用于击杀伤害转化）。
    pub fn averageKillDamageEfficiency(self: Metrics) f64 {
        if (self.sample == 0) return 1;
        return self.kill_damage_efficiency_total / @as(f64, @floatFromInt(self.sample));
    }

    pub fn averageSoloKills(self: Metrics) ?f64 {
        if (self.solo_count == 0) return null;
        return self.solo_total / @as(f64, @floatFromInt(self.solo_count));
    }

    pub fn averageEarlyDeathsWithJungler(self: Metrics) ?f64 {
        if (self.gank_count == 0) return null;
        return self.gank_total / @as(f64, @floatFromInt(self.gank_count));
    }

    /// 一会儿放 D 一会儿放 F：在「是不是本人」这件事上比战绩更有信息量。
    pub fn suspiciousFlashPosition(self: Metrics) bool {
        return self.flash_on_d > 0 and self.flash_on_f > 0;
    }
};

/// 只统计已结束的对局（`durationMinutes > 0`），与前端 `facts.ts` 的 `finished` 一致。
pub fn analyze(player: std.json.Value) Metrics {
    var metrics = Metrics{ .is_jungler = isJungler(player) };
    const recent = nestedArray(player, "recentMatches") orelse return metrics;

    // 连胜/连败：未结束的对局按前端口径「先过滤、再从头扫描」，即跳过而非打断。
    metrics.winning_streak = leadingStreak(recent, true);
    metrics.losing_streak = leadingStreak(recent, false);

    for (recent) |match| {
        if (match != .object) continue;
        const minutes = jsonInt(match, "durationMinutes");
        if (minutes <= 0) continue;
        metrics.sample += 1;
        if (jsonBool(match, "win")) metrics.wins += 1;

        // AK: `kills / teamTotalKills / (damage / teamTotalDamage)`；退化局记 1。
        // 缺 `teamKills`（老缓存）时同样记 1，结果落在「正常」档、不出信号。
        const kills = jsonInt(match, "kills");
        const team_kills = jsonInt(match, "teamKills");
        const damage_share = jsonFloat(match, "damageShare");
        metrics.kill_damage_efficiency_total += if (team_kills == 0 or damage_share <= 0)
            1
        else
            @as(f64, @floatFromInt(kills)) / @as(f64, @floatFromInt(team_kills)) / damage_share;

        if (jsonOptionalFloat(match, "soloKills")) |value| {
            metrics.solo_count += 1;
            metrics.solo_total += value;
        }
        if (jsonOptionalFloat(match, "earlyDeathsWithEnemyJungler")) |value| {
            metrics.gank_count += 1;
            metrics.gank_total += value;
        }

        // `summonerSpells` 按 [spell1Id, spell2Id] 输出，即索引 0 = D、索引 1 = F。
        if (nestedArray(match, "summonerSpells")) |spells| {
            if (spells.len > 0 and jsonInt(spells[0], "id") == flash_spell_id) metrics.flash_on_d += 1;
            if (spells.len > 1 and jsonInt(spells[1], "id") == flash_spell_id) metrics.flash_on_f += 1;
        }
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

/// 遍历全部信号。顺序对齐 `frontend/src/tags/signals.ts` 的 `playerSignals`。
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
    const kill_damage = metrics.averageKillDamageEfficiency();
    if (kill_damage > kill_damage_high_threshold) {
        try emitter.emit(.positive, "击杀伤害转化高", .{});
    } else if (kill_damage < kill_damage_low_threshold) {
        try emitter.emit(.negative, "击杀伤害转化低", .{});
    }
    if (metrics.suspiciousFlashPosition()) {
        try emitter.emit(.negative, "闪现位置可疑", .{});
    }
    if (metrics.solo_count >= solo_kill_min_sample) {
        if (metrics.averageSoloKills()) |average| {
            if (average > 0) try emitter.emit(.neutral, "{d:.1} 单杀", .{average});
        }
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

test "strengths 与 risks 只按 AK 的信号分档" {
    var output: [512]u8 = undefined;
    // 4 连胜 + 高击杀伤害转化（8 / 10 / 0.4 = 2.0 > 1.35）。
    const player_json =
        "{\"assignedPosition\":\"MIDDLE\",\"recentMatches\":[" ++
        "{\"durationMinutes\":30,\"win\":true,\"kills\":8,\"teamKills\":10,\"damageShare\":0.4}," ++
        "{\"durationMinutes\":30,\"win\":true,\"kills\":8,\"teamKills\":10,\"damageShare\":0.4}," ++
        "{\"durationMinutes\":30,\"win\":true,\"kills\":8,\"teamKills\":10,\"damageShare\":0.4}," ++
        "{\"durationMinutes\":30,\"win\":true,\"kills\":8,\"teamKills\":10,\"damageShare\":0.4}," ++
        "{\"durationMinutes\":30,\"win\":false,\"kills\":8,\"teamKills\":10,\"damageShare\":0.4}" ++
        "]}";

    const strengths = try writeBucketToBuf(&output, player_json, .strengths);
    try std.testing.expect(std.mem.indexOf(u8, strengths, "4 连胜") != null);
    try std.testing.expect(std.mem.indexOf(u8, strengths, "击杀伤害转化高") != null);

    // 已随标签系统删除的主观信号不再出现。
    try std.testing.expect(std.mem.indexOf(u8, strengths, "生存稳健") == null);
    try std.testing.expect(std.mem.indexOf(u8, strengths, "参团积极") == null);
    try std.testing.expect(std.mem.indexOf(u8, strengths, "伤害 30%") == null);
    try std.testing.expect(std.mem.indexOf(u8, strengths, "分均补刀") == null);

    // 同一份数据没有任何负向信号。
    try std.testing.expectEqualStrings("", try writeBucketToBuf(&output, player_json, .risks));

    // 颜色/文案与前端定义一致：极高胜率要 16 场 85%，这里只有 5 场。
    try std.testing.expect(std.mem.indexOf(u8, strengths, "极高胜率") == null);
}

test "闪现位置可疑与击杀伤害转化低进 risks" {
    var output: [256]u8 = undefined;
    // 1 / 20 / 0.45 = 0.111 < 0.65；第一局闪现在 D、第二局在 F。
    const player_json =
        "{\"recentMatches\":[" ++
        "{\"durationMinutes\":25,\"win\":true,\"kills\":1,\"teamKills\":20,\"damageShare\":0.45,\"summonerSpells\":[{\"id\":4},{\"id\":12}]}," ++
        "{\"durationMinutes\":25,\"win\":true,\"kills\":1,\"teamKills\":20,\"damageShare\":0.45,\"summonerSpells\":[{\"id\":12},{\"id\":4}]}" ++
        "]}";
    const risks = try writeBucketToBuf(&output, player_json, .risks);
    try std.testing.expect(std.mem.indexOf(u8, risks, "击杀伤害转化低") != null);
    try std.testing.expect(std.mem.indexOf(u8, risks, "闪现位置可疑") != null);
}

test "击杀伤害转化按 > 1.35 / < 0.65 分档" {
    var output: [256]u8 = undefined;
    // 每局 kills=1、teamKills=2、damageShare=0.5 → 1/2/0.5 = 1.0（正常，不出信号）。
    const normal =
        "{\"recentMatches\":[" ++
        "{\"durationMinutes\":20,\"win\":true,\"kills\":1,\"teamKills\":2,\"damageShare\":0.5}," ++
        "{\"durationMinutes\":20,\"win\":true,\"kills\":1,\"teamKills\":2,\"damageShare\":0.5}]}";
    try std.testing.expect(std.mem.indexOf(u8, try writeBucketToBuf(&output, normal, .strengths), "击杀伤害转化") == null);
    try std.testing.expect(std.mem.indexOf(u8, try writeBucketToBuf(&output, normal, .risks), "击杀伤害转化") == null);

    // 1/1/0.5 = 2.0（> 1.35，高）。
    const high =
        "{\"recentMatches\":[" ++
        "{\"durationMinutes\":20,\"win\":true,\"kills\":1,\"teamKills\":1,\"damageShare\":0.5}," ++
        "{\"durationMinutes\":20,\"win\":true,\"kills\":1,\"teamKills\":1,\"damageShare\":0.5}]}";
    try std.testing.expect(std.mem.indexOf(u8, try writeBucketToBuf(&output, high, .strengths), "击杀伤害转化高") != null);

    // 1/8/0.5 = 0.25（< 0.65，低）。
    const low =
        "{\"recentMatches\":[" ++
        "{\"durationMinutes\":20,\"win\":true,\"kills\":1,\"teamKills\":8,\"damageShare\":0.5}," ++
        "{\"durationMinutes\":20,\"win\":true,\"kills\":1,\"teamKills\":8,\"damageShare\":0.5}]}";
    try std.testing.expect(std.mem.indexOf(u8, try writeBucketToBuf(&output, low, .risks), "击杀伤害转化低") != null);

    // 缺 `teamKills`（老缓存）时该局记 1 → 结果落在正常档，不误报。
    const legacy =
        "{\"recentMatches\":[" ++
        "{\"durationMinutes\":20,\"win\":true,\"kills\":30,\"damageShare\":0.9}," ++
        "{\"durationMinutes\":20,\"win\":true,\"kills\":30,\"damageShare\":0.9}]}";
    try std.testing.expect(std.mem.indexOf(u8, try writeBucketToBuf(&output, legacy, .strengths), "击杀伤害转化") == null);
    try std.testing.expect(std.mem.indexOf(u8, try writeBucketToBuf(&output, legacy, .risks), "击杀伤害转化") == null);
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
        // 未结束：99 杀 / 100 击杀 / 1% 伤害占比（若被计入会把场均转化拉到 33+），
        // 并且两个召唤师技能位都带闪现（若被计入会伪造出「闪现位置可疑」）。
        "{\"durationMinutes\":0,\"win\":false,\"kills\":99,\"teamKills\":100,\"damageShare\":0.01,\"summonerSpells\":[{\"id\":4},{\"id\":4}]}," ++
        "{\"durationMinutes\":25,\"win\":true,\"kills\":4,\"teamKills\":10,\"damageShare\":0.4}," ++
        "{\"durationMinutes\":25,\"win\":true,\"kills\":4,\"teamKills\":10,\"damageShare\":0.4}" ++
        "]}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const player = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), player_json, .{});

    const metrics = analyze(player);
    try std.testing.expectEqual(@as(usize, 2), metrics.sample);
    try std.testing.expectEqual(@as(usize, 2), metrics.winning_streak);
    try std.testing.expectEqual(@as(usize, 0), metrics.flash_on_d);
    try std.testing.expectEqual(@as(usize, 0), metrics.flash_on_f);
    // 已结束的两局转化都是 4/10/0.4 = 1.0，落在正常档。
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), metrics.averageKillDamageEfficiency(), 0.0001);

    var writer = std.Io.Writer.fixed(&output);
    _ = try writeBucket(&writer, player, .risks, "、", max_signals);
    try std.testing.expectEqualStrings("", writer.buffered());

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

test "concentrationOf 以最大英雄占比为准，缺 championId 时为 0" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const two_of_three = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        "[{\"durationMinutes\":20,\"championId\":1},{\"durationMinutes\":20,\"championId\":1},{\"durationMinutes\":20,\"championId\":2}]", .{});
    try std.testing.expectApproxEqAbs(@as(f64, 2.0 / 3.0), concentrationOf(two_of_three.array.items), 0.0001);

    const four_of_five = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        "[{\"durationMinutes\":20,\"championId\":1},{\"durationMinutes\":20,\"championId\":1},{\"durationMinutes\":20,\"championId\":1},{\"durationMinutes\":20,\"championId\":1},{\"durationMinutes\":20,\"championId\":2}]", .{});
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), concentrationOf(four_of_five.array.items), 0.0001);

    // 全部缺 championId → 0，而不是「100% 集中」。
    const no_champion = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        "[{\"durationMinutes\":20},{\"durationMinutes\":20},{\"durationMinutes\":20}]", .{});
    try std.testing.expectEqual(@as(f64, 0), concentrationOf(no_champion.array.items));
}

test "writeFirst 只输出第一条命中信号" {
    var output: [256]u8 = undefined;
    const player_json =
        "{\"recentMatches\":[" ++
        "{\"durationMinutes\":30,\"win\":false}," ++
        "{\"durationMinutes\":30,\"win\":false}," ++
        "{\"durationMinutes\":30,\"win\":false}" ++
        "]}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const player = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), player_json, .{});
    var writer = std.Io.Writer.fixed(&output);
    const count = try writeFirst(&writer, player, "、", max_signals);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings("3 连败", writer.buffered());
}
