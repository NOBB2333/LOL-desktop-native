const std = @import("std");
const builtin = @import("builtin");
const windows_http = @import("lcu/http_windows.zig");
pub const transport = windows_http;
pub const RequestControl = @import("lcu/request_control.zig").Control;
/// 每条 lane 由 bridge 的**一个或多个**独立 worker 线程消费。事件轮询与连接刷新
/// 原本挤在 roster lane 上，会推迟阵容结果的到达时间，因此各自独立成 lane。
///
/// `asset` 是**图标/头像取字节**的专属 lane。它和 `query` 分开是为了让「一屏 200 多个
/// 英雄头像」这类纯装饰性、可并行的请求**不去挤**交互式查询（点开英雄看技能、
/// 选人阶段的段位战绩）。分开之后两者各自有独立的 worker 数量（见 `lane_worker_count`）
/// 与配额通道（见 `http_windows.zig` 的 `budget_limits`）。
pub const RequestLane = enum(u8) { state, roster, query, action, events, connection, asset };
pub const lane_count = @typeInfo(RequestLane).@"enum".fields.len;

/// 每条 lane 起几个 worker 线程（消费 bridge 队列的消费者数量）。
///
/// **为什么不是一条 lane 一个 worker**（这是本改动要修的根因）：原先每条 lane 只有
/// 一个 worker，于是同一条 lane 上的命令被**严格串行**执行——前端"10 个并发"发出去的
/// 请求，到了这里就是一个一个过。英雄页首屏 245 个 `lol.get_asset` 全在 `query` 上，
/// 排队排到天荒地老，用户看到的就是「头像一个一个慢慢往外冒」。
///
/// 图标取字节是**互相独立、只读、没有顺序依赖**的，天然可以并行；给它 4 个 worker
/// （再叠加 `asset` 独立 lane 与独立配额）之后，245 张图的墙钟时间从「245 × 单次」
/// 回落到「245 / 并发 × 单次」。
///
/// 其余 lane 保持 1 个 worker：`state` / `roster` / `action` / `events` 里的命令有
/// 共享状态机或明确的先后语义（阵容合并、动作执行、事件轮询），多消费者反而会
/// 打乱顺序、放大锁竞争，收益为负。
pub const lane_worker_count = blk: {
    var counts = [_]usize{1} ** lane_count;
    counts[@intFromEnum(RequestLane.query)] = 4;
    counts[@intFromEnum(RequestLane.asset)] = 4;
    break :blk counts;
};

test {
    std.testing.refAllDecls(windows_http);
    std.testing.refAllDecls(RequestControl);
}

test "图标与查询通道是多消费者，其余保持单消费者" {
    // 多消费者是本轮「请求串行」性能修复的核心：队列已经按 lane 分开，消费端还得
    // 能并行，否则前端再多并发也只是一个一个过。这条同时是 `lane_worker_count` 的
    // 形状护栏——它被误改回全 1 时，这个用例会立刻红。
    try std.testing.expect(lane_worker_count[@intFromEnum(RequestLane.asset)] > 1);
    try std.testing.expect(lane_worker_count[@intFromEnum(RequestLane.query)] > 1);
    // 有顺序/状态语义的通道必须仍是单消费者。
    for ([_]RequestLane{ .state, .roster, .action, .events, .connection }) |lane| {
        try std.testing.expectEqual(@as(usize, 1), lane_worker_count[@intFromEnum(lane)]);
    }
}

pub const websocket = @import("lcu/websocket.zig");

/// Credentials are borrowed from the process command line or lockfile.
/// The token never crosses the JavaScript bridge.
pub const Credentials = struct {
    port: u16,
    token: []const u8,
    protocol: []const u8,
    platform: [32]u8 = .{0} ** 32,
    platform_len: usize = 0,

    pub fn platformId(self: *const Credentials) []const u8 {
        return self.platform[0..self.platform_len];
    }

    pub fn endpoint(self: Credentials, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{s}://127.0.0.1:{d}", .{ self.protocol, self.port });
    }
};

pub const ParseError = error{
    MissingPort,
    MissingToken,
    InvalidPort,
    InvalidLockfile,
};

pub const DiscoveryError = error{ NotRunning, IoFailure };

const remote_windows_discovery_script =
    "$OutputEncoding=[Console]::OutputEncoding=[System.Text.UTF8Encoding]::new(); " ++
    "$processes=@(Get-CimInstance Win32_Process -Filter \"Name='LeagueClientUx.exe'\" -ErrorAction SilentlyContinue); " ++
    "$process=$processes | Where-Object { $_.CommandLine -match '--(?:app|riotclient-app)-port' -and $_.CommandLine -match '--(?:remoting|riotclient)-auth-token' } | Select-Object -First 1; " ++
    "if ($null -ne $process -and -not [string]::IsNullOrWhiteSpace($process.CommandLine)) { [Console]::Out.Write($process.CommandLine); exit 0 }; " ++
    "$fallback=$processes | Select-Object -First 1; $executable=if ($null -ne $fallback) { $fallback.ExecutablePath } else { $null }; " ++
    "if ([string]::IsNullOrWhiteSpace($executable)) { $native=Get-Process -Name LeagueClientUx -ErrorAction SilentlyContinue | Select-Object -First 1; if ($null -ne $native) { $executable=$native.Path } }; " ++
    "if (-not [string]::IsNullOrWhiteSpace($executable)) { $lockfile=Join-Path (Split-Path -Parent $executable) 'lockfile'; if (Test-Path -LiteralPath $lockfile) { [Console]::Out.Write((Get-Content -Raw -LiteralPath $lockfile)); exit 0 } }; " ++
    "[Console]::Error.Write('未找到带 LCU 凭据的 LeagueClientUx.exe 进程或同目录 lockfile'); exit 3";

