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
//!  4. 计算项只有一段 `BuffCounterByNamedDataValueCalculationPart` → 它印的**不是**被
//!     消费的那个数值，而是同类里「像层数的那一项」（见 `buffCounterSource`）。
//!     龙王 `@BurstBonusTrueDamageToChamps@` 客户端印 `2 / 2 / … / 2` 就是这么来的。
//!
//! # 「它是什么加成」
//!
//! 文案里 `@BurstBonusTrueDamageToChamps@` 只有一个**变量名**，读者没法知道它乘的是
//! 法强还是最大生命值。这里给出答案，两条路：
//!
//!  - 公式里带 `StatByNamedDataValueCalculationPart` →  `ratio` / `ratios` + `ratioStat`
//!    （`@DamagePerSecond@` = `30/45/… + 0.55 法强`）。属性优先取官方枚举 `mStat`。
//!  - 公式里**没有**显式系数（`QMaxHealthTrueDamagePerStack` 那种）→ 就一条 `ratioStat`，
//!    说明「这一项是按最大生命值算的」。前端显示成「最大生命值加成」。
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
/// v2：2026-09-30 加 `ratios[]` 与「没有 ratio 的 `ratioStat`」，并把 `BuffCounter` 项
/// 的取值改成层数——旧缓存里的 `BurstBonusTrueDamageToChamps` 还是那个 0.031%。
/// v3：2026-09-30 加**跨技能引用**（`@spell.StringSpell:Var@`，22 个英雄）——每个槽位
/// 现在会多出名字带 `spell.X:Y` 前缀的条目。
/// v4：2026-10-03 **去掉首位负数哨兵**（瑟庄妮 W 的 `BaseDamageOne = [-5, 5, 15, …]`
///     不再显示成「-5 / 5 / 15」），并且**时长类变量名不再被当成百分数**
///     （`SlowDuration = 0.5` 是 0.5 **秒**，不是 50%）。旧缓存里两处都是错的。
/// v5：2026-10-03 **补上字面系数型的加成**（`StatByCoefficientCalculationPart` /
///     `AbilityResourceByCoefficientCalculationPart`），并支持**一项多个加成**
///     （艾瑞莉娅 W = 40% 攻击力 + 50% 法术强度，瑞兹 Q = 55% 法术强度 + 2% 最大法力值）。
///     旧缓存里这些「+55% 法术强度」整行都是缺的——用户报的「伤害加成怎么全没了」。
/// v6：2026-10-03 **补上乘积段**（`ProductOfSubPartsCalculationPart` 及其
///     `SumOfSubParts` / `Number` 子段）。拉莫斯 W 的 `BonusArmorTooltip` /
///     `BonusMRTooltip` 以前整项算不出来 → 从结果里消失 → 文案里
///     `@BonusArmorTooltip@` 一直以字面量出现（用户报的「有些地方还是不行」）。
///     新形状会多出这两个变量，并且它们的 `ratios` 是**逐级**的（22.5% → 67.5%）。
const values_cache_prefix = "v6:";

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

    // 技能短名 → CDragon 路径。`@spell.SmolderP:Passive_QDamageIncrease@` 里的
    // `SmolderP` 就是**路径最后一段**，靠这张索引才能跨技能取值。
    // 被动也进索引（斯莫德的三个 Q/W/E 加成都在被动里）。
    var spell_index = std.StringHashMap([]const u8).init(allocator);
    var passive_path_string: ?[]const u8 = null;
    if (spells[0]) |passive_path| {
        if (passive_path == .string) {
            passive_path_string = passive_path.string;
            if (spellShortName(passive_path.string)) |short| {
                spell_index.put(short, passive_path.string) catch {};
            }
        }
    }
    if (spells[1]) |spell_paths| {
        if (spell_paths == .array) {
            for (spell_paths.array.items) |spell_path| {
                if (spell_path != .string) continue;
                if (spellShortName(spell_path.string)) |short| {
                    spell_index.put(short, spell_path.string) catch {};
                }
            }
        }
    }

    // ① 被动：LCU 里叫 `p`，CDragon 的路径在 `mCharacterPassiveSpell`。
    if (passive_path_string) |path| {
        if (collectSpell(allocator, object, path, &spell_index)) |entries| {
            if (entries.len > 0) {
                if (!first_spell) try writer.writeAll(",");
                first_spell = false;
                try writer.writeAll("{\"slot\":\"p\",\"values\":");
                try writeEntries(&writer, entries);
                try writer.writeAll("}");
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
                const entries = collectSpell(allocator, object, spell_path.string, &spell_index) orelse continue;
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

/// 从 CDragon 的技能路径里取**最后一段**当短名。
///
/// `Characters/Smolder/Spells/SmolderPAbility/SmolderP` → `SmolderP`。
/// LCU 文案里的 `@spell.SmolderP:Passive_QDamageIncrease@` 用的就是这个短名
/// （以及 `@spell.PowerBall:PowerBallDamage@` 里的 `PowerBall`）。
fn spellShortName(path: []const u8) ?[]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    const name = path[slash + 1 ..];
    return if (name.len == 0) null else name;
}

/// 一项「系数 × 某个属性」。
///
/// # 为什么是一条**列表**而不是一个数
///
/// 一个计算项可以有**多段**加成，客户端文案也确实是几段分开写的：
///
/// ```text
/// 艾瑞莉娅 W  MinDamageCalc = 基础值 + {mStat:2, 0.4} 攻击力 + {0.5} 法术强度
/// 瑞兹     Q  QDamageCalc   = 基础值 + {0.55} 法术强度 + {0.02, mStatFormula:2} 最大法力值
/// ```
///
/// 以前只留「最后一段」（`ratio` 单值），于是艾瑞莉娅只剩法强、瑞兹只剩法强，
/// 攻击力与法力值两段**直接看不到**（用户 2026-10-03 报的「加成怎么全没了」）。
const RatioItem = struct {
    /// 系数。**可以为 null**：龙王 Q 的 `BurstBonusTrueDamageToChamps` 只有
    /// 「按最大生命值算」这个事实、没有显式系数（公式里只有消耗层数的那一段）。
    ratio: ?f64 = null,
    /// 系数的**逐级值**（与 `values` 同长）。只有确实逐级不同时才填。
    ratios: ?[]const f64 = null,
    /// 乘的属性（`AP` / `AD` / `Armor` / `MR` / `MaxHealth` / `MaxMana`…）。认不出就 null。
    stat: ?[]const u8 = null,
};

/// 造一条「只有属性、没有系数」的加成项。
fn statOnlyRatioItems(allocator: std.mem.Allocator, stat: ?[]const u8) []const RatioItem {
    const value = stat orelse return &.{};
    const slice = allocator.alloc(RatioItem, 1) catch return &.{};
    slice[0] = .{ .stat = value };
    return slice;
}

const Entry = struct {
    name: []const u8,
    values: []const f64,
    /// 这一项带的加成（系数乘哪个属性）。空表示「就是一组裸数值」。
    ///
    /// ⚠️ 系数**本身就逐级不同**时不能只留第 0 格：实测金克丝 W 的
    /// `TotalDamage = 10/45/80/… + 1.6 AD`，亚索 Q 的 AD 系数也随等级变。
    /// 只写第 0 格会让「升到 5 级」的加成看上去和 1 级一样。
    ratio_items: []const RatioItem = &.{},
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
///
/// `spell_index` 是「技能短名 → CDragon 路径」的索引，用来跟进**跨技能引用**
/// （`@spell.SmolderP:Passive_QDamageIncrease@`：斯莫德 Q 的加成其实写在被动里）。
/// 传 null 就只在本技能内找（老行为，测试用）。
fn collectSpell(allocator: std.mem.Allocator, root: std.json.ObjectMap, spell_path: []const u8, spell_index: ?*const std.StringHashMap([]const u8)) ?[]const Entry {
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

    // 「这个变量是什么加成」按**消费的数据值**推：`@BurstBonusTrueDamageToChamps@`
    // 自己叫不出属性，但它吃的是 `QMaxHealthTrueDamagePerStack` → 最大生命值。
    // 只能从计算项的公式里看出来，所以先建 名字 → 加成属性 的反查表。
    var data_stats = std.StringHashMap([]const u8).init(allocator);
    if (spell_map.get("mSpellCalculations")) |calcs| {
        if (calcs == .object) {
            var stat_it = calcs.object.iterator();
            while (stat_it.next()) |pair| {
                const calc = pair.value_ptr.*;
                if (calc != .object) continue;
                const parts = switch (calc.object.get("mFormulaParts") orelse continue) {
                    .array => |a| a,
                    else => continue,
                };
                for (parts.items) |part| {
                    const stat = statFromFormulaPart(part) orelse continue;
                    if (stat.source.len == 0) continue;
                    data_stats.put(stat.source, stat.name) catch continue;
                }
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
                if (resolveFormula(allocator, parts, data_values)) |entry| {
                    out.append(allocator, .{
                        .name = name,
                        .values = entry.values,
                        .ratio_items = entry.ratio_items,
                        // ⚠️ `declared_percent` 要**跟着值一起传下去**：`values` 可能
                        // 来自消费的数据值（见下），那时 `looksLikeFraction` 判不出来，
                        // 只有这个字段能说清「它按百分数读」。
                        .is_percent = declared_percent or looksLikeFraction(name, entry.values),
                    }) catch continue;
                }
                // ③ 公式里只有「消耗层数的数据值」（`BuffCounterByNamedDataValueCalculationPart`）。
                //    这种项的输出**不是**那个数据值本身，而是层数——实测龙王
                //    `@BurstBonusTrueDamageToChamps@` 客户端印的是 `@QMassStolen@` 的值
                //    （2/2/…/2），而不是 `QMaxHealthTrueDamagePerStack`（0.031%）。
                //    认不出来就跳过，**绝不拿那个数据值凑数**。
                if (buffCounterSource(parts, data_values)) |source_name| {
                    out.append(allocator, .{
                        .name = name,
                        .values = source_name.values,
                        .ratio_items = statOnlyRatioItems(allocator, data_stats.get(source_name.expr) orelse data_stats.get(source_name.name)),
                        // 层数是整数（星尘是一颗一颗攒的），原样读。
                        .is_percent = false,
                    }) catch continue;
                }
            }
        }
    }

    // ①b **跨技能引用**：`@spell.<短名>:<变量>@` 指向另一个技能（通常是被动）
    //     里的计算项。斯莫德 Q/W/E 的 `Passive_QDamageIncrease` / `EBonusDamage`
    //     全写在被动 `SmolderP` 里；拉莫斯 R 的 `@spell.PowerBall:PowerBallDamage@`
    //     指向 Q。2026-09-30 全英雄扫描：**22 个英雄**有这种写法。
    //
    //     做法：把被指向的那个技能**整体**再收一遍，但凡名字带 `:` 的引用
    //     （`spell.SmolderP:Passive_QDamageIncrease`）就把它落成条目，
    //     名字**保留完整调用形式**——因为前端拿的是原文里那个完整名字。
    if (spell_index) |index| {
        var ref_it = index.iterator();
        while (ref_it.next()) |pair| {
            const short = pair.key_ptr.*;
            const target_path = pair.value_ptr.*;
            if (std.mem.eql(u8, target_path, spell_path)) continue; // 自己不用再收一遍
            const referenced = collectSpell(allocator, root, target_path, null) orelse continue;
            for (referenced) |entry| {
                var name_buffer: [256]u8 = undefined;
                const qualified = std.fmt.bufPrint(&name_buffer, "spell.{s}:{s}", .{ short, entry.name }) catch continue;
                // 已经收过就别重复（同名可能出现两次）。
                var already = false;
                for (out.items) |existing| {
                    if (std.mem.eql(u8, existing.name, qualified)) {
                        already = true;
                        break;
                    }
                }
                if (already) continue;
                const owned = allocator.dupe(u8, qualified) catch continue;
                out.append(allocator, .{
                    .name = owned,
                    .values = entry.values,
                    .ratio_items = entry.ratio_items,
                    .is_percent = entry.is_percent,
                }) catch continue;
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
        // 名字直接就是 DataValues 的，也顺手把「它乘的是什么属性」补上：
        // `APPerSecond` 单看名字带 `AP`，但要认 `QMaxHealthTrueDamagePerStack`
        // 这种就靠 ② 建的反查表。**这直接回答「它是什么加成」。**
        const stat = data_stats.get(pair.key_ptr.*) orelse statNameFrom(pair.key_ptr.*);
        out.append(allocator, .{
            .name = pair.key_ptr.*,
            .values = pair.value_ptr.*,
            .ratio_items = statOnlyRatioItems(allocator, stat),
            .is_percent = looksLikeFraction(pair.key_ptr.*, pair.value_ptr.*),
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

/// 从 `mFormulaParts` 里挑出「基础值 + 全部加成系数」。
fn resolveFormula(
    allocator: std.mem.Allocator,
    parts: std.json.Array,
    data_values: std.StringHashMap([]const f64),
) ?struct {
    values: []const f64,
    ratio_items: []const RatioItem,
} {
    var base: ?[]const f64 = null;
    var ratio_items = std.ArrayList(RatioItem).empty;

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
                if (coef.len == 0) continue;
                // 属性优先取 `mStat`（官方枚举，权威），退回名字启发式。
                const stat = statFromFormulaPart(part);
                ratio_items.append(allocator, .{
                    .ratio = coef[0],
                    // 逐级不同的系数（金克丝 W / 亚索 Q）要整条留下去，
                    // 否则 5 级的加成会显示成 1 级的。
                    .ratios = if (allEqual(coef)) null else coef,
                    .stat = (if (stat) |found| found.name else null) orelse statNameFrom(name),
                }) catch {};
            }
        } else if (std.mem.eql(u8, type_name, "StatByCoefficientCalculationPart")) {
            // 系数**不是** DataValue，而是公式里写死的字面量（`mCoefficient`）。
            //
            // 这一类以前整块被跳过，于是「+55% 法术强度」这种最常见的加成
            // （瑞兹 Q、莫甘娜 Q、娜美 W、艾瑞莉娅 W…）在界面上**一个字都没有**。
            // 2026-10-03 全量扫描 245 个英雄：共 831 处，其中 620 处没写属性。
            const coefficient = numberField(part.object.get("mCoefficient") orelse continue) orelse continue;
            // 系数 0 = 这一段不生效（CDragon 里有这种占位），别列出来。
            if (coefficient == 0) continue;
            ratio_items.append(allocator, .{
                .ratio = coefficient,
                .stat = coefficientStat(part.object),
            }) catch {};
        } else if (std.mem.eql(u8, type_name, "AbilityResourceByCoefficientCalculationPart")) {
            // 「按最大法力值的百分比」——瑞兹 Q/W/E、卡萨丁、布里茨被动护盾
            // （`ShieldAmount = 0.35` → 35% 最大法力值）、玛尔扎哈 E。
            // 2026-10-03 全量扫描只有 12 处，全部是法力值玩家，所以属性统一按最大法力值。
            const coefficient = numberField(part.object.get("mCoefficient") orelse continue) orelse continue;
            if (coefficient == 0) continue;
            ratio_items.append(allocator, .{ .ratio = coefficient, .stat = "MaxMana" }) catch {};
        } else if (std.mem.eql(u8, type_name, "ProductOfSubPartsCalculationPart")) {
            // 乘积段：`基础值 × (1 + 百分比)` 这种。
            //
            // 拉莫斯 W 的 `@BonusArmorTooltip@` 就是它，而且**一直是字面量**：
            //
            // ```text
            // BonusArmorTooltip = ProductOfSubParts(
            //     FlatBonusArmor,                       // [22, 27, 32, 37, 42, 47, 52]
            //     SumOfSubParts([1.0, BonusArmorPercent]) // (1 + 0.225 … 0.675)
            //   )
            //   + StatByNamedDataValue(Armor, BonusArmorPercent)   // 22.5%…67.5% 护甲
            // ```
            //
            // 以前整类跳过 → 这一项算不出 `base`，于是**整个变量从结果里消失**，
            // 文案里的 `@BonusArmorTooltip@` / `@BonusMRTooltip@` 只能原样印出来
            // （用户报的「有些地方还是不行」）。它的前半段**不依赖任何实时属性**
            // （`FlatBonusArmor` 与 `BonusArmorPercent` 都是本技能的逐级数据），
            // 能精确算出来；后半段照旧落成 ratio（逐级百分比）。
            //
            // ⚠️ 只在**还没有** base 时采纳：万一别处的公式是
            // `[NamedDataValue(基础), ProductOfSubParts(放大系数…)]`，那个具名基础值
            // 才是正主，把乘积当基础值会得出一个更大的错数。
            if (base == null) {
                if (evaluatePart(allocator, part, data_values)) |values| {
                    if (values.len > 0) base = values;
                }
            }
        }
        // 其余类型（`ByCharLevelInterpolationCalculationPart` /
        // `BuffCounterByNamedDataValueCalculationPart` …）仍然**不参与**——它们要么依赖
        // 实时属性（英雄等级插值），要么需要别的展开方式。
        // 宁可不给，也不给半截数字。
        // （`BuffCounter…` 由调用方单独走 `buffCounterSource` 处理。）
    }

    if (base) |values| {
        return .{ .values = values, .ratio_items = ratio_items.items };
    }
    return null;
}

/// 把一段公式**精确算成逐级数组**（只有完全不依赖实时属性的才返回）。
///
/// 这是 `ProductOfSubPartsCalculationPart` 的支撑：这类段是「若干个子段的乘积」，
/// 而子段又可能是 `SumOfSubParts`、`Number` 或具名数据值。层层展开之后才知道
/// 它到底是不是一个能算的数——`ByCharLevelInterpolation` / `StatBy*` 那类一遇到
/// 就返回 null，让调用方**放弃整段**（宁可没有，也不给错数）。
fn evaluatePart(
    allocator: std.mem.Allocator,
    part: std.json.Value,
    data_values: std.StringHashMap([]const f64),
) ?[]const f64 {
    if (part != .object) return null;
    const type_name = switch (part.object.get("__type") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    if (std.mem.eql(u8, type_name, "NamedDataValueCalculationPart")) {
        const name = switch (part.object.get("mDataValue") orelse return null) {
            .string => |s| s,
            else => return null,
        };
        return data_values.get(name);
    }
    if (std.mem.eql(u8, type_name, "NumberCalculationPart")) {
        const number = numberField(part.object.get("mNumber") orelse return null) orelse return null;
        const single = allocator.alloc(f64, 1) catch return null;
        single[0] = number;
        return single;
    }
    if (std.mem.eql(u8, type_name, "SumOfSubPartsCalculationPart")) {
        const subparts = switch (part.object.get("mSubparts") orelse return null) {
            .array => |a| a,
            else => return null,
        };
        return combineParts(allocator, subparts.items, data_values, .sum);
    }
    if (std.mem.eql(u8, type_name, "ProductOfSubPartsCalculationPart")) {
        var parts = std.ArrayList(std.json.Value).empty;
        // 官方写法是 `mPart1` / `mPart2` 两个具名字段；这里也收 `mParts` 数组写法。
        if (part.object.get("mParts")) |value| {
            if (value == .array) for (value.array.items) |item| parts.append(allocator, item) catch {};
        }
        if (part.object.get("mPart1")) |value| parts.append(allocator, value) catch {};
        if (part.object.get("mPart2")) |value| parts.append(allocator, value) catch {};
        if (parts.items.len == 0) return null;
        return combineParts(allocator, parts.items, data_values, .product);
    }
    return null;
}

const PartOp = enum { sum, product };

/// 把若干段按 `sum` 或 `product` 合并成一条逐级数组。
///
/// 长度规则：**单元素数组当常量广播**（`NumberCalculationPart` 写的就是 `mNumber: 1.0`，
/// 它没有「第几级」的概念）；长度一致就逐格合并；两者都不是（长度都对不上）就返回
/// null —— 这种形状没见过，不猜。
///
/// ⚠️ **任何一段算不出来就整段放弃**（`orelse return null`，不是 `continue`）。
/// 这个区别会静默出错：`ProductOfSubParts(FlatBonusArmor, ByCharLevelInterpolation)`
/// 若在第二段上跳过，乘积就退化成了 `FlatBonusArmor` 本身 —— 看起来是个像样的数，
/// 其实是半截的。宁可整项不出现（文案里占位符原样保留），也不给这种数。
fn combineParts(
    allocator: std.mem.Allocator,
    parts: []const std.json.Value,
    data_values: std.StringHashMap([]const f64),
    op: PartOp,
) ?[]const f64 {
    var out: ?[]f64 = null;
    for (parts) |item| {
        const values = evaluatePart(allocator, item, data_values) orelse return null;
        if (values.len == 0) return null;
        if (out) |acc| {
            if (acc.len == 1 and values.len > 1) {
                const widened = allocator.alloc(f64, values.len) catch return null;
                const left = acc[0];
                for (widened, values) |*slot, value| slot.* = if (op == .sum) left + value else left * value;
                out = widened;
            } else if (values.len == 1) {
                const right = values[0];
                for (acc) |*slot| slot.* = if (op == .sum) slot.* + right else slot.* * right;
            } else if (acc.len == values.len) {
                for (acc, values) |*slot, value| slot.* = if (op == .sum) slot.* + value else slot.* * value;
            } else {
                return null;
            }
        } else {
            out = allocator.dupe(f64, values) catch return null;
        }
    }
    return if (out) |acc| acc else null;
}

/// 读一个 JSON 数字（CDragon 里整数与浮点都有，同一字段两种都可能出现）。
fn numberField(value: std.json.Value) ?f64 {
    return switch (value) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => null,
    };
}

/// `StatByCoefficientCalculationPart` 乘的是哪个属性。
///
/// # 判据（2026-10-03 全量扫描 245 个英雄定案）
///
/// 1. 写了 `mStat` 就用它（艾瑞莉娅 W 的 `{mStat:2, 0.4}` = **40% 攻击力**）；
/// 2. 没写 `mStat` 但写了 `mStatFormula` 就用它（奥拉夫 `TotalDamage` 的
///    `{mStatFormula:2, 1.0}` = **100% 攻击力**——和 `mStat` 是同一套枚举）；
/// 3. 两个都**没写** → **法术强度**。
///
/// 第 3 条不是猜：620 处没写属性的逐个抽查都是法强（瑞兹 Q 0.55、莫甘娜 Q 0.9、
/// 娜美 W 0.6），而且艾瑞莉娅 W、沃里克 Q 这两处「同时有 `mStat:2` 和裸系数」的
/// 公式，客户端文案正是「攻击力 + 法术强度」两段并写——裸的那段就是法强。
fn coefficientStat(part: std.json.ObjectMap) ?[]const u8 {
    // 写了但**枚举认不出**时不表态（宁可只显示数字，也不乱贴属性名）。
    if (part.get("mStat")) |value| {
        if (value != .null) return statNameFromEnum(value);
    }
    if (part.get("mStatFormula")) |value| {
        if (value != .null) return statNameFromEnum(value);
    }
    return "AP";
}

/// 逐级值是否全都一样（一样就不用单独存一条 `ratios`）。
fn allEqual(values: []const f64) bool {
    if (values.len == 0) return true;
    for (values[1..]) |value| {
        if (value != values[0]) return false;
    }
    return true;
}

/// 公式里只有「消耗层数的数据值」时，返回「这一项实际该读的取值」。
///
/// 两种形状要分开处理（2026-09-30 实测，斯莫德 / 龙王各占一种）：
///
/// 1. **同一个技能里另有「像层数」的数据值** → 客户端印的是**层数**。
///    龙王 Q 的 `BurstBonusTrueDamageToChamps` 只有一段
///    `BuffCounterByNamedDataValueCalculationPart{mDataValue:"QMaxHealthTrueDamagePerStack"}`，
///    但文案 `@BurstBonusTrueDamageToChamps@` 印出来是 `2 / 2 / … / 2`——那是
///    `QMassStolen`（每次吸收的星尘数）。这时取那个「像层数」的项。
///
/// 2. **没有这种同类项** → 客户端印的就是**被消费的那个值本身**。
///    斯莫德被动的 `Passive_QDamageIncrease` 吃 `QDamagePerStack`（0.25，每层加成），
///    被动里没有任何 `Stack/Count/…` 同族项——这时读 `QDamagePerStack` 才对
///    （「每层 +0.25」）。照老逻辑返回 null 会让 Q/W/E 的加成一路空着。
///
/// 判据的顺序很要紧：先找同类项（形状 1），找不到才退回被消费值（形状 2）。
/// 反过来会让龙王那几个星尘项印成 0.031%。
fn buffCounterSource(parts: std.json.Array, data_values: std.StringHashMap([]const f64)) ?CounterPick {
    if (parts.items.len != 1) return null;
    const part = parts.items[0];
    if (part != .object) return null;
    const type_name = switch (part.object.get("__type") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    if (!std.mem.eql(u8, type_name, "BuffCounterByNamedDataValueCalculationPart")) return null;
    const expr = switch (part.object.get("mDataValue") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    // 被消费的数据值必须真的存在（否则我们连它在说什么都不知道）。
    const consumed = data_values.get(expr) orelse return null;
    // 形状 1：同类里另有一个「像层数」的项 → 那才是客户端印的量。
    if (counterValuesFor(expr, data_values)) |picked| {
        return .{ .name = picked.name, .expr = expr, .values = picked.values };
    }
    // 形状 2：没有同类项 → 被消费值本身就是要印的数（每层加成）。
    return .{ .name = expr, .expr = expr, .values = consumed };
}

/// 在同一个技能的 `DataValues` 里找「这一项实际该读的量」。
fn counterValuesFor(expr: []const u8, data_values: std.StringHashMap([]const f64)) ?CounterSource {
    var it = data_values.iterator();
    var picked: ?CounterSource = null;
    while (it.next()) |pair| {
        const name = pair.key_ptr.*;
        if (std.mem.eql(u8, name, expr)) continue;
        // 被消费的那个数据值（`QMaxHealthTrueDamagePerStack`）本身也在表里，
        // 它不是「另一个量」，跳过。
        if (std.mem.indexOf(u8, name, "PerStack") != null) continue;
        if (!looksLikeCounterName(name)) continue;
        // 名字不定（HashMap 迭代顺序），取名字最小的那个，保证输出可复现。
        if (picked == null or std.mem.lessThan(u8, name, picked.?.name)) {
            picked = .{ .name = name, .values = pair.value_ptr.* };
        }
    }
    return picked;
}

/// 「这名字读起来像**个数/层数**」而不是像伤害数值：星尘、层数、眩晕数…
fn looksLikeCounterName(name: []const u8) bool {
    const hints = [_][]const u8{ "Mass", "Stack", "Stun", "Count", "Charge", "Soul", "Essence", "Token", "Splinter" };
    for (hints) |hint| {
        if (std.mem.indexOf(u8, name, hint) != null) return true;
    }
    return false;
}

/// 「这个变量按哪个属性算」——`source` 是消费的数据值、`name` 是属性代码。
///
/// ⚠️ 必须是**具名**结构体：Zig 里两处各写一遍匿名 `struct {…}` 会生成两个互不
/// 兼容的类型，`orelse` 直接编译失败（2026-10-02 踩到）。
const StatSource = struct {
    source: []const u8,
    name: []const u8,
};

/// `counterValuesFor` 的返回值：实际该读的那一项的名字与逐级值。
const CounterSource = struct {
    name: []const u8,
    values: []const f64,
};

/// `buffCounterSource` 的返回值：被消费的表达式 + 实际该读的那一项。
const CounterPick = struct {
    name: []const u8,
    expr: []const u8,
    values: []const f64,
};

/// 从一段公式里读出「它乘的是哪个属性」。
///
/// 优先用官方枚举 `mStat`（权威、无需猜名字）；没有就退回 `mDataValue` 的名字启发式。
fn statFromFormulaPart(part: std.json.Value) ?StatSource {
    if (part != .object) return null;
    const value_name = switch (part.object.get("mDataValue") orelse .null) {
        .string => |s| s,
        else => "",
    };
    if (statNameFromEnum(part.object.get("mStat") orelse .null)) |stat| {
        return .{ .source = value_name, .name = stat };
    }
    if (value_name.len > 0) {
        if (statNameFrom(value_name)) |stat| {
            return .{ .source = value_name, .name = stat };
        }
    }
    return null;
}

/// CDragon 的 `mStat` 是官方属性枚举。只映射**实测见过**的取值，
/// 没见过的返回 null（宁可退回名字启发式，也不乱猜）。
///
/// 2026-09-30 实测（7 个英雄、19 处 `StatByNamedDataValueCalculationPart`）：
/// 2 = 攻击力、7 = 移动速度、9 = 暴击伤害、12 = 最大生命值。
/// 1 = 护甲、6 = 魔法抗性是社区长期记录，一并收着。
fn statNameFromEnum(value: std.json.Value) ?[]const u8 {
    const stat: i64 = switch (value) {
        .integer => |i| i,
        .float => |f| @as(i64, @intFromFloat(f)),
        else => return null,
    };
    return switch (stat) {
        1 => "Armor",
        2 => "AD",
        6 => "MR",
        7 => "MoveSpeed",
        9 => "Crit",
        12 => "MaxHealth",
        else => null,
    };
}

/// 全部取值都落在 `[0, 1]` 且**至少有一个非 0** 时，**猜**它是分数。
///
/// # ⚠️ 这个猜测对「时长」是错的，前端会用正文纠正它
///
/// `0.5 秒` 和 `50%` 在数值上完全一样，光看取值范围**无法区分**。
/// 2026-10-03 全量扫描 245 个英雄实测：按范围判会把
/// `SlowDuration`(55 英雄) / `StunDuration`(33) / `KnockupDuration`(18)
/// 这些**时长**变量全部误判成百分数，正文里共 151 处印成「击飞 50 秒」。
///
/// 所以这里保留它只是为了让**取值速查表**（没有正文上下文的那一层）也有个大致像样的
/// 显示；**正文替换**一律以客户端文案里紧跟占位符的 `秒` / `%` 为准
/// （见前端 `detectUnitFromText`）。
///
/// 名字里带时长词（`Duration` / `Time` / …）的**直接否掉**——那不是猜，是知道。
///
/// 为什么要求「非 0」：`CloneDamageMod` 那种真的从 0 开始的要做限制，而全 0 的
/// 占位数组（CDragon 里不少）本来就是没用的，标成百分比也毫无意义。
/// 为什么要求「全部」：`SlowAmount` = 0.2…0.8 全是分数；而
/// `TooltipTakedownCooldownMultiplier` = 90 不是——只要有一个越界就整体否定，
/// 宁可少标，也不要把一个「90」印成「9000%」。
fn looksLikeFraction(name: []const u8, values: []const f64) bool {
    if (values.len == 0) return false;
    // 时长类名字直接排除：`SlowDuration` = 0.5 是**秒**，不是 50%。
    if (isDurationName(name)) return false;
    var has_nonzero = false;
    for (values) |value| {
        if (!(value >= 0 and value <= 1)) return false;
        if (value != 0) has_nonzero = true;
    }
    return has_nonzero;
}

/// 变量名是否讲的是「时间」。
///
/// 2026-10-03 全量扫描里，这些名字的取值**全部**是秒（`0.25`~`2.0`），
/// 却被「落在 [0,1] 就当百分数」的规则误判。命中 76 个名字 / 167 个英雄。
///
/// 判据是**词根**而不是整名匹配：`SlowDuration` / `KnockupDuration` /
/// `Cast_Time_Base` / `RecastDelay` / `CCDurationMin` 都要能命中。
fn isDurationName(name: []const u8) bool {
    const roots = [_][]const u8{
        "duration", "time",   "interval", "delay",
        "cooldown", "timer",  "seconds",
    };
    for (roots) |root| {
        if (containsIgnoreCase(name, root)) return true;
    }
    return false;
}

/// 大小写无关的子串查找（CDragon 的命名大小写不统一：`Cast_Time` 对 `castTime`）。
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    if (haystack.len < needle.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) return true;
    }
    return false;
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
    const items = list.items;
    // ⚠️ 去掉**首位的负数哨兵**（2026-10-03 全量扫描 245 个英雄定案）。
    //
    // CDragon 的 `DataValues` 有一批数组第 0 格是负数，而它**不是真实数值**，
    // 是「这一级没有该效果」的占位：瑟庄妮 W 的
    // `BaseDamageOne = [-5, 5, 15, 25, 35, 45, 55]`——客户端印的是
    // 「造成 5 / 5 / 15 / … 物理伤害」，那个 `-5` 从来不会出现在界面上。
    // 不去掉就会显示成「造成 **-5** / 5 / 15 … 物理伤害」（用户 2026-10-03 报的）。
    //
    // 判据是**首格为负、其余全部非负**——这个形状在 245 个英雄里命中 81 处，
    // 且留下的 134 处全是**真负值**（`SlowAmount = [-0.5, …]` 减速是负的、
    // `Tryndamere.ADReduction = [-5, -20, …]` 减甲是负的），一条都没被误伤。
    // 所以这里只丢「孤零零一个负数打头」，绝不碰整体为负的数组。
    if (items.len > 1 and items[0] < 0) {
        var all_non_negative = true;
        for (items[1..]) |rest| {
            if (rest < 0) {
                all_non_negative = false;
                break;
            }
        }
        if (all_non_negative) return items[1..];
    }
    return items;
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
        // 兼容字段：**第一段**加成照旧写成 `ratio` / `ratios` / `ratioStat`。
        // 前端在只有一段时走的就是这条老路，老缓存与老前端也不受影响。
        if (entry.ratio_items.len > 0) {
            const first = entry.ratio_items[0];
            if (first.ratio) |ratio| {
                try writer.writeAll(",\"ratio\":");
                try writer.writeFloat(ratio);
                // 系数逐级不同时，把整条也带上（否则前端只能看到第 1 级的）。
                if (first.ratios) |ratios| {
                    try writer.writeAll(",\"ratios\":[");
                    for (ratios, 0..) |value, ratio_index| {
                        if (ratio_index > 0) try writer.writeAll(",");
                        try writer.writeFloat(value);
                    }
                    try writer.writeAll("]");
                }
            }
            // `ratioStat` 有时**没有** `ratio`（`BurstBonusTrueDamageToChamps` 那种
            // 「加成属性由它消费的数据值决定」的项），所以单独判、不能挂在 ratio 里。
            if (first.stat) |stat| {
                try writer.writeAll(",\"ratioStat\":");
                try writer.writeJsonString(stat);
            }
        }
        // **多段**加成（艾瑞莉娅 W = 攻击力 + 法强、瑞兹 Q = 法强 + 最大法力值）。
        // 只在真有第二段时才写，否则绝大多数项的输出会白白撑大。
        if (entry.ratio_items.len > 1) {
            try writer.writeAll(",\"ratioItems\":[");
            for (entry.ratio_items, 0..) |item, item_index| {
                if (item_index > 0) try writer.writeAll(",");
                try writer.writeAll("{");
                var wrote_field = false;
                if (item.ratio) |ratio| {
                    try writer.writeAll("\"ratio\":");
                    try writer.writeFloat(ratio);
                    wrote_field = true;
                }
                if (item.ratios) |ratios| {
                    if (wrote_field) try writer.writeAll(",");
                    try writer.writeAll("\"ratios\":[");
                    for (ratios, 0..) |value, ratio_index| {
                        if (ratio_index > 0) try writer.writeAll(",");
                        try writer.writeFloat(value);
                    }
                    try writer.writeAll("]");
                    wrote_field = true;
                }
                if (item.stat) |stat| {
                    if (wrote_field) try writer.writeAll(",");
                    try writer.writeAll("\"stat\":");
                    try writer.writeJsonString(stat);
                }
                try writer.writeAll("}");
            }
            try writer.writeAll("]");
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

test "时长类变量名不再被当成百分数（击飞 0.5 秒曾被印成 50 秒）" {
    // 瑟庄妮 Q / 加里奥 Q 的真机数据（2026-10-03 实测）：
    //   KnockupDurationTOOLTIPONLY = 0.5，客户端文案写「击飞敌人@KnockupDuration@秒」
    // 旧逻辑只看「值落在 [0,1]」→ 判成百分数 → 正文印成「击飞 50 秒」。
    // 名字里带 Duration/Time 就是**时间**，不是比例，直接否掉。
    const body =
        \\{"Characters/Sejuani/CharacterRecords/Root":{"spells":["Characters/Sejuani/Spells/SejuaniQAbility/SejuaniQ"]},
        \\ "Characters/Sejuani/Spells/SejuaniQAbility/SejuaniQ":{"mSpell":{"DataValues":[
        \\   {"name":"KnockupDurationTOOLTIPONLY","values":[0.5,0.5,0.5,0.5,0.5,0.5,0.5]},
        \\   {"name":"QSpellCooldown","values":[10,9,8,7,6,5,4]},
        \\   {"name":"TotalDamage","values":[40,90,140,190,240,290,340]},
        \\   {"name":"SlowAmount","values":[0.75,0.75,0.75,0.75,0.75,0.75,0.75]}
        \\ ]}}}
    ;
    var output: [4096]u8 = undefined;
    const json = try writeValues("Sejuani", body, &output);

    // ⚠️ 关键断言：**不带** percent。带上就会在前端被乘 100 → 「50 秒」。
    try std.testing.expect(std.mem.indexOf(u8, json, "\"KnockupDurationTOOLTIPONLY\":{\"values\":[0.5000,0.5000,0.5000,0.5000,0.5000,0.5000,0.5000]}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "KnockupDurationTOOLTIPONLY\":{\"values\":[0.5000,0.5000,0.5000,0.5000,0.5000,0.5000,0.5000],\"percent\"") == null);
    // 对照：真正的分数（SlowAmount）仍然要标百分比
    try std.testing.expect(std.mem.indexOf(u8, json, "\"SlowAmount\":{\"values\":[0.7500,0.7500,0.7500,0.7500,0.7500,0.7500,0.7500],\"percent\":true}") != null);
    // 对照：伤害与冷却本来就不在 [0,1]，不受影响
    try std.testing.expect(std.mem.indexOf(u8, json, "\"TotalDamage\":{\"values\":[40,90,140,190,240,290,340]}") != null);
}

test "不同大小写/词形的时间词根都能认出来" {
    try std.testing.expect(isDurationName("SlowDuration"));
    try std.testing.expect(isDurationName("KnockupDuration"));
    try std.testing.expect(isDurationName("Cast_Time_Base"));
    try std.testing.expect(isDurationName("RecastDelay"));
    try std.testing.expect(isDurationName("CCDurationMin"));
    try std.testing.expect(isDurationName("casttime"));
    // 不是时间的东西不能被误伤
    try std.testing.expect(!isDurationName("TotalDamage"));
    try std.testing.expect(!isDurationName("AOEModifier"));
    try std.testing.expect(!isDurationName("ArmorShredPercent"));
}

test "首位的负数哨兵被丢掉（瑟庄妮 W 曾显示成 -5 / 5 / 15）" {
    // 真机数据：`BaseDamageOne = [-5, 5, 15, 25, 35, 45, 55]`，客户端印的是
    // 「造成 5 / 5 / 15 / 25 / 35 / 45 / 55 物理伤害」——那个 -5 是「这一级没有」的占位。
    const body =
        \\{"Characters/Sejuani/CharacterRecords/Root":{"spells":["Characters/Sejuani/Spells/SejuaniWAbility/SejuaniW"]},
        \\ "Characters/Sejuani/Spells/SejuaniWAbility/SejuaniW":{"mSpell":{"DataValues":[
        \\   {"name":"BaseDamageOne","values":[-5,5,15,25,35,45,55]},
        \\   {"name":"BaseDamageTwo","values":[-15,5,25,45,65,85,105]}
        \\ ]}}}
    ;
    var output: [4096]u8 = undefined;
    const json = try writeValues("Sejuani", body, &output);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"BaseDamageOne\":{\"values\":[5,15,25,35,45,55]}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"BaseDamageTwo\":{\"values\":[5,25,45,65,85,105]}") != null);
    // 首格不该再出现
    try std.testing.expect(std.mem.indexOf(u8, json, "[-5") == null);
}

test "整体为负的数组原样保留（减速/减甲本来就是负的）" {
    // SlowAmount = [-0.25, -0.3, …]：减速幅度是负的，不是「首个哨兵」。
    // ADReduction = [-5, -20, -35, -50]：减甲同理。
    // 这两类绝不能被「丢首格」的规则改掉（改了数值就全错了）。
    const body =
        \\{"Characters/Nunu/CharacterRecords/Root":{"spells":["Characters/Nunu/Spells/W"]},
        \\ "Characters/Nunu/Spells/W":{"mSpell":{"DataValues":[
        \\   {"name":"SlowAmount","values":[-0.25,-0.3,-0.35,-0.4,-0.45,-0.5]},
        \\   {"name":"ADReduction","values":[-5,-20,-35,-50,-65,-80]}
        \\ ]}}}
    ;
    var output: [4096]u8 = undefined;
    const json = try writeValues("Nunu", body, &output);
    // 负号必须都还在（下面只截到 `]` 为止：`ADReduction` 名字里带 `AD`，
    // 会被顺带标上 `ratioStat:"AD"`，那是「它是什么加成」，与这里的断言无关）。
    try std.testing.expect(std.mem.indexOf(u8, json, "\"SlowAmount\":{\"values\":[-0.2500,-0.3000,-0.3500,-0.4000,-0.4500,-0.5000]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ADReduction\":{\"values\":[-5,-20,-35,-50,-65,-80]") != null);
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

test "消耗层数的计算项读的是层数，不是它乘的那个数值（龙王 Q）" {
    // 结构照 2026-10-02 实测的龙王 Q 抄。三个关键事实：
    //   `BurstBonusTrueDamageToChamps` 只有一段 BuffCounter，消费
    //   `QMaxHealthTrueDamagePerStack`（0.00031，按最大生命值算的）；
    //   但客户端文案 `@BurstBonusTrueDamageToChamps@` 印出来是 `2 / 2 / … / 2`
    //   ——那是 `QMassStolen`（每次吸收的星尘数）。
    //   印 0.031% 就是错的，所以必须认出层数那一项。
    const body =
        \\{"Characters/AurelionSol/CharacterRecords/Root":{"spells":["Characters/AurelionSol/Spells/AurelionSolQAbility/AurelionSolQ"]},
        \\ "Characters/AurelionSol/Spells/AurelionSolQAbility/AurelionSolQ":{"mSpell":{
        \\   "DataValues":[
        \\     {"name":"RankDamagePerSecond","values":[30,45,60,75,90,105,120]},
        \\     {"name":"QMaxHealthTrueDamagePerStack","values":[0.00031,0.00031,0.00031,0.00031,0.00031,0.00031,0.00031]},
        \\     {"name":"QMassStolen","values":[2,2,2,2,2,2,2]},
        \\     {"name":"AOEModifier","values":[0.5,0.5,0.5,0.5,0.5,0.5,0.5]}
        \\   ],
        \\   "mSpellCalculations":{
        \\     "BurstBonusTrueDamageToChamps":{
        \\       "mFormulaParts":[{"__type":"BuffCounterByNamedDataValueCalculationPart","mDataValue":"QMaxHealthTrueDamagePerStack","mBuffName":"{c9372c6b}"}],
        \\       "mDisplayAsPercent":true
        \\     }
        \\   }
        \\ }}}
    ;
    var output: [4096]u8 = undefined;
    const json = try writeValues("AurelionSol", body, &output);
    // 读到的是星尘层数 2/2/…/2
    try std.testing.expect(std.mem.indexOf(u8, json, "\"BurstBonusTrueDamageToChamps\":{\"values\":[2,2,2,2,2,2,2]") != null);
    // ⚠️ 这一项**绝不能**是那个 0.031%（`QMaxHealthTrueDamagePerStack` 自己作为
    // DataValue 条目照常出现在列表里，所以只能盯住 `BurstBonusTrueDamageToChamps` 这一项）。
    try std.testing.expect(std.mem.indexOf(u8, json, "\"BurstBonusTrueDamageToChamps\":{\"values\":[0.0003") == null);
    // 层数是整数，**不能**被标成百分比（标了就成了 200%）
    try std.testing.expect(std.mem.indexOf(u8, json, "\"BurstBonusTrueDamageToChamps\":{\"values\":[2,2,2,2,2,2,2],\"percent\"") == null);
    // 半分的 AOE 系数照旧是量值（不是层数，不该被别名逻辑抢走）
    try std.testing.expect(std.mem.indexOf(u8, json, "\"AOEModifier\":{\"values\":[0.5000,0.5000,0.5000,0.5000,0.5000,0.5000,0.5000],\"percent\":true}") != null);
}

test "加成属性按消费的数据值推：龙王 Q 的爆发是最大生命值加成" {
    // 「它是什么加成」的答案就在公式里：`QMaxHealthTrueDamagePerStack` 名字里
    // 带 `MaxHealth`。这一项**没有** ratio（不是「基础值 + 系数」的形状），
    // 所以只有 `ratioStat`、没有 `ratio`——JSON 形状要允许这种组合。
    const body =
        \\{"Characters/AurelionSol/CharacterRecords/Root":{"spells":["Characters/AurelionSol/Spells/AurelionSolQAbility/AurelionSolQ"]},
        \\ "Characters/AurelionSol/Spells/AurelionSolQAbility/AurelionSolQ":{"mSpell":{
        \\   "DataValues":[
        \\     {"name":"QMaxHealthTrueDamagePerStack","values":[0.00031,0.00031]},
        \\     {"name":"QMassStolen","values":[2,2]}
        \\   ],
        \\   "mSpellCalculations":{"BurstBonusTrueDamageToChamps":{
        \\     "mFormulaParts":[{"__type":"BuffCounterByNamedDataValueCalculationPart","mDataValue":"QMaxHealthTrueDamagePerStack"}]
        \\   }}
        \\ }}}
    ;
    var output: [4096]u8 = undefined;
    const json = try writeValues("AurelionSol", body, &output);
    // 关键：必须出现 `ratioStat":"MaxHealth"`，且**不能**多出一个假 `ratio`
    try std.testing.expect(std.mem.indexOf(u8, json, "\"BurstBonusTrueDamageToChamps\":{\"values\":[2,2],\"ratioStat\":\"MaxHealth\"}") != null);
    // 被消费的那个数据值自己也该带上属性，方便速查表回答「它是什么加成」
    try std.testing.expect(std.mem.indexOf(u8, json, "\"QMaxHealthTrueDamagePerStack\":{\"values\":[0.0003,0.0003],\"ratioStat\":\"MaxHealth\"") != null);
}

test "逐级不同的系数要整条留住（金克丝 W / 亚索 Q 那种）" {
    // 实测金克丝 W 的 `TotalDamage` 是「基础值 + AD 系数」，而 AD 系数逐级变。
    // 只留第 0 格会让「升到 5 级」的加成看上去和 1 级一样。
    const body =
        \\{"Characters/Jinx/CharacterRecords/Root":{"spells":["Characters/Jinx/Spells/JinxW/JinxW"]},
        \\ "Characters/Jinx/Spells/JinxW/JinxW":{"mSpell":{
        \\   "DataValues":[
        \\     {"name":"BaseDamage","values":[10,45,80,115,150]},
        \\     {"name":"ADRatio","values":[1.4,1.5,1.6,1.7,1.8]}
        \\   ],
        \\   "mSpellCalculations":{"TotalDamage":{"mFormulaParts":[
        \\     {"__type":"NamedDataValueCalculationPart","mDataValue":"BaseDamage"},
        \\     {"__type":"StatByNamedDataValueCalculationPart","mDataValue":"ADRatio"}
        \\   ]}}
        \\ }}}
    ;
    var output: [4096]u8 = undefined;
    const json = try writeValues("Jinx", body, &output);
    // 首格照旧写成 `ratio`，整条写在 `ratios` 里
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ratio\":1.4000,\"ratios\":[1.4000,1.5000,1.6000,1.7000,1.8000],\"ratioStat\":\"AD\"") != null);
}

test "系数全都一样时不写 ratios（省体积，前端也照旧显一个数）" {
    // 龙王 Q 的 `APPerSecond` 七级都是 0.55——不该产生一条冗余的 ratios。
    const body =
        \\{"Characters/AurelionSol/CharacterRecords/Root":{"spells":["Characters/AurelionSol/Spells/AurelionSolQAbility/AurelionSolQ"]},
        \\ "Characters/AurelionSol/Spells/AurelionSolQAbility/AurelionSolQ":{"mSpell":{
        \\   "DataValues":[
        \\     {"name":"RankDamagePerSecond","values":[30,45,60]},
        \\     {"name":"APPerSecond","values":[0.55,0.55,0.55]}
        \\   ],
        \\   "mSpellCalculations":{"DamagePerSecond":{"mFormulaParts":[
        \\     {"__type":"NamedDataValueCalculationPart","mDataValue":"RankDamagePerSecond"},
        \\     {"__type":"StatByNamedDataValueCalculationPart","mDataValue":"APPerSecond"}
        \\   ]}}
        \\ }}}
    ;
    var output: [4096]u8 = undefined;
    const json = try writeValues("AurelionSol", body, &output);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ratio\":0.5500,\"ratioStat\":\"AP\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "ratios") == null);
}

test "mStat 是官方枚举，比名字猜得准（护盾按最大生命值）" {
    // 盖伦 W 的 `TotalShield = BaseShield + ShieldHealthRatio × 最大生命值`。
    // 名字 `ShieldHealthRatio` 里带 `Health`，启发式会猜成 `Health`；
    // 但官方 `mStat:12` 说的是**最大生命值**，所以要以 mStat 为准。
    const body =
        \\{"Characters/Garen/CharacterRecords/Root":{"spells":["Characters/Garen/Spells/GarenWAbility/GarenW"]},
        \\ "Characters/Garen/Spells/GarenWAbility/GarenW":{"mSpell":{
        \\   "DataValues":[
        \\     {"name":"BaseShield","values":[45,65,85,105,125]},
        \\     {"name":"ShieldHealthRatio","values":[0.18,0.18,0.18,0.18,0.18]}
        \\   ],
        \\   "mSpellCalculations":{"TotalShield":{"mFormulaParts":[
        \\     {"__type":"NamedDataValueCalculationPart","mDataValue":"BaseShield"},
        \\     {"__type":"StatByNamedDataValueCalculationPart","mDataValue":"ShieldHealthRatio","mStat":12,"mStatFormula":2}
        \\   ]}}
        \\ }}}
    ;
    var output: [4096]u8 = undefined;
    const json = try writeValues("Garen", body, &output);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ratioStat\":\"MaxHealth\"") != null);
    // `Health` 是启发式的结果，mStat 在时**不该**出现
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ratioStat\":\"Health\"") == null);
}

test "没有同类层数项时读被消费值本身（斯莫德的每层加成）" {
    // 斯莫德被动 `Passive_QDamageIncrease` 吃 `QDamagePerStack`（0.25），
    // 被动里没有任何 `Stack/Count/…` 同族项 → 这时印的**就是** 0.25（每层 +0.25）。
    // 老逻辑在这里返回 null，导致斯莫德 Q/W/E 的加成一路空着（用户报的就是这个）。
    const body =
        \\{"Characters/Smolder/CharacterRecords/Root":{"spells":["Characters/Smolder/Spells/Q"]},
        \\ "Characters/Smolder/Spells/Q":{"mSpell":{
        \\   "DataValues":[{"name":"QDamagePerStack","values":[0.25,0.25,0.25,0.25,0.25,0.25,0.25]}],
        \\   "mSpellCalculations":{"Passive_QDamageIncrease":{"mFormulaParts":[
        \\     {"__type":"BuffCounterByNamedDataValueCalculationPart","mDataValue":"QDamagePerStack"}
        \\   ]}}
        \\ }}}
    ;
    var output: [2048]u8 = undefined;
    const json = try writeValues("Smolder", body, &output);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Passive_QDamageIncrease\":{\"values\":[0.2500,0.2500,0.2500,0.2500,0.2500,0.2500,0.2500]") != null);
}

