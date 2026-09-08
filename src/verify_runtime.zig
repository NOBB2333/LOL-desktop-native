const std = @import("std");
const backend = @import("backend");
const storage = @import("storage");
const http = @import("lcu").transport;

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    if (args.next()) |url| {
        if (!std.mem.startsWith(u8, url, "http://127.0.0.1:")) return error.InvalidTestAddress;
        return verifyNetwork(init.io, url);
    }
    return verifyClient(init);
}

fn verifyNetwork(io: std.Io, base: []const u8) !void {
    const port = try std.fmt.parseInt(u16, base["http://127.0.0.1:".len..], 10);
    try backend.verifyLiveProfilePipeline(io, port);
    var address: [256]u8 = undefined;
    const cases = [_]struct { path: []const u8, expected: ?anyerror = null, timeout: u32 = 1500, limit: usize = 512 * 1024 }{
        .{ .path = "/ok" },
        .{ .path = "/large" },
        .{ .path = "/401", .expected = error.HttpUnauthorized },
        .{ .path = "/403", .expected = error.HttpForbidden },
        .{ .path = "/404", .expected = error.HttpNotFound },
        .{ .path = "/500", .expected = error.HttpServerError },
        .{ .path = "/large", .expected = error.ResponseTooLarge, .limit = 32 },
        .{ .path = "/slow", .expected = error.RequestTimedOut, .timeout = 100 },
        .{ .path = "/slow-body", .expected = error.RequestTimedOut, .timeout = 120 },
    };
    for (cases) |case| {
        const start = millis(io);
        const url = try std.fmt.bufPrint(&address, "{s}{s}", .{ base, case.path });
        try checkResponse(.{ .io = io, .url = url, .timeout_ms = case.timeout, .max_response_bytes = case.limit }, case.expected);
        std.debug.print("受控请求 {s}：通过，耗时 {d} 毫秒\n", .{ case.path, millis(io) - start });
        if (case.expected != null and case.expected.? == error.RequestTimedOut and millis(io) - start > 600) return error.CancellationTooSlow;
    }
    const Cancel = struct {
        io: std.Io,
        deadline: i64,
        fn check(context: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (millis(self.io) >= self.deadline) return error.RequestCancelled;
        }
    };
    var cancel = Cancel{ .io = io, .deadline = millis(io) + 60 };
    try checkResponse(.{ .io = io, .url = try std.fmt.bufPrint(&address, "{s}/slow", .{base}), .control = .{ .context = &cancel, .check_fn = Cancel.check } }, error.RequestCancelled);
    try checkResponse(.{ .io = io, .url = try std.fmt.bufPrint(&address, "{s}/must-not-run", .{base}), .control = .{ .context = &cancel, .check_fn = Cancel.check } }, error.RequestCancelled);
    try checkResponse(.{ .io = io, .url = try std.fmt.bufPrint(&address, "{s}/429", .{base}), .budget = .remote }, error.HttpRateLimited);
    try checkResponse(.{ .io = io, .url = try std.fmt.bufPrint(&address, "{s}/must-not-run", .{base}), .budget = .remote }, error.HttpRateLimited);
    // 远端退避不能阻塞阵容预留通道。
    try checkResponse(.{ .io = io, .url = try std.fmt.bufPrint(&address, "{s}/ok", .{base}), .budget = .roster }, null);
    std.debug.print("异步取消、执行前取消、限流退避及阵容预留通道：通过\n", .{});
}

fn checkResponse(options: http.Options, expected: ?anyerror) !void {
    if (http.request(std.heap.page_allocator, options)) |response| {
        defer std.heap.page_allocator.free(response);
        if (expected != null or response.len == 0) return error.UnexpectedResponse;
    } else |err| {
        if (expected == null or expected.? != err) {
            std.debug.print("请求验证失败，实际错误：{s}\n", .{@errorName(err)});
            return error.UnexpectedResponse;
        }
    }
}

