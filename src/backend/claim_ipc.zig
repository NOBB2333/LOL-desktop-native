//! 一键领取 IPC handler：任务 / 奖励（grants）/ 事件中心（通行证奖励轨道）。
//!
//! 三处的接口与「什么算可领、怎么提交」都是从 LeagueAkari 抄准的
//! （`src/shared/http-api-axios-helper/league-client/` 下的 `missions.ts` /
//! `rewards.ts` / `event-hub.ts`，以及 `views/toolkit/claim-tools/` 里三个组件）。
//! **不要凭记忆改路径或请求体**：
//!
//! - 任务：`GET /lol-missions/v1/missions` → 取 `status == "SELECT_REWARDS"`；
//!   领取 `PUT /lol-missions/v1/player/{id}`，body `{"rewardGroups":[...]}`。
//! - 奖励：`GET /lol-rewards/v1/grants?status=PENDING_SELECTION`；
//!   领取 `POST /lol-rewards/v1/grants/{id}/select`，
//!   body `{"grantId":..,"rewardGroupId":..,"selections":[..]}`。
//! - 事件中心：`GET /lol-event-hub/v1/events`，`eventInfo.unclaimedRewardCount > 0`
//!   就是有待领；领取 `POST /lol-event-hub/v1/events/{eventId}/reward-track/claim-all`
//!   （AK 传 `undefined`，即**没有 body**，所以这里用 `postNoContent`）。
//!
//! 「多选一」的地方 AK 走加权随机（`ChoiceMaker`）；我们取**前 N 个**：
//! 提交的都是合法的一份，结果等价，但不引入随机，测试才能断言。
const std = @import("std");
const native_sdk = @import("native_sdk");
const lcu = @import("lcu");
const backend = @import("../backend.zig");

/// 每个来源最多列/领多少项。
///
/// 这三处的真实条目数是几十的量级，给上限既护住固定输出缓冲，也免得界面被刷屏。
const claim_item_limit: usize = 50;

/// 领取时提交的 body 都是短 id 数组，4KB 绰绰有余。
const body_buffer_size: usize = 4 * 1024;

const empty_claims_json = "{\"items\":[],\"sources\":[],\"total\":0}";

const ClaimPlan = struct {
    key: []const u8,
    id: []const u8,
    title: []const u8,
    detail: []const u8,
    icon: []const u8,
    /// 多选一场景要提交的选项 id（任务 = rewardGroup，奖励 = reward id）。事件为空。
    selection: []const []const u8,
    /// 奖励的 select 接口还要带上 `rewardGroupId`，只有这条来源用得到。
    parent: []const u8 = "",
    /// 这一项里包含几份奖励，给界面显示用。
    count: usize,
};

/// `lol.get_claims` —— 汇总「现在就能领」的东西，只读，不改任何状态。
pub fn getClaims(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = backend.runtime(context);
    _ = invocation;
    if (self.mode != .live) return backend.copyJson(empty_claims_json, output);
    const io = self.io orelse return error.LcuNotRunning;
    var client = backend.discoverClient(self, io) catch return error.LcuNotRunning;
    defer client.deinit();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const missions = client.get("/lol-missions/v1/missions") catch null;
    defer if (missions) |value| std.heap.page_allocator.free(value);
    const grants = client.get("/lol-rewards/v1/grants?status=PENDING_SELECTION") catch null;
    defer if (grants) |value| std.heap.page_allocator.free(value);
    const events = client.get("/lol-event-hub/v1/events") catch null;
    defer if (events) |value| std.heap.page_allocator.free(value);

    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll("{\"items\":[");
    var first = true;
    var mission_count: usize = 0;
    for (parseArray(allocator, missions)) |mission| {
        if (mission_count >= claim_item_limit) break;
        const plan = missionPlan(allocator, mission) orelse continue;
        try writeItem(&writer, &first, "mission", "任务", plan);
        mission_count += 1;
    }
    var reward_count: usize = 0;
    for (parseArray(allocator, grants)) |grant| {
        if (reward_count >= claim_item_limit) break;
        const plan = rewardPlan(allocator, grant) orelse continue;
        try writeItem(&writer, &first, "reward", "奖励", plan);
        reward_count += 1;
    }
    var event_count: usize = 0;
    for (parseArray(allocator, events)) |event| {
        if (event_count >= claim_item_limit) break;
        const plan = eventPlan(allocator, event) orelse continue;
        try writeItem(&writer, &first, "event", "事件中心", plan);
        event_count += 1;
    }
    try writer.writeAll("],\"sources\":[");
    try writeSource(&writer, "mission", "任务", mission_count);
    try writer.writeByte(',');
    try writeSource(&writer, "reward", "奖励", reward_count);
    try writer.writeByte(',');
    try writeSource(&writer, "event", "事件中心", event_count);
    try writer.print("],\"total\":{d}}}", .{mission_count + reward_count + event_count});
    return writer.buffered();
}

