const std = @import("std");
const lcu = @import("lcu");

var ready_check_deadline_ms: i64 = 0;
var ready_check_delay_done = false;
var ready_check_accept_sent = false;
var ready_check_retry_at_ms: i64 = 0;
var pick_action_id: i64 = 0;
var pick_champion_id: i64 = 0;
var pick_lock_deadline_ms: i64 = 0;
var pick_intent_sent = false;
var pick_lock_sent = false;

/// 大乱斗抢人的状态机。
///
/// `target_id` / `target_seen_ms` 记的是「替补席上这个目标英雄是**什么时候**出现的」。
/// 对齐 AK 的 `benchSwapAccumulatedDelaySeconds`（默认 2.9 秒，我们取整成 3 秒）：
/// 换人是不可逆的，刚出现在替补席上就立刻抢掉既不礼貌也容易点错，留几秒给手动换人。
/// `pending_swap_id` / `pending_until_ms` 是「请求已发出、客户端还没反映过来」的窗口，
/// 避免每 250ms 重复 POST 同一次换人。
var aram_target_id: i64 = 0;
var aram_target_seen_ms: i64 = 0;
var aram_pending_swap_id: i64 = 0;
var aram_pending_until_ms: i64 = 0;

const PendingAction = struct {
    action_type: []const u8,
    action_id: i64,
    champion_id: i64,
    current_champion_id: i64,
};

const ReadyCheckRoute = enum { matchmaking, team_builder };

const ReadyCheckSnapshot = struct {
    json: []u8,
    route: ReadyCheckRoute,
};

