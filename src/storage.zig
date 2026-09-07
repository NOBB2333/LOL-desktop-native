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
        const sql = "INSERT INTO snapshots(kind,key,value,updated_at) VALUES(?1,?2,?3,unixepoch()) ON CONFLICT(kind,key) DO UPDATE SET value=excluded.value,updated_at=excluded.updated_at;";
        var statement: ?*c.sqlite3_stmt = null;
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        if (c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &statement, null) != c.SQLITE_OK) return error.QueryFailed;
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement.?, 1, kind);
        try bindText(statement.?, 2, key);
        try bindText(statement.?, 3, value);
        if (c.sqlite3_step(statement.?) != c.SQLITE_DONE) return error.QueryFailed;
    }

    pub fn get(self: *Store, kind: []const u8, key: []const u8) !?[]u8 {
        const sql = "SELECT value FROM snapshots WHERE kind=?1 AND key=?2;";
        var statement: ?*c.sqlite3_stmt = null;
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        if (c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &statement, null) != c.SQLITE_OK) return error.QueryFailed;
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement.?, 1, kind);
        try bindText(statement.?, 2, key);
        if (c.sqlite3_step(statement.?) != c.SQLITE_ROW) return null;
        const ptr = c.sqlite3_column_text(statement.?, 0) orelse return null;
        const len = c.sqlite3_column_bytes(statement.?, 0);
        return try self.allocator.dupe(u8, ptr[0..@intCast(len)]);
    }

    pub fn getUpdatedAt(self: *Store, kind: []const u8, key: []const u8) !?i64 {
        const sql = "SELECT updated_at FROM snapshots WHERE kind=?1 AND key=?2;";
        var statement: ?*c.sqlite3_stmt = null;
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        if (c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &statement, null) != c.SQLITE_OK) return error.QueryFailed;
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement.?, 1, kind);
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

test "sqlite snapshots round trip" {
    var store = try Store.open(std.testing.allocator, std.testing.io, ".zig-cache/test-storage.sqlite3");
    defer store.deinit();
    try store.put("config", "current", "{\"version\":1}");
    const found = (try store.get("config", "current")).?;
    defer std.testing.allocator.free(found);
    try std.testing.expectEqualStrings("{\"version\":1}", found);
}
