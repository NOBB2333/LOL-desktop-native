//! 英雄技能详情：把 LCU 的单英雄资料文件压成界面能直接渲染的形状。
//!
//! # 数据来源
//!
//! `GET /lol-game-data/assets/v1/champions/{id}.json`——**LCU 本地就有**（不是公网），
//! 而且 LCU 会把技能名和描述**按客户端语言本地化好**再给你。用户在国服看到的就是中文技能名，
//! 不需要我们维护任何翻译表。
//!
//! # 为什么不用 CommunityDragon 的 `<alias>.bin.json`
//!
//! 那条路能拿到 AD/AP 加成公式（`mSpellCalculations[].mFormulaParts[]` 里有
//! `mCoefficient`），但有两个问题：
//!  1. **技能顺序拿不到**。技能所在的文件夹名是随意的——Olaf 的 Q 在
//!     `OlafAxeThrowCastAbility`、Cho'Gath 的 R 在 `FeastAbility`、Singed 的 Q 在
//!     `PoisonTrailAbility`。按 `<英雄><槽位>Ability` 去猜，245 个英雄里 115 个猜不中。
//!     真正有序的列表在 `Characters/<Champ>/CharacterRecords/Root.spells` 里，
//!     但那是**另一条请求**（每个英雄 ~60KB）。
//!  2. **没有中文**。CommunityDragon 的 `lol.stringtable.json`（31MB）**只有 en_us**，
//!     zh_cn 目录存在但里面是空的。
//!
//! 而 LCU 这份文件里 `spells[].spellKey` 直接就是 `q`/`w`/`e`/`r`，名字和描述也已本地化。
//! 所以以它为主。加成公式（AD/AP 系数）**本来就不展示**——见下面的「不做的部分」。
//!
//! # 不做的部分
//!
//! LCU 这份文件里 `coefficients` 全是 0、`effectAmounts` 也基本是占位（官方客户端里这些
//! 数值是**客户端自己算**的）。真实的每级伤害只存在于 CommunityDragon 的
//! `mSpellCalculations` 里。所以这里**只输出「文案 + 冷却 + 耗蓝 + 射程 + 图标 + 视频」**，
//! 不输出每级伤害数字——宁可少给，也不能给一个编出来的数。
const std = @import("std");
const native_sdk = @import("native_sdk");
const backend = @import("../backend.zig");

/// 落盘缓存键的版本前缀。**输出形状一变就要 +1**，理由同 `timeline.zig`：
/// 缓存存的是整份输出 JSON、没有版本字段，旧条目会被一直读回来（而且不报错）。
const ability_cache_prefix = "v1:";

/// 只认识这四个槽位。被动单独走 `passive` 字段。
const slot_keys = [_][]const u8{ "q", "w", "e", "r" };

/// `lol.get_champion_abilities` —— 单个英雄的技能详情。
///
/// payload：`{championId}`。取不到就报错（不打 fixture 兜底）：前端要能区分
/// 「这个英雄没有技能数据」和「客户端没开」。
pub fn getChampionAbilities(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = backend.runtime(context);
    const payload_json = backend.parsePayload(struct { championId: i64 = 0 }, invocation.request.payload) catch return error.InvalidRequest;
    defer payload_json.deinit();
    if (payload_json.value.championId <= 0) return error.InvalidRequest;
    const champion_id = payload_json.value.championId;

    var key_buffer: [32]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buffer, ability_cache_prefix ++ "{d}", .{champion_id}) catch return error.AbilityUnavailable;
    // 一个英雄的技能资料只随补丁变，落盘缓存可以直接当权威。
    if (self.storage) |*store| if (store.get("championAbilities", key) catch null) |cached| {
        defer std.heap.page_allocator.free(cached);
        if (cached.len > 0 and cached.len <= output.len) {
            @memcpy(output[0..cached.len], cached);
            return output[0..cached.len];
        }
    };

    if (self.mode != .live) return error.AbilityUnavailable;
    var client = backend.discoverClient(self, self.io orelse return error.LcuNotRunning) catch return error.LcuNotRunning;
    defer client.deinit();

    var path_buffer: [96]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "/lol-game-data/assets/v1/champions/{d}.json", .{champion_id}) catch return error.AbilityUnavailable;
    const raw = client.get(path) catch return error.LcuRequestFailed;
    defer std.heap.page_allocator.free(raw);

    const dto = try writeAbilities(raw, output);
    if (self.storage) |*store| store.put("championAbilities", key, dto) catch {};
    return dto;
}