/// A small, synchronous LCU transport. The renderer never receives the
/// credentials: this type resolves lockfiles and performs requests entirely
/// in the Native host. Windows uses WinHTTP in-process; other hosts retain the
/// curl fallback until their platform transport is implemented.
pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    credentials: Credentials,
    timeout_ms: u32 = 6000,
    verify_tls: bool = false,
    control: RequestControl = .{},
    lane: RequestLane = .query,
    /// 显式覆盖本地请求走的配额通道；`null` 时按 `lane` 推导。
    ///
    /// `lane` 只管 bridge 把命令派给哪个 worker，而十人资料富化批次是自己起线程
    /// 跑的、根本不经过 bridge，所以它想要一条独立配额只能从这里指定。改 `lane`
    /// 会顺带搬动命令的派发位置，不能拿来干这件事。
    budget: ?windows_http.Budget = null,

    pub fn discover(allocator: std.mem.Allocator, io: std.Io, configured: []const []const u8, env_map: ?*const std.process.Environ.Map) !Client {
        if (builtin.os.tag == .windows) {
            const probe = discoverProcessNative(allocator, io);
            if (probe.command_line) |command_line| {
                if (fromCommandLine(command_line)) |credentials| {
                    const owned = try ownCredentials(allocator, credentials);
                    allocator.free(command_line);
                    return .{ .allocator = allocator, .io = io, .credentials = owned };
                } else |_| {}
                if (fromLockfile(command_line)) |credentials| {
                    const owned = try ownCredentials(allocator, credentials);
                    allocator.free(command_line);
                    return .{ .allocator = allocator, .io = io, .credentials = owned };
                } else |_| {}
                allocator.free(command_line);
            }
            // ⚠️ 只有**确认进程存在**时才值得动用 WMI 兜底。
            //
            // 那个兜底脚本本身就是 `Get-CimInstance Win32_Process -Filter "Name='LeagueClientUx.exe'"`
            // ——进程不存在它必然查空。而它的代价是**起一个 PowerShell 进程**（启动开销
            // 几百毫秒 + WMI 查询），远贵于一次 Toolhelp 扫描。
            //
            // 以前这里不看 `seen`，于是客户端没开时每轮连接刷新（5 秒）都要 spawn 一次
            // PowerShell，这就是「后台一直在扫什么」的真身。客户端在跑、只是命令行读不到
            // （比如管理员权限启动）时 `seen` 为 true，兜底照旧生效。
            if (probe.seen) {
                if (discoverProcess(allocator, io)) |command_line| {
                    if (fromCommandLine(command_line)) |credentials| {
                        const owned = try ownCredentials(allocator, credentials);
                        allocator.free(command_line);
                        return .{ .allocator = allocator, .io = io, .credentials = owned };
                    } else |_| {}
                    if (fromLockfile(command_line)) |credentials| {
                        const owned = try ownCredentials(allocator, credentials);
                        allocator.free(command_line);
                        return .{ .allocator = allocator, .io = io, .credentials = owned };
                    } else |_| {}
                    allocator.free(command_line);
                }
            }
        }
        for (configured) |path| {
            if (readLockfile(allocator, io, path)) |contents| {
                if (fromLockfile(contents)) |credentials| {
                    const owned = try ownCredentials(allocator, credentials);
                    allocator.free(contents);
                    return .{ .allocator = allocator, .io = io, .credentials = owned };
                } else |_| {}
                allocator.free(contents);
            }
        }
        const candidates = [_][]const u8{
            "C:/Riot Games/League of Legends/lockfile",
            "C:/ProgramData/Riot Games/Metadata/league_of_legends.live/lockfile",
            "C:/Program Files/Riot Games/League of Legends/lockfile",
            "C:/Program Files (x86)/Riot Games/League of Legends/lockfile",
            "lockfile",
        };
        for (candidates) |path| {
            if (readLockfile(allocator, io, path)) |contents| {
                if (fromLockfile(contents)) |credentials| {
                    const owned = try ownCredentials(allocator, credentials);
                    allocator.free(contents);
                    return .{ .allocator = allocator, .io = io, .credentials = owned };
                } else |_| {}
                allocator.free(contents);
            }
        }
        if (env_map) |environment| {
            const names = [_][]const u8{ "PROGRAMDATA", "LOCALAPPDATA", "PROGRAMFILES", "PROGRAMFILES(X86)" };
            const suffixes = [_][]const u8{
                "Riot Games/Metadata/league_of_legends.live/lockfile",
                "Riot Games/League of Legends/lockfile",
                "Riot Games/League of Legends/lockfile",
                "Riot Games/League of Legends/lockfile",
            };
            for (names, suffixes) |name, suffix| {
                const base = environment.get(name) orelse continue;
                var path_buf: [1024]u8 = undefined;
                const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ base, suffix }) catch continue;
                if (readLockfile(allocator, io, path)) |contents| {
                    if (fromLockfile(contents)) |credentials| {
                        const owned = try ownCredentials(allocator, credentials);
                        allocator.free(contents);
                        return .{ .allocator = allocator, .io = io, .credentials = owned };
                    } else |_| {}
                    allocator.free(contents);
                }
            }
        }
        return error.NotRunning;
    }

    /// 发现 **Riot Client** 本地服务凭据。
    ///
    /// 只有跨区 `名字#TAG → puuid`（`player-account/aliases/v1/lookup`）需要它，
    /// 该接口在 RC 端口而不在 LCU 端口。复用与 LCU 相同的进程发现路径，但只用
    /// [`fromRiotClientCommandLine`] 解析；找不到就返回 `error.NotRunning`，
    /// 调用方据此降级为「只用当前大区的 LCU 查询」。
    pub fn discoverRiotClient(allocator: std.mem.Allocator, io: std.Io) !Client {
        if (builtin.os.tag == .windows) {
            const probe = discoverProcessNative(allocator, io);
            if (probe.command_line) |command_line| {
                defer allocator.free(command_line);
                if (fromRiotClientCommandLine(command_line)) |credentials| {
                    return .{ .allocator = allocator, .io = io, .credentials = try ownCredentials(allocator, credentials) };
                } else |_| {}
            }
            // 与 `discover` 同理：进程不在就没什么可问 WMI 的，别白起一个 PowerShell。
            if (probe.seen) {
                if (discoverProcess(allocator, io)) |command_line| {
                    defer allocator.free(command_line);
                    if (fromRiotClientCommandLine(command_line)) |credentials| {
                        return .{ .allocator = allocator, .io = io, .credentials = try ownCredentials(allocator, credentials) };
                    } else |_| {}
                }
            }
        }
        return error.NotRunning;
    }

    pub fn discoverRemote(allocator: std.mem.Allocator, io: std.Io, ssh_target: []const u8, identity_file: []const u8, forwarded_port: u16, timeout_ms: u32, verify_tls: bool) !Client {
        if (std.mem.trim(u8, ssh_target, " \t\r\n").len == 0) return error.NotRunning;
        var argv: [20][]const u8 = undefined;
        var argc: usize = 0;
        for ([_][]const u8{ "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5" }) |arg| {
            argv[argc] = arg;
            argc += 1;
        }
        if (std.mem.trim(u8, identity_file, " \t\r\n").len > 0) {
            argv[argc] = "-i";
            argc += 1;
            argv[argc] = identity_file;
            argc += 1;
        }
        for ([_][]const u8{ ssh_target, "powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", remote_windows_discovery_script }) |arg| {
            argv[argc] = arg;
            argc += 1;
        }
        const result = std.process.run(allocator, io, .{
            .argv = argv[0..argc],
            .stdout_limit = .limited(32 * 1024),
            .stderr_limit = .limited(32 * 1024),
            .timeout = .{ .duration = .{ .raw = .{ .nanoseconds = 8 * std.time.ns_per_s }, .clock = .awake } },
        }) catch return error.IoFailure;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0 or result.stdout.len == 0) return error.NotRunning;
        var credentials = fromCommandLine(result.stdout) catch fromLockfile(result.stdout) catch return error.NotRunning;
        if (forwarded_port > 0) {
            credentials.port = forwarded_port;
            return clientFromBorrowedCredentials(allocator, io, credentials, timeout_ms, verify_tls);
        }
        var local_port: u16 = 29_999;
        while (local_port <= 30_049) : (local_port += 1) {
            credentials.port = local_port;
            var candidate = clientFromBorrowedCredentials(allocator, io, credentials, 700, verify_tls) catch continue;
            const phase = candidate.get("/lol-gameflow/v1/gameflow-phase") catch {
                candidate.deinit();
                continue;
            };
            allocator.free(phase);
            candidate.timeout_ms = timeout_ms;
            return candidate;
        }
        return error.NotRunning;
    }

    pub fn deinit(self: *Client) void {
        self.allocator.free(self.credentials.token);
        self.allocator.free(self.credentials.protocol);
    }

    /// 本地请求实际会走的配额通道。公开是为了让「批次到底挂在哪条配额上」
    /// 能被验证入口直接打印出来——只报毫秒数看不出是快还是侥幸。
    pub fn localBudget(self: Client) windows_http.Budget {
        if (self.budget) |value| return value;
        return switch (self.lane) {
            .roster => .roster,
            .action => .action,
            .events => .events,
            .asset => .asset,
            else => .lcu,
        };
    }

    test "显式指定的配额通道优先于 lane 推导" {
        const base = Client{ .allocator = std.testing.allocator, .io = std.testing.io, .credentials = .{ .port = 1, .protocol = "http", .token = "" } };
        try std.testing.expectEqual(windows_http.Budget.lcu, base.localBudget());
        var overridden = base;
        overridden.budget = .profiles;
        // lane 仍是 `.query`（推导出 `.lcu`），但覆盖值必须赢——否则批次又会
        // 和英雄图标挤在同一个 6 名额上。
        try std.testing.expectEqual(windows_http.Budget.profiles, overridden.localBudget());
    }

    pub fn get(self: Client, path: []const u8) ![]u8 {
        return self.request("GET", path, null);
    }

    pub fn post(self: Client, path: []const u8, body: []const u8) ![]u8 {
        return self.request("POST", path, body);
    }

    /// Send a POST with no entity body. The ready-check accept endpoint uses
    /// this shape in the Rust and LeagueAkari clients; sending `{}` can be
    /// rejected by some LCU builds even though the endpoint is correct.
    pub fn postNoContent(self: Client, path: []const u8) ![]u8 {
        return self.request("POST", path, null);
    }

    /// Send a JSON null entity. Rust's LCU client uses this for endpoints
    /// whose API has no meaningful request fields but still expects a JSON
    /// body on some client versions.
    pub fn postJsonNull(self: Client, path: []const u8) ![]u8 {
        return self.request("POST", path, "null");
    }

    pub fn put(self: Client, path: []const u8, body: []const u8) ![]u8 {
        return self.request("PUT", path, body);
    }

    pub fn patch(self: Client, path: []const u8, body: []const u8) ![]u8 {
        return self.request("PATCH", path, body);
    }

    pub fn delete(self: Client, path: []const u8) ![]u8 {
        return self.request("DELETE", path, null);
    }

    /// Request a Riot SGP endpoint with the short-lived entitlement token.
    /// The URL and token remain inside the native layer and never cross the
    /// WebView bridge.
    pub fn getBearerUrl(self: Client, url: []const u8, token: []const u8, user_agent: []const u8) ![]u8 {
        try self.control.check();
        if (!std.mem.startsWith(u8, url, "https://") or token.len == 0) return error.InvalidPath;
        var authorization_buffer: [16 * 1024]u8 = undefined;
        const authorization = try std.fmt.bufPrint(&authorization_buffer, "Authorization: Bearer {s}", .{token});
        if (builtin.os.tag == .windows) return windows_http.request(self.allocator, .{
            .url = url,
            .headers = authorization,
            .user_agent = user_agent,
            .timeout_ms = self.timeout_ms,
            .verify_tls = true,
            .max_response_bytes = 16 * 1024 * 1024,
            .io = self.io,
            .control = self.control,
            .budget = .remote,
        });
        var timeout_buffer: [16]u8 = undefined;
        const timeout = try std.fmt.bufPrint(&timeout_buffer, "{d}", .{(@as(u32, self.timeout_ms) + 999) / 1000});
        const result = std.process.run(self.allocator, self.io, .{
            .argv = &.{
                "curl",
                "--silent",
                "--show-error",
                "--fail-with-body",
                "--max-time",
                timeout,
                "--header",
                authorization,
                "--user-agent",
                user_agent,
                url,
            },
            .stdout_limit = .limited(16 * 1024 * 1024),
            .stderr_limit = .limited(64 * 1024),
            .timeout = .{ .duration = .{ .raw = .{ .nanoseconds = @as(i96, self.timeout_ms) * std.time.ns_per_ms }, .clock = .awake } },
        }) catch return error.RequestFailed;
        defer self.allocator.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) {
            self.allocator.free(result.stdout);
            return error.RequestFailed;
        }
        return result.stdout;
    }

    /// `postBearerUrl` 的请求头。
    ///
    /// 抽成独立函数**唯一的目的就是能被单测**：这个 415 之所以能藏那么久，
    /// 正是因为「POST 的请求头里到底有没有 `Content-Type`」当时没有任何用例覆盖，
    /// 而它只写在 curl 分支里、WinHTTP 分支漏掉，Windows 上又没有任何测试会发真请求。
    fn bearerPostHeaders(token: []const u8, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "Authorization: Bearer {s}\r\nContent-Type: application/json", .{token});
    }

    /// Request a Riot SGP endpoint with a bearer token **and a JSON body**.
    ///
    /// SGP's `summoner-ledge` / `namesets-for-puuids` are POSTs; the GET-only
    /// `getBearerUrl` above could not reach them. Same credential handling:
    /// the URL and token stay inside the native layer.
    /// Bearer 令牌的跨区 POST。
    ///
    /// ⚠️ **必须带 `Content-Type: application/json`**（2026-10-03 实测定位）。
    ///
    /// SGP 网关对**没有** `Content-Type` 的 POST 一律回 **415 Unsupported Media Type**：
    ///
    /// ```text
    /// POST /summoner-ledge/v1/regions/CQ100/summoners/puuids
    ///   Authorization: Bearer …                          → 415 {"status":{…"Unsupported Media Type"…}}
    ///   Authorization + Content-Type: application/json   → 200 [{"puuid":"…","level":670,…}]
    /// ```
    ///
    /// 原来只有下面那个 **curl 分支**发了这个头，WinHTTP 分支漏了 —— 于是
    /// **Windows 上所有 `postBearerUrl` 调用都在收 415**，而 macOS/Linux 是好的。
    /// 受影响的是仅有的两个调用点，且都是跨区功能：
    /// `probeTencentSubRegionLogged`（逐区定位）与 `enrichCandidateFromSgp`（跨区等级）。
    /// 界面上的表现就是「精确匹配到了人，8 个大区却都说没这个人」+ 跨区战绩打不开。
    /// **GET（`getBearerUrl`）不受影响**，同一个网关对 GET 不要求这个头 ——
    /// 这也是它藏得深的原因：查自己的战绩一直好使，只有跨区那条路是死的。
    pub fn postBearerUrl(
        self: Client,
        url: []const u8,
        token: []const u8,
        user_agent: []const u8,
        body: []const u8,
    ) ![]u8 {
        try self.control.check();
        if (!std.mem.startsWith(u8, url, "https://") or token.len == 0) return error.InvalidPath;
        var authorization_buffer: [16 * 1024]u8 = undefined;
        const authorization = try std.fmt.bufPrint(&authorization_buffer, "Authorization: Bearer {s}", .{token});
        if (builtin.os.tag == .windows) {
            // 复用同一块缓冲区：这一支直接 return，下面的 curl 分支不会再读到 `authorization`。
            return windows_http.request(self.allocator, .{
                .method = "POST",
                .url = url,
                .headers = try bearerPostHeaders(token, &authorization_buffer),
                .user_agent = user_agent,
                .body = body,
                .timeout_ms = self.timeout_ms,
                .verify_tls = true,
                .max_response_bytes = 16 * 1024 * 1024,
                .io = self.io,
                .control = self.control,
                .budget = .remote,
            });
        }
        var timeout_buffer: [16]u8 = undefined;
        const timeout = try std.fmt.bufPrint(&timeout_buffer, "{d}", .{(@as(u32, self.timeout_ms) + 999) / 1000});
        const result = std.process.run(self.allocator, self.io, .{
            .argv = &.{
                "curl",
                "--silent",
                "--show-error",
                "--fail-with-body",
                "--max-time",
                timeout,
                "--header",
                authorization,
                "--header",
                "Content-Type: application/json",
                "--request",
                "POST",
                "--data",
                body,
                "--user-agent",
                user_agent,
                url,
            },
            .stdout_limit = .limited(16 * 1024 * 1024),
            .stderr_limit = .limited(64 * 1024),
            .timeout = .{ .duration = .{ .raw = .{ .nanoseconds = @as(i96, self.timeout_ms) * std.time.ns_per_ms }, .clock = .awake } },
        }) catch return error.RequestFailed;
        defer self.allocator.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) {
            self.allocator.free(result.stdout);
            return error.RequestFailed;
        }
        return result.stdout;
    }
    /// for provider snapshots such as OP.GG; callers still control the fixed
    /// URL and the response never crosses the bridge as raw credentials.
    pub fn getPublicUrl(self: Client, url: []const u8, user_agent: []const u8) ![]u8 {
        try self.control.check();
        if (!std.mem.startsWith(u8, url, "https://")) return error.InvalidPath;
        if (builtin.os.tag == .windows) return windows_http.request(self.allocator, .{
            .url = url,
            .user_agent = user_agent,
            .timeout_ms = self.timeout_ms,
            .verify_tls = true,
            .max_response_bytes = 8 * 1024 * 1024,
            .io = self.io,
            .control = self.control,
            .budget = .remote,
        });
        var timeout_buffer: [16]u8 = undefined;
        const timeout = try std.fmt.bufPrint(&timeout_buffer, "{d}", .{(@as(u32, self.timeout_ms) + 999) / 1000});
        const result = std.process.run(self.allocator, self.io, .{
            .argv = &.{ "curl", "--silent", "--show-error", "--fail-with-body", "--max-time", timeout, "--user-agent", user_agent, url },
            .stdout_limit = .limited(8 * 1024 * 1024),
            .stderr_limit = .limited(64 * 1024),
            .timeout = .{ .duration = .{ .raw = .{ .nanoseconds = @as(i96, self.timeout_ms) * std.time.ns_per_ms }, .clock = .awake } },
        }) catch return error.RequestFailed;
        defer self.allocator.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) {
            self.allocator.free(result.stdout);
            return error.RequestFailed;
        }
        return result.stdout;
    }

    /// Fetch an unauthenticated local HTTPS endpoint such as Live Client Data.
    /// This deliberately accepts only loopback URLs so arbitrary web access
    /// cannot be smuggled through the native bridge.
    pub fn getLocalUrl(self: Client, url: []const u8) ![]u8 {
        try self.control.check();
        if (!std.mem.startsWith(u8, url, "https://127.0.0.1:") and
            !std.mem.startsWith(u8, url, "https://localhost:")) return error.InvalidPath;
        if (builtin.os.tag == .windows) return windows_http.request(self.allocator, .{
            .url = url,
            .timeout_ms = self.timeout_ms,
            .verify_tls = false,
            .max_response_bytes = 8 * 1024 * 1024,
            .io = self.io,
            .control = self.control,
            .budget = self.localBudget(),
        });
        var timeout_buffer: [16]u8 = undefined;
        const timeout = try std.fmt.bufPrint(&timeout_buffer, "{d}", .{(@as(u32, self.timeout_ms) + 999) / 1000});
        const result = std.process.run(self.allocator, self.io, .{
            .argv = &.{
                "curl",
                "--silent",
                "--show-error",
                "--fail-with-body",
                "--insecure",
                "--max-time",
                timeout,
                url,
            },
            .stdout_limit = .limited(8 * 1024 * 1024),
            .stderr_limit = .limited(64 * 1024),
            .timeout = .{ .duration = .{ .raw = .{ .nanoseconds = @as(i96, self.timeout_ms) * std.time.ns_per_ms }, .clock = .awake } },
        }) catch return error.RequestFailed;
        defer self.allocator.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) {
            self.allocator.free(result.stdout);
            return error.RequestFailed;
        }
        return result.stdout;
    }

    fn request(self: Client, method: []const u8, path: []const u8, body: ?[]const u8) ![]u8 {
        try self.control.check();
        if (!std.mem.startsWith(u8, path, "/")) return error.InvalidPath;
        var url_buf: [2048]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "{s}://127.0.0.1:{d}{s}", .{ self.credentials.protocol, self.credentials.port, path });
        var auth_buf: [2048]u8 = undefined;
        const auth = try std.fmt.bufPrint(&auth_buf, "riot:{s}", .{self.credentials.token});
        if (builtin.os.tag == .windows) {
            var encoded: [2048]u8 = undefined;
            const encoded_len = std.base64.standard.Encoder.calcSize(auth.len);
            if (encoded_len > encoded.len) return error.RequestFailed;
            _ = std.base64.standard.Encoder.encode(encoded[0..encoded_len], auth);
            var headers_buffer: [2304]u8 = undefined;
            const headers = if (body != null)
                try std.fmt.bufPrint(&headers_buffer, "Authorization: Basic {s}\r\nContent-Type: application/json", .{encoded[0..encoded_len]})
            else
                try std.fmt.bufPrint(&headers_buffer, "Authorization: Basic {s}", .{encoded[0..encoded_len]});
            return windows_http.request(self.allocator, .{
                .method = method,
                .url = url,
                .headers = headers,
                .body = body,
                .timeout_ms = self.timeout_ms,
                .verify_tls = self.verify_tls,
                .max_response_bytes = 8 * 1024 * 1024,
                .io = self.io,
                .control = self.control,
                .budget = self.localBudget(),
            });
        }
        var argv: [16][]const u8 = undefined;
        var argc: usize = 0;
        argv[argc] = "curl";
        argc += 1;
        argv[argc] = "--silent";
        argc += 1;
        argv[argc] = "--show-error";
        argc += 1;
        if (!self.verify_tls) {
            argv[argc] = "--insecure";
            argc += 1;
        }
        argv[argc] = "--max-time";
        argc += 1;
        var timeout_buf: [16]u8 = undefined;
        argv[argc] = try std.fmt.bufPrint(&timeout_buf, "{d}", .{(@as(u32, self.timeout_ms) + 999) / 1000});
        argc += 1;
        argv[argc] = "--user";
        argc += 1;
        argv[argc] = auth;
        argc += 1;
        argv[argc] = "--request";
        argc += 1;
        argv[argc] = method;
        argc += 1;
        if (body) |payload| {
            argv[argc] = "--header";
            argc += 1;
            argv[argc] = "Content-Type: application/json";
            argc += 1;
            argv[argc] = "--data-binary";
            argc += 1;
            argv[argc] = payload;
            argc += 1;
        }
        argv[argc] = url;
        argc += 1;
        const result = std.process.run(self.allocator, self.io, .{
            .argv = argv[0..argc],
            .stdout_limit = .limited(8 * 1024 * 1024),
            .stderr_limit = .limited(64 * 1024),
            .timeout = .{ .duration = .{ .raw = .{ .nanoseconds = @as(i96, self.timeout_ms) * std.time.ns_per_ms }, .clock = .awake } },
        }) catch return error.RequestFailed;
        defer self.allocator.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) {
            self.allocator.free(result.stdout);
            return error.RequestFailed;
        }
        return result.stdout;
    }
};

