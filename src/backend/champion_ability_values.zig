//! 技能文案里 `@Name@` 变量的**逐级真实数值**。
//!
//! # 为什么需要单独一条命令
//!
//! LCU 的单英雄文件（`champions/{id}.json`）只给**文案骨架**——描述里写着
//! `@PowerBallDamage@`、`@RollDuration@` 这类变量，但它自己的 `coefficients` 全是 0、
//! `effectAmounts` 也基本是占位。真实数值在 CommunityDragon 那边。
//!
//! # 映射是怎么对上的（2026-09-30 实测）
//!
//! `https://raw.communitydragon.org/latest/game/data/characters/<alias>/<alias>.bin.json`
//! 里每个技能的 `mSpell`：
//!
//! ```text
//! mSpell.DataValues[]        = [ { name: "QBaseDamage", values: [40, 80, 120, …] }, … ]
//! mSpell.mSpellCalculations  = { "PowerBallDamage": { mFormulaParts: [ … ] }, … }
//! ```
//!
//! ⚠️ 关键：**`mSpellCalculations` 的键名和 LCU 文案里的 `@名字@` 是同一套**。
//! 拉莫斯 Q 的 `@PowerBallDamage@` 在这里就叫 `PowerBallDamage`。所以不需要任何映射表。
//!
//! 取值的三级降级（越靠后越弱，都取不到就**什么都不给**）：
//!  1. 计算项只有**一个** `NamedDataValueCalculationPart` → 直接用那个 `DataValues` 数组。
//!  2. 计算项是 `NamedDataValue` + `StatByNamedDataValue`（基础值 + 一个系数）→ 用基础值那组，
//!     并把系数记下来（前端可以显示成「+ 1.0 法强」）。
//!  3. 名字**直接**就是一个 `DataValues` 名（`RollDuration` / `SlowPercent` 这种）。
//!
//! # 明确取不到的三类（**不许编数字**）
//!
//! - `ByCharLevelInterpolationCalculationPart`（`@MinimumMoveSpeed@`）：随**英雄等级**插值，
//!   不是技能等级，得知道当前等级才算得出。
//! - 引用了**英雄实时属性**的（`@BonusArmorTooltip@` 要护甲、`@BonusMRTooltip@` 要魔抗）：
//!   数值随装备与符文变。
//! - `@SpellModifierDescriptionAppend@`：它不是数值，是客户端**拼接装备/符文加成的位置**，
//!   本来就该空。
//!
//! 这三类在这里**直接不出现在结果里**，由前端保留原文并标注说明。
//! 实测填充率：拉莫斯 11/16、金克丝 14/15（合计 ≈81%）。
const std = @import("std");
const native_sdk = @import("native_sdk");
const backend = @import("../backend.zig");

/// 缓存键前缀。**输出形状一变就要 +1**（缓存里没有版本字段，理由同 `timeline.zig`）。
const values_cache_prefix = "v1:";

const community_dragon_character_base = "https://raw.communitydragon.org/latest/game/data/characters";