/// `lol.claim` —— 领取。
///
/// `keys` 为空表示「这一来源下所有可领的都领」，否则只领 key 命中的那些。
/// 逐项提交、逐项回报：一项失败不影响其余，前端能把失败原因列出来。
pub fn claim(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = backend.runtime(context);
    const parsed = backend.parsePayload(struct {
        source: []const u8 = "",
        keys: []const []const u8 = &.{},
    }, invocation.request.payload) catch return error.InvalidRequest;
    defer parsed.deinit();
    const payload = parsed.value;
    const wants_mission = std.mem.eql(u8, payload.source, "mission") or std.mem.eql(u8, payload.source, "all");
    const wants_reward = std.mem.eql(u8, payload.source, "reward") or std.mem.eql(u8, payload.source, "all");
    const wants_event = std.mem.eql(u8, payload.source, "event") or std.mem.eql(u8, payload.source, "all");
    if (!wants_mission and !wants_reward and !wants_event) return error.InvalidRequest;

    if (self.mode != .live) return error.LcuNotRunning;
    const io = self.io orelse return error.LcuNotRunning;
    var client = backend.discoverClient(self, io) catch return error.LcuNotRunning;
    defer client.deinit();
    // 领取会写进当前登录账号的库存，切号后照旧执行会很糟，所以先校验归属。
    try backend.verifyActionAccount(self, client);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll("{\"claimed\":[");
    var first = true;
    var claimed_count: usize = 0;
    var failed_count: usize = 0;

    if (wants_mission) {
        const missions = client.get("/lol-missions/v1/missions") catch null;
        defer if (missions) |value| std.heap.page_allocator.free(value);
        for (parseArray(allocator, missions)) |mission| {
            if (claimed_count + failed_count >= claim_item_limit) break;
            const plan = missionPlan(allocator, mission) orelse continue;
            if (!wanted(payload.keys, plan.key)) continue;
            claimMission(&writer, &first, client, plan, &claimed_count, &failed_count);
        }
    }
    if (wants_reward) {
        const grants = client.get("/lol-rewards/v1/grants?status=PENDING_SELECTION") catch null;
        defer if (grants) |value| std.heap.page_allocator.free(value);
        for (parseArray(allocator, grants)) |grant| {
            if (claimed_count + failed_count >= claim_item_limit) break;
            const plan = rewardPlan(allocator, grant) orelse continue;
            if (!wanted(payload.keys, plan.key)) continue;
            claimReward(&writer, &first, client, plan, &claimed_count, &failed_count);
        }
    }
    if (wants_event) {
        const events = client.get("/lol-event-hub/v1/events") catch null;
        defer if (events) |value| std.heap.page_allocator.free(value);
        for (parseArray(allocator, events)) |event| {
            if (claimed_count + failed_count >= claim_item_limit) break;
            const plan = eventPlan(allocator, event) orelse continue;
            if (!wanted(payload.keys, plan.key)) continue;
            claimEvent(&writer, &first, client, plan, &claimed_count, &failed_count);
        }
    }
    try writer.print("],\"claimedCount\":{d},\"failedCount\":{d}}}", .{ claimed_count, failed_count });
    return writer.buffered();
}