test "被消费值不存在时仍然跳过（不编数）" {
    // `mDataValue` 指的名字在这个技能里根本不存在 → 连它在说什么都不知道，跳过。
    const body =
        \\{"Characters/X/CharacterRecords/Root":{"spells":["Characters/X/Spells/Q"]},
        \\ "Characters/X/Spells/Q":{"mSpell":{
        \\   "DataValues":[{"name":"StunCount","values":[1,1]}],
        \\   "mSpellCalculations":{"Mystery":{"mFormulaParts":[
        \\     {"__type":"BuffCounterByNamedDataValueCalculationPart","mDataValue":"NotHereAtAll"}
        \\   ]}}
        \\ }}}
    ;
    var output: [2048]u8 = undefined;
    const json = try writeValues("X", body, &output);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Mystery\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"StunCount\"") != null);
}

test "多层公式的 BuffCounter 不当别名处理" {
    // 两段以上说明不是「纯层数」的形状，一律不走别名逻辑。
    const body =
        \\{"Characters/X/CharacterRecords/Root":{"spells":["Characters/X/Spells/Q"]},
        \\ "Characters/X/Spells/Q":{"mSpell":{
        \\   "DataValues":[
        \\     {"name":"Base","values":[10,20]},
        \\     {"name":"DamagePerStack","values":[0.0003,0.0003]},
        \\     {"name":"QMassStolen","values":[2,2]}
        \\   ],
        \\   "mSpellCalculations":{"Mix":{"mFormulaParts":[
        \\     {"__type":"NamedDataValueCalculationPart","mDataValue":"Base"},
        \\     {"__type":"BuffCounterByNamedDataValueCalculationPart","mDataValue":"DamagePerStack"}
        \\   ]}}
        \\ }}}
    ;
    var output: [2048]u8 = undefined;
    const json = try writeValues("X", body, &output);
    // 基础值那一路照常生效
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Mix\":{\"values\":[10,20]}") != null);
    // 但**不该**被换成星尘的 2
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Mix\":{\"values\":[2,2]") == null);
}