pub fn run(io: std.Io, client: lcu.Client, config_json: []const u8, output: []u8) ![]const u8 {
    // This function runs every 250 ms. Keep all parsed trees in a per-pass
    // arena; page-allocator-backed leaky parses would accumulate indefinitely.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const config = std.json.parseFromSliceLeaky(std.json.Value, allocator, config_json, .{}) catch return error.InvalidConfig;
    if (!automationBool(config, "enabled")) return error.AutomationDisabled;

    const phase_json = client.get("/lol-gameflow/v1/gameflow-phase") catch return error.LcuRequestFailed;
    defer std.heap.page_allocator.free(phase_json);
    const phase_value = std.json.parseFromSliceLeaky(std.json.Value, allocator, phase_json, .{}) catch return error.LcuInvalidResponse;
    if (phase_value != .string) return error.LcuInvalidResponse;
    const phase = phase_value.string;

    const normalized_phase = std.mem.trim(u8, phase, " \t\r\n");
    if (std.mem.eql(u8, normalized_phase, "ReadyCheck")) return runReadyCheck(io, client, config, allocator, output);
    // Some team-builder queues publish their active ready-check before
    // gameflow changes from Matchmaking. Probe only queue-adjacent phases.
    if (automationBool(config, "autoAccept") and
        (std.mem.eql(u8, normalized_phase, "Matchmaking") or std.mem.eql(u8, normalized_phase, "Lobby")) and
        hasActionableReadyCheck(client, allocator))
    {
        return runReadyCheck(io, client, config, allocator, output);
    }
    ready_check_deadline_ms = 0;
    ready_check_delay_done = false;
    ready_check_accept_sent = false;
    ready_check_retry_at_ms = 0;
    if (!std.mem.eql(u8, normalized_phase, "ChampSelect")) {
        resetPickState();
        resetAramState();
        return std.fmt.bufPrint(output, "[]", .{});
    }

    const session_json = client.get("/lol-champ-select/v1/session") catch return error.LcuRequestFailed;
    defer std.heap.page_allocator.free(session_json);
    const session = std.json.parseFromSliceLeaky(std.json.Value, allocator, session_json, .{}) catch return error.LcuInvalidResponse;

    // 大乱斗没有 pick/ban action：进选人时客户端已经随机分好英雄，只能从替补席换人。
    // 所以这条路要**先于**选人/禁用那条走，否则永远轮不到（`selectPendingAction` 在
    // 大乱斗里必然返回 null）。
    if (aramGrabEnabled(config) and isBenchSelect(session)) {
        return runAramGrab(io, client, config, session, output);
    }
    resetAramState();
    const pending = selectPendingAction(config, session) orelse {
        // There is no active local action, or the player has already made a
        // manual choice. Keep state only while the same action is alive.
        resetPickState();
        return std.fmt.bufPrint(output, "[]", .{});
    };
    if (pending.champion_id <= 0) {
        return writeAction(output, pending.action_type, pending.action_id, 0, false, "候选列表为空，或候选英雄已被占用");
    }
    if (automationBool(config, "advisoryMode")) {
        return writeAction(output, pending.action_type, pending.action_id, pending.champion_id, false, "建议模式：已生成动作，不会写入客户端");
    }

    var endpoint_buffer: [256]u8 = undefined;
    const endpoint = std.fmt.bufPrint(&endpoint_buffer, "/lol-champ-select/v1/session/actions/{d}", .{pending.action_id}) catch return error.InvalidConfig;
    var body_buffer: [128]u8 = undefined;
    var completed = std.mem.eql(u8, pending.action_type, "ban");
    var reason: []const u8 = "已提交 LCU action";
    if (std.mem.eql(u8, pending.action_type, "pick")) {
        const strategy = pickStrategy(config);
        const delay_seconds = std.math.clamp(automationInt(config, "autoPickDelaySeconds", 1), @as(i64, 0), @as(i64, 10));
        const now_ms: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
        var intent_sent_this_pass = false;
        if (pick_action_id != pending.action_id or pick_champion_id != pending.champion_id) {
            pick_action_id = pending.action_id;
            pick_champion_id = pending.champion_id;
            // Always make the first non-immediate pass an explicit hover
            // request.  Some LCU builds expose the configured/current id in
            // `championId` before the action is actually rendered; treating
            // that field as an acknowledged intent made the next watchdog
            // tick submit completed:true without a visible hover.
            pick_intent_sent = false;
            pick_lock_sent = false;
            // The countdown starts only after the intent request succeeds (or
            // after we observe that the same champion was already shown).
            // Starting it before the network round-trip can make a one-second
            // delay expire before the client has rendered the highlight.
            pick_lock_deadline_ms = 0;
        }
        if (pick_lock_sent) return writeAction(output, "pick", pending.action_id, pending.champion_id, false, "已发送锁定请求，等待客户端完成");
        if (!std.mem.eql(u8, strategy, "lock-in-immediately") and !pick_intent_sent) {
            intent_sent_this_pass = true;
            if (pending.current_champion_id != pending.champion_id) {
                const intent_body = actionBody("pick-intent", pending.champion_id, false, &body_buffer) catch return error.InvalidConfig;
                const intent_response = client.patch(endpoint, intent_body) catch {
                    return error.LcuRequestFailed;
                };
                // The LCU can acknowledge PATCH before championPickIntent is
                // visible in the next session response. The session remains
                // the authoritative acknowledgement, but keep the sent state
                // so the configured delay is not restarted on every poll.
                std.heap.page_allocator.free(intent_response);
            }
            pick_intent_sent = true;
            // Even a zero configured delay gets one polling tick in which the
            // client can render the highlighted champion before lock-in.
            pick_lock_deadline_ms = now_ms + if (delay_seconds > 0) delay_seconds * std.time.ms_per_s else 250;
            if (!std.mem.eql(u8, strategy, "lock-in-immediately")) {
                return writeAction(output, "pick", pending.action_id, pending.champion_id, true, "已亮出英雄，等待客户端更新");
            }
        }
        if (std.mem.eql(u8, strategy, "just-show")) {
            // Keep the hover alive if this LCU build acknowledges the PATCH
            // before exposing championPickIntent in the next session read.
            // There is deliberately no completed:true request in this mode.
            if (!intent_sent_this_pass and pick_intent_sent and pending.current_champion_id != pending.champion_id) {
                const retry_body = actionBody("pick-intent", pending.champion_id, false, &body_buffer) catch return error.InvalidConfig;
                const retry_response = client.patch(endpoint, retry_body) catch return error.LcuRequestFailed;
                std.heap.page_allocator.free(retry_response);
            }
            return writeAction(output, "pick", pending.action_id, pending.champion_id, false, "已亮出英雄，等待手动锁定");
        }
        if (std.mem.eql(u8, strategy, "show-and-lock-in")) {
            // A lock countdown is valid only after the configured champion is
            // visible in the LCU action. Do not treat a stale/intermediate
            // action championId as a completed hover.
            if (pick_lock_deadline_ms == 0 and pending.current_champion_id == pending.champion_id) {
                pick_lock_deadline_ms = now_ms + if (delay_seconds > 0) delay_seconds * std.time.ms_per_s else 250;
            }
            if (now_ms < pick_lock_deadline_ms) {
                const remaining = @divTrunc(pick_lock_deadline_ms - now_ms + 999, 1000);
                var reason_buffer: [128]u8 = undefined;
                reason = std.fmt.bufPrint(&reason_buffer, "已亮出英雄，将在 {d} 秒后锁定", .{remaining}) catch "已亮出英雄，等待锁定";
                return writeAction(output, "pick", pending.action_id, pending.champion_id, true, reason);
            }
            // Do not turn a successful PATCH into an immediate lock when the
            // client has not rendered the hover yet. On slower LCU builds the
            // action endpoint can acknowledge the request before
            // championPickIntent/championId is updated. Keep sending the
            // intent until the server confirms the highlighted champion.
            if (pending.current_champion_id != pending.champion_id) {
                pick_intent_sent = false;
                pick_lock_deadline_ms = now_ms + 250;
                return writeAction(output, "pick", pending.action_id, pending.champion_id, true, "已发送亮人请求，等待客户端确认后锁定");
            }
        }
        completed = true;
        reason = "已提交英雄锁定";
    }
    const body = if (completed)
        actionBody(pending.action_type, pending.champion_id, true, &body_buffer) catch return error.InvalidConfig
    else
        actionBody("pick-intent", pending.champion_id, false, &body_buffer) catch return error.InvalidConfig;
    const response = client.patch(endpoint, body) catch return error.LcuRequestFailed;
    std.heap.page_allocator.free(response);
    if (std.mem.eql(u8, pending.action_type, "pick") and completed) pick_lock_sent = true;
    return writeAction(output, pending.action_type, pending.action_id, pending.champion_id, true, reason);
}