fn clientFromBorrowedCredentials(allocator: std.mem.Allocator, io: std.Io, credentials: Credentials, timeout_ms: u32, verify_tls: bool) !Client {
    return .{
        .allocator = allocator,
        .io = io,
        .credentials = try ownCredentials(allocator, credentials),
        .timeout_ms = timeout_ms,
        .verify_tls = verify_tls,
    };
}

fn discoverProcess(allocator: std.mem.Allocator, io: std.Io) ?[]u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", "$OutputEncoding=[Console]::OutputEncoding=[System.Text.UTF8Encoding]::new(); $processes=@(Get-CimInstance Win32_Process -Filter \"Name='LeagueClientUx.exe'\" -ErrorAction SilentlyContinue); $process=$processes | Where-Object { $_.CommandLine -match '--(?:app|riotclient-app)-port' -and $_.CommandLine -match '--(?:remoting|riotclient)-auth-token' } | Select-Object -First 1; if ($null -ne $process -and -not [string]::IsNullOrWhiteSpace($process.CommandLine)) { [Console]::Out.Write($process.CommandLine); exit 0 }; $fallback=$processes | Select-Object -First 1; $executable=if ($null -ne $fallback) { $fallback.ExecutablePath } else { $null }; if ([string]::IsNullOrWhiteSpace($executable)) { $native=Get-Process -Name LeagueClientUx -ErrorAction SilentlyContinue | Select-Object -First 1; if ($null -ne $native) { $executable=$native.Path } }; if (-not [string]::IsNullOrWhiteSpace($executable)) { $lockfile=Join-Path (Split-Path -Parent $executable) 'lockfile'; if (Test-Path -LiteralPath $lockfile) { [Console]::Out.Write((Get-Content -Raw -LiteralPath $lockfile)); exit 0 } }; exit 3" },
        .stdout_limit = .limited(32 * 1024),
        .stderr_limit = .limited(8 * 1024),
        .timeout = .{ .duration = .{ .raw = .{ .nanoseconds = 2 * std.time.ns_per_s }, .clock = .awake } },
    }) catch return null;
    allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0 or result.stdout.len == 0) {
        allocator.free(result.stdout);
        return null;
    }
    return result.stdout;
}