test "跨技能引用：@spell.被动:变量@ 要从被动里取值（斯莫德 Q）" {
    // 斯莫德 Q 的文案是 `@spell.SmolderP:Passive_QDamageIncrease@`——加成写着**被动**里。
    // 不解析这层引用，界面上就永远是一个裸露的变量名。
    // 2026-09-30 全英雄扫描：22 个英雄有这种写法（拉莫斯 R、蔚、凯莎、慧…）。
    const body =
        \\{"Characters/Smolder/CharacterRecords/Root":{
        \\   "mCharacterPassiveSpell":"Characters/Smolder/Spells/SmolderPAbility/SmolderP",
        \\   "spells":["Characters/Smolder/Spells/SmolderQAbility/SmolderQ"]
        \\ },
        \\ "Characters/Smolder/Spells/SmolderPAbility/SmolderP":{"mSpell":{
        \\   "DataValues":[
        \\     {"name":"QDamagePerStack","values":[0.25,0.25,0.25,0.25,0.25,0.25,0.25]},
        \\     {"name":"QCritRatio","values":[1.2,1.2,1.2,1.2,1.2,1.2,1.2]}
        \\   ],
        \\   "mSpellCalculations":{
        \\     "Passive_QDamageIncrease":{"mFormulaParts":[
        \\       {"__type":"BuffCounterByNamedDataValueCalculationPart","mDataValue":"QDamagePerStack"}
        \\     ]},
        \\     "TooltipOnly_QCritMultiplier":{"mFormulaParts":[
        \\       {"__type":"NamedDataValueCalculationPart","mDataValue":"QCritRatio"}
        \\     ]}
        \\   }
        \\ }},
        \\ "Characters/Smolder/Spells/SmolderQAbility/SmolderQ":{"mSpell":{
        \\   "DataValues":[
        \\     {"name":"BaseDamage","values":[50,60,70,80,90,100,110]},
        \\     {"name":"ADRatio","values":[1.3,1.3,1.3,1.3,1.3,1.3,1.3]}
        \\   ],
        \\   "mSpellCalculations":{"TotalDamage":{"mFormulaParts":[
        \\     {"__type":"NamedDataValueCalculationPart","mDataValue":"BaseDamage"},
        \\     {"__type":"StatByNamedDataValueCalculationPart","mDataValue":"ADRatio"}
        \\   ]}}
        \\ }}}
    ;
    var output: [8192]u8 = undefined;
    const json = try writeValues("Smolder", body, &output);

    // Q 槽位里既有自己的 `TotalDamage`…
    try std.testing.expect(std.mem.indexOf(u8, json, "\"TotalDamage\":{\"values\":[50,60,70,80,90,100,110],\"ratio\":1.3000,\"ratioStat\":\"AD\"}") != null);
    // …也有**带完整调用名**的跨技能项。名字必须原样保留（前端要拿它配 `@spell.SmolderP:…@`）。
    // 值读的是被消费的 `QDamagePerStack`（每层 +0.25）——被动里没有同族层数项。
    try std.testing.expect(std.mem.indexOf(u8, json, "\"spell.SmolderP:Passive_QDamageIncrease\":{\"values\":[0.2500,0.2500,0.2500,0.2500,0.2500,0.2500,0.2500]") != null);
    // 被动里的另一个计算项也一并带过来（同事一起引用）
    try std.testing.expect(std.mem.indexOf(u8, json, "\"spell.SmolderP:TooltipOnly_QCritMultiplier\"") != null);
    // 被动槽位自己照常保留短名（不重复加前缀）
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Passive_QDamageIncrease\":{\"values\":[0.2500") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"spell.SmolderP:spell.") == null);
}