fn runReadyCheck(io: std.Io, client: lcu.Client, config: std.json.Value, allocator: std.mem.Allocator, output: []u8) ![]const u8 {
    if (!automationBool(config, "autoAccept")) {
        ready_check_deadline_ms = 0;
        ready_check_delay_done = false;
        ready_check_accept_sent = false;
        ready_check_retry_at_ms = 0;
        return writeAction(output, "accept", 0, 0, false, "自动接受未开启");
    }
    if (automationBool(config, "advisoryMode")) {
        ready_check_deadline_ms = 0;
        ready_check_delay_done = false;
        ready_check_accept_sent = false;
        ready_check_retry_at_ms = 0;
        return writeAction(output, "accept", 0, 0, false, "建议模式：不会接受队列");
    }

    // LCU can keep returning ReadyCheck briefly after accepting. Poll the
    // server state after the POST instead of claiming success from HTTP 204.
    if (ready_check_accept_sent) {
        const sent_snapshot = getReadyCheck(client, allocator) catch return error.LcuRequestFailed;
        defer std.heap.page_allocator.free(sent_snapshot.json);
        const sent_ready = std.json.parseFromSliceLeaky(std.json.Value, allocator, sent_snapshot.json, .{}) catch return error.LcuInvalidResponse;
        const sent_response = std.mem.trim(u8, jsonStringField(sent_ready, "playerResponse"), " \t\r\n");
        if (std.ascii.eqlIgnoreCase(sent_response, "Accepted")) {
            ready_check_accept_sent = false;
            ready_check_retry_at_ms = 0;
            return writeAction(output, "accept", 0, 0, true, "客户端已确认接受对局");
        }
        if (std.ascii.eqlIgnoreCase(sent_response, "Declined")) {
            ready_check_accept_sent = false;
            ready_check_retry_at_ms = 0;
            return writeAction(output, "accept", 0, 0, false, "客户端已拒绝本次对局");
        }
        const now_ms = nowMillis(io);
        if (ready_check_retry_at_ms == 0 or now_ms < ready_check_retry_at_ms) {
            return writeAction(output, "accept", 0, 0, false, "已发送接受请求，等待客户端确认");
        }
        // A few LCU versions acknowledge the POST with 204 but do not update
        // playerResponse until the next event loop. Do not get stuck forever:
        // after a short confirmation window, allow an idempotent retry.
        ready_check_accept_sent = false;
        ready_check_retry_at_ms = 0;
    }

    const delay_seconds = std.math.clamp(automationInt(config, "autoAcceptDelaySeconds", 0), @as(i64, 0), @as(i64, 5));
    if (!ready_check_delay_done and delay_seconds > 0) {
        const now_ms = nowMillis(io);
        if (ready_check_deadline_ms == 0) {
            ready_check_deadline_ms = now_ms + delay_seconds * std.time.ms_per_s;
            return writeAction(output, "accept", 0, 0, false, "等待自动接受延迟后执行");
        }
        if (now_ms < ready_check_deadline_ms) {
            const remaining = @divTrunc(ready_check_deadline_ms - now_ms + std.time.ms_per_s - 1, std.time.ms_per_s);
            var reason_buffer: [128]u8 = undefined;
            const reason = std.fmt.bufPrint(&reason_buffer, "自动接受将在 {d} 秒后执行", .{remaining}) catch "等待自动接受延迟后执行";
            return writeAction(output, "accept", 0, 0, false, reason);
        }
    }
    ready_check_deadline_ms = 0;
    ready_check_delay_done = true;

    // The delay runs across several watchdog ticks. The gameflow phase may
    // have advanced (or the ready-check may have been cancelled) while the
    // timer was pending, so mirror the Rust path and re-check before POST.
    if (delay_seconds > 0) {
        const phase_after_delay_json = client.get("/lol-gameflow/v1/gameflow-phase") catch return error.LcuRequestFailed;
        defer std.heap.page_allocator.free(phase_after_delay_json);
        const phase_after_delay = std.json.parseFromSliceLeaky(std.json.Value, allocator, phase_after_delay_json, .{}) catch return error.LcuInvalidResponse;
        const phase_name = if (phase_after_delay == .string) std.mem.trim(u8, phase_after_delay.string, " \t\r\n") else "";
        if (!std.mem.eql(u8, phase_name, "ReadyCheck") and !hasActionableReadyCheck(client, allocator)) {
            ready_check_accept_sent = false;
            ready_check_delay_done = false;
            ready_check_retry_at_ms = 0;
            return writeAction(output, "accept", 0, 0, false, "等待延迟期间队列确认已结束，未执行接受");
        }
    }

    const snapshot = getReadyCheck(client, allocator) catch return error.LcuRequestFailed;
    defer std.heap.page_allocator.free(snapshot.json);
    const ready = std.json.parseFromSliceLeaky(std.json.Value, allocator, snapshot.json, .{}) catch return error.LcuInvalidResponse;
    const response = std.mem.trim(u8, jsonStringField(ready, "playerResponse"), " \t\r\n");
    if (std.ascii.eqlIgnoreCase(response, "Declined")) return writeAction(output, "accept", 0, 0, false, "已手动拒绝本次对局，不执行自动接受");
    if (std.ascii.eqlIgnoreCase(response, "Accepted")) return writeAction(output, "accept", 0, 0, false, "本次对局已经接受，无需重复操作");
    // LCU has used several non-terminal values here (for example
    // `Waiting`/`InProgress`) while the ready-check is still actionable.
    // Only an explicit user response is terminal; all other states should
    // continue to the accept endpoint like the Rust and LeagueAkari clients.

    if (!readyCheckValueActionable(ready)) {
        ready_check_delay_done = false;
        return writeAction(output, "accept", 0, 0, false, "队列确认接口当前不可操作，等待下一次状态更新");
    }

    const accepted = acceptReadyCheck(client, snapshot.route) catch return error.LcuRequestFailed;
    std.heap.page_allocator.free(accepted);
    ready_check_accept_sent = true;
    // 204 responses can arrive before playerResponse is updated. Retry on a
    // short cadence while the ready-check is still active so a delayed LCU
    // event does not consume the whole acceptance window.
    ready_check_retry_at_ms = nowMillis(io) + 300;
    return writeAction(output, "accept", 0, 0, true, if (delay_seconds > 0) "等待后已发送接受请求" else "已发送接受请求");
}