/// WMI intentionally remains a fallback: on Windows a League Client started
/// with a different integrity level often exposes an empty CommandLine field.
/// The Rust client handles that case with Toolhelp + QueryFullProcessImageName;
/// keep the same native path here so a normal user launch can still locate the
/// client-side lockfile without requiring an elevated PowerShell process.
/// `discoverProcessNative` 的探测结果。
///
/// 分成两件事是有意义的：`seen`（进程在不在）非常便宜——Toolhelp 快照里每个进程都
/// 直接带 `szExeFile`，不用碰进程句柄；`command_line`（凭据读没读到）才需要开句柄。
/// 调用方靠 `seen` 决定要不要动用 WMI 兜底，见 `discover` 里的说明。
const ProcessProbe = struct {
    seen: bool = false,
    command_line: ?[]u8 = null,
};

fn discoverProcessNative(allocator: std.mem.Allocator, io: std.Io) ProcessProbe {
    if (builtin.os.tag != .windows) return .{};
    const api = windows_process_api;
    const snapshot = api.CreateToolhelp32Snapshot(api.TH32CS_SNAPPROCESS, 0) orelse return .{};
    if (@intFromPtr(snapshot) == std.math.maxInt(usize)) return .{};
    defer _ = api.CloseHandle(snapshot);

    var entry: api.ProcessEntry32W = undefined;
    entry.dwSize = @sizeOf(api.ProcessEntry32W);
    if (api.Process32FirstW(snapshot, &entry) == 0) return .{};
    var seen = false;
    while (true) {
        if (api.isLeagueClientUx(entry.szExeFile[0..])) {
            seen = true;
            if (discoverNativeProcessCredentials(allocator, io, entry.th32ProcessID)) |value| return .{ .seen = true, .command_line = value };
        }
        if (api.Process32NextW(snapshot, &entry) == 0) break;
    }
    return .{ .seen = seen };
}

