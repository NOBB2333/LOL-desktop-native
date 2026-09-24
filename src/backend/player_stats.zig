//! 按批查询一批 puuid 的**召唤师等级与段位**。
//!
//! 为什么要有这个命令：LCU 的 `/lol-ranked/v1/current-ranked-stats` 只回答当前账号，
//! 别人的段位得按 puuid 逐个问 `/lol-ranked/v1/ranked-stats/{puuid}`，等级再问一次
//! `/lol-summoner/v2/summoners/puuid/{puuid}`。历史页展开一局要展示十个人的段位，
//! 之前没有任何命令能一次拿全，所以把这两步打包成一个命令。
//!
//! ⚠️ 成本：**每人两次 LCU 往返**。调用方必须只给界面上真的会展示的那批人（上限
//! `max_players` = 一局十个人），别拿它去批量扫对局。逐人一个线程（与实时页的十人
//! 资料同一套做法），墙钟时间上只多一次往返。
//!
//! 平台边界：这两条路径都**只服务当前登录大区**。跨区玩家（比如用 Riot ID 从 RC
//! 解析出来的别区账号）两项都拿不到，字段保持 `null` —— 前端据此显示「—」，
//! 不要伪装成「没打排位」。
const std = @import("std");
const native_sdk = @import("native_sdk");
const backend = @import("../backend.zig");
const lcu = @import("lcu");

/// 一次最多查几个人。10 = 一局十个人，正好是唯一的用法；前端有同名上限。
pub const max_players: usize = 10;

/// 一个玩家的取数任务：两次 LCU 请求在**同一个线程**里串行跑，
/// 这样十个人才是十路并行，而不是二十路。
const PlayerJob = struct {
    client: lcu.Client,
    puuid: []const u8,
    ranked: ?[]u8 = null,
    summoner: ?[]u8 = null,
};

fn runPlayerJob(job: *PlayerJob) void {
    var path_buffer: [1280]u8 = undefined;
    if (std.fmt.bufPrint(&path_buffer, "/lol-ranked/v1/ranked-stats/{s}", .{job.puuid})) |path| {
        job.ranked = job.client.get(path) catch null;
    } else |_| {}
    if (std.fmt.bufPrint(&path_buffer, "/lol-summoner/v2/summoners/puuid/{s}", .{job.puuid})) |path| {
        job.summoner = job.client.get(path) catch null;
    } else |_| {}
}