fn nowMillis(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
}

/// 是不是「有替补席的选人」。
///
/// 用 `benchEnabled` 当判据，等于 AK 的 `isAramLikeMode`
/// （`auto-gameflow/aram-team-side-controller.ts`：`benchEnabled && gameMode ∈ {ARAM, KIWI}`）
/// **减去模式名那半条**——替补席只在这两种模式里存在，而模式名要去
/// `/lol-gameflow/v1/session`（几百 KB）里读，每 250ms 拉一次不划算，
/// 手里这份 champ-select session 又不带模式名。所以以替补席为准。
fn isBenchSelect(session: std.json.Value) bool {
    return jsonBoolField(session, "benchEnabled");
}

fn aramGrabEnabled(config: std.json.Value) bool {
    return automationBool(config, "aramGrab");
}

fn aramSwapDelaySeconds(config: std.json.Value) i64 {
    // 0 也是合法值（立刻换），所以不能用「取不到就连带默认」的写法，得区分缺字段。
    const automation = automationObject(config) orelse return 3;
    const value = automation.object.get("aramSwapDelaySeconds") orelse return 3;
    return std.math.clamp(jsonInteger(value), @as(i64, 0), @as(i64, 30));
}

/// 大乱斗抢人：从替补席里换出**偏好顺序里最靠前、且当前真的可换**的那个英雄。
///
/// 只在两种情况下动手（对齐 AK `bench-controller.ts` 的 `getExpectedSwaps`）：
/// - 手上的英雄压根不在偏好列表里；
/// - 手上的英雄在列表里，但替补席上有**优先级更高**的。
/// 手上已经是最优解时什么都不做，返回空数组（不刷状态栏）。
fn runAramGrab(io: std.Io, client: lcu.Client, config: std.json.Value, session: std.json.Value, output: []u8) ![]const u8 {
    const now_ms = nowMillis(io);
    const current_id = localChampionId(session);

    // 客户端已经把换人反映出来了（手上的英雄就是上次请求的那个）→ 清掉待确认窗口。
    if (aram_pending_swap_id != 0 and current_id == aram_pending_swap_id) aram_pending_swap_id = 0;
    if (aram_pending_swap_id != 0 and now_ms < aram_pending_until_ms) {
        return writeAction(output, "bench-swap", 0, aram_pending_swap_id, false, "已发送换人请求，等待客户端更新");
    }

    const candidates = aramCandidates(config);
    if (candidates.len == 0) {
        resetAramState();
        return writeAction(output, "bench-swap", 0, 0, false, "大乱斗抢人已开启，但还没设置偏好英雄");
    }
    // 拿不到替补席列表（接口暂时不可用）不能当成「替补席是空的」，否则会误判成
    // 「当前已经是最优」而静默什么都不做。
    const bench_json = client.get("/lol-champ-select/v1/pickable-champion-ids") catch
        return writeAction(output, "bench-swap", 0, 0, false, "读不到替补席列表，稍后重试");
    defer std.heap.page_allocator.free(bench_json);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const bench = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), bench_json, .{}) catch
        return writeAction(output, "bench-swap", 0, 0, false, "替补席列表格式不认识，稍后重试");

    const target_id = benchTarget(config, bench, current_id);
    if (target_id <= 0) {
        resetAramState();
        return std.fmt.bufPrint(output, "[]", .{});
    }

    if (aram_target_id != target_id) {
        aram_target_id = target_id;
        aram_target_seen_ms = now_ms;
    }
    const delay_ms = aramSwapDelaySeconds(config) * std.time.ms_per_s;
    const waited_ms = now_ms - aram_target_seen_ms;
    if (waited_ms < delay_ms) {
        const remaining = @divTrunc(delay_ms - waited_ms + 999, 1000);
        var reason_buffer: [128]u8 = undefined;
        const reason = std.fmt.bufPrint(&reason_buffer, "替补席上有更合适的英雄，{d} 秒后自动换上", .{remaining}) catch "等待延迟后从替补席换人";
        return writeAction(output, "bench-swap", 0, target_id, false, reason);
    }
    if (automationBool(config, "advisoryMode")) {
        return writeAction(output, "bench-swap", 0, target_id, true, "建议模式：会从替补席换上这个英雄，不写入客户端");
    }

    var path_buffer: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "/lol-champ-select/v1/session/bench/swap/{d}", .{target_id}) catch return error.InvalidConfig;
    // 与 AK 的 `benchSwap` 一致：POST 不带 body。
    const response = client.postNoContent(path) catch return error.LcuRequestFailed;
    std.heap.page_allocator.free(response);
    aram_pending_swap_id = target_id;
    aram_target_id = 0;
    aram_target_seen_ms = 0;
    // 客户端不是立刻更新 session，留一个窗口，避免每 250ms 重复提交同一次换人。
    aram_pending_until_ms = now_ms + 3 * std.time.ms_per_s;
    return writeAction(output, "bench-swap", 0, target_id, true, "已从替补席换上优先级更高的英雄");
}

/// 偏好列表。
fn aramCandidates(config: std.json.Value) []const std.json.Value {
    const automation = automationObject(config) orelse return &.{};
    const list = automation.object.get("aramChampionIds") orelse return &.{};
    return if (list == .array) list.array.items else &.{};
}