test "跨技能引用：拉莫斯 R 引用 Q 的 PowerBallDamage" {
    // 用户「已经修过」的拉莫斯其实也漏着一个：R 的文案写
    // `@spell.PowerBall:PowerBallDamage@`（指向 Q）。这条钉死它不再漏。
    const body =
        \\{"Characters/Rammus/CharacterRecords/Root":{
        \\   "mCharacterPassiveSpell":"Characters/Rammus/Spells/RammusPAbility/RammusP",
        \\   "spells":[
        \\     "Characters/Rammus/Spells/PowerBallAbility/PowerBall",
        \\     "Characters/Rammus/Spells/Tremors2Ability/Tremors2"
        \\   ]
        \\ },
        \\ "Characters/Rammus/Spells/RammusPAbility/RammusP":{"mSpell":{
        \\   "DataValues":[{"name":"PBonus","values":[10,20]}]
        \\ }},
        \\ "Characters/Rammus/Spells/PowerBallAbility/PowerBall":{"mSpell":{
        \\   "DataValues":[
        \\     {"name":"QBaseDamage","values":[40,80,120,160,200,240,280]},
        \\     {"name":"APRatio","values":[1,1,1,1,1,1,1]}
        \\   ],
        \\   "mSpellCalculations":{"PowerBallDamage":{"mFormulaParts":[
        \\     {"__type":"NamedDataValueCalculationPart","mDataValue":"QBaseDamage"},
        \\     {"__type":"StatByNamedDataValueCalculationPart","mDataValue":"APRatio"}
        \\   ]}}
        \\ }},
        \\ "Characters/Rammus/Spells/Tremors2Ability/Tremors2":{"mSpell":{
        \\   "DataValues":[{"name":"SlowAmount","values":[0.2,0.3,0.4,0.5,0.6,0.7,0.8]}]
        \\ }}}
    ;
    var output: [8192]u8 = undefined;
    const json = try writeValues("Rammus", body, &output);
    // R 槽位（第 4 个 spell，`slot":"r"`）里出现 `spell.PowerBall:PowerBallDamage`
    try std.testing.expect(std.mem.indexOf(u8, json, "\"spell.PowerBall:PowerBallDamage\"") != null);
    // Q 槽位照常有自己的短名版本
    try std.testing.expect(std.mem.indexOf(u8, json, "\"PowerBallDamage\":{\"values\":[40,80,120,160,200,240,280],\"ratio\":1,\"ratioStat\":\"AP\"}") != null);
    // 跨技能项自己**不能再挂一层前缀**（防止 `spell.X:spell.` 这种）
    try std.testing.expect(std.mem.indexOf(u8, json, ":spell.") == null);
}