fn verifyClient(init: std.process.Init) !void {
    const runtime = try std.heap.page_allocator.create(backend.Runtime);
    defer std.heap.page_allocator.destroy(runtime);
    runtime.* = backend.Runtime.init();
    runtime.io = init.io;
    runtime.env_map = init.environ_map;
    // 验证只用内存数据库，既有用户配置和战绩文件不参与。
    runtime.storage = try storage.Store.open(std.heap.page_allocator, init.io, ":memory:");
    runtime.storage.?.require_scope = true;
    defer runtime.deinit();
    const output = try std.heap.page_allocator.alloc(u8, 8 * 1024 * 1024);
    defer std.heap.page_allocator.free(output);
    for ([_][]const u8{ "lol.refresh_connection", "lol.get_live_roster", "lol.get_match_history" }) |name| {
        for (runtime.handlers()) |handler| if (std.mem.eql(u8, handler.name, name)) {
            const start = millis(init.io);
            const result = try backend.invokeConcurrent(runtime, handler, .{
                .request = .{ .id = "只读验证", .command = name, .payload = "{\"pageSize\":10}" },
                .source = .{ .origin = "zero://app" },
            }, output);
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const json = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), result, .{});
            // 输出仅含状态、数量与耗时，不输出凭据、玩家标识或战绩原文。
            if (json == .array) {
                std.debug.print("只读战绩：{d} 场，耗时 {d} 毫秒\n", .{ json.array.items.len, millis(init.io) - start });
            } else if (json == .object) {
                const status = json.object.get("status") orelse .null;
                const phase = json.object.get("phase") orelse .null;
                const ally = json.object.get("ally") orelse .null;
                const enemy = json.object.get("enemy") orelse .null;
                std.debug.print("只读连接或阵容：状态 {s}，阶段 {s}，人数 {d}，耗时 {d} 毫秒\n", .{
                    if (status == .string) status.string else "已读取",
                    if (phase == .string) phase.string else "未知",
                    (if (ally == .array) ally.array.items.len else @as(usize, 0)) + (if (enemy == .array) enemy.array.items.len else @as(usize, 0)),
                    millis(init.io) - start,
                });
                if (status == .string and !std.mem.eql(u8, status.string, "connected")) return error.ClientUnavailable;
            }
        };
    }
    for (runtime.handlers()) |handler| if (std.mem.eql(u8, handler.name, "lol.get_live_lobby")) {
        const deadline = millis(init.io) + 30_000;
        var last_completed: i64 = -1;
        while (millis(init.io) < deadline) {
            const result = try backend.invokeConcurrent(runtime, handler, .{ .request = .{ .id = "只读资料进度", .command = handler.name, .payload = "{}" }, .source = .{ .origin = "zero://app" } }, output);
            const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, result, .{});
            defer parsed.deinit();
            const root = parsed.value;
            if (root != .object) break;
            const progress = root.object.get("loading") orelse break;
            const completed = progress.object.get("completed").?.integer;
            if (completed != last_completed) {
                last_completed = completed;
                std.debug.print("只读资料进度：完成 {d}/{d}，缺失资料 {d}，耗时 {d} 毫秒\n", .{ completed, progress.object.get("total").?.integer, progress.object.get("failed").?.integer, progress.object.get("elapsedMs").?.integer });
            }
            var ids = std.StringHashMap(void).init(std.heap.page_allocator);
            defer ids.deinit();
            var count: usize = 0;
            for ([_][]const u8{ "ally", "enemy" }) |side| {
                const players = root.object.get(side) orelse continue;
                if (players != .array) continue;
                for (players.array.items) |player| {
                    count += 1;
                    const id = player.object.get("puuid") orelse continue;
                    if (id != .string or id.string.len == 0) return error.MissingPlayerIdentity;
                    const entry = try ids.getOrPut(id.string);
                    if (entry.found_existing) return error.DuplicatePlayerIdentity;
                }
            }
            if (!progress.object.get("active").?.bool) {
                std.debug.print("只读资料身份检查：{d} 张卡片，无重复身份\n", .{count});
                return;
            }
            try std.Io.sleep(init.io, .fromMilliseconds(250), .awake);
        }
    };
}

fn millis(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .awake).nanoseconds, std.time.ns_per_ms));
}