/// `lol.get_player_stats` —— payload：`{puuids[], selfPuuid}`。
///
/// `selfPuuid` 与 `get_match_detail` 同义：只做**账号归属**校验（换号后旧结果一律拒绝），
/// 不参与查询。
pub fn getPlayerStats(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = backend.runtime(context);
    const payload_json = backend.parsePayload(
        struct { puuids: []const []const u8 = &.{}, selfPuuid: ?[]const u8 = null },
        invocation.request.payload,
    ) catch return error.InvalidRequest;
    defer payload_json.deinit();
    const payload = payload_json.value;
    if (self.live_owner_puuid_len > 0) {
        const owner = payload.selfPuuid orelse return error.AccountChanged;
        if (!samePuuid(owner, self.live_owner_puuid[0..self.live_owner_puuid_len])) return error.AccountChanged;
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var jobs: [max_players]PlayerJob = undefined;
    var threads: [max_players]?std.Thread = @splat(null);
    var count: usize = 0;
    var client_holder: ?lcu.Client = null;

    if (self.mode == .live) if (self.io) |io| {
        client_holder = backend.discoverClient(self, io) catch null;
        if (client_holder) |client| {
            // 去重 + 截断都做在这里，别指望调用方——前端传错也不至于打爆 LCU。
            for (payload.puuids) |raw_puuid| {
                if (count == max_players) break;
                const puuid = std.mem.trim(u8, raw_puuid, " \t\r\n");
                if (puuid.len == 0 or backend.isNumericIdentity(puuid)) continue;
                var duplicate = false;
                for (jobs[0..count]) |job| if (samePuuid(job.puuid, puuid)) {
                    duplicate = true;
                };
                if (duplicate) continue;
                jobs[count] = .{ .client = client, .puuid = puuid };
                threads[count] = std.Thread.spawn(.{}, runPlayerJob, .{&jobs[count]}) catch null;
                count += 1;
            }
        }
    };

    defer {
        for (threads[0..count]) |thread| if (thread) |value| value.join();
        // 凭据只在原 client 里 free 一次；jobs 里的都是同一块内存的浅拷贝，
        // 所以必须等所有线程 join 完才能 deinit（上面的 join 在同一个 defer 里）。
        if (client_holder) |*client| client.deinit();
    }

    // ⚠️ 解析、写输出、释放必须严格按这个顺序：`std.json.Value` 在默认的
    // `.alloc_if_needed` 策略下可能**引用输入缓冲里的字符串**，所以原始响应要等
    // 输出写完才能释放——提前 free 就是 use-after-free。
    const ParsedPlayer = struct { ranked: ?std.json.Value = null, level: ?i64 = null };
    var parsed_players: [max_players]ParsedPlayer = @splat(.{});

    for (jobs[0..count], 0..) |*job, job_index| {
        if (job.ranked) |body| parsed_players[job_index].ranked = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch null;
        if (job.summoner) |body| {
            const value = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch null;
            if (value) |root| parsed_players[job_index].level = backend.summonerLevelFromJson(backend.firstJsonValue(root));
        }
    }

    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll("{\"players\":[");
    for (jobs[0..count], 0..) |*job, job_index| {
        if (job_index > 0) try writer.writeAll(",");
        try backend.writePlayerStat(&writer, job.puuid, parsed_players[job_index].ranked, parsed_players[job_index].level);
    }
    try writer.writeAll("]}");

    for (jobs[0..count]) |*job| {
        if (job.ranked) |body| std.heap.page_allocator.free(body);
        if (job.summoner) |body| std.heap.page_allocator.free(body);
    }
    return writer.buffered();
}

/// puuid 比较：客户端偶尔会带空白，统一去掉再比，且大小写不敏感。
fn samePuuid(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, left, " \t\r\n"), std.mem.trim(u8, right, " \t\r\n"));
}

test "writePlayerStat emits level and both ranks, null when data missing" {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const ranked =
        \\{"summonerId":1,"queueMap":{"RANKED_SOLO_5x5":{"queueType":"RANKED_SOLO_5x5","tier":"DIAMOND","rank":"II","leaguePoints":67,"wins":62,"losses":49},"RANKED_FLEX_SR":{"queueType":"RANKED_FLEX_SR","tier":"UNRANKED","rank":"","leaguePoints":0,"wins":3,"losses":5}}}
    ;
    // ⚠️ leaky 解析会一直占着 allocator，所以必须套一个 arena，
    // 否则 testing.allocator 会把这算成内存泄漏、整个测试进程以 1 退出。
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), ranked, .{});
    try backend.writePlayerStat(&writer, "puuid-甲", parsed, @as(?i64, 315));

    try std.testing.expectEqualStrings(
        "{\"puuid\":\"puuid-甲\",\"summonerLevel\":315,\"soloRank\":{\"queueType\":\"RANKED_SOLO_5x5\",\"tier\":\"DIAMOND\",\"division\":\"II\",\"leaguePoints\":67,\"wins\":62,\"losses\":49},\"flexRank\":null}",
        writer.buffered(),
    );

    var missing = std.Io.Writer.fixed(&buffer);
    try backend.writePlayerStat(&missing, "puuid-乙", null, null);
    try std.testing.expectEqualStrings("{\"puuid\":\"puuid-乙\",\"summonerLevel\":null,\"soloRank\":null,\"flexRank\":null}", missing.buffered());
}
