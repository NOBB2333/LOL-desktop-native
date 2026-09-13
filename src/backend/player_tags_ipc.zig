//! 玩家备注（标记）IPC handler。
//!
//! 存储与清洗规则在 `backend/player_tags.zig`；本模块只负责请求解析与 JSON 输出，
//! 与 `backend.zig` 的共享基础设施（`runtime` / `parsePayload` / `jsonString`）对接。
const std = @import("std");
const native_sdk = @import("native_sdk");
const backend = @import("../backend.zig");
const player_tag_service = @import("player_tags.zig");

const PlayerTagQueryPayload = struct {
    puuids: []const []const u8 = &.{},
    selfPuuid: ?[]const u8 = null,
};

const PlayerTagUpdatePayload = struct {
    puuid: []const u8,
    notes: []const []const u8 = &.{},
    selfPuuid: ?[]const u8 = null,
};

/// 备注的「写入者」：优先用请求里带的 puuid（快照模式与测试没有登录账号），
/// 否则退回当前客户端登录账号。
fn playerTagOwner(self: *backend.Runtime, provided: ?[]const u8) []const u8 {
    if (provided) |puuid| {
        if (puuid.len > 0) return puuid;
    }
    return self.live_owner_puuid[0..self.live_owner_puuid_len];
}

fn writePlayerTagNotes(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    self: *backend.Runtime,
    owner: []const u8,
    puuid: []const u8,
) !void {
    const notes: []const []const u8 = if (self.storage) |*store|
        try player_tag_service.read(store, allocator, owner, puuid)
    else
        &.{};
    try writer.writeByte('[');
    for (notes, 0..) |note, index| {
        if (index > 0) try writer.writeByte(',');
        try backend.jsonString(writer, note);
    }
    try writer.writeByte(']');
}

/// `lol.get_player_tags` —— 批量读取本局十人的备注，返回 `{"tags":{"<puuid>":["备注"]}}`。
pub fn getPlayerTags(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = backend.runtime(context);
    const payload_json = backend.parsePayload(PlayerTagQueryPayload, invocation.request.payload) catch return error.InvalidRequest;
    defer payload_json.deinit();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const owner = playerTagOwner(self, payload_json.value.selfPuuid);

    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll("{\"tags\":{");
    var first = true;
    for (payload_json.value.puuids) |puuid| {
        if (puuid.len == 0) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try backend.jsonString(&writer, puuid);
        try writer.writeByte(':');
        try writePlayerTagNotes(&writer, allocator, self, owner, puuid);
    }
    try writer.writeAll("}}");
    return writer.buffered();
}

/// `lol.update_player_tag` —— 覆盖写入某位玩家的备注，返回清洗后的结果与更新时间。
pub fn updatePlayerTag(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = backend.runtime(context);
    const payload_json = backend.parsePayload(PlayerTagUpdatePayload, invocation.request.payload) catch return error.InvalidRequest;
    defer payload_json.deinit();
    const payload = payload_json.value;
    if (payload.puuid.len == 0) return error.InvalidRequest;

    const owner = playerTagOwner(self, payload.selfPuuid);
    if (owner.len == 0) return error.PlayerTagUnavailable;
    const store = if (self.storage) |*slot| slot else return error.PlayerTagUnavailable;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const saved = try player_tag_service.write(store, allocator, owner, payload.puuid, payload.notes);
    const updated_at = try player_tag_service.updatedAt(store, allocator, owner, payload.puuid);

    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll("{\"puuid\":");
    try backend.jsonString(&writer, payload.puuid);
    try writer.writeAll(",\"notes\":[");
    for (saved, 0..) |note, index| {
        if (index > 0) try writer.writeByte(',');
        try backend.jsonString(&writer, note);
    }
    try writer.print("],\"updatedAt\":{d}}}", .{updated_at});
    return writer.buffered();
}