test "被动没有可取值时不会凭空塞前缀项" {
    // 索引里只有「路径能取到值的技能」。若被动路径指向的对象根本不存在
    // （或者它一个 DataValue / 计算项都没有），就不该多出任何 `spell.X:` 条目。
    const body =
        \\{"Characters/Solo/CharacterRecords/Root":{
        \\   "mCharacterPassiveSpell":"Characters/Solo/Spells/SoloPAbility/SoloP",
        \\   "spells":["Characters/Solo/Spells/SoloQAbility/SoloQ"]
        \\ },
        \\ "Characters/Solo/Spells/SoloQAbility/SoloQ":{"mSpell":{
        \\   "DataValues":[{"name":"Base","values":[5,10]}]
        \\ }}}
    ;
    var output: [4096]u8 = undefined;
    const json = try writeValues("Solo", body, &output);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Base\":{\"values\":[5,10]}") != null);
    // 被动取不到任何值 → 不该出现 `spell.SoloP:` 前缀项（没有可复制的条目）。
    try std.testing.expect(std.mem.indexOf(u8, json, "\"spell.") == null);
}

test "跨技能引用也会带上系数与加成属性" {
    // 引用过来的项若本身是「基础值 + 系数」，系数信息不能丢——
    // 用户要的「它是什么加成」在这条路径上同样要成立。
    const body =
        \\{"Characters/Kaisa/CharacterRecords/Root":{
        \\   "mCharacterPassiveSpell":"Characters/Kaisa/Spells/KaisaPassiveAbility/KaisaPassive",
        \\   "spells":["Characters/Kaisa/Spells/KaisaWAbility/KaisaW"]
        \\ },
        \\ "Characters/Kaisa/Spells/KaisaPassiveAbility/KaisaPassive":{"mSpell":{
        \\   "DataValues":[
        \\     {"name":"PBase","values":[15,20,25,30,35]},
        \\     {"name":"APRatio","values":[0.2,0.2,0.2,0.2,0.2]}
        \\   ],
        \\   "mSpellCalculations":{"PDamage":{"mFormulaParts":[
        \\     {"__type":"NamedDataValueCalculationPart","mDataValue":"PBase"},
        \\     {"__type":"StatByNamedDataValueCalculationPart","mDataValue":"APRatio","mStat":2}
        \\   ]}}
        \\ }},
        \\ "Characters/Kaisa/Spells/KaisaWAbility/KaisaW":{"mSpell":{
        \\   "DataValues":[{"name":"WBase","values":[20,45,70]}]
        \\ }}}
    ;
    var output: [4096]u8 = undefined;
    const json = try writeValues("Kaisa", body, &output);
    // `mStat:2` = 攻击力（官方枚举），不是名字里的 `AP`——枚举优先。
    try std.testing.expect(std.mem.indexOf(u8, json, "\"spell.KaisaPassive:PDamage\":{\"values\":[15,20,25,30,35],\"ratio\":0.2000,\"ratioStat\":\"AD\"}") != null);
}


