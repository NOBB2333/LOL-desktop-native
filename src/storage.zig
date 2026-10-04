//! Small application-owned SQLite repository.
//! The Native SDK relational store is used for runtime migrations; this
//! repository keeps bridge DTO snapshots in a stable, app-scoped database.
const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Store = struct {
    allocator: std.mem.Allocator,
    db: *c.sqlite3,
    path: [:0]u8,
    scope: [256]u8 = undefined,
    scope_len: usize = 0,
    require_scope: bool = false,

    pub fn setScope(self: *Store, platform: []const u8, owner: []const u8) !void {
        self.scope_len = 0;
        if (platform.len == 0 or owner.len == 0) return;
        const region = if (std.ascii.startsWithIgnoreCase(platform, "TENCENT_")) platform[8..] else platform;
        const value = try std.fmt.bufPrint(&self.scope, "{s}/{s}", .{ region, owner });
        for (value) |*byte| byte.* = std.ascii.toLower(byte.*);
        self.scope_len = value.len;
    }

    fn scopedKind(self: *const Store, kind: []const u8, buffer: []u8) ![]const u8 {
        // 配置和公共静态资源仍共用；玩家及对局缓存必须绑定账号和大区。
        // 玩家标记的键自带「谁写的」，因此同样不需要账号作用域。
        if (std.mem.eql(u8, kind, "config") or std.mem.eql(u8, kind, "settings") or
            std.mem.eql(u8, kind, "cache") or std.mem.eql(u8, kind, "playerTag")) return kind;
        if (self.scope_len == 0) return if (self.require_scope) error.CacheScopeUnavailable else kind;
        return std.fmt.bufPrint(buffer, "{s}/{s}", .{ kind, self.scope[0..self.scope_len] });
    }

    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Store {
        const dir = std.fs.path.dirname(path) orelse ".";
        std.Io.Dir.cwd().createDirPath(io, dir) catch return error.OpenFailed;
        const path_z = try allocator.dupeZ(u8, path);
        errdefer allocator.free(path_z);
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(path_z.ptr, &db, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX, null);
        if (rc != c.SQLITE_OK or db == null) {
            if (db) |handle| _ = c.sqlite3_close(handle);
            return error.OpenFailed;
        }
        errdefer _ = c.sqlite3_close(db.?);
        var store = Store{ .allocator = allocator, .db = db.?, .path = path_z };
        // 富化线程、阵容 lane、资料发布都会并发写这唯一一条连接；250ms 的
        // 超时让大快照的写静默失败，放宽到 3s 让写真正排在锁上等。
        try store.exec("PRAGMA journal_mode=WAL; PRAGMA busy_timeout=3000;");
        try store.exec("CREATE TABLE IF NOT EXISTS snapshots (kind TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, updated_at INTEGER NOT NULL, PRIMARY KEY(kind,key));");
        return store;
    }

    pub fn deinit(self: *Store) void {
        _ = c.sqlite3_close(self.db);
        self.allocator.free(self.path);
    }

    pub fn put(self: *Store, kind: []const u8, key: []const u8, value: []const u8) !void {
        var kind_buffer: [512]u8 = undefined;
        const scoped_kind = try self.scopedKind(kind, &kind_buffer);
        const sql = "INSERT INTO snapshots(kind,key,value,updated_at) VALUES(?1,?2,?3,unixepoch()) ON CONFLICT(kind,key) DO UPDATE SET value=excluded.value,updated_at=excluded.updated_at;";
        var statement: ?*c.sqlite3_stmt = null;
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        if (c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &statement, null) != c.SQLITE_OK) return error.QueryFailed;
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement.?, 1, scoped_kind);
        try bindText(statement.?, 2, key);
        try bindText(statement.?, 3, value);
        if (c.sqlite3_step(statement.?) != c.SQLITE_DONE) return error.QueryFailed;
    }

    pub fn get(self: *Store, kind: []const u8, key: []const u8) !?[]u8 {
        var kind_buffer: [512]u8 = undefined;
        const scoped_kind = self.scopedKind(kind, &kind_buffer) catch |err| return if (err == error.CacheScopeUnavailable) null else err;
        const sql = "SELECT value FROM snapshots WHERE kind=?1 AND key=?2;";
        var statement: ?*c.sqlite3_stmt = null;
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        if (c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &statement, null) != c.SQLITE_OK) return error.QueryFailed;
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement.?, 1, scoped_kind);
        try bindText(statement.?, 2, key);
        if (c.sqlite3_step(statement.?) != c.SQLITE_ROW) return null;
        const ptr = c.sqlite3_column_text(statement.?, 0) orelse return null;
        const len = c.sqlite3_column_bytes(statement.?, 0);
        return try self.allocator.dupe(u8, ptr[0..@intCast(len)]);
    }

    pub fn getUpdatedAt(self: *Store, kind: []const u8, key: []const u8) !?i64 {
        var kind_buffer: [512]u8 = undefined;
        const scoped_kind = self.scopedKind(kind, &kind_buffer) catch |err| return if (err == error.CacheScopeUnavailable) null else err;
        const sql = "SELECT updated_at FROM snapshots WHERE kind=?1 AND key=?2;";
        var statement: ?*c.sqlite3_stmt = null;
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        if (c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &statement, null) != c.SQLITE_OK) return error.QueryFailed;
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement.?, 1, scoped_kind);
        try bindText(statement.?, 2, key);
        if (c.sqlite3_step(statement.?) != c.SQLITE_ROW) return null;
        return c.sqlite3_column_int64(statement.?, 0);
    }

    /// 把某个 kind 的快照数压到 `max_rows` 以内，**优先删写入时间最旧的**。
    ///
    /// 给图标磁盘缓存用（`backend/assets_ipc.zig` 的 `diskAssetCachePut`）。
    /// 图标是「写一次、之后一直读」的小对象，天然不需要 LRU —— 老的图标
    /// 不代表没用（经典皮肤头像、旧版装备图都还在被引用），但总量必须封顶，
    /// 否则一个长期使用的客户端会把整张表撑到几百 MB。
    ///
    /// 只有真的超限才删：正常情况下这是一次廉价的 COUNT。删除操作用一条
    /// `DELETE ... WHERE rowid IN (SELECT ... ORDER BY updated_at LIMIT n)` 完成，
    /// 避免把行全读进内存。
    pub fn prune(self: *Store, kind: []const u8, max_rows: i64) !void {
        var kind_buffer: [512]u8 = undefined;
        const scoped_kind = self.scopedKind(kind, &kind_buffer) catch |err| return if (err == error.CacheScopeUnavailable) {} else err;

        const count_sql = "SELECT COUNT(*) FROM snapshots WHERE kind=?1;";
        var count_statement: ?*c.sqlite3_stmt = null;
        const count_z = try self.allocator.dupeZ(u8, count_sql);
        defer self.allocator.free(count_z);
        if (c.sqlite3_prepare_v2(self.db, count_z.ptr, -1, &count_statement, null) != c.SQLITE_OK) return error.QueryFailed;
        defer _ = c.sqlite3_finalize(count_statement);
        try bindText(count_statement.?, 1, scoped_kind);
        if (c.sqlite3_step(count_statement.?) != c.SQLITE_ROW) return error.QueryFailed;
        const total = c.sqlite3_column_int64(count_statement.?, 0);
        const excess = total - max_rows;
        if (excess <= 0) return;

        const delete_sql = "DELETE FROM snapshots WHERE kind=?1 AND rowid IN (SELECT rowid FROM snapshots WHERE kind=?1 ORDER BY updated_at ASC LIMIT ?2);";
        var delete_statement: ?*c.sqlite3_stmt = null;
        const delete_z = try self.allocator.dupeZ(u8, delete_sql);
        defer self.allocator.free(delete_z);
        if (c.sqlite3_prepare_v2(self.db, delete_z.ptr, -1, &delete_statement, null) != c.SQLITE_OK) return error.QueryFailed;
        defer _ = c.sqlite3_finalize(delete_statement);
        try bindText(delete_statement.?, 1, scoped_kind);
        if (c.sqlite3_bind_int64(delete_statement.?, 2, excess) != c.SQLITE_OK) return error.QueryFailed;
        if (c.sqlite3_step(delete_statement.?) != c.SQLITE_DONE) return error.QueryFailed;
    }

    /// 一个 kind 下的一条快照。`key` / `value` 都是调用方负责释放的副本。
    pub const Entry = struct {
        key: []u8,
        value: []u8,
        updated_at: i64,
    };

    /// 列出某个 kind 的全部快照，**写入时间新的在前**。
    ///
    /// 回收站（被删好友）需要「最近删的在最上面」，所以排序放在 SQL 里而不是调用方——
    /// 只有这里知道 `updated_at`。
    pub fn list(self: *Store, allocator: std.mem.Allocator, kind: []const u8) ![]Entry {
        var kind_buffer: [512]u8 = undefined;
        const scoped_kind = self.scopedKind(kind, &kind_buffer) catch |err| return if (err == error.CacheScopeUnavailable) &.{} else err;
        const sql = "SELECT key,value,updated_at FROM snapshots WHERE kind=?1 ORDER BY updated_at DESC;";
        var statement: ?*c.sqlite3_stmt = null;
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        if (c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &statement, null) != c.SQLITE_OK) return error.QueryFailed;
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement.?, 1, scoped_kind);
        var entries = std.ArrayList(Entry).empty;
        errdefer {
            for (entries.items) |entry| {
                allocator.free(entry.key);
                allocator.free(entry.value);
            }
            entries.deinit(allocator);
        }
        while (c.sqlite3_step(statement.?) == c.SQLITE_ROW) {
            const key_ptr = c.sqlite3_column_text(statement.?, 0) orelse continue;
            const key_len = c.sqlite3_column_bytes(statement.?, 0);
            const value_ptr = c.sqlite3_column_text(statement.?, 1) orelse continue;
            const value_len = c.sqlite3_column_bytes(statement.?, 1);
            try entries.append(allocator, .{
                .key = try allocator.dupe(u8, key_ptr[0..@intCast(key_len)]),
                .value = try allocator.dupe(u8, value_ptr[0..@intCast(value_len)]),
                .updated_at = c.sqlite3_column_int64(statement.?, 2),
            });
        }
        return entries.toOwnedSlice(allocator);
    }

    pub fn freeEntries(allocator: std.mem.Allocator, entries: []Entry) void {
        for (entries) |entry| {
            allocator.free(entry.key);
            allocator.free(entry.value);
        }
        allocator.free(entries);
    }

    pub fn remove(self: *Store, kind: []const u8, key: []const u8) !void {
        var kind_buffer: [512]u8 = undefined;
        const scoped_kind = try self.scopedKind(kind, &kind_buffer);
        const sql = "DELETE FROM snapshots WHERE kind=?1 AND key=?2;";
        var statement: ?*c.sqlite3_stmt = null;
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        if (c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &statement, null) != c.SQLITE_OK) return error.QueryFailed;
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement.?, 1, scoped_kind);
        try bindText(statement.?, 2, key);
        if (c.sqlite3_step(statement.?) != c.SQLITE_DONE) return error.QueryFailed;
    }

    fn exec(self: *Store, sql: []const u8) !void {
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        var error_message: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.db, sql_z.ptr, null, null, &error_message);
        if (error_message != null) c.sqlite3_free(error_message);
        if (rc != c.SQLITE_OK) return error.QueryFailed;
    }
};

