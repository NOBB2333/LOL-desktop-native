//! 英雄资料与静态资源 IPC handler。
//!
//! 英雄 DTO 的组装规则在 `backend/champions.zig`；本模块只负责取数（LCU / OP.GG /
//! CommunityDragon）与缓存取舍，是「数据来源」这一层。
const std = @import("std");
const native_sdk = @import("native_sdk");
const lcu = @import("lcu");
const backend = @import("../backend.zig");
const champion_mapper = @import("champions.zig");

pub fn getChampions(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = backend.runtime(context);
    _ = invocation;
    if (self.mode == .live) {
        if (self.io) |io| {
            var client = backend.discoverClient(self, io) catch {
                if (self.storage) |*store| if (store.get("cache", "champions") catch null) |cached| {
                    defer std.heap.page_allocator.free(cached);
                    const stats = store.get("cache", "opgg-ranked-emerald-plus") catch null;
                    defer if (stats) |value| std.heap.page_allocator.free(value);
                    const updated_seconds = store.getUpdatedAt("cache", "opgg-ranked-emerald-plus") catch null;
                    const fetched_at = (updated_seconds orelse 0) * std.time.ms_per_s;
                    const expires_at = fetched_at + backend.runtimeCacheTtlMillis(self);
                    const stale = stats != null and backend.runtimeNowMillis(self) > expires_at;
                    return champion_mapper.dtoWithStats(cached, stats, .{
                        .source = if (stale) "sqlite-stale" else "sqlite-fresh",
                        .stats_source = if (stats != null) "sqlite" else "unavailable",
                        .fetched_at_millis = fetched_at,
                        .expires_at_millis = if (stats != null) expires_at else null,
                        .is_stale = stale,
                        .error_message = "LCU 未连接，已使用本地英雄快照",
                    }, output);
                };
                return error.LcuNotRunning;
            };
            defer client.deinit();
            const champions = client.get("/lol-game-data/assets/v1/champion-summary.json") catch blk: {
                if (self.storage) |*store| if (store.get("cache", "champions") catch null) |cached| break :blk cached;
                return error.LcuRequestFailed;
            };
            defer std.heap.page_allocator.free(champions);
            if (self.storage) |*store| store.put("cache", "champions", champions) catch {};
            var cached_stats: ?[]u8 = null;
            defer if (cached_stats) |value| std.heap.page_allocator.free(value);
            var cached_at: i64 = 0;
            if (self.storage) |*store| {
                cached_stats = store.get("cache", "opgg-ranked-emerald-plus") catch null;
                cached_at = ((store.getUpdatedAt("cache", "opgg-ranked-emerald-plus") catch null) orelse 0) * std.time.ms_per_s;
            }
            if (cached_stats) |value| if (!champion_mapper.hasRankedStats(value)) {
                std.heap.page_allocator.free(value);
                cached_stats = null;
                cached_at = 0;
            };
            const now = backend.runtimeNowMillis(self);
            const ttl = backend.runtimeCacheTtlMillis(self);
            const cache_fresh = cached_stats != null and cached_at > 0 and now <= cached_at + ttl;
            var fetched_stats: ?[]u8 = null;
            defer if (fetched_stats) |value| std.heap.page_allocator.free(value);
            var fetch_failed = false;
            if (!cache_fresh) {
                fetched_stats = client.getPublicUrl("https://lol-api-champion.op.gg/api/global/champions/ranked?tier=emerald_plus", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) lol-desktop-native/2.0") catch blk: {
                    fetch_failed = true;
                    break :blk null;
                };
                if (fetched_stats) |stats| {
                    if (champion_mapper.hasRankedStats(stats)) {
                        if (self.storage) |*store| store.put("cache", "opgg-ranked-emerald-plus", stats) catch {};
                    } else {
                        std.heap.page_allocator.free(stats);
                        fetched_stats = null;
                        fetch_failed = true;
                    }
                }
            }
            const stats = fetched_stats orelse cached_stats;
            const fetched_at = if (fetched_stats != null) now else cached_at;
            const stale = stats != null and !cache_fresh and fetched_stats == null;
            return champion_mapper.dtoWithStats(champions, stats, .{
                .source = if (fetched_stats != null) "opgg" else if (stale) "sqlite-stale" else if (cache_fresh) "sqlite-fresh" else "lcu",
                .stats_source = if (fetched_stats != null) "opgg" else if (stats != null) "sqlite" else "unavailable",
                .fetched_at_millis = fetched_at,
                .expires_at_millis = if (stats != null and fetched_at > 0) fetched_at + ttl else null,
                .is_stale = stale,
                .error_message = if (stale)
                    "OP.GG 刷新失败，已回退旧缓存"
                else if (fetch_failed and stats == null)
                    "OP.GG 刷新失败，当前仅显示 LCU 基础资料"
                else
                    null,
            }, output);
        }
        return error.LcuNotRunning;
    }
    return std.fmt.bufPrint(output, "[]", .{});
}