fn wanted(keys: []const []const u8, key: []const u8) bool {
    if (keys.len == 0) return true;
    for (keys) |item| if (std.mem.eql(u8, item, key)) return true;
    return false;
}

fn claimMission(
    writer: *std.Io.Writer,
    first: *bool,
    client: lcu.Client,
    plan: ClaimPlan,
    claimed: *usize,
    failed: *usize,
) void {
    var path_buffer: [768]u8 = undefined;
    var body_buffer: [body_buffer_size]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "/lol-missions/v1/player/{s}", .{plan.id}) catch {
        writeFailure(writer, first, "mission", plan, error.InvalidRequest);
        failed.* += 1;
        return;
    };
    const body = stringArrayBody(&body_buffer, "rewardGroups", plan.selection) catch {
        writeFailure(writer, first, "mission", plan, error.InvalidRequest);
        failed.* += 1;
        return;
    };
    const response = client.put(path, body) catch |err| {
        writeFailure(writer, first, "mission", plan, err);
        failed.* += 1;
        return;
    };
    std.heap.page_allocator.free(response);
    writeSuccess(writer, first, "mission", plan);
    claimed.* += 1;
}

fn claimReward(
    writer: *std.Io.Writer,
    first: *bool,
    client: lcu.Client,
    plan: ClaimPlan,
    claimed: *usize,
    failed: *usize,
) void {
    var path_buffer: [768]u8 = undefined;
    var body_buffer: [body_buffer_size]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "/lol-rewards/v1/grants/{s}/select", .{plan.id}) catch {
        writeFailure(writer, first, "reward", plan, error.InvalidRequest);
        failed.* += 1;
        return;
    };
    const body = grantSelectBody(&body_buffer, plan.id, plan.parent, plan.selection) catch {
        writeFailure(writer, first, "reward", plan, error.InvalidRequest);
        failed.* += 1;
        return;
    };
    const response = client.post(path, body) catch |err| {
        writeFailure(writer, first, "reward", plan, err);
        failed.* += 1;
        return;
    };
    std.heap.page_allocator.free(response);
    writeSuccess(writer, first, "reward", plan);
    claimed.* += 1;
}

fn claimEvent(
    writer: *std.Io.Writer,
    first: *bool,
    client: lcu.Client,
    plan: ClaimPlan,
    claimed: *usize,
    failed: *usize,
) void {
    var path_buffer: [768]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "/lol-event-hub/v1/events/{s}/reward-track/claim-all", .{plan.id}) catch {
        writeFailure(writer, first, "event", plan, error.InvalidRequest);
        failed.* += 1;
        return;
    };
    const response = client.postNoContent(path) catch |err| {
        writeFailure(writer, first, "event", plan, err);
        failed.* += 1;
        return;
    };
    std.heap.page_allocator.free(response);
    writeSuccess(writer, first, "event", plan);
    claimed.* += 1;
}

// ---------------------------------------------------------------- 计划推导

/// 任务：`SELECT_REWARDS` 表示「奖励已到手，等你选/领」。
fn missionPlan(allocator: std.mem.Allocator, mission: std.json.Value) ?ClaimPlan {
    if (mission != .object) return null;
    if (!std.mem.eql(u8, backend.jsonField(mission, "status"), "SELECT_REWARDS")) return null;
    const id = backend.jsonField(mission, "id");
    if (id.len == 0) return null;
    const rewards = arrayOf(at(mission, "rewards"));
    if (rewards.len == 0) return null;
    const max_select = @max(@as(i64, 1), backend.jsonInt(at(mission, "rewardStrategy"), "selectMaxGroupCount"));
    var selection = std.ArrayList([]const u8).empty;
    var detail_buffer = std.ArrayList(u8).empty;
    for (rewards) |reward| {
        const group = backend.jsonField(reward, "rewardGroup");
        if (group.len == 0) continue;
        if (selection.items.len >= @as(usize, @intCast(max_select))) break;
        selection.append(allocator, group) catch return null;
        // 详情只列实际会提交的那几份，免得界面写着「三选一」却把三份都列出来。
        const description = backend.jsonField(reward, "description");
        if (description.len == 0) continue;
        if (detail_buffer.items.len > 0) detail_buffer.appendSlice(allocator, " · ") catch return null;
        detail_buffer.appendSlice(allocator, description) catch return null;
    }
    if (selection.items.len == 0) return null;
    const title = if (backend.jsonField(mission, "title").len > 0) backend.jsonField(mission, "title") else backend.jsonField(mission, "internalName");
    return .{
        .key = std.fmt.allocPrint(allocator, "mission:{s}", .{id}) catch return null,
        .id = id,
        .title = title,
        .detail = detail_buffer.items,
        .icon = backend.jsonField(rewards[0], "iconUrl"),
        .selection = selection.items,
        .count = selection.items.len,
    };
}

