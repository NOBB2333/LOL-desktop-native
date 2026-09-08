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
        if (std.mem.eql(u8, kind, "config") or std.mem.eql(u8, kind, "settings") or std.mem.eql(u8, kind, "cache")) return kind;
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
        try store.exec("PRAGMA journal_mode=WAL; PRAGMA busy_timeout=250;");
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