fn bindText(statement: *c.sqlite3_stmt, index: c_int, value: []const u8) !void {
    if (c.sqlite3_bind_text(statement, index, value.ptr, @intCast(value.len), c.SQLITE_TRANSIENT) != c.SQLITE_OK) return error.QueryFailed;
}

test "数据库快照读写一致" {
    var store = try Store.open(std.testing.allocator, std.testing.io, ".zig-cache/test-storage.sqlite3");
    defer store.deinit();
    try store.put("config", "current", "{\"version\":1}");
    const found = (try store.get("config", "current")).?;
    defer std.testing.allocator.free(found);
    try std.testing.expectEqualStrings("{\"version\":1}", found);
}

test "玩家缓存按账号和大区隔离且旧无归属缓存不混用" {
    var store = try Store.open(std.testing.allocator, std.testing.io, ":memory:");
    defer store.deinit();
    try store.put("playerHistory", "目标玩家", "旧缓存");
    try store.put("config", "current", "公共配置");
    store.require_scope = true;
    try std.testing.expectEqual(@as(?[]u8, null), try store.get("playerHistory", "目标玩家"));
    try std.testing.expectError(error.CacheScopeUnavailable, store.put("playerHistory", "目标玩家", "未知归属"));
    try store.setScope("TENCENT_HN1", "账号甲");
    try store.put("playerHistory", "目标玩家", "一区战绩");
    try store.setScope("hn2", "账号甲");
    try std.testing.expectEqual(@as(?[]u8, null), try store.get("playerHistory", "目标玩家"));
    try store.setScope("HN1", "账号乙");
    try std.testing.expectEqual(@as(?i64, null), try store.getUpdatedAt("playerHistory", "目标玩家"));
    try store.setScope("hn1", "账号甲");
    const found = (try store.get("playerHistory", "目标玩家")).?;
    defer std.testing.allocator.free(found);
    try std.testing.expectEqualStrings("一区战绩", found);
    const config = (try store.get("config", "current")).?;
    defer std.testing.allocator.free(config);
    try std.testing.expectEqualStrings("公共配置", config);
}