/// 该换上哪个英雄；`0` 表示不用换。
fn benchTarget(config: std.json.Value, bench: std.json.Value, current_id: i64) i64 {
    const candidates = aramCandidates(config);
    if (candidates.len == 0 or bench != .array) return 0;
    var current_rank: i64 = -1;
    if (current_id > 0) {
        for (candidates, 0..) |item, index| {
            if (jsonInteger(item) == current_id) {
                current_rank = @intCast(index);
                break;
            }
        }
    }
    for (candidates, 0..) |item, index| {
        const champion_id = jsonInteger(item);
        if (champion_id <= 0 or !championInBench(bench, champion_id)) continue;
        if (champion_id == current_id) return 0;
        // 替补席上优先级最高的那个还不如手上的 → 不换。
        if (current_rank >= 0 and @as(i64, @intCast(index)) > current_rank) return 0;
        return champion_id;
    }
    return 0;
}

fn championInBench(bench: std.json.Value, champion_id: i64) bool {
    for (bench.array.items) |item| if (jsonInteger(item) == champion_id) return true;
    return false;
}

/// 本地玩家在选人里拿到的英雄。
///
/// 大乱斗选人没有 action，`myTeam[].championId` 就是手上那个；刚进选人时可能还是 0。
fn localChampionId(session: std.json.Value) i64 {
    if (session != .object) return 0;
    const cell_id = jsonIntField(session, "localPlayerCellId");
    if (cell_id < 0) return 0;
    const team = session.object.get("myTeam") orelse return 0;
    if (team != .array) return 0;
    for (team.array.items) |participant| {
        if (jsonIntField(participant, "cellId") != cell_id) continue;
        const committed = jsonIntField(participant, "championId");
        if (committed > 0) return committed;
        return @max(@as(i64, 0), jsonIntField(participant, "championPickIntent"));
    }
    return 0;
}

fn resetAramState() void {
    aram_target_id = 0;
    aram_target_seen_ms = 0;
    aram_pending_swap_id = 0;
    aram_pending_until_ms = 0;
}

fn getReadyCheck(client: lcu.Client, allocator: std.mem.Allocator) !ReadyCheckSnapshot {
    // Special queues can keep both routes installed while only one is active.
    // HTTP 200 with state=Invalid must not prevent the team-builder fallback.
    const matchmaking = client.get(readyCheckPath(.matchmaking)) catch {
        return .{ .json = try client.get(readyCheckPath(.team_builder)), .route = .team_builder };
    };
    if (readyCheckJsonActionable(allocator, matchmaking)) {
        return .{ .json = matchmaking, .route = .matchmaking };
    }
    const team_builder = client.get(readyCheckPath(.team_builder)) catch {
        return .{ .json = matchmaking, .route = .matchmaking };
    };
    if (readyCheckJsonActionable(allocator, team_builder)) {
        std.heap.page_allocator.free(matchmaking);
        return .{ .json = team_builder, .route = .team_builder };
    }
    if (readyCheckJsonTerminal(allocator, matchmaking)) {
        std.heap.page_allocator.free(team_builder);
        return .{ .json = matchmaking, .route = .matchmaking };
    }
    if (readyCheckJsonTerminal(allocator, team_builder)) {
        std.heap.page_allocator.free(matchmaking);
        return .{ .json = team_builder, .route = .team_builder };
    }
    std.heap.page_allocator.free(team_builder);
    return .{ .json = matchmaking, .route = .matchmaking };
}

fn acceptReadyCheck(client: lcu.Client, route: ReadyCheckRoute) ![]u8 {
    // Rust's reqwest path serializes `Some(&())` as JSON null. A few LCU
    // versions reject an empty POST while accepting the same endpoint with a
    // JSON entity, so try that shape first and retain the empty-body fallback.
    const primary = readyCheckAcceptPath(route);
    const fallback_route: ReadyCheckRoute = if (route == .matchmaking) .team_builder else .matchmaking;
    const fallback = readyCheckAcceptPath(fallback_route);
    return client.postJsonNull(primary) catch
        client.postNoContent(primary) catch
        client.postJsonNull(fallback) catch
        client.postNoContent(fallback);
}

fn readyCheckPath(route: ReadyCheckRoute) []const u8 {
    return switch (route) {
        .matchmaking => "/lol-matchmaking/v1/ready-check",
        .team_builder => "/lol-lobby-team-builder/v1/ready-check",
    };
}

fn readyCheckAcceptPath(route: ReadyCheckRoute) []const u8 {
    return switch (route) {
        .matchmaking => "/lol-matchmaking/v1/ready-check/accept",
        .team_builder => "/lol-lobby-team-builder/v1/ready-check/accept",
    };
}

fn hasActionableReadyCheck(client: lcu.Client, allocator: std.mem.Allocator) bool {
    const snapshot = getReadyCheck(client, allocator) catch return false;
    defer std.heap.page_allocator.free(snapshot.json);
    const value = std.json.parseFromSliceLeaky(std.json.Value, allocator, snapshot.json, .{}) catch return false;
    return readyCheckValueActionable(value);
}

fn readyCheckJsonActionable(allocator: std.mem.Allocator, json: []const u8) bool {
    const value = std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{}) catch return false;
    return readyCheckValueActionable(value);
}

fn readyCheckJsonTerminal(allocator: std.mem.Allocator, json: []const u8) bool {
    const value = std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{}) catch return false;
    const response = std.mem.trim(u8, jsonStringField(value, "playerResponse"), " \t\r\n");
    return std.ascii.eqlIgnoreCase(response, "Accepted") or
        std.ascii.eqlIgnoreCase(response, "Declined");
}