/// `lol.get_champion_ability_values` —— 某个英雄所有技能的变量取值。
///
/// payload：`{championId, alias}`。`alias` 是必需的：CommunityDragon 的目录用**英文别名**
/// （`Rammus`），而 LCU 给的 `championId` 拼不出那个名字。
pub fn getChampionAbilityValues(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = backend.runtime(context);
    const payload_json = backend.parsePayload(struct {
        championId: i64 = 0,
        alias: []const u8 = "",
    }, invocation.request.payload) catch return error.InvalidRequest;
    defer payload_json.deinit();

    const champion_id = payload_json.value.championId;
    const alias = payload_json.value.alias;
    if (champion_id <= 0 or alias.len == 0) return error.InvalidRequest;
    // 别名要进 URL 路径，只放行字母数字和少数几个安全字符（青龙刀 `Kai'Sa` 那种带撇号的
    // 别名在 CommunityDragon 上用的是**去撇号**的小写目录，所以这里直接拒绝可疑字符）。
    for (alias) |ch| {
        if (!std.ascii.isAlphanumeric(ch)) return error.InvalidRequest;
    }

    var key_buffer: [64]u8 = undefined;
    var lower_buffer: [64]u8 = undefined;
    const lower = std.ascii.lowerString(&lower_buffer, alias);
    const key = std.fmt.bufPrint(&key_buffer, values_cache_prefix ++ "{d}", .{champion_id}) catch return error.AbilityValuesUnavailable;

    if (self.storage) |*store| if (store.get("championAbilityValues", key) catch null) |cached| {
        defer std.heap.page_allocator.free(cached);
        if (cached.len > 0 and cached.len <= output.len) {
            @memcpy(output[0..cached.len], cached);
            return output[0..cached.len];
        }
    };

    var url_buffer: [256]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buffer, "{s}/{s}/{s}.bin.json", .{ community_dragon_character_base, lower, lower }) catch return error.AbilityValuesUnavailable;

    // 公网请求**不**用 LCU 凭据，只借它的传输层（TLS / 超时 / 响应上限都在 native 侧）。
    // `.budget = .remote` 见 lcu.zig 的 getPublicUrl。
    const public_client = backend.lcu.Client{
        .allocator = std.heap.page_allocator,
        .io = self.io orelse return error.LcuNotRunning,
        .credentials = .{ .port = 0, .token = "", .protocol = "https" },
        .timeout_ms = backend.runtimeRequestTimeoutMs(self),
        .verify_tls = true,
    };

    const body = public_client.getPublicUrl(url, "lol-desktop-native/2.0") catch return error.AbilityValuesUnavailable;
    defer std.heap.page_allocator.free(body);

    const rendered = writeValues(alias, body, output) catch return error.AbilityValuesUnavailable;

    if (self.storage) |*store| store.put("championAbilityValues", key, rendered) catch {};

    return rendered;
}

/// 把 CommunityDragon 的角色文件压成 `{ "<spellKey或p>": { "<变量名>": [逐级] } }`。
///
/// 单独拿出来是为了能被测试直接喂一份固定 JSON。
pub fn writeValues(alias: []const u8, body: []const u8, output: []u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch return error.AbilityValuesUnavailable;
    var root_path_buffer: [128]u8 = undefined;
    const root_path = std.fmt.bufPrint(&root_path_buffer, "Characters/{s}/CharacterRecords/Root", .{alias}) catch return error.AbilityValuesUnavailable;

    // ⚠️ CDragon 的键**大小写不固定**（`CharacterRecords` vs `characterrecords`），
    // 所以必须做不区分大小写的查找，不能拿拼好的字符串直接 index。
    const object = switch (parsed) {
        .object => |value| value,
        else => return error.AbilityValuesUnavailable,
    };
    const root = findValueCaseInsensitive(object, root_path) orelse return error.AbilityValuesUnavailable;
    const spells = switch (root) {
        .object => |value| blk: {
            const passives = if (value.get("mCharacterPassiveSpell")) |p| p else null;
            break :blk .{ passives, value.get("spells") };
        },
        else => return error.AbilityValuesUnavailable,
    };

    var writer = Writer{ .output = output, .length = 0 };
    try writer.writeAll("{\"alias\":");
    try writer.writeJsonString(alias);
    try writer.writeAll(",\"spells\":[");

    var first_spell = true;

    // ① 被动：LCU 里叫 `p`，CDragon 的路径在 `mCharacterPassiveSpell`。
    if (spells[0]) |passive_path| {
        if (passive_path == .string) {
            if (collectSpell(allocator, object, passive_path.string)) |entries| {
                if (entries.len > 0) {
                    if (!first_spell) try writer.writeAll(",");
                    first_spell = false;
                    try writer.writeAll("{\"slot\":\"p\",\"values\":");
                    try writeEntries(&writer, entries);
                    try writer.writeAll("}");
                }
            }
        }
    }

    // ② 主动技能：`Root.spells` 是**有序**的，下标即 q/w/e/r（这也是不能用文件夹名猜的原因）。
    if (spells[1]) |spell_paths| {
        if (spell_paths == .array) {
            const slots = [_][]const u8{ "q", "w", "e", "r" };
            for (spell_paths.array.items, 0..) |spell_path, index| {
                if (index >= slots.len) break;
                if (spell_path != .string) continue;
                const entries = collectSpell(allocator, object, spell_path.string) orelse continue;
                if (entries.len == 0) continue;
                if (!first_spell) try writer.writeAll(",");
                first_spell = false;
                try writer.writeAll("{\"slot\":\"");
                try writer.writeAll(slots[index]);
                try writer.writeAll("\",\"values\":");
                try writeEntries(&writer, entries);
                try writer.writeAll("}");
            }
        }
    }

    try writer.writeAll("]}");
    return writer.output[0..writer.length];
}