test "字面系数型的加成不能整块丢掉（瑞兹 Q = 55% 法术强度 + 2% 最大法力值）" {
    // 真机数据（2026-10-03 拉 CDragon 逐条核对）：
    //
    //   QDamageCalc.mFormulaParts = [
    //     {NamedDataValue: BaseDamage},
    //     {StatByCoefficient: 0.55},                              ← 法术强度（没写属性）
    //     {AbilityResourceByCoefficient: 0.02, mStatFormula: 2},   ← 最大法力值
    //   ]
    //
    // 旧逻辑只认 `StatByNamedDataValueCalculationPart`，这两段**全被跳过**，
    // 于是面板上「伤害加成」那一块是空的（用户报的「加成怎么全没了」）。
    const body =
        \\{"Characters/Ryze/CharacterRecords/Root":{"spells":["Characters/Ryze/Spells/RyzeQAbility/RyzeQ"]},
        \\ "Characters/Ryze/Spells/RyzeQAbility/RyzeQ":{"mSpell":{
        \\   "DataValues":[{"name":"BaseDamage","values":[55,75,95,115,135,155,175]}],
        \\   "mSpellCalculations":{"QDamageCalc":{"mFormulaParts":[
        \\     {"__type":"NamedDataValueCalculationPart","mDataValue":"BaseDamage"},
        \\     {"__type":"StatByCoefficientCalculationPart","mCoefficient":0.55},
        \\     {"__type":"AbilityResourceByCoefficientCalculationPart","mCoefficient":0.02,"mStatFormula":2}
        \\   ]}}
        \\ }}}
    ;
    var output: [4096]u8 = undefined;
    const json = try writeValues("Ryze", body, &output);
    // 第一段仍写在老字段（`ratio` / `ratioStat`）里——兼容面不能断；
    // 第二段走 `ratioItems`，两段都不能少。
    try std.testing.expect(std.mem.indexOf(u8, json, "\"QDamageCalc\":{\"values\":[55,75,95,115,135,155,175],\"ratio\":0.5500,\"ratioStat\":\"AP\",\"ratioItems\":[{\"ratio\":0.5500,\"stat\":\"AP\"},{\"ratio\":0.0200,\"stat\":\"MaxMana\"}]}") != null);
}