fn readyCheckValueActionable(value: std.json.Value) bool {
    if (value != .object) return false;
    const response = std.mem.trim(u8, jsonStringField(value, "playerResponse"), " \t\r\n");
    if (std.ascii.eqlIgnoreCase(response, "Accepted") or std.ascii.eqlIgnoreCase(response, "Declined")) return false;
    const state = std.mem.trim(u8, jsonStringField(value, "state"), " \t\r\n");
    if (jsonIntField(value, "timer") > 0) return true;
    if (state.len == 0 or
        std.ascii.eqlIgnoreCase(state, "Invalid") or
        std.ascii.eqlIgnoreCase(state, "EveryoneReady") or
        std.ascii.eqlIgnoreCase(state, "PartyNotReady") or
        std.ascii.eqlIgnoreCase(state, "Cancelled") or
        std.ascii.eqlIgnoreCase(state, "Error")) return false;
    // Riot has added queue-specific active names over time. Once terminal
    // and explicitly invalid states are excluded, a non-empty state during a
    // ready-check probe is safer to accept than to silently miss.
    return true;
}

fn actionBody(action_type: []const u8, champion_id: i64, completed: bool, output: []u8) ![]const u8 {
    // A pick action without `completed` is the LCU hover/intent operation.
    // The same endpoint needs `completed:true` for the final lock-in. Bans
    // remain completed immediately because there is no useful ban intent for
    // the user to confirm manually.
    if (std.mem.eql(u8, action_type, "pick-intent") or
        (std.mem.eql(u8, action_type, "pick") and !completed))
    {
        return std.fmt.bufPrint(output, "{{\"championId\":{d}}}", .{champion_id});
    }
    return std.fmt.bufPrint(output, "{{\"championId\":{d},\"completed\":true}}", .{champion_id});
}

fn selectPendingAction(config: std.json.Value, session: std.json.Value) ?PendingAction {
    if (session != .object) return null;
    const local_cell = jsonIntField(session, "localPlayerCellId");
    if (local_cell < 0) return null;
    const actions = session.object.get("actions") orelse return null;
    if (actions != .array) return null;

    for (actions.array.items) |group| {
        if (group != .array) continue;
        for (group.array.items) |action| {
            if (action != .object or jsonIntField(action, "actorCellId") != local_cell) continue;
            if (jsonBoolField(action, "completed")) continue;
            if (action.object.get("isInProgress")) |active| if (active == .bool and !active.bool) continue;
            const action_type = jsonStringField(action, "type");
            const candidate_field = if (std.mem.eql(u8, action_type, "pick") and automationBool(config, "autoPick"))
                "pickChampionIds"
            else if (std.mem.eql(u8, action_type, "ban") and automationBool(config, "autoBan"))
                "banChampionIds"
            else
                continue;
            const committed_id = jsonIntField(action, "championId");
            const intent_id = jsonIntField(action, "championPickIntent");
            const current_id = if (committed_id > 0) committed_id else intent_id;
            return .{
                .action_type = action_type,
                .action_id = jsonIntField(action, "id"),
                // LCU exposes a hover as championPickIntent on some client
                // builds and as championId on others. Respect either value so
                // the watchdog never replaces an already visible champion
                // with the first configured candidate on the next poll.
                // The configured pool is the desired action. The current LCU
                // id is only an acknowledgement signal; using it as the
                // desired candidate lets a transient action value bypass the
                // visible hover step and lock immediately.
                .champion_id = firstAvailableCandidate(config, candidate_field, session),
                .current_champion_id = current_id,
            };
        }
    }
    return null;
}

fn resetPickState() void {
    pick_action_id = 0;
    pick_champion_id = 0;
    pick_lock_deadline_ms = 0;
    pick_intent_sent = false;
    pick_lock_sent = false;
}

fn firstAvailableCandidate(config: std.json.Value, field: []const u8, session: std.json.Value) i64 {
    const automation = automationObject(config) orelse return 0;
    const candidates = automation.object.get(field) orelse return 0;
    if (candidates != .array) return 0;
    for (candidates.array.items) |candidate| {
        const champion_id = jsonInteger(candidate);
        if (champion_id > 0 and !championOccupied(session, champion_id)) return champion_id;
    }
    return 0;
}

fn championOccupied(session: std.json.Value, champion_id: i64) bool {
    if (session != .object) return false;
    for ([_][]const u8{ "myTeam", "theirTeam" }) |field| {
        if (session.object.get(field)) |team| if (team == .array) {
            for (team.array.items) |participant| if (jsonIntField(participant, "championId") == champion_id) return true;
        };
    }
    if (session.object.get("bans")) |bans| if (bans == .object) {
        for ([_][]const u8{ "champions", "myTeamBans", "theirTeamBans" }) |field| {
            if (bans.object.get(field)) |values| if (values == .array) {
                for (values.array.items) |value| if (jsonInteger(value) == champion_id) return true;
            };
        }
    };
    return false;
}

fn automationObject(config: std.json.Value) ?std.json.Value {
    if (config != .object) return null;
    const automation = config.object.get("automation") orelse return null;
    return if (automation == .object) automation else null;
}

fn automationBool(config: std.json.Value, field: []const u8) bool {
    const automation = automationObject(config) orelse return false;
    const value = automation.object.get(field) orelse return false;
    return value == .bool and value.bool;
}

fn automationInt(config: std.json.Value, field: []const u8, fallback: i64) i64 {
    const automation = automationObject(config) orelse return fallback;
    const value = automation.object.get(field) orelse return fallback;
    return jsonInteger(value);
}

fn automationString(config: std.json.Value, field: []const u8, fallback: []const u8) []const u8 {
    const automation = automationObject(config) orelse return fallback;
    const value = automation.object.get(field) orelse return fallback;
    return if (value == .string and value.string.len > 0) value.string else fallback;
}