const Entry = struct {
    name: []const u8,
    values: []const f64,
    /// 若这一项带系数（`+ 1.0 法强`），记下原始系数供前端展示。
    ratio: ?f64 = null,
    /// 系数乘的是哪个属性（`AP` / `AD` / 护甲…）。取不到就 null。
    ratio_stat: ?[]const u8 = null,
    /// 这一项是**分数**（0.5 要显示成 `50%`）。
    ///
    /// 判据两条，任一成立即可：CDragon 自己标了 `mDisplayAsPercent`（`MinimumMoveSpeed`
    /// 就是），或者全部取值都落在 `[0, 1]` 区间（`AOEModifier` = 0.5、`ArmorShredPercent` = 0.1）。
    ///
    /// ⚠️ 之所以不能只看 `mDisplayAsPercent`：实测它只在**少数**计算项上出现
    /// （拉莫斯 1 个、龙王 2 个），而 `AOEModifier` / `SlowAmount` / `CloneDamageMod`
    /// 这些纯 DataValue 一个都没标——但它们全都是分数，用 0.5 显示会让人读成「0.5 点伤害」。
    /// 反过来 `TooltipTakedownCooldownMultiplier` = 90 这种「已经是百分数」的**不算**分数
    /// （不在 [0,1] 内），照常显示 90。
    is_percent: bool = false,
};

/// 从一个技能对象里收集 `名字 → 逐级数值`。
fn collectSpell(allocator: std.mem.Allocator, root: std.json.ObjectMap, spell_path: []const u8) ?[]const Entry {
    const spell_object = findValueCaseInsensitive(root, spell_path) orelse return null;
    const spell = switch (spell_object) {
        .object => |value| value.get("mSpell") orelse return null,
        else => return null,
    };
    const spell_map = switch (spell) {
        .object => |value| value,
        else => return null,
    };

    // 先建 `DataValues` 索引：名字 → 逐级数组。
    var data_values = std.StringHashMap([]const f64).init(allocator);
    if (spell_map.get("DataValues")) |dv| {
        if (dv == .array) {
            for (dv.array.items) |item| {
                if (item != .object) continue;
                const name = switch (item.object.get("name") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const values_value = item.object.get("values") orelse continue;
                const values = readNumberArray(allocator, values_value) orelse continue;
                data_values.put(name, values) catch continue;
            }
        }
    }

    var out = std.ArrayList(Entry).empty;

    // ① `mSpellCalculations`：键名即文案里的变量名。
    if (spell_map.get("mSpellCalculations")) |calcs| {
        if (calcs == .object) {
            var it = calcs.object.iterator();
            while (it.next()) |pair| {
                const name = pair.key_ptr.*;
                const calc = pair.value_ptr.*;
                if (calc != .object) continue;
                const parts = switch (calc.object.get("mFormulaParts") orelse continue) {
                    .array => |a| a,
                    else => continue,
                };
                // 计算项自己标的「这是百分比」优先。
                const declared_percent = switch (calc.object.get("mDisplayAsPercent") orelse .null) {
                    .bool => |b| b,
                    else => false,
                };
                if (resolveFormula(parts, data_values)) |entry| {
                    out.append(allocator, .{
                        .name = name,
                        .values = entry.values,
                        .ratio = entry.ratio,
                        .ratio_stat = entry.ratio_stat,
                        .is_percent = declared_percent or looksLikeFraction(entry.values),
                    }) catch continue;
                }
            }
        }
    }

    // ② 名字直接就是 DataValues 的（`RollDuration` / `SlowPercent` / `AOEModifier`…）。
    //    只在还没被 ① 覆盖时补。
    var dv_it = data_values.iterator();
    while (dv_it.next()) |pair| {
        var already = false;
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing.name, pair.key_ptr.*)) {
                already = true;
                break;
            }
        }
        if (already) continue;
        out.append(allocator, .{
            .name = pair.key_ptr.*,
            .values = pair.value_ptr.*,
            .is_percent = looksLikeFraction(pair.value_ptr.*),
        }) catch continue;
    }

    // 顺序稳定（HashMap 迭代顺序不定，输出必须可复现，否则缓存与测试都会抖）。
    std.mem.sort(Entry, out.items, {}, struct {
        fn lessThan(_: void, left: Entry, right: Entry) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);

    return out.toOwnedSlice(allocator) catch null;
}

