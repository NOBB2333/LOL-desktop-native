//! 进行时操作 IPC handler：客户端卡住时的「急救」动作。
//!
//! 用途是「界面/流程卡死了」这种时候的最后一招，所以这里刻意**不做**账号归属校验
//! （`verifyActionAccount`）——那个校验自己会发一个 LCU 请求，多一个失败点；
//! 而这些动作本来就是对着当前会话来的，切号场景下也不会误伤别人。
//!
//! 路径与请求体都对齐 LeagueAkari（`http-api-axios-helper/league-client/`
//! 的 `gameflow.ts` / `lobby.ts`）：
//!
//! - 秒退：`POST /lol-gameflow/v1/session/dodge`，body `{"dodgeIds":[..],"phase":"ChampSelect"}`。
//! - 退出房间：`DELETE /lol-lobby/v2/lobby`。
//! - 退出结算页（回到房间）：`POST /lol-lobby/v2/play-again`，无 body。
//! - 重连：`POST /lol-gameflow/v1/reconnect`，无 body（治「卡在重连」）。
//! - 清掉「启动游戏失败」：`POST /lol-gameflow/v1/ack-failed-to-launch`，无 body
//!   （治「进不去游戏」，这时界面通常已经点不动了）。
const std = @import("std");
const native_sdk = @import("native_sdk");
const lcu = @import("lcu");
const backend = @import("../backend.zig");

/// AK 里秒退提交的就是这个哨兵 id，不是真实对局 id；照抄即可。
const dodge_sentinel_id: i64 = 1145141919810;

const ActionSpec = struct {
    key: []const u8,
    label: []const u8,
    /// 这个动作只在哪些 gameflow 阶段有意义（空 = 任何阶段）。
    phases: []const []const u8 = &.{},
};

/// 阶段限制只用来**提前**给玩家一句人话，真正的判定仍在客户端：
/// 阶段不对时 LCU 会自己拒绝，我们照原样把失败回报上去。
const action_table = [_]ActionSpec{
    .{ .key = "dodge", .label = "英雄选择秒退", .phases = &.{ "ChampSelect" } },
    .{ .key = "leave-lobby", .label = "退出房间", .phases = &.{ "Lobby", "Matchmaking", "ReadyCheck", "ChampSelect" } },
    .{ .key = "play-again", .label = "退出结算页面", .phases = &.{ "EndOfGame", "PreEndOfGame", "WaitingForStats" } },
    .{ .key = "reconnect", .label = "重新连接", .phases = &.{ "Reconnect" } },
    .{ .key = "ack-failed-launch", .label = "清除「启动游戏失败」", .phases = &.{ "FailedToLaunch" } },
};

/// `lol.gameflow_action` —— 执行一个进行时动作，永远返回结构化结果而不是抛错，
/// 这样界面能直接把 `reason` 显示出来（急救场景下「为什么没生效」比「失败了」重要）。
pub fn action(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = backend.runtime(context);
    const parsed = backend.parsePayload(struct { action: []const u8 = "" }, invocation.request.payload) catch return error.InvalidRequest;
    defer parsed.deinit();
    const key = parsed.value.action;
    var spec: ?ActionSpec = null;
    for (action_table) |candidate| if (std.mem.eql(u8, candidate.key, key)) {
        spec = candidate;
        break;
    };
    if (spec == null) return error.InvalidRequest;
    if (self.mode != .live) return resultJson(output, key, false, "", "没连上客户端");
    const io = self.io orelse return resultJson(output, key, false, "", "没连上客户端");
    var client = backend.discoverClient(self, io) catch return resultJson(output, key, false, "", "没连上客户端");
    defer client.deinit();

    var phase_buffer: [64]u8 = undefined;
    const phase = currentPhase(client, &phase_buffer);
    // 阶段列表**只**用来在失败时给出更具体的一句话，不用来提前拦截：
    // 阶段判断的真身在客户端，我这边列漏一个阶段就会把本来能用的操作挡掉，
    // 而「急救」恰恰是卡在非预期状态时才用的。
    execute(client, key) catch |err| return resultJson(output, key, false, phase, failureText(spec.?, phase, err));
    return resultJson(output, key, true, phase, "");
}