test "一条公式里的多段加成一段都不能丢（艾瑞莉娅 W = 40% 攻击力 + 50% 法术强度）" {
    // 真机 `MinDamageCalc` = 基础值 + `{mStat:2, 0.4}` + `{0.5}`：
    // 客户端文案正是「+40% 攻击力 +50% 法术强度」两段并写——裸系数那段是法强。
    // 这正是「裸系数 = 法术强度」这条判据的来源（沃里克 Q 的 `{1.0}` 同理）。
    const body =
        \\{"Characters/Irelia/CharacterRecords/Root":{"spells":["Characters/Irelia/Spells/IreliaWAbility/IreliaW"]},
        \\ "Characters/Irelia/Spells/IreliaWAbility/IreliaW":{"mSpell":{
        \\   "DataValues":[{"name":"MinDamage","values":[10,25,40,55,70]}],
        \\   "mSpellCalculations":{"MinDamageCalc":{"mFormulaParts":[
        \\     {"__type":"NamedDataValueCalculationPart","mDataValue":"MinDamage"},
        \\     {"__type":"StatByCoefficientCalculationPart","mCoefficient":0.4,"mStat":2},
        \\     {"__type":"StatByCoefficientCalculationPart","mCoefficient":0.5}
        \\   ]}}
        \\ }}}
    ;
    var output: [4096]u8 = undefined;
    const json = try writeValues("Irelia", body, &output);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"MinDamageCalc\":{\"values\":[10,25,40,55,70],\"ratio\":0.4000,\"ratioStat\":\"AD\",\"ratioItems\":[{\"ratio\":0.4000,\"stat\":\"AD\"},{\"ratio\":0.5000,\"stat\":\"AP\"}]}") != null);
}