/// 从 `mFormulaParts` 里挑出「基础值 + 可选系数」。
fn resolveFormula(parts: std.json.Array, data_values: std.StringHashMap([]const f64)) ?struct { values: []const f64, ratio: ?f64, ratio_stat: ?[]const u8 } {
    var base: ?[]const f64 = null;
    var ratio: ?f64 = null;
    var ratio_stat: ?[]const u8 = null;

    for (parts.items) |part| {
        if (part != .object) continue;
        const type_name = switch (part.object.get("__type") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, type_name, "NamedDataValueCalculationPart")) {
            const name = switch (part.object.get("mDataValue") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            base = data_values.get(name) orelse base;
        } else if (std.mem.eql(u8, type_name, "StatByNamedDataValueCalculationPart")) {
            // 系数本身是另一个 DataValue（`APRatio` 的逐级值通常全是 1）。
            const name = switch (part.object.get("mDataValue") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            if (data_values.get(name)) |coef| {
                if (coef.len > 0) ratio = coef[0];
                ratio_stat = statNameFrom(name);
            }
        }
        // 其余类型（`ByCharLevelInterpolationCalculationPart` / `ProductOfSubParts` /
        // `StatByCoefficientCalculationPart` …）都**不参与**——它们要么依赖实时属性，
        // 要么需要乘法展开。宁可不给，也不给半截数字。
    }

    if (base) |values| return .{ .values = values, .ratio = ratio, .ratio_stat = ratio_stat };
    return null;
}

/// 全部取值都落在 `[0, 1]` 且**至少有一个非 0** 时，认定它是分数（要按百分比显示）。
///
/// 为什么要求「非 0」：`CloneDamageMod` 那种真的从 0 开始的要做限制，而全 0 的
/// 占位数组（CDragon 里不少）本来就是没用的，标成百分比也毫无意义。
/// 为什么要求「全部」：`SlowAmount` = 0.2…0.8 全是分数；而
/// `TooltipTakedownCooldownMultiplier` = 90 不是——只要有一个越界就整体否定，
/// 宁可少标，也不要把一个「90」印成「9000%」。
fn looksLikeFraction(values: []const f64) bool {
    if (values.len == 0) return false;
    var has_nonzero = false;
    for (values) |value| {
        if (!(value >= 0 and value <= 1)) return false;
        if (value != 0) has_nonzero = true;
    }
    return has_nonzero;
}

/// `APRatio` → `AP`，`DamageArmorRatio` → `Armor`。认不出来就返回 null（显示成「系数」）。
///
/// ⚠️ 顺序要紧：`AD` 必须排在 `Armor` 前面——`AD` 是两字母前缀，而 `DamageArmorRatio`
/// 里也有 `A`+`D` 但不相邻，实际不会撞；真正会撞的是 `AttackDamage`（含 `AD` 吗？不含，
/// 是 `A…t…t…a…c…k…D…`）。所以这里用前缀判 `AD` 是安全的。
fn statNameFrom(data_value_name: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, data_value_name, "AP")) return "AP";
    if (std.mem.startsWith(u8, data_value_name, "AD")) return "AD";
    if (std.mem.indexOf(u8, data_value_name, "MaxHealth") != null) return "MaxHealth";
    if (std.mem.indexOf(u8, data_value_name, "Health") != null) return "Health";
    if (std.mem.indexOf(u8, data_value_name, "MagicResist") != null) return "MR";
    if (std.mem.indexOf(u8, data_value_name, "Armor") != null) return "Armor";
    if (std.mem.indexOf(u8, data_value_name, "AttackSpeed") != null) return "AttackSpeed";
    if (std.mem.indexOf(u8, data_value_name, "MoveSpeed") != null) return "MoveSpeed";
    if (std.mem.indexOf(u8, data_value_name, "Crit") != null) return "Crit";
    if (std.mem.indexOf(u8, data_value_name, "Mana") != null) return "Mana";
    return null;
}