/// 把 LCU 的单英雄资料压成技能 DTO。
///
/// 输出形状（前端 `ChampionAbilities`）：
/// ```
/// {
///   "championId": 103, "alias": "Ahri", "name": "九尾妖狐",
///   "passive": { "name": "摄魂夺魄", "description": "...", "iconPath": "/lol-game-data/..." },
///   "spells": [ { "slot": "q", "name": "欺诈宝珠", "description": "...",
///                 "dynamicDescription": "...", "cooldown": [7,7,7,7,7], "cost": [55,65,75,85,95],
///                 "range": [970,...], "iconPath": "...", "videoPath": "...", "videoImagePath": "..." } ]
/// }
/// ```
/// `cooldown` / `cost` / `range` 是**按技能等级**的数组（1..5 级），长度可能是 5 或 6——
/// 原样带出，前端按索引取，不在这里补齐或截断（补齐等于编数据）。
pub fn writeAbilities(champion_json: []const u8, output: []u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = std.json.parseFromSliceLeaky(std.json.Value, allocator, champion_json, .{}) catch return error.LcuInvalidResponse;
    if (root != .object) return error.LcuInvalidResponse;

    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll("{\"championId\":");
    try writer.print("{d}", .{jsonInt(root, "id")});
    try writer.writeAll(",\"alias\":");
    try jsonString(&writer, jsonField(root, "alias"));
    try writer.writeAll(",\"name\":");
    try jsonString(&writer, jsonField(root, "name"));
    try writer.writeAll(",\"title\":");
    try jsonString(&writer, jsonField(root, "title"));

    try writer.writeAll(",\"passive\":");
    try writePassive(&writer, root);
    try writer.writeAll(",\"spells\":[");
    var first = true;
    if (root.object.get("spells")) |spells| if (spells == .array) {
        for (spells.array.items) |spell| {
            // `spellKey` 是唯一的槽位真源；拿不到就跳过（宁可少一个技能也不猜顺序）。
            const slot = jsonField(spell, "spellKey");
            if (!isSlot(slot)) continue;
            if (!first) try writer.writeByte(',');
            first = false;
            try writeSpell(&writer, spell, slot);
        }
    };
    try writer.writeAll("]}");
    return writer.buffered();
}

fn isSlot(value: []const u8) bool {
    for (slot_keys) |candidate| if (std.ascii.eqlIgnoreCase(candidate, value)) return true;
    return false;
}

fn writePassive(writer: *std.Io.Writer, root: std.json.Value) !void {
    if (root != .object) return writer.writeAll("null");
    const passive = root.object.get("passive") orelse return writer.writeAll("null");
    if (passive != .object) return writer.writeAll("null");
    const name = jsonField(passive, "name");
    if (name.len == 0) return writer.writeAll("null");
    try writer.writeAll("{\"name\":");
    try jsonString(writer, name);
    try writer.writeAll(",\"description\":");
    try jsonString(writer, jsonField(passive, "description"));
    try writer.writeAll(",\"iconPath\":");
    try jsonString(writer, jsonField(passive, "abilityIconPath"));
    try writer.writeAll(",\"videoPath\":");
    try jsonString(writer, jsonField(passive, "abilityVideoPath"));
    try writer.writeAll(",\"videoImagePath\":");
    try jsonString(writer, jsonField(passive, "abilityVideoImagePath"));
    try writer.writeByte('}');
}