fn discoverNativeProcessCredentials(allocator: std.mem.Allocator, io: std.Io, pid: u32) ?[]u8 {
    if (windowsProcessCommandLine(allocator, pid)) |command_line| {
        if (fromCommandLine(command_line) catch null) |_| return command_line;
        allocator.free(command_line);
    }
    const executable = windowsProcessImagePath(allocator, pid) orelse return null;
    defer allocator.free(executable);
    const directory = std.fs.path.dirname(executable) orelse return null;
    var lockfile_path: [4096]u8 = undefined;
    const lockfile = std.fmt.bufPrint(&lockfile_path, "{s}\\lockfile", .{directory}) catch return null;
    const contents = std.Io.Dir.cwd().readFileAlloc(io, lockfile, allocator, .limited(16 * 1024)) catch return null;
    if (fromLockfile(contents) catch null) |_| return contents;
    allocator.free(contents);
    return null;
}

fn windowsProcessCommandLine(allocator: std.mem.Allocator, pid: u32) ?[]u8 {
    if (builtin.os.tag != .windows) return null;
    const api = windows_process_api;
    const process = api.OpenProcess(api.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return null;
    defer _ = api.CloseHandle(process);

    // ProcessCommandLineInformation is information class 60. The returned
    // UNICODE_STRING points into the same buffer on supported Windows builds.
    var buffer: [16384]u8 align(@alignOf(usize)) = undefined;
    var returned: u32 = 0;
    const status = api.NtQueryInformationProcess(process, 60, &buffer, buffer.len, &returned);
    if (status != 0 or returned < @sizeOf(api.UnicodeString)) return null;
    const command = @as(*const api.UnicodeString, @ptrCast(@alignCast(&buffer))).*;
    const pointer = command.Buffer orelse return null;
    if (command.Length == 0) return null;
    return std.unicode.wtf16LeToWtf8Alloc(allocator, pointer[0 .. command.Length / 2]) catch null;
}

fn windowsProcessImagePath(allocator: std.mem.Allocator, pid: u32) ?[]u8 {
    if (builtin.os.tag != .windows) return null;
    const api = windows_process_api;
    const process = api.OpenProcess(api.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return null;
    defer _ = api.CloseHandle(process);
    var buffer: [32768]u16 = undefined;
    var length: u32 = buffer.len;
    if (api.QueryFullProcessImageNameW(process, 0, &buffer, &length) == 0 or length == 0) return null;
    return std.unicode.wtf16LeToWtf8Alloc(allocator, buffer[0..length]) catch null;
}

const windows_process_api = if (builtin.os.tag == .windows) struct {
    const TH32CS_SNAPPROCESS: u32 = 0x00000002;
    const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;

    const ProcessEntry32W = extern struct {
        dwSize: u32,
        cntUsage: u32,
        th32ProcessID: u32,
        thDefaultHeapID: usize,
        th32ModuleID: u32,
        cntThreads: u32,
        th32ParentProcessID: u32,
        pcPriClassBase: i32,
        dwFlags: u32,
        szExeFile: [260]u16,
    };

    const UnicodeString = extern struct {
        Length: u16,
        MaximumLength: u16,
        Buffer: ?[*]u16,
    };

    extern "kernel32" fn CreateToolhelp32Snapshot(flags: u32, process_id: u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn Process32FirstW(snapshot: *anyopaque, entry: *ProcessEntry32W) callconv(.winapi) i32;
    extern "kernel32" fn Process32NextW(snapshot: *anyopaque, entry: *ProcessEntry32W) callconv(.winapi) i32;
    extern "kernel32" fn OpenProcess(access: u32, inherit_handle: i32, process_id: u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn QueryFullProcessImageNameW(process: *anyopaque, flags: u32, buffer: [*]u16, length: *u32) callconv(.winapi) i32;
    extern "kernel32" fn CloseHandle(handle: *anyopaque) callconv(.winapi) i32;
    extern "ntdll" fn NtQueryInformationProcess(process: *anyopaque, information_class: u32, buffer: *anyopaque, buffer_length: u32, return_length: *u32) callconv(.winapi) i32;

    fn isLeagueClientUx(name: []const u16) bool {
        const expected = "LeagueClientUx.exe";
        var length: usize = 0;
        while (length < name.len and name[length] != 0) : (length += 1) {}
        if (length != expected.len) return false;
        for (name[0..length], expected) |actual, wanted| {
            if (std.ascii.toLower(@as(u8, @truncate(actual))) != std.ascii.toLower(wanted)) return false;
        }
        return true;
    }
} else struct {};

fn readLockfile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024)) catch null;
}

pub fn fromLockfile(content: []const u8) ParseError!Credentials {
    var fields: [5][]const u8 = undefined;
    var count: usize = 0;
    var iterator = std.mem.splitScalar(u8, std.mem.trim(u8, content, " \t\r\n"), ':');
    while (iterator.next()) |field| {
        if (count < fields.len) fields[count] = field;
        count += 1;
    }
    if (count < fields.len) return error.InvalidLockfile;
    const port = std.fmt.parseInt(u16, fields[2], 10) catch return error.InvalidPort;
    if (fields[3].len == 0) return error.MissingToken;
    return .{ .port = port, .token = fields[3], .protocol = fields[4] };
}

pub fn fromCommandLine(command_line: []const u8) ParseError!Credentials {
    const port_text = argumentValue(command_line, "--app-port") orelse
        argumentValue(command_line, "--riotclient-app-port") orelse return error.MissingPort;
    const token = argumentValue(command_line, "--remoting-auth-token") orelse
        argumentValue(command_line, "--riotclient-auth-token") orelse return error.MissingToken;
    const port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidPort;
    if (token.len == 0) return error.MissingToken;
    var credentials = Credentials{ .port = port, .token = token, .protocol = "https" };
    // 与参考项目一致，从客户端进程参数读取大区，兼容两种命名。
    const platform = argumentValue(command_line, "--rso_platform_id") orelse argumentValue(command_line, "--rso-platform-id") orelse "";
    if (platform.len <= credentials.platform.len) {
        @memcpy(credentials.platform[0..platform.len], platform);
        credentials.platform_len = platform.len;
    }
    return credentials;
}

/// 只从 `--riotclient-app-port` / `--riotclient-auth-token` 解析的 Riot Client 凭据。
///
/// `LeagueClientUx.exe` 的命令行里同时带两套凭据，指向**两个不同的本地服务**：
/// LCU 是 `--app-port` + `--remoting-auth-token`，Riot Client 是
/// `--riotclient-app-port` + `--riotclient-auth-token`。
///
/// 必须分开解析的原因：跨区 `名字#TAG → puuid` 的
/// `player-account/aliases/v1/lookup` **只在 RC 端口可用**（`fromCommandLine`
/// 会优先挑 `--app-port`，拿它去查 alias 只会 404）。
pub fn fromRiotClientCommandLine(command_line: []const u8) ParseError!Credentials {
    const port_text = argumentValue(command_line, "--riotclient-app-port") orelse return error.MissingPort;
    const token = argumentValue(command_line, "--riotclient-auth-token") orelse return error.MissingToken;
    const port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidPort;
    if (token.len == 0) return error.MissingToken;
    var credentials = Credentials{ .port = port, .token = token, .protocol = "https" };
    const platform = argumentValue(command_line, "--rso_platform_id") orelse argumentValue(command_line, "--rso-platform-id") orelse "";
    if (platform.len <= credentials.platform.len) {
        @memcpy(credentials.platform[0..platform.len], platform);
        credentials.platform_len = platform.len;
    }
    return credentials;
}

fn ownCredentials(allocator: std.mem.Allocator, borrowed: Credentials) !Credentials {
    const token = try allocator.dupe(u8, borrowed.token);
    errdefer allocator.free(token);
    const protocol = try allocator.dupe(u8, borrowed.protocol);
    return .{ .port = borrowed.port, .token = token, .protocol = protocol, .platform = borrowed.platform, .platform_len = borrowed.platform_len };
}

fn argumentValue(command_line: []const u8, key: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    while (cursor < command_line.len) {
        while (cursor < command_line.len and std.ascii.isWhitespace(command_line[cursor])) cursor += 1;
        if (cursor >= command_line.len) break;
        const start = cursor;
        var quoted = false;
        while (cursor < command_line.len) : (cursor += 1) {
            const character = command_line[cursor];
            if (character == '"') quoted = !quoted;
            if (!quoted and std.ascii.isWhitespace(character)) break;
        }
        const token = std.mem.trim(u8, command_line[start..cursor], "\"");
        if (token.len > key.len and std.mem.eql(u8, token[0..key.len], key) and token[key.len] == '=') {
            return std.mem.trim(u8, token[key.len + 1 ..], "\"");
        }
        if (std.mem.eql(u8, token, key)) {
            while (cursor < command_line.len and std.ascii.isWhitespace(command_line[cursor])) cursor += 1;
            if (cursor >= command_line.len) return null;
            const value_start = cursor;
            var value_quoted = false;
            while (cursor < command_line.len) : (cursor += 1) {
                const character = command_line[cursor];
                if (character == '"') value_quoted = !value_quoted;
                if (!value_quoted and std.ascii.isWhitespace(character)) break;
            }
            return std.mem.trim(u8, command_line[value_start..cursor], "\"");
        }
    }
    return null;
}

test "parses LCU lockfile credentials" {
    const credentials = try fromLockfile("LeagueClient:123:54321:secret:https\n");
    try std.testing.expectEqual(@as(u16, 54321), credentials.port);
    try std.testing.expectEqualStrings("secret", credentials.token);
    try std.testing.expectEqualStrings("https", credentials.protocol);
}

test "解析两种参数格式并保留独立大区信息" {
    const equals = try fromCommandLine("LeagueClientUx.exe --app-port=1234 --remoting-auth-token=abc");
    try std.testing.expectEqual(@as(u16, 1234), equals.port);
    try std.testing.expectEqualStrings("abc", equals.token);
    const separated = try fromCommandLine("LeagueClientUx.exe --riotclient-app-port 4321 --riotclient-auth-token \"secret value\"");
    try std.testing.expectEqual(@as(u16, 4321), separated.port);
    try std.testing.expectEqualStrings("secret value", separated.token);
    for ([_][]const u8{ "--rso_platform_id=HN1", "--rso-platform-id HN1" }) |flag| {
        const command = try std.fmt.allocPrint(std.testing.allocator, "LeagueClientUx.exe --app-port=1234 --remoting-auth-token=abc {s}", .{flag});
        defer std.testing.allocator.free(command);
        const borrowed = try fromCommandLine(command);
        const owned = try ownCredentials(std.testing.allocator, borrowed);
        defer std.testing.allocator.free(owned.token);
        defer std.testing.allocator.free(owned.protocol);
        try std.testing.expectEqualStrings("HN1", owned.platformId());
    }
}

test "Riot Client 凭据只取 riotclient 参数，不误用 LCU 端口" {
    // 真实命令行同时带两套凭据：LCU 是 --app-port，RC 是 --riotclient-app-port。
    // RC 解析必须挑后者，否则 alias 查询会打到 LCU 端口上（404）。
    const command =
        "LeagueClientUx.exe --app-port=53970 --remoting-auth-token=lcu-token " ++
        "--riotclient-app-port=53971 --riotclient-auth-token=rc-token --rso_platform_id=HN1";
    const rc = try fromRiotClientCommandLine(command);
    try std.testing.expectEqual(@as(u16, 53971), rc.port);
    try std.testing.expectEqualStrings("rc-token", rc.token);
    try std.testing.expectEqualStrings("HN1", rc.platformId());
    // LCU 解析仍然挑 --app-port，两者互不影响。
    const lcu_credentials = try fromCommandLine(command);
    try std.testing.expectEqual(@as(u16, 53970), lcu_credentials.port);
    try std.testing.expectEqualStrings("lcu-token", lcu_credentials.token);
    // 只有 LCU 参数时 RC 解析必须失败，而不是退回 LCU 端口。
    try std.testing.expectError(
        error.MissingPort,
        fromRiotClientCommandLine("LeagueClientUx.exe --app-port=53970 --remoting-auth-token=lcu-token"),
    );
}

test "rejects malformed credentials" {
    try std.testing.expectError(error.InvalidLockfile, fromLockfile("LeagueClient:1:2"));
    try std.testing.expectError(error.MissingToken, fromCommandLine("LeagueClientUx.exe --app-port=1234"));
    try std.testing.expectError(error.InvalidPort, fromLockfile("LeagueClient:1:nope:secret:https"));
}

test "Bearer POST 必须带 Content-Type，否则 SGP 网关回 415" {
    // 2026-10-03 实机实测（curl，同一个 league-session 令牌打
    // `POST /summoner-ledge/v1/regions/CQ100/summoners/puuids`）：
    //   只有 Authorization                        → 415 Unsupported Media Type
    //   Authorization + Content-Type: application → 200 [{puuid, level:670, …}]
    //
    // 当时 WinHTTP 分支只发了 Authorization（curl 分支反而是对的），
    // 于是 **Windows 上逐区定位 8 个区全灭**、跨区等级永远取不到，
    // 界面上表现为「精确匹配到了人，却都说 8 个大区没这个人」。
    // 这条用例就是给那次回归上的锁：请求头里必须两个字头都在。
    var buffer: [512]u8 = undefined;
    const headers = try Client.bearerPostHeaders("test-token", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, headers, "Authorization: Bearer test-token") != null);
    try std.testing.expect(std.mem.indexOf(u8, headers, "Content-Type: application/json") != null);
    // 换行必须是 CRLF：WinHTTP 的 lpszHeaders 靠它分隔多个头，用 LF 会被当成一个头名。
    try std.testing.expect(std.mem.indexOf(u8, headers, "\r\n") != null);
}