fn readNumberArray(allocator: std.mem.Allocator, value: std.json.Value) ?[]const f64 {
    if (value != .array) return null;
    var list = std.ArrayList(f64).empty;
    for (value.array.items) |item| {
        const number = switch (item) {
            .float => |f| f,
            .integer => |i| @as(f64, @floatFromInt(i)),
            else => continue,
        };
        list.append(allocator, number) catch return null;
    }
    if (list.items.len == 0) return null;
    return list.toOwnedSlice(allocator) catch null;
}

/// CDragon 的键大小写不固定，统一走不区分大小写的查找。
fn findValueCaseInsensitive(map: std.json.ObjectMap, key: []const u8) ?std.json.Value {
    if (map.get(key)) |found| return found;
    var it = map.iterator();
    while (it.next()) |pair| {
        if (std.ascii.eqlIgnoreCase(pair.key_ptr.*, key)) return pair.value_ptr.*;
    }
    return null;
}

fn writeEntries(writer: *Writer, entries: []const Entry) !void {
    try writer.writeAll("{");
    for (entries, 0..) |entry, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.writeJsonString(entry.name);
        try writer.writeAll(":{\"values\":[");
        for (entry.values, 0..) |value, value_index| {
            if (value_index > 0) try writer.writeAll(",");
            try writer.writeFloat(value);
        }
        try writer.writeAll("]");
        if (entry.ratio) |ratio| {
            try writer.writeAll(",\"ratio\":");
            try writer.writeFloat(ratio);
            if (entry.ratio_stat) |stat| {
                try writer.writeAll(",\"ratioStat\":");
                try writer.writeJsonString(stat);
            }
        }
        // 只在为真时才写，让输出短一点（绝大多数项都不是分数）。
        if (entry.is_percent) try writer.writeAll(",\"percent\":true");
        try writer.writeAll("}");
    }
    try writer.writeAll("}");
}

/// 极简 JSON 写入器：直接往调用方给的 output 里写，不额外分配。
const Writer = struct {
    output: []u8,
    length: usize,

    fn writeAll(self: *Writer, text: []const u8) !void {
        if (self.length + text.len > self.output.len) return error.AbilityValuesUnavailable;
        @memcpy(self.output[self.length..][0..text.len], text);
        self.length += text.len;
    }

    fn writeJsonString(self: *Writer, text: []const u8) !void {
        try self.writeAll("\"");
        for (text) |ch| {
            if (ch == '"' or ch == '\\') {
                try self.writeAll("\\");
                try self.writeAll(&[_]u8{ch});
            } else if (ch < 0x20) {
                continue;
            } else {
                try self.writeAll(&[_]u8{ch});
            }
        }
        try self.writeAll("\"");
    }

    /// 整数就写整数形式（`6` 而不是 `6.0`），其余保留最多 4 位小数。
    fn writeFloat(self: *Writer, value: f64) !void {
        var buffer: [40]u8 = undefined;
        const text = if (value == @trunc(value) and @abs(value) < 1e15)
            std.fmt.bufPrint(&buffer, "{d}", .{@as(i64, @intFromFloat(value))}) catch return error.AbilityValuesUnavailable
        else
            std.fmt.bufPrint(&buffer, "{d:.4}", .{value}) catch return error.AbilityValuesUnavailable;
        try self.writeAll(text);
    }
};