fn pickStrategy(config: std.json.Value) []const u8 {
    const value = automationString(config, "autoPickStrategy", "show-and-lock-in");
    if (std.mem.eql(u8, value, "just-show") or
        std.mem.eql(u8, value, "show-and-lock-in") or
        std.mem.eql(u8, value, "lock-in-immediately")) return value;
    return "show-and-lock-in";
}

fn jsonStringField(value: std.json.Value, field: []const u8) []const u8 {
    if (value != .object) return "";
    const item = value.object.get(field) orelse return "";
    return if (item == .string) item.string else "";
}

fn jsonBoolField(value: std.json.Value, field: []const u8) bool {
    if (value != .object) return false;
    const item = value.object.get(field) orelse return false;
    return item == .bool and item.bool;
}

fn jsonIntField(value: std.json.Value, field: []const u8) i64 {
    if (value != .object) return -1;
    return jsonInteger(value.object.get(field) orelse return -1);
}

fn jsonInteger(value: std.json.Value) i64 {
    return switch (value) {
        .integer => |number| number,
        .float => |number| @intFromFloat(number),
        .string => |text| std.fmt.parseInt(i64, text, 10) catch 0,
        else => 0,
    };
}

fn writeAction(output: []u8, action_type: []const u8, action_id: i64, champion_id: i64, executed: bool, reason: []const u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll("[{\"actionType\":");
    try writeJsonString(&writer, action_type);
    try writer.print(",\"actionId\":{d},\"championId\":{d},\"executed\":{},\"reason\":", .{ action_id, champion_id, executed });
    try writeJsonString(&writer, reason);
    try writer.writeAll("}]");
    return writer.buffered();
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    var stringify = std.json.Stringify{ .writer = writer, .options = .{} };
    try stringify.write(value);
}

test "selects a local in-progress action and skips occupied candidates" {
    const config_json = "{\"automation\":{\"enabled\":true,\"autoPick\":true,\"autoBan\":true,\"pickChampionIds\":[103,64]}}";
    const session_json = "{\"localPlayerCellId\":1,\"myTeam\":[{\"championId\":103}],\"theirTeam\":[],\"actions\":[[{\"id\":9,\"actorCellId\":2,\"type\":\"pick\",\"completed\":false,\"isInProgress\":true},{\"id\":10,\"actorCellId\":1,\"type\":\"pick\",\"completed\":false,\"isInProgress\":true}]]}";
    const config_json_value = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, config_json, .{});
    defer config_json_value.deinit();
    const config = config_json_value.value;
    const session_json_value = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, session_json, .{});
    defer session_json_value.deinit();
    const session = session_json_value.value;
    const action = selectPendingAction(config, session).?;
    try std.testing.expectEqualStrings("pick", action.action_type);
    try std.testing.expectEqual(@as(i64, 10), action.action_id);
    try std.testing.expectEqual(@as(i64, 64), action.champion_id);
}

test "keeps the LCU champion pick intent when it is the available candidate" {
    const config_json = "{\"automation\":{\"enabled\":true,\"autoPick\":true,\"pickChampionIds\":[103,64]}}";
    const session_json = "{\"localPlayerCellId\":1,\"myTeam\":[{\"championId\":103}],\"theirTeam\":[],\"actions\":[[{\"id\":10,\"actorCellId\":1,\"type\":\"pick\",\"championId\":0,\"championPickIntent\":64,\"completed\":false,\"isInProgress\":true}]]}";
    const config_json_value = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, config_json, .{});
    defer config_json_value.deinit();
    const config = config_json_value.value;
    const session_json_value = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, session_json, .{});
    defer session_json_value.deinit();
    const session = session_json_value.value;
    const action = selectPendingAction(config, session).?;
    try std.testing.expectEqual(@as(i64, 64), action.champion_id);
    try std.testing.expectEqual(@as(i64, 64), action.current_champion_id);
}

test "auto pick keeps configured candidate separate from transient action id" {
    const config_json = "{\"automation\":{\"enabled\":true,\"autoPick\":true,\"pickChampionIds\":[103,64]}}";
    const session_json = "{\"localPlayerCellId\":1,\"myTeam\":[],\"theirTeam\":[],\"actions\":[[{\"id\":10,\"actorCellId\":1,\"type\":\"pick\",\"championId\":0,\"championPickIntent\":64,\"completed\":false,\"isInProgress\":true}]]}";
    const config_json_value = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, config_json, .{});
    defer config_json_value.deinit();
    const config = config_json_value.value;
    const session_json_value = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, session_json, .{});
    defer session_json_value.deinit();
    const session = session_json_value.value;
    const action = selectPendingAction(config, session).?;
    try std.testing.expectEqual(@as(i64, 103), action.champion_id);
    try std.testing.expectEqual(@as(i64, 64), action.current_champion_id);
}

test "automation action JSON encodes multiple string fields" {
    var output: [512]u8 = undefined;
    const result = try writeAction(&output, "pick", 10, 64, true, "已提交 LCU action");
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("pick", parsed.value.array.items[0].object.get("actionType").?.string);
    try std.testing.expect(parsed.value.array.items[0].object.get("executed").?.bool);
}

test "pick action body is an intent while bans complete immediately" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("{\"championId\":64}", try actionBody("pick", 64, false, &buffer));
    try std.testing.expectEqualStrings("{\"championId\":64}", try actionBody("pick-intent", 64, false, &buffer));
    try std.testing.expectEqualStrings("{\"championId\":64,\"completed\":true}", try actionBody("pick", 64, true, &buffer));
    try std.testing.expectEqualStrings("{\"championId\":64,\"completed\":true}", try actionBody("ban", 64, true, &buffer));
}

