//! 玩家标记（tagged）：本地玩家为其他玩家写下的一行备注。
//!
//! 对齐 LeagueAkari 的 `saved-player` 标签语义，但这里归属于本机数据库：
//! 存储键同时带上「谁写的」和「写给谁」（`self|target`），所以多个账号共用
//! 同一个 SQLite 也不会互相覆盖，也不需要依赖当前大区/账号作用域。
//! 备注以 `{"notes":[...]}` 存放，读写都会做长度与条数收敛，脏数据一律
//! 退化成「没有备注」而不是让整页报错。
const std = @import("std");
const storage = @import("storage");

/// 快照 kind；`storage.scopedKind` 把它当作公共 kind，不参与账号作用域。
pub const kind = "playerTag";
/// 单条备注的字节上限（超出按 UTF-8 边界截断）。
///
/// 前端 `tags/notes.ts` 的 `MAX_TAG_NOTE_LENGTH = 120` 按 UTF-16 码元计数，
/// 而 UTF-8 对基本平面字符最多 3 字节/码元，因此 120 * 3 = 360 可以保证
/// 「前端允许输入的内容，后端不会二次截断」。两边改动需同步。
pub const max_note_bytes = 360;
/// 每位玩家最多保留的备注条数。
pub const max_notes = 8;

/// 存储键：写入者与目标玩家共同决定，避免多账号串备注。
pub fn makeKey(allocator: std.mem.Allocator, self_puuid: []const u8, target_puuid: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}|{s}", .{ self_puuid, target_puuid });
}

fn truncateUtf8(value: []const u8, limit: usize) []const u8 {
    if (value.len <= limit) return value;
    var end = limit;
    // 不要把一个多字节字符切成两半。
    while (end > 0 and (value[end] & 0xC0) == 0x80) end -= 1;
    return value[0..end];
}

fn cleaned(note: []const u8) []const u8 {
    return truncateUtf8(std.mem.trim(u8, note, " \t\r\n"), max_note_bytes);
}

/// 读取「self 写给 target」的备注。缺键、脏数据、空 puuid 都返回空列表。
/// 返回的切片指向 `arena`，随调用方的 arena 一起释放。
pub fn read(
    store: *storage.Store,
    arena: std.mem.Allocator,
    self_puuid: []const u8,
    target_puuid: []const u8,
) ![]const []const u8 {
    if (self_puuid.len == 0 or target_puuid.len == 0) return &.{};

    const key = try makeKey(arena, self_puuid, target_puuid);
    const raw = (try store.get(kind, key)) orelse return &.{};
    defer store.allocator.free(raw);

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch return &.{};
    if (parsed != .object) return &.{};
    const notes_value = parsed.object.get("notes") orelse return &.{};
    if (notes_value != .array) return &.{};

    const items = notes_value.array.items;
    const limit = @min(items.len, max_notes);
    if (limit == 0) return &.{};

    const output = try arena.alloc([]const u8, limit);
    var count: usize = 0;
    for (items) |item| {
        if (count >= limit) break;
        if (item != .string) continue;
        const value = cleaned(item.string);
        if (value.len == 0) continue;
        output[count] = value;
        count += 1;
    }
    return output[0..count];
}

/// 写回备注：丢弃空白项、按 UTF-8 边界截断超长文本、忽略超出条数的部分。
/// 清洗后为空时写入空数组（语义是「清空备注」，保留更新时间便于前端刷新）。
pub fn write(
    store: *storage.Store,
    arena: std.mem.Allocator,
    self_puuid: []const u8,
    target_puuid: []const u8,
    notes: []const []const u8,
) ![]const []const u8 {
    if (self_puuid.len == 0 or target_puuid.len == 0) return error.PlayerTagUnavailable;

    // 结果切片必须活过本函数（调用方会继续遍历），因此放在 arena 上，
    // 不能返回指向栈上数组的切片。
    const kept = try arena.alloc([]const u8, max_notes);
    var count: usize = 0;
    for (notes) |note| {
        if (count >= max_notes) break;
        const value = cleaned(note);
        if (value.len == 0) continue;
        kept[count] = value;
        count += 1;
    }

    // JSON 转义最坏情况是一个字节膨胀成 `\u00XX`（6 字节），按上限预留，
    // 避免超长控制字符输入把序列化顶成 NoSpaceLeft。
    const buffer = try arena.alloc(u8, max_notes * (max_note_bytes * 6 + 8) + 32);
    var writer = std.Io.Writer.fixed(buffer);
    try writer.writeAll("{\"notes\":[");
    for (kept[0..count], 0..) |note, index| {
        if (index > 0) try writer.writeByte(',');
        var stringify = std.json.Stringify{ .writer = &writer, .options = .{} };
        try stringify.write(note);
    }
    try writer.writeAll("]}");

    const key = try makeKey(arena, self_puuid, target_puuid);
    try store.put(kind, key, writer.buffered());
    return kept[0..count];
}

/// 已保存备注的更新时间（秒），用于前端判断是否需要重新拉取。
pub fn updatedAt(store: *storage.Store, arena: std.mem.Allocator, self_puuid: []const u8, target_puuid: []const u8) !i64 {
    if (self_puuid.len == 0 or target_puuid.len == 0) return 0;
    const key = try makeKey(arena, self_puuid, target_puuid);
    return (try store.getUpdatedAt(kind, key)) orelse 0;
}

test "备注按写入者隔离，并做长度与条数清洗" {
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, ":memory:");
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqual(@as(usize, 0), (try read(&store, allocator, "self-a", "target-a")).len);

    const saved = try write(&store, allocator, "self-a", "target-a", &.{ " 爱打野 ", "", "挂机过" });
    try std.testing.expectEqual(@as(usize, 2), saved.len);
    try std.testing.expectEqualStrings("爱打野", saved[0]);
    try std.testing.expectEqualStrings("挂机过", saved[1]);

    const loaded = try read(&store, allocator, "self-a", "target-a");
    try std.testing.expectEqual(@as(usize, 2), loaded.len);
    try std.testing.expectEqualStrings("挂机过", loaded[1]);
    try std.testing.expect((try updatedAt(&store, allocator, "self-a", "target-a")) > 0);

    // 别人的备注不会串过来。
    try std.testing.expectEqual(@as(usize, 0), (try read(&store, allocator, "self-b", "target-a")).len);

    // 清空后仍可读，只是没有条目。
    _ = try write(&store, allocator, "self-a", "target-a", &.{"   "});
    try std.testing.expectEqual(@as(usize, 0), (try read(&store, allocator, "self-a", "target-a")).len);
}

test "超长备注按 UTF-8 边界截断且条数收敛" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const long = try allocator.alloc(u8, max_note_bytes + 40);
    // 全部填充三字节字符，保证截断点一定落在字符中间。
    for (long, 0..) |*byte, index| byte.* = if (index % 3 == 0) 0xE4 else 0xBD;
    long[long.len - 1] = 0x80;

    var store = try storage.Store.open(std.testing.allocator, std.testing.io, ":memory:");
    defer store.deinit();

    const many = try allocator.alloc([]const u8, max_notes + 3);
    for (many) |*note| note.* = "重复备注";
    many[0] = long;

    const saved = try write(&store, allocator, "self-a", "target-a", many);
    try std.testing.expectEqual(@as(usize, max_notes), saved.len);
    try std.testing.expect(saved[0].len <= max_note_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(saved[0]));
}