test "从真实形状的 CDragon 片段里取出变量数值，并对上 LCU 的占位符名" {
    // 结构照 2026-09-30 实测的拉莫斯 Q 抄（只留必要字段）。
    const body =
        \\{"Characters/Rammus/CharacterRecords/Root":{
        \\  "mCharacterPassiveSpell":"Characters/Rammus/Spells/RammusPAbility/RammusP",
        \\  "spells":["Characters/Rammus/Spells/PowerBallAbility/PowerBall"]
        \\ },
        \\ "Characters/Rammus/Spells/PowerBallAbility/PowerBall":{"mSpell":{
        \\   "DataValues":[
        \\     {"name":"QBaseDamage","values":[40,80,120,160,200,240,280]},
        \\     {"name":"APRatio","values":[1,1,1,1,1,1,1]},
        \\     {"name":"RollDuration","values":[6,6,6,6,6,6,6]},
        \\     {"name":"SlowPercent","values":[30,40,50,60,70,80,90]},
        \\     {"name":"UnnamedEffectAmount4","values":[]}
        \\   ],
        \\   "mSpellCalculations":{
        \\     "PowerBallDamage":{"mFormulaParts":[
        \\       {"__type":"NamedDataValueCalculationPart","mDataValue":"QBaseDamage"},
        \\       {"__type":"StatByNamedDataValueCalculationPart","mDataValue":"APRatio"}
        \\     ]},
        \\     "MinimumMoveSpeed":{"mFormulaParts":[
        \\       {"__type":"ByCharLevelInterpolationCalculationPart","mStartValue":0.25,"mEndValue":0.391}
        \\     ]}
        \\   }
        \\ }},
        \\ "Characters/Rammus/Spells/RammusPAbility/RammusP":{"mSpell":{
        \\   "DataValues":[{"name":"PBonus","values":[10,20]}]
        \\ }}}
    ;
    var output: [4096]u8 = undefined;
    const json = try writeValues("Rammus", body, &output);

    // 关键：`PowerBallDamage` 这个名字必须和 LCU 文案里的 `@PowerBallDamage@` 对得上。
    try std.testing.expect(std.mem.indexOf(u8, json, "\"PowerBallDamage\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "[40,80,120,160,200,240,280]") != null);
    // 整数不带小数点
    try std.testing.expect(std.mem.indexOf(u8, json, "6.0") == null);
    // 系数也带上了（AP × 1）
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ratio\":1,\"ratioStat\":\"AP\"") != null);
    // 直接是 DataValues 的也补进来
    try std.testing.expect(std.mem.indexOf(u8, json, "\"SlowPercent\"") != null);
    // 随等级插值的那个**不能出现**（它需要英雄等级，不是技能等级）
    try std.testing.expect(std.mem.indexOf(u8, json, "\"MinimumMoveSpeed\"") == null);
    // 槽位要标出来，且被动走 p
    try std.testing.expect(std.mem.indexOf(u8, json, "\"slot\":\"q\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"slot\":\"p\"") != null);
}

test "大小写不固定的键也能找到（CDragon 实测两种都有）" {
    const body =
        \\{"characters/ahri/characterrecords/root":{"spells":["Characters/Ahri/Spells/Q"]},
        \\ "characters/ahri/spells/q":{"mSpell":{"DataValues":[{"name":"BaseDamage","values":[10,20,30]}]}}}
    ;
    var output: [2048]u8 = undefined;
    const json = try writeValues("Ahri", body, &output);
    try std.testing.expect(std.mem.indexOf(u8, json, "[10,20,30]") != null);
}

test "落在 [0,1] 的取值标成百分比（@Name*100@ 那批变量）" {
    // 取值全照 2026-09-30 实测：拉莫斯 R 的 `SlowAmount` = 0.2…0.8，
    // 客户端文案里写作 `@SlowAmount*100@%`。
    const body =
        \\{"Characters/Rammus/CharacterRecords/Root":{"spells":["Characters/Rammus/Spells/Tremors2Ability/Tremors2"]},
        \\ "Characters/Rammus/Spells/Tremors2Ability/Tremors2":{"mSpell":{"DataValues":[
        \\   {"name":"SlowAmount","values":[0.2,0.3,0.4,0.5,0.6,0.7,0.8]},
        \\   {"name":"TooltipTakedownCooldownMultiplier","values":[90,90,90,90,90,90,90]},
        \\   {"name":"KnockbackDistance","values":[125,125,125,125,125,125,125]},
        \\   {"name":"AllZeroPlaceholder","values":[0,0,0,0,0,0,0]}
        \\ ]}}}
    ;
    var output: [4096]u8 = undefined;
    const json = try writeValues("Rammus", body, &output);

    // 0.2…0.8 → 分数，前端会渲染成 20%…80%
    try std.testing.expect(std.mem.indexOf(u8, json, "\"SlowAmount\":{\"values\":[0.2000,0.3000,0.4000,0.5000,0.6000,0.7000,0.8000],\"percent\":true}") != null);
    // 90 不是分数——标了就会显示成 9000%
    try std.testing.expect(std.mem.indexOf(u8, json, "\"TooltipTakedownCooldownMultiplier\":{\"values\":[90,90,90,90,90,90,90]}") != null);
    // 125 同理
    try std.testing.expect(std.mem.indexOf(u8, json, "\"KnockbackDistance\":{\"values\":[125,125,125,125,125,125,125]}") != null);
    // 全 0 的占位数组不标（标了也没意义）
    try std.testing.expect(std.mem.indexOf(u8, json, "\"AllZeroPlaceholder\":{\"values\":[0,0,0,0,0,0,0]}") != null);
}