/// 奖励：`PENDING_SELECTION` 的 grant。
fn rewardPlan(allocator: std.mem.Allocator, grant: std.json.Value) ?ClaimPlan {
    if (grant != .object) return null;
    const info = at(grant, "info");
    const id = backend.jsonField(info, "id");
    if (id.len == 0) return null;
    const group = at(grant, "rewardGroup");
    const group_id = if (backend.jsonField(group, "id").len > 0) backend.jsonField(group, "id") else backend.jsonField(info, "rewardGroupId");
    if (group_id.len == 0) return null;
    const rewards = arrayOf(at(group, "rewards"));
    if (rewards.len == 0) return null;
    const strategy = at(group, "selectionStrategyConfig");
    // `selectionStrategyConfig` 可能是 null —— 那就是单选一份。
    const max_select = @max(@as(i64, 1), backend.jsonInt(strategy, "maxSelectionsAllowed"));
    var selection = std.ArrayList([]const u8).empty;
    var detail_buffer = std.ArrayList(u8).empty;
    for (rewards) |reward| {
        const reward_id = backend.jsonField(reward, "id");
        if (reward_id.len == 0) continue;
        if (selection.items.len >= @as(usize, @intCast(max_select))) break;
        selection.append(allocator, reward_id) catch return null;
        const title = backend.jsonField(at(reward, "localizations"), "title");
        if (title.len == 0) continue;
        if (detail_buffer.items.len > 0) detail_buffer.appendSlice(allocator, " · ") catch return null;
        detail_buffer.appendSlice(allocator, title) catch return null;
    }
    if (selection.items.len == 0) return null;
    // 标题优先用奖励组自己的名字；没有就退回发放者描述。
    const group_title = backend.jsonField(at(group, "localizations"), "title");
    const title = if (group_title.len > 0) group_title else backend.jsonField(at(info, "grantorDescription"), "appName");
    return .{
        .key = std.fmt.allocPrint(allocator, "reward:{s}", .{id}) catch return null,
        .id = id,
        .title = title,
        .detail = detail_buffer.items,
        .icon = backend.jsonField(at(rewards[0], "media"), "iconUrl"),
        .selection = selection.items,
        .parent = group_id,
        .count = selection.items.len,
    };
}

/// 事件中心：通行证奖励轨道有没领的就能一键全领。
fn eventPlan(allocator: std.mem.Allocator, event: std.json.Value) ?ClaimPlan {
    if (event != .object) return null;
    const info = at(event, "eventInfo");
    const id = if (backend.jsonField(event, "eventId").len > 0) backend.jsonField(event, "eventId") else backend.jsonField(info, "eventId");
    if (id.len == 0) return null;
    const unclaimed = backend.jsonInt(info, "unclaimedRewardCount");
    if (unclaimed <= 0) return null;
    return .{
        .key = std.fmt.allocPrint(allocator, "event:{s}", .{id}) catch return null,
        .id = id,
        .title = backend.jsonField(info, "eventName"),
        .detail = std.fmt.allocPrint(allocator, "奖励轨道待领 {d} 项", .{unclaimed}) catch return null,
        .icon = backend.jsonField(info, "eventIcon"),
        .selection = &.{},
        .count = @intCast(unclaimed),
    };
}

// ---------------------------------------------------------------- 写 JSON