test "系数写了属性但枚举认不出时，只给数字、不乱贴属性名" {
    // `mStat: 4` 不在已确认的枚举里（实测 Varus 的 `MinionAD` 用的就是 4）。
    // 宁可只显示「+1」也不写一个可能错的属性名。
    const body =
        \\{"Characters/Varus/CharacterRecords/Root":{"spells":["Characters/Varus/Spells/VarusWAbility/VarusW"]},
        \\ "Characters/Varus/Spells/VarusWAbility/VarusW":{"mSpell":{
        \\   "DataValues":[{"name":"MinionDamage","values":[40,80,120,160,200]}],
        \\   "mSpellCalculations":{"TotalDamage":{"mFormulaParts":[
        \\     {"__type":"NamedDataValueCalculationPart","mDataValue":"MinionDamage"},
        \\     {"__type":"StatByCoefficientCalculationPart","mCoefficient":1,"mStat":4}
        \\   ]}}
        \\ }}}
    ;
    var output: [4096]u8 = undefined;
    const json = try writeValues("Varus", body, &output);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"TotalDamage\":{\"values\":[40,80,120,160,200],\"ratio\":1}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "ratioStat") == null);
}

test "系数为 0 的那一段不列出来（CDragon 里有 0 占位）" {
    const body =
        \\{"Characters/X/CharacterRecords/Root":{"spells":["Characters/X/Spells/Q"]},
        \\ "Characters/X/Spells/Q":{"mSpell":{
        \\   "DataValues":[{"name":"TotalDamage","values":[100,150,200]}],
        \\   "mSpellCalculations":{"TotalDamage":{"mFormulaParts":[
        \\     {"__type":"NamedDataValueCalculationPart","mDataValue":"TotalDamage"},
        \\     {"__type":"StatByCoefficientCalculationPart","mCoefficient":0}
        \\   ]}}
        \\ }}}
    ;
    var output: [2048]u8 = undefined;
    const json = try writeValues("X", body, &output);
    // 只有基础值，没有 ratio 那一串。
    try std.testing.expect(std.mem.indexOf(u8, json, "\"TotalDamage\":{\"values\":[100,150,200]}") != null);
}

test "乘积段算得出来：拉莫斯 W 的 @BonusArmorTooltip@ 不再消失" {
    // 用户 2026-10-03 报的「有些地方还是不行」——W 的文案里
    // `@BonusArmorTooltip@` / `@BonusMRTooltip@` 一直以字面量印出来。
    //
    // 真因不是文案也不是 LCU，是**公式形状**：
    //
    //   BonusArmorTooltip = ProductOfSubParts(
    //       FlatBonusArmor,                            // [22,27,32,37,42,47,52]
    //       SumOfSubParts([1.0, BonusArmorPercent])    // 1 + 0.225 … 0.675
    //     )
    //     + StatByNamedDataValue(护甲, BonusArmorPercent)
    //
    // 首段是 `ProductOfSubParts`，以前整类被跳过 → 这一项算不出 `base` →
    // **整个变量从结果里消失** → 前端只能把占位符原样印出来。
    // 注意它前半段**不依赖任何实时属性**（两个数据值都是本技能的逐级数据），
    // 所以能精确算出来；后半段才是「按当前护甲算」的那部分。
    const body =
        \\{"Characters/Rammus/CharacterRecords/Root":{
        \\   "spells":["Characters/Rammus/Spells/DefensiveBallCurlAbility/DefensiveBallCurl"]
        \\ },
        \\ "Characters/Rammus/Spells/DefensiveBallCurlAbility/DefensiveBallCurl":{"mSpell":{
        \\   "DataValues":[
        \\     {"name":"FlatBonusArmor","values":[22,27,32,37,42,47,52]},
        \\     {"name":"BonusArmorPercent","values":[0.22499999403953552,0.30000001192092896,0.375,0.44999998807907104,0.5249999761581421,0.6000000238418579,0.675000011920929]}
        \\   ],
        \\   "mSpellCalculations":{"BonusArmorTooltip":{"mFormulaParts":[
        \\     {"__type":"ProductOfSubPartsCalculationPart",
        \\      "mPart1":{"__type":"NamedDataValueCalculationPart","mDataValue":"FlatBonusArmor"},
        \\      "mPart2":{"__type":"SumOfSubPartsCalculationPart","mSubparts":[
        \\        {"__type":"NumberCalculationPart","mNumber":1.0},
        \\        {"__type":"NamedDataValueCalculationPart","mDataValue":"BonusArmorPercent"}
        \\      ]}},
        \\     {"__type":"StatByNamedDataValueCalculationPart","mStat":1,"mDataValue":"BonusArmorPercent"}
        \\   ]}}
        \\ }}}
    ;
    var output: [8192]u8 = undefined;
    const json = try writeValues("Rammus", body, &output);
    // 基础值逐级算出来（22×1.225 … 52×1.675），加成是**逐级**的百分比。
    // ⚠️ 数值写法看 `Writer.writeFloat`：整数写整数形式（`44`），其余补到 4 位小数
    //    （`26.9500`）——**不**裁掉末尾的 0。
    try std.testing.expect(std.mem.indexOf(u8, json, "\"BonusArmorTooltip\":{\"values\":[26.9500,35.1000,44,53.6500,64.0500,75.2000,87.1000],\"ratio\":0.2250,\"ratios\":[0.2250,0.3000,0.3750,0.4500,0.5250,0.6000,0.6750],\"ratioStat\":\"Armor\"}") != null);
}

test "乘积段里有实时属性插值时整段放弃，不编一个数" {
    // 只有「能精确算出来」的乘积段才采纳。混进
    // `ByCharLevelInterpolationCalculationPart`（随英雄等级插值）就返回 null——
    // 宁可这一项仍然缺席（UI 上表现为占位符原样保留），也不能给一个错的数。
    const body =
        \\{"Characters/X/CharacterRecords/Root":{"spells":["Characters/X/Spells/Q"]},
        \\ "Characters/X/Spells/Q":{"mSpell":{
        \\   "DataValues":[{"name":"BaseValue","values":[10,20,30]}],
        \\   "mSpellCalculations":{"ScaledTooltip":{"mFormulaParts":[
        \\     {"__type":"ProductOfSubPartsCalculationPart",
        \\      "mPart1":{"__type":"NamedDataValueCalculationPart","mDataValue":"BaseValue"},
        \\      "mPart2":{"__type":"ByCharLevelInterpolationCalculationPart","mStartValue":0.25,"mEndValue":0.391}}
        \\   ]}}
        \\ }}}
    ;
    var output: [2048]u8 = undefined;
    const json = try writeValues("X", body, &output);
    try std.testing.expect(std.mem.indexOf(u8, json, "ScaledTooltip") == null);
    // 本技能的逐级数据值照旧要给（那是 DataValue，不是公式）
    try std.testing.expect(std.mem.indexOf(u8, json, "\"BaseValue\":{\"values\":[10,20,30]}") != null);
}