fn writeSpell(writer: *std.Io.Writer, spell: std.json.Value, slot: []const u8) !void {
    try writer.writeAll("{\"slot\":");
    try jsonString(writer, slot);
    try writer.writeAll(",\"name\":");
    try jsonString(writer, jsonField(spell, "name"));
    try writer.writeAll(",\"description\":");
    try jsonString(writer, jsonField(spell, "description"));
    try writer.writeAll(",\"dynamicDescription\":");
    try jsonString(writer, jsonField(spell, "dynamicDescription"));
    try writer.writeAll(",\"cooldown\":");
    try writeIntArray(writer, spell, "cooldownCoefficients");
    try writer.writeAll(",\"cost\":");
    try writeIntArray(writer, spell, "costCoefficients");
    try writer.writeAll(",\"range\":");
    try writeIntArray(writer, spell, "range");
    try writer.writeAll(",\"iconPath\":");
    try jsonString(writer, jsonField(spell, "abilityIconPath"));
    try writer.writeAll(",\"videoPath\":");
    try jsonString(writer, jsonField(spell, "abilityVideoPath"));
    try writer.writeAll(",\"videoImagePath\":");
    try jsonString(writer, jsonField(spell, "abilityVideoImagePath"));
    try writer.writeByte('}');
}

/// 原样写出一个数字数组。缺字段 → `[]`（不是 `[0,0,0]`：那些 0 会被当成真数据画出来）。
fn writeIntArray(writer: *std.Io.Writer, object: std.json.Value, name: []const u8) !void {
    try writer.writeByte('[');
    if (object == .object) if (object.object.get(name)) |value| if (value == .array) {
        var first = true;
        for (value.array.items) |item| {
            const number: f64 = switch (item) {
                .integer => |int| @floatFromInt(int),
                .float => |float| float,
                else => continue,
            };
            if (!first) try writer.writeByte(',');
            first = false;
            // 冷却可能是 0.5 秒（亚索 E 前几级），所以按小数写；整数就写成整数。
            if (number == @floor(number)) try writer.print("{d}", .{@as(i64, @intFromFloat(number))}) else try writer.print("{d}", .{number});
        }
    };
    try writer.writeByte(']');
}