fn writeItem(writer: *std.Io.Writer, first: *bool, source: []const u8, label: []const u8, plan: ClaimPlan) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
    try writer.writeAll("{\"key\":");
    try backend.jsonString(writer, plan.key);
    try writer.writeAll(",\"source\":");
    try backend.jsonString(writer, source);
    try writer.writeAll(",\"sourceLabel\":");
    try backend.jsonString(writer, label);
    try writer.writeAll(",\"id\":");
    try backend.jsonString(writer, plan.id);
    try writer.writeAll(",\"title\":");
    try backend.jsonString(writer, plan.title);
    try writer.writeAll(",\"detail\":");
    try backend.jsonString(writer, plan.detail);
    try writer.writeAll(",\"iconUrl\":");
    if (plan.icon.len > 0) try backend.jsonString(writer, plan.icon) else try writer.writeAll("null");
    try writer.print(",\"count\":{d}}}", .{plan.count});
}

fn writeSource(writer: *std.Io.Writer, source: []const u8, label: []const u8, count: usize) !void {
    try writer.writeAll("{\"source\":");
    try backend.jsonString(writer, source);
    try writer.writeAll(",\"label\":");
    try backend.jsonString(writer, label);
    try writer.print(",\"count\":{d}}}", .{count});
}

fn writeSuccess(writer: *std.Io.Writer, first: *bool, source: []const u8, plan: ClaimPlan) void {
    if (!first.*) writer.writeByte(',') catch return;
    first.* = false;
    writer.writeAll("{\"source\":") catch return;
    backend.jsonString(writer, source) catch return;
    writer.writeAll(",\"id\":") catch return;
    backend.jsonString(writer, plan.id) catch return;
    writer.writeAll(",\"title\":") catch return;
    backend.jsonString(writer, plan.title) catch return;
    writer.writeAll(",\"detail\":") catch return;
    backend.jsonString(writer, plan.detail) catch return;
    writer.writeByte('}') catch return;
}

fn writeFailure(writer: *std.Io.Writer, first: *bool, source: []const u8, plan: ClaimPlan, err: anyerror) void {
    if (!first.*) writer.writeByte(',') catch return;
    first.* = false;
    writer.writeAll("{\"source\":") catch return;
    backend.jsonString(writer, source) catch return;
    writer.writeAll(",\"id\":") catch return;
    backend.jsonString(writer, plan.id) catch return;
    writer.writeAll(",\"title\":") catch return;
    backend.jsonString(writer, plan.title) catch return;
    writer.writeAll(",\"reason\":") catch return;
    backend.jsonString(writer, reasonText(err)) catch return;
    writer.writeByte('}') catch return;
}

/// 把 Zig 错误翻成能给玩家看的一句话。
fn reasonText(err: anyerror) []const u8 {
    return switch (err) {
        error.LcuNotRunning => "没连上客户端",
        error.LcuRequestFailed => "客户端拒绝了这个请求",
        error.AccountChanged => "账号已切换，已中止",
        error.RequestCancelled => "已取消",
        error.NoSpaceLeft => "结果太长，放不下",
        error.InvalidRequest => "请求参数不对",
        else => "领取失败",
    };
}

fn stringArrayBody(buffer: []u8, field: []const u8, values: []const []const u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writer.print("{{\"{s}\":[", .{field});
    for (values, 0..) |value, index| {
        if (index > 0) try writer.writeByte(',');
        try backend.jsonString(&writer, value);
    }
    try writer.writeAll("]}");
    return writer.buffered();
}

fn grantSelectBody(buffer: []u8, grant_id: []const u8, group_id: []const u8, selection: []const []const u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writer.writeAll("{\"grantId\":");
    try backend.jsonString(&writer, grant_id);
    try writer.writeAll(",\"rewardGroupId\":");
    try backend.jsonString(&writer, group_id);
    try writer.writeAll(",\"selections\":[");
    for (selection, 0..) |value, index| {
        if (index > 0) try writer.writeByte(',');
        try backend.jsonString(&writer, value);
    }
    try writer.writeAll("]}");
    return writer.buffered();
}

// ---------------------------------------------------------------- 小工具

fn at(value: std.json.Value, name: []const u8) std.json.Value {
    if (value != .object) return .{ .null = {} };
    return value.object.get(name) orelse .{ .null = {} };
}