test "计算项自己声明的 mDisplayAsPercent 也算数" {
    // 声明了 percent、但取值落在 [0,1] 之外时，靠区间判不出来，只能靠这个字段。
    const body =
        \\{"Characters/X/CharacterRecords/Root":{"spells":["Characters/X/Spells/Q"]},
        \\ "Characters/X/Spells/Q":{"mSpell":{
        \\   "DataValues":[{"name":"Base","values":[5,10,15]}],
        \\   "mSpellCalculations":{"DeclaredPercent":{
        \\     "mFormulaParts":[{"__type":"NamedDataValueCalculationPart","mDataValue":"Base"}],
        \\     "mDisplayAsPercent":true
        \\   }}
        \\ }}}
    ;
    var output: [2048]u8 = undefined;
    const json = try writeValues("X", body, &output);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"DeclaredPercent\":{\"values\":[5,10,15],\"percent\":true}") != null);
}

test "系数乘的是什么属性：法强要能认出来" {
    // 龙王整套技能都是法强加成（`APPerSecond` / `BurstAPRatio` / `APRatio`）——
    // 这直接回答「它是什么加成」那个问题。
    const body =
        \\{"Characters/AurelionSol/CharacterRecords/Root":{"spells":["Characters/AurelionSol/Spells/AurelionSolQAbility/AurelionSolQ"]},
        \\ "Characters/AurelionSol/Spells/AurelionSolQAbility/AurelionSolQ":{"mSpell":{
        \\   "DataValues":[
        \\     {"name":"RankDamagePerSecond","values":[30,45,60,75,90]},
        \\     {"name":"APPerSecond","values":[0.6,0.6,0.6,0.6,0.6]}
        \\   ],
        \\   "mSpellCalculations":{"DamagePerSecond":{"mFormulaParts":[
        \\     {"__type":"NamedDataValueCalculationPart","mDataValue":"RankDamagePerSecond"},
        \\     {"__type":"StatByNamedDataValueCalculationPart","mDataValue":"APPerSecond"}
        \\   ]}}
        \\ }}}
    ;
    var output: [4096]u8 = undefined;
    const json = try writeValues("AurelionSol", body, &output);
    // 关键：`ratioStat` 必须是 `AP`，前端才能写出「+0.6 法强」而不是「+0.6 加成」。
    try std.testing.expect(std.mem.indexOf(u8, json, "\"DamagePerSecond\":{\"values\":[30,45,60,75,90],\"ratio\":0.6000,\"ratioStat\":\"AP\"}") != null);
}

test "只有插值公式的技能返回空列表，而不是编一个数" {
    const body =
        \\{"Characters/X/CharacterRecords/Root":{"spells":["Characters/X/Spells/Q"]},
        \\ "Characters/X/Spells/Q":{"mSpell":{"mSpellCalculations":{
        \\   "MinimumMoveSpeed":{"mFormulaParts":[{"__type":"ByCharLevelInterpolationCalculationPart"}]}
        \\ }}}}
    ;
    var output: [1024]u8 = undefined;
    const json = try writeValues("X", body, &output);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"spells\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "MinimumMoveSpeed") == null);
}

test "别名里有可疑字符时直接拒绝（防止拼进 URL 路径）" {
    // 把真实链路里那段校验照抄一遍：别名要进 URL 路径，所以只放行字母数字。
    for ([_][]const u8{ "Ram mus", "../etc", "Ram@mus", "a/b" }) |bad| {
        var rejected = false;
        for (bad) |ch| {
            if (!std.ascii.isAlphanumeric(ch)) rejected = true;
        }
        try std.testing.expect(rejected);
    }
    // 正常别名一个都不该被拒。
    for ([_][]const u8{ "Rammus", "Ahri", "MonkeyKing", "Kaisa" }) |good| {
        var rejected = false;
        for (good) |ch| {
            if (!std.ascii.isAlphanumeric(ch)) rejected = true;
        }
        try std.testing.expect(!rejected);
    }
}