fn failureText(spec: ActionSpec, phase: []const u8, err: anyerror) []const u8 {
    if (err == error.InvalidRequest) return "请求参数不对";
    if (phase.len > 0 and spec.phases.len > 0 and !phaseAllowed(spec, phase)) return "当前阶段不能用这个操作";
    return reasonText(err);
}

fn phaseAllowed(spec: ActionSpec, phase: []const u8) bool {
    for (spec.phases) |candidate| if (std.ascii.eqlIgnoreCase(candidate, phase)) return true;
    return false;
}

fn execute(client: lcu.Client, key: []const u8) !void {
    const response = if (std.mem.eql(u8, key, "dodge")) blk: {
        var body_buffer: [128]u8 = undefined;
        const body = try std.fmt.bufPrint(&body_buffer, "{{\"dodgeIds\":[{d}],\"phase\":\"ChampSelect\"}}", .{dodge_sentinel_id});
        break :blk try client.post("/lol-gameflow/v1/session/dodge", body);
    } else if (std.mem.eql(u8, key, "leave-lobby")) try client.delete("/lol-lobby/v2/lobby") else if (std.mem.eql(u8, key, "play-again")) try client.postNoContent("/lol-lobby/v2/play-again") else if (std.mem.eql(u8, key, "reconnect")) try client.postNoContent("/lol-gameflow/v1/reconnect") else if (std.mem.eql(u8, key, "ack-failed-launch")) try client.postNoContent("/lol-gameflow/v1/ack-failed-to-launch") else return error.InvalidRequest;
    std.heap.page_allocator.free(response);
}

/// 读一下当前 gameflow 阶段。
///
/// 结果**复制进调用方的缓冲**再返回：LCU 的响应是堆上的，出了这个函数就被释放，
/// 直接返回切片会拿到已经失效的内存。
fn currentPhase(client: lcu.Client, buffer: []u8) []const u8 {
    const json = client.get("/lol-gameflow/v1/gameflow-phase") catch return "";
    defer std.heap.page_allocator.free(json);
    const trimmed = std.mem.trim(u8, json, " \t\r\n");
    if (trimmed.len < 2 or trimmed[0] != '"') return "";
    const inner = trimmed[1 .. trimmed.len - 1];
    if (inner.len > buffer.len) return "";
    @memcpy(buffer[0..inner.len], inner);
    return buffer[0..inner.len];
}

fn resultJson(output: []u8, action_key: []const u8, ok: bool, phase: []const u8, reason: []const u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll("{\"action\":");
    try backend.jsonString(&writer, action_key);
    try writer.writeAll(",\"ok\":");
    try writer.writeAll(if (ok) "true" else "false");
    try writer.writeAll(",\"phase\":");
    try backend.jsonString(&writer, phase);
    try writer.writeAll(",\"reason\":");
    try backend.jsonString(&writer, reason);
    try writer.writeByte('}');
    return writer.buffered();
}

fn reasonText(err: anyerror) []const u8 {
    return switch (err) {
        error.LcuNotRunning => "没连上客户端",
        error.RequestCancelled => "已取消",
        error.NoSpaceLeft => "结果太长，放不下",
        error.InvalidRequest => "请求参数不对",
        else => "客户端没有接受这个操作（多半是当前阶段不允许）",
    };
}

test "动作表与 handler 支持的动作集合一致" {
    // 防止以后加了表项却忘了在 execute 里接线（或反过来）。
    try std.testing.expectEqual(@as(usize, 5), action_table.len);
    for (action_table) |spec| try std.testing.expect(spec.key.len > 0 and spec.label.len > 0);
}

test "结果 JSON 是结构化的，成功失败都不抛错" {
    var output: [512]u8 = undefined;
    const ok = try resultJson(&output, "dodge", true, "ChampSelect", "");
    try std.testing.expectEqualStrings("{\"action\":\"dodge\",\"ok\":true,\"phase\":\"ChampSelect\",\"reason\":\"\"}", ok);

    const refused = try resultJson(&output, "dodge", false, "Lobby", "客户端没有接受这个操作（多半是当前阶段不允许）");
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, refused, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(false, parsed.value.object.get("ok").?.bool);
    try std.testing.expectEqualStrings("Lobby", parsed.value.object.get("phase").?.string);
}
