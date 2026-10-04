//! 英雄资料与静态资源 IPC handler。
//!
//! 英雄 DTO 的组装规则在 `backend/champions.zig`；本模块只负责取数（LCU / OP.GG /
//! CommunityDragon）与缓存取舍，是「数据来源」这一层。
const std = @import("std");
const native_sdk = @import("native_sdk");
const lcu = @import("lcu");
const backend = @import("../backend.zig");
const champion_mapper = @import("champions.zig");

const ChampionQuery = struct { region: []const u8 = "", tier: []const u8 = "" };

// OP.GG 允许的区服与分段。
//
// 抄 LeagueAkari 的 `RegionType` / `TierType`（`shared/types/opgg/index.ts`），
// 但**用白名单收口**：这两个值会被拼进请求 URL，不能让调用方自由传入。表外的值
// 一律落回默认，不报错——界面传了个旧名字时，降级到默认口径比整块空掉好。
const opgg_regions = [_][]const u8{
    "global", "na", "euw", "eune", "kr", "jp", "br", "lan", "las", "oce",
    "tr",     "ru", "sg",  "id",   "ph", "th", "vn", "tw",  "me",
};

const opgg_tiers = [_][]const u8{
    "all", "ibsg", "gold_plus", "platinum_plus", "emerald_plus", "diamond_plus", "master", "master_plus", "grandmaster", "challenger",
};

const default_opgg_region = "global";
const default_opgg_tier = "emerald_plus";

fn normalizeOpggRegion(value: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    for (opgg_regions) |candidate| if (std.ascii.eqlIgnoreCase(candidate, trimmed)) return candidate;
    return default_opgg_region;
}

fn normalizeOpggTier(value: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    for (opgg_tiers) |candidate| if (std.ascii.eqlIgnoreCase(candidate, trimmed)) return candidate;
    return default_opgg_tier;
}

/// 缓存条目按「区服 + 分段」分开。
///
/// 默认那组刻意沿用老 key（`opgg-ranked-emerald-plus`），升级后原来的缓存还能直接
/// 命中，不至于白刷一次网络。
fn opggCacheKey(buffer: []u8, region: []const u8, tier: []const u8) []const u8 {
    if (std.mem.eql(u8, region, default_opgg_region) and std.mem.eql(u8, tier, default_opgg_tier)) return "opgg-ranked-emerald-plus";
    return std.fmt.bufPrint(buffer, "opgg-ranked-{s}-{s}", .{ region, tier }) catch "opgg-ranked";
}

fn opggUrl(buffer: []u8, region: []const u8, tier: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "https://lol-api-champion.op.gg/api/{s}/champions/ranked?tier={s}", .{ region, tier }) catch "https://lol-api-champion.op.gg/api/global/champions/ranked?tier=emerald_plus";
}