fn jsonInt(value: std.json.Value, name: []const u8) i64 {
    if (value != .object) return 0;
    const item = value.object.get(name) orelse return 0;
    return switch (item) {
        .integer => |number| number,
        .float => |number| @intFromFloat(number),
        else => 0,
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

const ahri_fixture =
    \\{"id":103,"name":"九尾妖狐","alias":"Ahri","title":"九尾妖狐",
    \\"passive":{"name":"摄魂夺魄","description":"阿狸用技能命中敌人后会获得一层[摄魂夺魄]。","abilityIconPath":"/lol-game-data/assets/ASSETS/Characters/Ahri/HUD/Icons2D/Icons_Ahri_Passive.png","abilityVideoPath":"champion-abilities/0103/ability_0103_P1.webm","abilityVideoImagePath":"champion-abilities/0103/ability_0103_P1.jpg"},
    \\"spells":[{"spellKey":"q","name":"欺诈宝珠","description":"阿狸掷出宝珠并收回。","dynamicDescription":"造成 <magicDamage>@TotalDamage@ 魔法伤害</magicDamage>。","cooldownCoefficients":[7,7,7,7,7],"costCoefficients":[55,65,75,85,95],"range":[970,970,970,970,970],"abilityIconPath":"/lol-game-data/assets/ASSETS/Characters/Ahri/HUD/Icons2D/Icons_Ahri_Q.png","abilityVideoPath":"champion-abilities/0103/ability_0103_Q1.webm","abilityVideoImagePath":"champion-abilities/0103/ability_0103_Q1.jpg"}]}
;

test "把 LCU 的单英雄资料压成技能 DTO（含被动与 Q）" {
    var output: [4096]u8 = undefined;
    const result = try writeAbilities(ahri_fixture, &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    const root = parsed.value;
    try std.testing.expectEqual(@as(i64, 103), jsonInt(root, "championId"));
    try std.testing.expectEqualStrings("Ahri", jsonField(root, "alias"));
    // 被动单独一块，技能名是本地化过的。
    const passive = root.object.get("passive").?;
    try std.testing.expectEqualStrings("摄魂夺魄", jsonField(passive, "name"));
    // 四个槽位里只有 Q 有数据 → 只输出一条，不补空槽。
    const spells = root.object.get("spells").?;
    try std.testing.expectEqual(@as(usize, 1), spells.array.items.len);
    const q = spells.array.items[0];
    try std.testing.expectEqualStrings("q", jsonField(q, "slot"));
    try std.testing.expectEqualStrings("欺诈宝珠", jsonField(q, "name"));
    // 每级数组原样带出。
    try std.testing.expectEqual(@as(usize, 5), q.object.get("cooldown").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 7), q.object.get("cooldown").?.array.items[0].integer);
    try std.testing.expectEqual(@as(i64, 55), q.object.get("cost").?.array.items[0].integer);
    try std.testing.expectEqual(@as(i64, 970), q.object.get("range").?.array.items[0].integer);
}

test "槽位顺序跟 spellKey 走，不按数组下标猜" {
    // 故意把 R 放第一个：老代码按 `spells[0]` 当 Q 的话这里就会错。
    const shuffled =
        \\{"id":1,"alias":"X","name":"试验英雄","passive":null,
        \\"spells":[{"spellKey":"r","name":"大招","cooldownCoefficients":[100,90,80],"costCoefficients":[100,100,100],"range":[1000]},
        \\           {"spellKey":"q","name":"一技能","cooldownCoefficients":[5],"costCoefficients":[10],"range":[500]}]}
    ;
    var output: [2048]u8 = undefined;
    const result = try writeAbilities(shuffled, &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    const spells = parsed.value.object.get("spells").?;
    try std.testing.expectEqualStrings("r", jsonField(spells.array.items[0], "slot"));
    try std.testing.expectEqualStrings("q", jsonField(spells.array.items[1], "slot"));
    try std.testing.expectEqualStrings("大招", jsonField(spells.array.items[0], "name"));
}

test "没有 spellKey 的条目整条丢掉，不去猜它是哪个槽" {
    const junk =
        \\{"id":2,"alias":"Y","name":"乱七八糟","spells":[{"name":"没槽位"},{"spellKey":"q","name":"真 Q","cooldownCoefficients":[4],"costCoefficients":[1],"range":[1]}]}
    ;
    var output: [2048]u8 = undefined;
    const result = try writeAbilities(junk, &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    const spells = parsed.value.object.get("spells").?;
    // 只剩 Q 一条，而且它是**原样那条**（不是被撑到 4 个槽）。
    try std.testing.expectEqual(@as(usize, 1), spells.array.items.len);
    try std.testing.expectEqualStrings("真 Q", jsonField(spells.array.items[0], "name"));
    try std.testing.expectEqualStrings("null", if (parsed.value.object.get("passive").? == .null) "null" else "not-null");
}

test "缺字段写成空数组 / 空串，而不是 0 把「不知道」顶替掉" {
    const sparse =
        \\{"id":3,"alias":"Z","name":"缺字段","spells":[{"spellKey":"w","name":"W"}]}
    ;
    var output: [2048]u8 = undefined;
    const result = try writeAbilities(sparse, &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    const w = parsed.value.object.get("spells").?.array.items[0];
    try std.testing.expectEqual(@as(usize, 0), w.object.get("cooldown").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), w.object.get("range").?.array.items.len);
    try std.testing.expectEqualStrings("", jsonField(w, "description"));
    // 文本字段是空串不是 null：前端 `??` 兜不住的 null 会渲成 "null"。
    try std.testing.expect(w.object.get("description").? == .string);
}

test "冷却里的 0.5 秒（亚索 E）不能被取整成 0" {
    const fractional =
        \\{"id":4,"alias":"W","name":"亚索","spells":[{"spellKey":"e","name":"踏前斩","cooldownCoefficients":[0.5,0.5,0.4,0.3,0.2,0.1],"costCoefficients":[0],"range":[475]}]}
    ;
    var output: [2048]u8 = undefined;
    const result = try writeAbilities(fractional, &output);
    // 直接看原始文本：0.5 必须还在（被归成 0 的话这条断言会红）。
    try std.testing.expect(std.mem.indexOf(u8, result, "\"cooldown\":[0.5,0.5,0.4,0.3,0.2,0.1]") != null);
}

test "不是对象 / 结构不对时明确报错，不返回半个 JSON" {
    var output: [256]u8 = undefined;
    try std.testing.expectError(error.LcuInvalidResponse, writeAbilities("[]", &output));
    try std.testing.expectError(error.LcuInvalidResponse, writeAbilities("not json", &output));
}