pub fn getAsset(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = backend.runtime(context);
    const payload_json = backend.parsePayload(struct { kind: []const u8 = "", id: i64 = 0 }, invocation.request.payload) catch return error.InvalidAsset;
    defer payload_json.deinit();
    const payload = payload_json.value;
    if (payload.id <= 0) return error.InvalidAsset;
    const kind = assetKind(payload.kind) orelse return error.InvalidAsset;
    if (self.io) |io| {
        var client = backend.discoverClient(self, io) catch return communityDragonAsset(kind, payload.id, output);
        defer client.deinit();
        const bytes = fetchLcuAsset(client, kind, payload.id) catch return communityDragonAsset(kind, payload.id, output);
        defer std.heap.page_allocator.free(bytes);
        return assetDataDto(kind, payload.id, bytes, output);
    }
    return communityDragonAsset(kind, payload.id, output);
}

const AssetKind = enum { champion, item, spell, perk, profile };

fn assetKind(value: []const u8) ?AssetKind {
    return std.meta.stringToEnum(AssetKind, value);
}

fn fetchLcuAsset(client: lcu.Client, kind: AssetKind, id: i64) ![]u8 {
    var direct_path_buffer: [256]u8 = undefined;
    if (kind == .profile) {
        const path = try std.fmt.bufPrint(&direct_path_buffer, "/lol-game-data/assets/v1/profile-icons/{d}.jpg", .{id});
        return client.get(path);
    }
    if (kind == .champion) {
        const path = try std.fmt.bufPrint(&direct_path_buffer, "/lol-game-data/assets/v1/champion-icons/{d}.png", .{id});
        return client.get(path);
    }

    const endpoint = switch (kind) {
        .item => "/lol-game-data/assets/v1/items.json",
        .spell => "/lol-game-data/assets/v1/summoner-spells.json",
        .perk => "/lol-game-data/assets/v1/perks.json",
        else => unreachable,
    };
    const catalog_json = try client.get(endpoint);
    defer std.heap.page_allocator.free(catalog_json);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const catalog = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), catalog_json, .{}) catch return error.LcuInvalidResponse;
    if (catalog != .array) return error.LcuInvalidResponse;
    for (catalog.array.items) |entry| {
        if (entry != .object or backend.jsonInt(entry, "id") != id) continue;
        const icon_path = backend.jsonField(entry, "iconPath");
        if (icon_path.len == 0 or !std.mem.startsWith(u8, icon_path, "/")) return error.AssetNotFound;
        return client.get(icon_path);
    }
    return error.AssetNotFound;
}

fn assetDataDto(kind: AssetKind, id: i64, bytes: []const u8, output: []u8) ![]const u8 {
    const is_jpeg = bytes.len >= 3 and bytes[0] == 0xff and bytes[1] == 0xd8 and bytes[2] == 0xff;
    const is_png = bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n");
    if (!is_jpeg and !is_png) return error.AssetNotFound;
    const mime = if (is_jpeg) "image/jpeg" else "image/png";
    const prefix = try std.fmt.bufPrint(output, "{{\"kind\":\"{s}\",\"id\":{d},\"mimeType\":\"{s}\",\"dataUrl\":\"data:{s};base64,", .{ @tagName(kind), id, mime, mime });
    const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
    const suffix = "\",\"source\":\"lcu\"}";
    if (prefix.len + encoded_len + suffix.len > output.len) return error.ResponseTooLarge;
    _ = std.base64.standard.Encoder.encode(output[prefix.len..][0..encoded_len], bytes);
    @memcpy(output[prefix.len + encoded_len ..][0..suffix.len], suffix);
    return output[0 .. prefix.len + encoded_len + suffix.len];
}

fn communityDragonAsset(kind: AssetKind, id: i64, output: []u8) ![]const u8 {
    const folder = switch (kind) {
        .champion => "champion-icons",
        .profile => "profile-icons",
        .item => "items",
        .spell => "summoner-spells",
        .perk => "perk-images/Styles",
    };
    const extension = if (kind == .profile) "jpg" else "png";
    const mime = if (kind == .profile) "image/jpeg" else "image/png";
    return std.fmt.bufPrint(output, "{{\"kind\":\"{s}\",\"id\":{d},\"mimeType\":\"{s}\",\"dataUrl\":\"https://raw.communitydragon.org/latest/plugins/rcp-be-lol-game-data/global/default/v1/{s}/{d}.{s}\",\"source\":\"communitydragon\"}}", .{ @tagName(kind), id, mime, folder, id, extension });
}

// 就地测试：DTO 组装函数已随模块迁出。
test "asset DTO embeds LCU images and uses the profile jpeg fallback" {
    const png = "\x89PNG\r\n\x1a\ncontent";
    var output: [1024]u8 = undefined;
    const result = try assetDataDto(.item, 3031, png, &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expect(std.mem.indexOf(u8, result, "data:image/png;base64,") != null);

    const fallback = try communityDragonAsset(.profile, 3494, &output);
    const fallback_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, fallback, .{});
    defer fallback_parsed.deinit();
    try std.testing.expect(std.mem.endsWith(u8, fallback_parsed.value.object.get("dataUrl").?.string, "3494.jpg"));
}