pub fn getChampions(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = backend.runtime(context);
    // 没带 payload（界面不带参数时）也要能跑，所以解析失败只退回默认值。
    const request = backend.parsePayload(ChampionQuery, invocation.request.payload) catch null;
    defer if (request) |parsed| parsed.deinit();
    const query = if (request) |parsed| parsed.value else ChampionQuery{};
    const region = normalizeOpggRegion(query.region);
    const tier = normalizeOpggTier(query.tier);
    var key_buffer: [96]u8 = undefined;
    const cache_key = opggCacheKey(&key_buffer, region, tier);
    var url_buffer: [192]u8 = undefined;
    const stats_url = opggUrl(&url_buffer, region, tier);
    const stats_status = .{ .region = region, .tier = tier };

    if (self.mode == .live) {
        if (self.io) |io| {
            var client = backend.discoverClient(self, io) catch {
                if (self.storage) |*store| if (store.get("cache", "champions") catch null) |cached| {
                    defer std.heap.page_allocator.free(cached);
                    const stats = store.get("cache", cache_key) catch null;
                    defer if (stats) |value| std.heap.page_allocator.free(value);
                    const updated_seconds = store.getUpdatedAt("cache", cache_key) catch null;
                    const fetched_at = (updated_seconds orelse 0) * std.time.ms_per_s;
                    const expires_at = fetched_at + backend.runtimeCacheTtlMillis(self);
                    const stale = stats != null and backend.runtimeNowMillis(self) > expires_at;
                    return champion_mapper.dtoWithStats(cached, stats, .{
                        .source = if (stale) "sqlite-stale" else "sqlite-fresh",
                        .stats_source = if (stats != null) "sqlite" else "unavailable",
                        .region = stats_status.region,
                        .tier = stats_status.tier,
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
                cached_stats = store.get("cache", cache_key) catch null;
                cached_at = ((store.getUpdatedAt("cache", cache_key) catch null) orelse 0) * std.time.ms_per_s;
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
                fetched_stats = client.getPublicUrl(stats_url, "Mozilla/5.0 (Windows NT 10.0; Win64; x64) lol-desktop-native/2.0") catch blk: {
                    fetch_failed = true;
                    break :blk null;
                };
                if (fetched_stats) |stats| {
                    if (champion_mapper.hasRankedStats(stats)) {
                        if (self.storage) |*store| store.put("cache", cache_key, stats) catch {};
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
                .region = stats_status.region,
                .tier = stats_status.tier,
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

/// LCU 的资源前缀。
///
/// 这个命令只允许取游戏数据资源，绝不能变成「任意 LCU 接口的探测器」——所以按
/// 路径取字节时前缀必须卡死在这里，而不是把用户给的字符串直接拼进请求。
const lcu_asset_prefix = "/lol-game-data/assets/";

/// CommunityDragon 的默认资产根。
///
/// 对齐 LeagueAkari `renderer-shared/providers/akari-resource/storybook.ts` 里的
/// `CDRAGON_DEFAULT_ASSET_BASE`：LCU 取不到时按同样的规则回退，界面才不至于空白。
const community_dragon_asset_base = "https://raw.communitydragon.org/latest/plugins/rcp-be-lol-game-data/global/default";

pub fn getAsset(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = backend.runtime(context);
    const payload_json = backend.parsePayload(struct { kind: []const u8 = "", id: i64 = 0, path: []const u8 = "" }, invocation.request.payload) catch return error.InvalidAsset;
    defer payload_json.deinit();
    const payload = payload_json.value;
    // 领取奖励的图标只有路径没有 (kind, id)：任务奖励给的就是
    // `/lol-game-data/assets/v1/...` 这样的整条资源路径。
    if (payload.path.len > 0) {
        var path_key_buffer: [1024]u8 = undefined;
        const path_key = std.fmt.bufPrint(&path_key_buffer, "path:{s}", .{payload.path}) catch
            return assetByPath(self, payload.path, output);
        if (assetCacheGet(path_key, output)) |cached| return cached;
        const dto = try assetByPath(self, payload.path, output);
        assetCachePut(path_key, dto);
        return dto;
    }
    if (payload.id <= 0) return error.InvalidAsset;
    const kind = assetKind(payload.kind) orelse return error.InvalidAsset;
    var key_buffer: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buffer, "{s}:{d}", .{ @tagName(kind), payload.id }) catch return error.InvalidAsset;
    if (assetCacheGet(key, output)) |cached| return cached;
    const dto = try fetchAssetDto(self, kind, payload.id, output);
    assetCachePut(key, dto);
    return dto;
}

/// 取 `(kind, id)` 的图标 DTO：LCU 本地字节优先，拿不到退回 CommunityDragon。
fn fetchAssetDto(self: *backend.Runtime, kind: AssetKind, id: i64, output: []u8) ![]const u8 {
    const io = self.io orelse return communityDragonAsset(kind, id, output);
    var client = assetClient(self, io) catch return communityDragonAsset(kind, id, output);
    defer client.deinit();
    const bytes = fetchLcuAsset(client, kind, id) catch return communityDragonAsset(kind, id, output);
    defer std.heap.page_allocator.free(bytes);
    return assetDataDto(kind, id, bytes, output);
}

/// 图标取字节专用的客户端配置：挂到 `.asset` 配额通道。
///
/// `discoverClient` 建出来的客户端默认是 `.query` lane，`localBudget()` 于是回落到
/// `.lcu`（6 个名额）——而 `.lcu` 还要给英雄目录、技能数值这些交互请求用。图标是
/// 一屏几百个的纯装饰请求，和交互请求抢同一条配额会两头都慢，所以这里显式覆盖成
/// `.asset`（独立 8 个名额）。命令的**派发** lane 由 `backend.zig` 的命令表决定
/// （见那里的 `lol.get_asset`），和这里的**配额**通道是两件事，必须各自设对。
fn assetClient(self: *backend.Runtime, io: std.Io) !lcu.Client {
    var client = try backend.discoverClient(self, io);
    client.budget = .asset;
    return client;
}

/// 按 LCU 资源路径取图标。取不到就回退 CommunityDragon 的同名 URL。
fn assetByPath(self: *backend.Runtime, path: []const u8, output: []u8) ![]const u8 {
    if (!isLcuAssetPath(path)) return error.InvalidAsset;
    if (self.io) |io| {
        var client = assetClient(self, io) catch return communityDragonAssetByPath(path, output);
        defer client.deinit();
        const bytes = client.get(path) catch return communityDragonAssetByPath(path, output);
        defer std.heap.page_allocator.free(bytes);
        return assetByPathDto(path, bytes, output);
    }
    return communityDragonAssetByPath(path, output);
}

/// 图标 DTO 的进程内缓存。
///
/// **为什么必须缓存**（2026-09-26 实测）：一局十人的对局页要画 ~90 个图标，而每个
/// 图标都是一次独立的桥调用 + 一条**新建的 WinHTTP 连接**去打 LCU——实测平均
/// **39.7ms**，同样 30 个请求复用一条连接只要 4.4ms/个。90 个串起来就是
/// **3.5 秒**，表现就是「数据 0.8 秒就到了，图标却一个一个往外冒」。
/// 而重复量极大：十个玩家互相打过同一批英雄、每 400ms 轮询一次、
/// 卡片还会因为玩家身份落定（`playerCardKey` 变了）整张重挂，每次都把同样的
/// 字节重新拉一遍。
///
/// 只缓存**真的从 LCU 拿到字节**的结果（DTO 尾巴是 `"source":"lcu"`）。
/// CommunityDragon 的兜底值只是一条 URL，缓存住会把「当时客户端没开」这一个瞬间
/// 焊死一整个会话——等用户真开了客户端反而还在用云上的图。
const asset_cache_budget_bytes: usize = 24 * 1024 * 1024;
/// 单条上限。桥的响应上限是 1 MiB（`native_sdk.bridge.max_response_bytes`），
/// 比它还大的 DTO 本来也回不去，直接不入缓存。
const asset_cache_max_entry_bytes: usize = 512 * 1024;
const AssetCacheEntry = struct { key: []u8, dto: []u8 };

var asset_cache_entries: std.array_list.Managed(AssetCacheEntry) = .init(std.heap.page_allocator);
var asset_cache_bytes: usize = 0;
var asset_cache_mutex: std.atomic.Mutex = .unlocked;

/// 图标是高频只读访问，临界区极短（几十 KB 的 memcpy），用自旋足够；
/// 抢不到时让出时间片，避免长任务在别的线程上把 CPU 空烧。
fn lockAssetCache() void {
    var spins: usize = 0;
    while (!asset_cache_mutex.tryLock()) {
        if (spins < 64) {
            std.atomic.spinLoopHint();
            spins += 1;
        } else {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
    }
}

fn isLcuSourcedDto(dto: []const u8) bool {
    return std.mem.endsWith(u8, dto, "\"source\":\"lcu\"}");
}

/// 命中就把缓存里的 DTO 原样拷进调用方的 `output`（超出容量时当未命中）。
fn assetCacheGet(key: []const u8, output: []u8) ?[]const u8 {
    lockAssetCache();
    defer asset_cache_mutex.unlock();
    for (asset_cache_entries.items) |entry| {
        if (!std.mem.eql(u8, entry.key, key)) continue;
        if (entry.dto.len > output.len) return null;
        @memcpy(output[0..entry.dto.len], entry.dto);
        return output[0..entry.dto.len];
    }
    return null;
}

fn assetCachePut(key: []const u8, dto: []const u8) void {
    if (!isLcuSourcedDto(dto) or dto.len > asset_cache_max_entry_bytes) return;
    const allocator = std.heap.page_allocator;
    lockAssetCache();
    defer asset_cache_mutex.unlock();
    for (asset_cache_entries.items) |entry| if (std.mem.eql(u8, entry.key, key)) return;
    const owned_key = allocator.dupe(u8, key) catch return;
    const owned_dto = allocator.dupe(u8, dto) catch {
        allocator.free(owned_key);
        return;
    };
    asset_cache_entries.append(.{ .key = owned_key, .dto = owned_dto }) catch {
        allocator.free(owned_key);
        allocator.free(owned_dto);
        return;
    };
    asset_cache_bytes += owned_key.len + owned_dto.len;
    // FIFO 淘汰到水位以下：图标都是差不多大的小对象，不值得为 LRU 记账。
    while (asset_cache_bytes > asset_cache_budget_bytes and asset_cache_entries.items.len > 1) {
        const evicted = asset_cache_entries.orderedRemove(0);
        asset_cache_bytes -= evicted.key.len + evicted.dto.len;
        allocator.free(evicted.key);
        allocator.free(evicted.dto);
    }
}

/// 测试用：清空缓存，避免用例之间互相污染。
fn assetCacheResetForTest() void {
    const allocator = std.heap.page_allocator;
    lockAssetCache();
    defer asset_cache_mutex.unlock();
    for (asset_cache_entries.items) |entry| {
        allocator.free(entry.key);
        allocator.free(entry.dto);
    }
    asset_cache_entries.clearRetainingCapacity();
    asset_cache_bytes = 0;
}

/// 把按路径取到的字节包成 DTO。`assetByPath` 已经做过路径白名单校验。
fn assetByPathDto(path: []const u8, bytes: []const u8, output: []u8) ![]const u8 {
    var prefix_buffer: [768]u8 = undefined;
    var prefix_writer = std.Io.Writer.fixed(&prefix_buffer);
    try prefix_writer.writeAll("{\"path\":");
    try backend.jsonString(&prefix_writer, path);
    try prefix_writer.writeByte(',');
    return assetBytesDto(prefix_writer.buffered(), bytes, output);
}

const AssetKind = enum { champion, item, spell, perk, profile };

fn assetKind(value: []const u8) ?AssetKind {
    return std.meta.stringToEnum(AssetKind, value);
}

/// 是不是一条合法的 LCU 游戏资源路径。
///
/// 前缀之后必须还有内容：`/lol-game-data/assets/` 本身不是资源。
fn isLcuAssetPath(path: []const u8) bool {
    return path.len > lcu_asset_prefix.len and std.mem.startsWith(u8, path, lcu_asset_prefix);
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
    const prefix = try std.fmt.bufPrint(output, "{{\"kind\":\"{s}\",\"id\":{d},", .{ @tagName(kind), id });
    return assetBytesDto(prefix, bytes, output);
}

/// 支持的图片类型嗅探。
///
/// LCU 的图标不止 PNG/JPEG：部分活动/通行证图标是 SVG，只认 PNG/JPEG 会让它们
/// 静默退化成占位块。
fn imageMimeType(bytes: []const u8) ?[]const u8 {
    if (bytes.len >= 3 and bytes[0] == 0xff and bytes[1] == 0xd8 and bytes[2] == 0xff) return "image/jpeg";
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return "image/png";
    const head = bytes[0..@min(bytes.len, 256)];
    if (std.mem.indexOf(u8, head, "<svg") != null) return "image/svg+xml";
    return null;
}

/// 把图片字节编码成 `dataUrl` DTO。
///
/// `dto_prefix` 是 `{` 之后到 `"mimeType"` 之前的那一段（`{"kind":"item","id":3031,`）。
/// 它来自调用方自己的栈缓冲，避免和 `output` 重叠。
fn assetBytesDto(dto_prefix: []const u8, bytes: []const u8, output: []u8) ![]const u8 {
    const mime = imageMimeType(bytes) orelse return error.AssetNotFound;
    var head_buffer: [1024]u8 = undefined;
    const head = try std.fmt.bufPrint(&head_buffer, "{s}\"mimeType\":\"{s}\",\"dataUrl\":\"data:{s};base64,", .{ dto_prefix, mime, mime });
    const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
    const suffix = "\",\"source\":\"lcu\"}";
    if (head.len + encoded_len + suffix.len > output.len) return error.ResponseTooLarge;
    @memcpy(output[0..head.len], head);
    _ = std.base64.standard.Encoder.encode(output[head.len..][0..encoded_len], bytes);
    @memcpy(output[head.len + encoded_len ..][0..suffix.len], suffix);
    return output[0 .. head.len + encoded_len + suffix.len];
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
    return std.fmt.bufPrint(output, "{{\"kind\":\"{s}\",\"id\":{d},\"mimeType\":\"{s}\",\"dataUrl\":\"{s}/v1/{s}/{d}.{s}\",\"source\":\"communitydragon\"}}", .{ @tagName(kind), id, mime, community_dragon_asset_base, folder, id, extension });
}

/// 按 LCU 资源路径回退到 CommunityDragon。
///
/// 规则抄 LeagueAkari：`/lol-game-data/assets/` 之后的相对路径直接接在默认资产根
/// 后面，并且**整条转小写**（CommunityDragon 的目录是小写的）。
fn communityDragonAssetByPath(path: []const u8, output: []u8) ![]const u8 {
    const relative = if (std.mem.startsWith(u8, path, lcu_asset_prefix))
        path[lcu_asset_prefix.len..]
    else
        std.mem.trimStart(u8, path, "/");
    var url_buffer: [1024]u8 = undefined;
    var url_writer = std.Io.Writer.fixed(&url_buffer);
    try url_writer.writeAll(community_dragon_asset_base);
    try url_writer.writeByte('/');
    for (relative) |character| try url_writer.writeByte(std.ascii.toLower(character));
    var dto_buffer: [1536]u8 = undefined;
    var dto_writer = std.Io.Writer.fixed(&dto_buffer);
    try dto_writer.writeAll("{\"path\":");
    try backend.jsonString(&dto_writer, path);
    // 走到这里说明 LCU 没给字节，真实类型无从得知；这个字段只是提示，前端直接用 URL。
    try dto_writer.writeAll(",\"mimeType\":\"image/png\",\"dataUrl\":");
    try backend.jsonString(&dto_writer, url_writer.buffered());
    try dto_writer.writeAll(",\"source\":\"communitydragon\"}");
    return backend.copyJson(dto_writer.buffered(), output);
}

// 就地测试：DTO 组装函数已随模块迁出。
test "assets by path are restricted to the LCU game-data prefix" {
    try std.testing.expect(isLcuAssetPath("/lol-game-data/assets/v1/missions/reward.png"));
    try std.testing.expect(!isLcuAssetPath("/lol-summoner/v1/current-summoner"));
    try std.testing.expect(!isLcuAssetPath("/lol-game-data/assets/"));
    try std.testing.expect(!isLcuAssetPath("https://example.com/x.png"));
}

test "assets by path fall back to community dragon with a lowercased relative path" {
    var output: [2048]u8 = undefined;
    const fallback = try communityDragonAssetByPath("/lol-game-data/assets/v1/Missions/Icons/Reward.PNG", &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, fallback, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("communitydragon", parsed.value.object.get("source").?.string);
    try std.testing.expectEqualStrings(
        "https://raw.communitydragon.org/latest/plugins/rcp-be-lol-game-data/global/default/v1/missions/icons/reward.png",
        parsed.value.object.get("dataUrl").?.string,
    );
}

test "图标 DTO 缓存命中就原样返回，未命中返回 null" {
    assetCacheResetForTest();
    defer assetCacheResetForTest();
    const dto = "{\"kind\":\"champion\",\"id\":36,\"mimeType\":\"image/png\",\"dataUrl\":\"data:image/png;base64,AAAA\",\"source\":\"lcu\"}";
    assetCachePut("champion:36", dto);
    var output: [512]u8 = undefined;
    try std.testing.expectEqualStrings(dto, assetCacheGet("champion:36", &output).?);
    try std.testing.expect(assetCacheGet("champion:37", &output) == null);
    // 同一个 key 只留一份，重复写入不该把条目数翻倍。
    assetCachePut("champion:36", dto);
    try std.testing.expectEqual(@as(usize, 1), asset_cache_entries.items.len);
}

test "CommunityDragon 兜底值不进图标缓存" {
    assetCacheResetForTest();
    defer assetCacheResetForTest();
    const cdn = "{\"kind\":\"champion\",\"id\":36,\"mimeType\":\"image/png\",\"dataUrl\":\"https://raw.communitydragon.org/x.png\",\"source\":\"communitydragon\"}";
    assetCachePut("champion:36", cdn);
    var output: [512]u8 = undefined;
    try std.testing.expect(assetCacheGet("champion:36", &output) == null);
    try std.testing.expect(!isLcuSourcedDto(cdn));
    try std.testing.expect(isLcuSourcedDto("{\"dataUrl\":\"data:image/png;base64,AA\",\"source\":\"lcu\"}"));
}

test "图标缓存的目标缓冲装不下时当未命中，不越界写" {
    assetCacheResetForTest();
    defer assetCacheResetForTest();
    const dto = "{\"kind\":\"champion\",\"id\":36,\"mimeType\":\"image/png\",\"dataUrl\":\"data:image/png;base64,AAAA\",\"source\":\"lcu\"}";
    assetCachePut("champion:36", dto);
    var tiny: [8]u8 = .{0} ** 8;
    try std.testing.expect(assetCacheGet("champion:36", &tiny) == null);
    try std.testing.expectEqual(@as(u8, 0), tiny[0]);
}

test "svg reward icons are no longer rejected as unknown types" {
    var output: [2048]u8 = undefined;
    const result = try assetByPathDto("/lol-game-data/assets/v1/icons/event.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>", &output);
    try std.testing.expect(std.mem.indexOf(u8, result, "data:image/svg+xml;base64,") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"source\":\"lcu\"") != null);
}

test "opgg query values are whitelisted and unknown ones fall back to the default" {
    try std.testing.expectEqualStrings("kr", normalizeOpggRegion("KR"));
    try std.testing.expectEqualStrings("euw", normalizeOpggRegion(" euw "));
    // 表外的值不能原样进 URL，一律退回默认。
    try std.testing.expectEqualStrings("global", normalizeOpggRegion("../../etc/passwd"));
    try std.testing.expectEqualStrings("global", normalizeOpggRegion(""));
    try std.testing.expectEqualStrings("diamond_plus", normalizeOpggTier("diamond_plus"));
    try std.testing.expectEqualStrings("emerald_plus", normalizeOpggTier("emerald_plus'; drop table"));
    try std.testing.expectEqualStrings("emerald_plus", normalizeOpggTier(""));
}

test "opgg cache key keeps the legacy name for the default region and tier" {
    var buffer: [96]u8 = undefined;
    // 默认那组沿用老 key，升级后原缓存还能直接命中。
    try std.testing.expectEqualStrings("opgg-ranked-emerald-plus", opggCacheKey(&buffer, "global", "emerald_plus"));
    try std.testing.expectEqualStrings("opgg-ranked-kr-master", opggCacheKey(&buffer, "kr", "master"));
    // 换区服 / 换分段必须是不同的缓存条目，否则切换之后数字不会变。
    try std.testing.expect(!std.mem.eql(u8, opggCacheKey(&buffer, "kr", "master"), opggCacheKey(&buffer, "kr", "challenger")));
}

test "opgg url carries the region and tier" {
    var buffer: [192]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://lol-api-champion.op.gg/api/na/champions/ranked?tier=master_plus",
        opggUrl(&buffer, "na", "master_plus"),
    );
}

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