fn arrayOf(value: std.json.Value) []std.json.Value {
    if (value != .array) return &.{};
    return value.array.items;
}

fn parseArray(allocator: std.mem.Allocator, json: ?[]const u8) []std.json.Value {
    const text = json orelse return &.{};
    const value = std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{}) catch return &.{};
    return arrayOf(value);
}

// ---------------------------------------------------------------- 测试

test "任务：SELECT_REWARDS 才算可领，且只提交前 N 个 rewardGroup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const json =
        \\{"id":"m-1","status":"SELECT_REWARDS","title":"首胜","rewards":[
        \\  {"rewardGroup":"rg-1","description":"蓝色精粹 500","iconUrl":"a.png"},
        \\  {"rewardGroup":"rg-2","description":"钥匙 1","iconUrl":"b.png"}
        \\],"rewardStrategy":{"selectMaxGroupCount":1,"selectMinGroupCount":1}}
    ;
    const mission = try std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{});
    const plan = missionPlan(allocator, mission).?;
    try std.testing.expectEqualStrings("mission:m-1", plan.key);
    try std.testing.expectEqualStrings("首胜", plan.title);
    // 多选一只取第一个，且详情只列提交的那一份。
    try std.testing.expectEqual(@as(usize, 1), plan.selection.len);
    try std.testing.expectEqualStrings("rg-1", plan.selection[0]);
    try std.testing.expectEqualStrings("蓝色精粹 500", plan.detail);

    const finished = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"id\":\"m-2\",\"status\":\"COMPLETED\"}", .{});
    try std.testing.expect(missionPlan(allocator, finished) == null);
}

test "奖励：selectionStrategyConfig 为 null 时按单选处理" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const json =
        \\{"info":{"id":"g-1","status":"PENDING_SELECTION","rewardGroupId":"rg-9"},"rewardGroup":{
        \\  "id":"rg-9","localizations":{"title":"自选皮肤"},
        \\  "rewards":[{"id":"r-1","localizations":{"title":"皮肤 A"}},{"id":"r-2","localizations":{"title":"皮肤 B"}}],
        \\  "selectionStrategyConfig":null}}
    ;
    const grant = try std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{});
    const plan = rewardPlan(allocator, grant).?;
    try std.testing.expectEqualStrings("reward:g-1", plan.key);
    try std.testing.expectEqualStrings("自选皮肤", plan.title);
    try std.testing.expectEqual(@as(usize, 1), plan.selection.len);
    try std.testing.expectEqualStrings("r-1", plan.selection[0]);
    try std.testing.expectEqualStrings("皮肤 A", plan.detail);
}

test "事件中心：unclaimedRewardCount 为 0 就不算可领" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const claimable = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{"eventId":"e-1","eventInfo":{"eventName":"灵魂莲华","unclaimedRewardCount":3,"eventIcon":"i.png"}}
    , .{});
    const plan = eventPlan(allocator, claimable).?;
    try std.testing.expectEqualStrings("event:e-1", plan.key);
    try std.testing.expectEqualStrings("灵魂莲华", plan.title);
    try std.testing.expectEqual(@as(usize, 3), plan.count);

    const empty = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{"eventId":"e-2","eventInfo":{"eventName":"空的","unclaimedRewardCount":0}}
    , .{});
    try std.testing.expect(eventPlan(allocator, empty) == null);
}

test "请求体形状与 AK 一致" {
    var buffer: [512]u8 = undefined;
    const mission_body = try stringArrayBody(&buffer, "rewardGroups", &.{ "rg-1", "rg-2" });
    try std.testing.expectEqualStrings("{\"rewardGroups\":[\"rg-1\",\"rg-2\"]}", mission_body);

    var second: [512]u8 = undefined;
    const grant_body = try grantSelectBody(&second, "g-1", "rg-9", &.{"r-1"});
    try std.testing.expectEqualStrings("{\"grantId\":\"g-1\",\"rewardGroupId\":\"rg-9\",\"selections\":[\"r-1\"]}", grant_body);
}