test "prune 只删最旧的、且不超限时不动数据" {
    var store = try Store.open(std.testing.allocator, std.testing.io, ":memory:");
    defer store.deinit();
    // 未超限：一条都不该删。
    try store.put("cache", "icon:1", "甲");
    try store.put("cache", "icon:2", "乙");
    try store.prune("cache", 5);
    const first = (try store.get("cache", "icon:1")).?;
    defer std.testing.allocator.free(first);
    const second = (try store.get("cache", "icon:2")).?;
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("甲", first);
    try std.testing.expectEqualStrings("乙", second);

    // 写 6 条、上限 3：必须只剩最新的 3 条。
    // `updated_at` 用 `unixepoch()`（秒），同一秒内写入会并列，所以这里靠
    // 插入顺序 + rowid 兜底：SQL 的 ORDER BY 在并列时按 rowid 升序，
    // 也就是先插入的先删——这正是「最旧先删」的语义。
    inline for (.{ "3", "4", "5", "6" }) |id| {
        var key_buffer: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buffer, "icon:{s}", .{id}) catch unreachable;
        try store.put("cache", key, "值");
    }
    try store.prune("cache", 3);
    const rows = try store.list(std.testing.allocator, "cache");
    defer Store.freeEntries(std.testing.allocator, rows);
    try std.testing.expectEqual(@as(usize, 3), rows.len);
}