test "unknown pick strategies are safe and still show before locking" {
    const config_json = "{\"automation\":{\"autoPickStrategy\":\"legacy-immediate\"}}";
    const config_json_value = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, config_json, .{});
    defer config_json_value.deinit();
    const config = config_json_value.value;
    try std.testing.expectEqualStrings("show-and-lock-in", pickStrategy(config));
}

test "treats the current champion-select ban list as occupied" {
    const session_json_value = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"bans\":{\"champions\":[103,64]}}", .{});
    defer session_json_value.deinit();
    const session = session_json_value.value;
    try std.testing.expect(championOccupied(session, 103));
    try std.testing.expect(!championOccupied(session, 7));
}

test "ready check activity rejects installed but inactive routes" {    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const active = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"state\":\"InProgress\",\"playerResponse\":\"None\",\"timer\":0}", .{});
    const inactive = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"state\":\"Invalid\",\"playerResponse\":\"None\",\"timer\":0}", .{});
    const accepted = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"state\":\"EveryoneReady\",\"playerResponse\":\"Accepted\",\"timer\":0}", .{});
    const queue_specific = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"state\":\"AwaitingResponse\",\"playerResponse\":\"None\",\"timer\":0}", .{});

    try std.testing.expect(readyCheckValueActionable(active));
    try std.testing.expect(!readyCheckValueActionable(inactive));
    try std.testing.expect(!readyCheckValueActionable(accepted));
    try std.testing.expect(readyCheckValueActionable(queue_specific));
    try std.testing.expect(readyCheckJsonTerminal(allocator, "{\"state\":\"EveryoneReady\",\"playerResponse\":\"Accepted\"}"));
}

test "大乱斗：替补席上有优先级更高的英雄才换" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const config = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"automation\":{\"aramGrab\":true,\"aramChampionIds\":[103,64,222]}}", .{});
    const bench = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "[64,222,7]", .{});

    // 手上没有偏好里的英雄 → 换上替补席上优先级最高的那个。
    try std.testing.expectEqual(@as(i64, 64), benchTarget(config, bench, 7));
    // 手上是第二优先，替补席上还有第一优先 → 换。
    try std.testing.expectEqual(@as(i64, 64), benchTarget(config, bench, 222));
    // 手上已经是替补席上优先级最高的 → 不动。
    try std.testing.expectEqual(@as(i64, 0), benchTarget(config, bench, 64));
    // 手上是第一优先，替补席上只有更差的 → 不动（AK 的「找到更高优先级才换」）。
    const worse_bench = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "[222,7]", .{});
    try std.testing.expectEqual(@as(i64, 0), benchTarget(config, worse_bench, 103));
    // 偏好里一个都不在替补席上 → 不动。
    const empty_bench = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "[7,40]", .{});
    try std.testing.expectEqual(@as(i64, 0), benchTarget(config, empty_bench, 7));
    // 没配偏好 → 不动。
    const bare = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"automation\":{\"aramGrab\":true}}", .{});
    try std.testing.expectEqual(@as(i64, 0), benchTarget(bare, bench, 7));
}

test "大乱斗：只有替补席开启时才走抢人这条线" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const aram = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"benchEnabled\":true,\"localPlayerCellId\":0}", .{});
    const ranked = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"benchEnabled\":false,\"localPlayerCellId\":0}", .{});
    try std.testing.expect(isBenchSelect(aram));
    try std.testing.expect(!isBenchSelect(ranked));
    // 取不到字段时不能当成大乱斗，否则排位选人也会去读替补席。
    const empty = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{}", .{});
    try std.testing.expect(!isBenchSelect(empty));
}

test "大乱斗：换人延迟默认 3 秒、可关到 0、上限 30" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const unset = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"automation\":{\"aramGrab\":true}}", .{});
    try std.testing.expectEqual(@as(i64, 3), aramSwapDelaySeconds(unset));
    const zero = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"automation\":{\"aramSwapDelaySeconds\":0}}", .{});
    try std.testing.expectEqual(@as(i64, 0), aramSwapDelaySeconds(zero));
    const huge = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"automation\":{\"aramSwapDelaySeconds\":900}}", .{});
    try std.testing.expectEqual(@as(i64, 30), aramSwapDelaySeconds(huge));
    const negative = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"automation\":{\"aramSwapDelaySeconds\":-5}}", .{});
    try std.testing.expectEqual(@as(i64, 0), aramSwapDelaySeconds(negative));
}

test "大乱斗：手上那个英雄从 myTeam 的本地格子里读" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const session = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{"localPlayerCellId":3,"myTeam":[{"cellId":1,"championId":64},{"cellId":3,"championId":103}]}
    , .{});
    try std.testing.expectEqual(@as(i64, 103), localChampionId(session));

    // 还没分到英雄时用预选意图兜底。
    const intent = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{"localPlayerCellId":1,"myTeam":[{"cellId":1,"championId":0,"championPickIntent":64}]}
    , .{});
    try std.testing.expectEqual(@as(i64, 64), localChampionId(intent));

    const broken = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{}", .{});
    try std.testing.expectEqual(@as(i64, 0), localChampionId(broken));
}

test "大乱斗：抢人动作带上 championId，界面能据此显示换了谁" {
    var output: [256]u8 = undefined;
    const result = try writeAction(&output, "bench-swap", 0, 64, true, "已从替补席换上优先级更高的英雄");
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    const action = parsed.value.array.items[0];
    try std.testing.expectEqualStrings("bench-swap", action.object.get("actionType").?.string);
    try std.testing.expectEqual(@as(i64, 64), action.object.get("championId").?.integer);
    try std.testing.expect(action.object.get("executed").?.bool);
}
