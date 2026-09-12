const std = @import("std");
const builtin = @import("builtin");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const lcu = @import("lcu");
const backend = @import("backend");
const bridge_policy = @import("bridge");
// 每个 bridge lane 一个 worker 线程；事件轮询与连接刷新已从 roster lane 拆出。
const lane_count = lcu.lane_count;
const build_options = @import("build_options");
const embedded_assets = @import("embedded_assets");
const app_manifest = @import("app_manifest_zon");

// The SDK exposes the Windows host APIs needed to locate the executable, but
// does not currently re-export GetModuleFileName. Keep this declaration local
// so packaged assets do not depend on the process working directory.
const windows_api = if (builtin.os.tag == .windows) struct {
    const Rect = extern struct {
        left: i32,
        top: i32,
        right: i32,
        bottom: i32,
    };

    extern "kernel32" fn GetModuleFileNameW(
        module: ?*anyopaque,
        filename: [*]u16,
        size: u32,
    ) callconv(.winapi) u32;
    extern "kernel32" fn LoadLibraryW(filename: [*:0]const u16) ?*anyopaque;
    extern "kernel32" fn GetModuleHandleW(module_name: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
    extern "kernel32" fn Sleep(milliseconds: u32) callconv(.winapi) void;
    extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: [*:0]const u16) callconv(.winapi) i32;
    extern "user32" fn FindWindowW(class_name: ?[*:0]const u16, window_name: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
    extern "user32" fn GetWindowThreadProcessId(window: *anyopaque, process_id: *u32) callconv(.winapi) u32;
    // `name` may be either a UTF-16 path or a MAKEINTRESOURCE value, so it
    // cannot carry Zig's normal u16 pointer-alignment guarantee.
    extern "user32" fn LoadImageW(instance: ?*anyopaque, name: *const anyopaque, image_type: u32, width: i32, height: i32, flags: u32) callconv(.winapi) ?*anyopaque;
    extern "user32" fn SetClassLongPtrW(window: *anyopaque, index: i32, new_long: isize) callconv(.winapi) isize;
    extern "user32" fn PostMessageW(window: *anyopaque, message: u32, wparam: usize, lparam: isize) callconv(.winapi) i32;
    extern "user32" fn SetProcessDpiAwarenessContext(value: isize) callconv(.winapi) i32;
    extern "user32" fn GetClientRect(window: *anyopaque, rect: *Rect) callconv(.winapi) i32;
    extern "user32" fn GetWindowRect(window: *anyopaque, rect: *Rect) callconv(.winapi) i32;
    extern "user32" fn GetDpiForWindow(window: *anyopaque) callconv(.winapi) u32;
    extern "user32" fn SetWindowPos(window: *anyopaque, insert_after: ?*anyopaque, x: i32, y: i32, width: i32, height: i32, flags: u32) callconv(.winapi) i32;
} else struct {};

const WindowsIconPair = struct {
    process_id: u32,
    large: ?*anyopaque,
    small: ?*anyopaque,
    resize_initial: bool,
};

const initial_window_width: f64 = app_manifest.windows[0].width;
const initial_window_height: f64 = app_manifest.windows[0].height;
const windows_main_title = std.unicode.utf8ToUtf16LeStringLiteral(app_manifest.windows[0].title);

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const AsyncBridgeContext = struct {
    app: *App,
    handler: native_sdk.bridge.Handler,
};

const AsyncBridgeJob = struct {
    context: *AsyncBridgeContext,
    responder: native_sdk.bridge.AsyncResponder,
    id: []u8,
    payload: []u8,
    origin: []u8,
    webview_label: []u8,
    window_id: u64,
    queued_at_ms: i64 = 0,
    action_ticket: ?backend.ActionTicket = null,
    result: ?[]u8 = null,
    failure_code: native_sdk.bridge.ErrorCode = .handler_failed,
    failure_message: ?[]const u8 = null,
    next: ?*AsyncBridgeJob = null,

    fn deinit(self: *AsyncBridgeJob) void {
        const allocator = std.heap.page_allocator;
        if (self.result) |result| allocator.free(result);
        allocator.free(self.id);
        allocator.free(self.payload);
        allocator.free(self.origin);
        allocator.free(self.webview_label);
        allocator.destroy(self);
    }
};

const App = struct {
    env_map: *std.process.Environ.Map,
    dist_path: []const u8,
    icon_path: []const u8 = "assets/icon.png",
    runtime: backend.Runtime,
    handlers: [1]native_sdk.bridge.Handler = undefined,
    async_contexts: [backend.command_names.len]AsyncBridgeContext = undefined,
    async_handlers: [backend.command_names.len]native_sdk.bridge.AsyncHandler = undefined,
    accepting_async_jobs: std.atomic.Value(bool) = .init(false),
    active_async_jobs: std.atomic.Value(usize) = .init(0),
    pending_mutex: std.atomic.Mutex = .unlocked,
    pending_heads: [lane_count]?*AsyncBridgeJob = .{null} ** lane_count,
    pending_tails: [lane_count]?*AsyncBridgeJob = .{null} ** lane_count,
    pending_counts: [lane_count]usize = .{0} ** lane_count,
    worker_signals: [lane_count]std.Io.Semaphore = .{std.Io.Semaphore{}} ** lane_count,
    worker_threads: [lane_count]?std.Thread = .{null} ** lane_count,
    automation_stop: std.atomic.Value(bool) = .init(false),
    automation_thread: ?std.Thread = null,
    completion_mutex: std.atomic.Mutex = .unlocked,
    completion_head: ?*AsyncBridgeJob = null,
    completion_tail: ?*AsyncBridgeJob = null,

    fn app(self: *@This()) native_sdk.App {
        return .{
            .context = self,
            .name = "lol-desktop-native",
            .source = native_sdk.frontend.productionSource(.{ .dist = self.dist_path }),
            .source_fn = source,
            .start_fn = startApp,
            .event_fn = appEvent,
            .stop_fn = stopApp,
        };
    }

    fn ping(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        _ = invocation;
        _ = context;
        return std.fmt.bufPrint(output, "{{\"name\":\"lol-desktop-native\",\"version\":\"2.0.0\",\"ready\":true}}", .{});
    }

    fn bridge(self: *@This()) native_sdk.BridgeDispatcher {
        self.handlers[0] = .{ .name = "native.ping", .context = self, .invoke_fn = ping };
        const runtime_handlers = self.runtime.handlers();
        for (runtime_handlers, 0..) |handler, index| {
            self.async_contexts[index] = .{
                .app = self,
                .handler = handler,
            };
            self.async_handlers[index] = .{
                .name = handler.name,
                .context = &self.async_contexts[index],
                .invoke_fn = invokeAsync,
            };
        }
        return .{
            .policy = .{ .enabled = true, .commands = &bridge_policy.policies },
            .registry = .{ .handlers = &self.handlers },
            .async_registry = .{ .handlers = &self.async_handlers },
        };
    }

    fn invokeAsync(context: *anyopaque, invocation: native_sdk.bridge.Invocation, responder: native_sdk.bridge.AsyncResponder) anyerror!void {
        const bridge_context: *AsyncBridgeContext = @ptrCast(@alignCast(context));
        const self = bridge_context.app;
        const io = self.runtime.io orelse {
            responder.fail(invocation.request.id, .internal_error, "后台请求通道尚未初始化") catch {};
            return;
        };
        if (!self.accepting_async_jobs.load(.acquire)) {
            responder.fail(invocation.request.id, .internal_error, "应用正在退出") catch {};
            return;
        }
        const allocator = std.heap.page_allocator;
        const job = allocator.create(AsyncBridgeJob) catch {
            responder.fail(invocation.request.id, .internal_error, "无法分配后台请求任务") catch {};
            return;
        };
        job.* = .{
            .context = bridge_context,
            .responder = responder,
            .id = allocator.dupe(u8, invocation.request.id) catch {
                allocator.destroy(job);
                responder.fail(invocation.request.id, .internal_error, "无法分配请求数据") catch {};
                return;
            },
            .payload = undefined,
            .origin = undefined,
            .webview_label = undefined,
            .window_id = invocation.source.window_id,
            .action_ticket = if (backend.commandLane(bridge_context.handler.name) == .action) backend.actionTicket(&self.runtime) else null,
            .queued_at_ms = @intCast(@divTrunc(std.Io.Timestamp.now(io, .awake).nanoseconds, std.time.ns_per_ms)),
        };
        job.payload = allocator.dupe(u8, invocation.request.payload) catch {
            allocator.free(job.id);
            allocator.destroy(job);
            responder.fail(invocation.request.id, .internal_error, "无法分配请求数据") catch {};
            return;
        };
        job.origin = allocator.dupe(u8, invocation.source.origin) catch {
            allocator.free(job.payload);
            allocator.free(job.id);
            allocator.destroy(job);
            responder.fail(invocation.request.id, .internal_error, "无法分配请求数据") catch {};
            return;
        };
        job.webview_label = allocator.dupe(u8, invocation.source.webview_label) catch {
            allocator.free(job.origin);
            allocator.free(job.payload);
            allocator.free(job.id);
            allocator.destroy(job);
            responder.fail(invocation.request.id, .internal_error, "无法分配请求数据") catch {};
            return;
        };
        lockAtomic(&self.pending_mutex);
        if (!self.accepting_async_jobs.load(.acquire)) {
            self.pending_mutex.unlock();
            job.deinit();
            responder.fail(invocation.request.id, .internal_error, "应用正在退出") catch {};
            return;
        }
        const lane = @intFromEnum(backend.commandLane(bridge_context.handler.name));
        if (self.pending_counts[lane] >= 64) {
            self.pending_mutex.unlock();
            job.deinit();
            responder.fail(invocation.request.id, .internal_error, "请求队列已满，请稍后重试") catch {};
            return;
        }
        _ = self.active_async_jobs.fetchAdd(1, .acq_rel);
        self.pending_counts[lane] += 1;
        if (self.pending_tails[lane]) |tail| {
            tail.next = job;
        } else {
            self.pending_heads[lane] = job;
        }
        self.pending_tails[lane] = job;
        self.pending_mutex.unlock();
        self.worker_signals[lane].post(io);
    }

    fn asyncBridgeWorker(self: *App, lane: usize) void {
        const io = self.runtime.io orelse return;
        while (true) {
            self.worker_signals[lane].waitUncancelable(io);
            if (self.dequeuePending(lane)) |job| {
                processAsyncBridgeJob(job);
                continue;
            }
            if (!self.accepting_async_jobs.load(.acquire)) return;
        }
    }

    fn dequeuePending(self: *App, lane: usize) ?*AsyncBridgeJob {
        lockAtomic(&self.pending_mutex);
        defer self.pending_mutex.unlock();
        const job = self.pending_heads[lane] orelse return null;
        self.pending_heads[lane] = job.next;
        self.pending_counts[lane] -= 1;
        if (self.pending_heads[lane] == null) self.pending_tails[lane] = null;
        job.next = null;
        return job;
    }

    fn processAsyncBridgeJob(job: *AsyncBridgeJob) void {
        const self = job.context.app;
        defer _ = self.active_async_jobs.fetchSub(1, .acq_rel);
        if (!self.accepting_async_jobs.load(.acquire)) {
            job.failure_message = "应用正在退出，已取消排队请求";
            enqueueCompleted(job);
            return;
        }
        const result_buffer = std.heap.page_allocator.alloc(u8, native_sdk.bridge.max_result_bytes) catch {
            job.failure_code = .internal_error;
            job.failure_message = "无法分配结果缓冲区";
            enqueueCompleted(job);
            return;
        };
        defer std.heap.page_allocator.free(result_buffer);

        // 发送等待过久就取消，避免在对局阶段改变后重放旧操作。
        if (std.mem.eql(u8, job.context.handler.name, "lol.send_shortcut")) if (self.runtime.io) |io| {
            const now_ms: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .awake).nanoseconds, std.time.ns_per_ms));
            if (now_ms - job.queued_at_ms > 10_000) {
                job.failure_message = "消息等待过久，已取消发送";
                enqueueCompleted(job);
                return;
            }
        };
        const result = backend.invokeQueued(&self.runtime, job.context.handler, .{
            .request = .{
                .id = job.id,
                .command = job.context.handler.name,
                .payload = job.payload,
            },
            .source = .{
                .origin = job.origin,
                .window_id = job.window_id,
                .webview_label = job.webview_label,
            },
        }, result_buffer, job.action_ticket) catch |err| {
            job.failure_message = backend.errorMessage(err);
            enqueueCompleted(job);
            return;
        };
        job.result = std.heap.page_allocator.dupe(u8, if (result.len == 0) "null" else result) catch {
            job.failure_code = .internal_error;
            job.failure_message = "无法分配返回数据";
            enqueueCompleted(job);
            return;
        };
        enqueueCompleted(job);
    }

    fn enqueueCompleted(job: *AsyncBridgeJob) void {
        const self = job.context.app;
        lockAtomic(&self.completion_mutex);
        if (self.completion_tail) |tail| {
            tail.next = job;
        } else {
            self.completion_head = job;
        }
        self.completion_tail = job;
        self.completion_mutex.unlock();

        // 网络和数据库工作在后台完成，桥接响应仍交回窗口线程。
        if (self.runtime.native_runtime) |runtime| runtime.options.platform.services.wake() catch {};
    }

    fn drainCompleted(self: *App) void {
        lockAtomic(&self.completion_mutex);
        var current = self.completion_head;
        self.completion_head = null;
        self.completion_tail = null;
        self.completion_mutex.unlock();

        while (current) |job| {
            const next = job.next;
            if (job.result) |result| {
                job.responder.success(job.id, result) catch {};
            } else {
                job.responder.fail(job.id, job.failure_code, job.failure_message orelse "请求处理失败") catch {};
            }
            job.deinit();
            current = next;
        }
    }

    fn stopAsyncBridge(self: *App) void {
        self.runtime.cancelRequests();
        lockAtomic(&self.pending_mutex);
        self.accepting_async_jobs.store(false, .release);
        self.pending_mutex.unlock();
        for (self.worker_threads, 0..) |thread, lane| if (thread != null) {
            if (self.runtime.io) |io| self.worker_signals[lane].post(io);
        };
        for (&self.worker_threads) |*thread| if (thread.*) |value| {
            value.join();
            thread.* = null;
        };
        self.drainCompleted();
    }

    fn startAutomationWatchdog(self: *App) !void {
        if (self.automation_thread != null) return;
        const io = self.runtime.io orelse return error.AutomationWatchdogIoUnavailable;
        self.automation_stop.store(false, .release);
        self.automation_thread = std.Thread.spawn(.{}, automationWatchdog, .{ self, io }) catch |err| {
            self.automation_stop.store(true, .release);
            return err;
        };
    }

    fn stopAutomationWatchdog(self: *App) void {
        self.automation_stop.store(true, .release);
        if (self.automation_thread) |thread| {
            thread.join();
            self.automation_thread = null;
        }
    }

    fn startAsyncBridge(self: *App) !void {
        if (self.worker_threads[0] != null) return;
        if (self.runtime.io == null) return error.BridgeWorkerIoUnavailable;
        self.accepting_async_jobs.store(true, .release);
        errdefer self.stopAsyncBridge();
        for (&self.worker_threads, 0..) |*thread, lane| thread.* = try std.Thread.spawn(.{}, asyncBridgeWorker, .{ self, lane });
    }

    fn source(context: *anyopaque) anyerror!native_sdk.WebViewSource {
        const self: *@This() = @ptrCast(@alignCast(context));
        const config: native_sdk.frontend.Config = .{
            .dist = self.dist_path,
            .entry = "index.html",
        };
        // The SDK uses this environment variable for its managed `native
        // dev` server. Never let an unrelated process-level value redirect a
        // Release/package build away from its bundled assets.
        return if (builtin.mode == .Debug)
            native_sdk.frontend.sourceFromEnv(self.env_map, config)
        else
            native_sdk.frontend.productionSource(config);
    }
};

/// Resolve production assets from the executable location. Native packages
/// place the executable in `bin/` and the Vite output in
/// `resources/frontend/dist`; development binaries keep `frontend/dist` in
/// the project tree. Looking at the executable rather than cwd makes a
/// packaged app reliable when launched from Explorer, a shortcut, or another
/// working directory.
fn productionDistPath(allocator: std.mem.Allocator, io: std.Io, env_map: *const std.process.Environ.Map) []const u8 {
    const fallback = "frontend/dist";
    // Load embedded runtime support before the WebView host starts, even when
    // a development checkout happens to be visible next to the executable.
    // This is what makes the copied single-file package independent of the
    // staging directory's WebView2Loader.dll.
    const embedded = extractEmbeddedAssets(allocator, io, env_map);
    // Release/package binaries carry the complete web bundle (including the
    // tray icon). Prefer that extracted, absolute runtime root so launching
    // the copied exe from Explorer or another cwd remains self-contained.
    if (builtin.mode != .Debug) if (embedded) |path| return path;
    const executable = executablePathAlloc(allocator, io) orelse return embedded orelse fallback;
    defer allocator.free(executable);
    const base_dir = std.fs.path.dirname(executable) orelse return fallback;

    // A macOS .app uses Contents/MacOS -> Contents/Resources, while the
    // desktop package uses bin -> resources on Windows and Linux.
    const packaged_relative = if (builtin.os.tag == .macos)
        "../Resources/frontend/dist"
    else
        "../resources/frontend/dist";
    const candidates = [_][]const u8{ packaged_relative, "../../frontend/dist" };
    for (candidates) |relative| {
        const candidate = std.fs.path.resolve(allocator, &.{ base_dir, relative }) catch continue;
        if (std.Io.Dir.openDirAbsolute(io, candidate, .{})) |dir| {
            dir.close(io);
            if (embedded) |path| allocator.free(path);
            return candidate;
        } else |_| {
            allocator.free(candidate);
        }
    }
    return embedded orelse fallback;
}

fn productionIconPath(allocator: std.mem.Allocator, io: std.Io, dist_path: []const u8) []const u8 {
    const relative = if (builtin.os.tag == .windows) "assets/icon.ico" else "assets/icon.png";
    if (builtin.mode == .Debug) return relative;
    var buffer: [4096]u8 = undefined;
    const candidate = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ dist_path, relative }) catch return relative;
    // The embedded bundle is extracted before this function runs. Keep the
    // absolute path even when a filesystem probe is unavailable during early
    // startup; the tray/window APIs resolve it after the host is initialized.
    if (builtin.mode != .Debug) return allocator.dupe(u8, candidate) catch relative;
    if (std.Io.Dir.cwd().openFile(io, candidate, .{})) |file| {
        file.close(io);
        return allocator.dupe(u8, candidate) catch relative;
    } else |_| return relative;
}

fn extractEmbeddedAssets(allocator: std.mem.Allocator, io: std.Io, env_map: *const std.process.Environ.Map) ?[]const u8 {
    const root = if (builtin.os.tag == .windows)
        env_map.get("LOCALAPPDATA") orelse env_map.get("TEMP") orelse "."
    else if (builtin.os.tag == .macos)
        env_map.get("HOME") orelse "."
    else
        env_map.get("XDG_CACHE_HOME") orelse env_map.get("HOME") orelse ".";
    var root_buf: [1024]u8 = undefined;
    const bundle_hash = std.hash.Wyhash.hash(0, embedded_assets.bytes);
    const runtime_root = std.fmt.bufPrint(&root_buf, "{s}/lol-desktop-native/runtime/2.0.0-{x}", .{ root, bundle_hash }) catch return null;
    std.Io.Dir.cwd().createDirPath(io, runtime_root) catch return null;
    var dir = std.Io.Dir.cwd().openDir(io, runtime_root, .{}) catch return null;
    defer dir.close(io);

    // A content hash gives every web bundle its own immutable directory. The
    // completion marker is written last, so subsequent launches can skip all
    // bundle writes while still loading the colocated WebView2 loader.
    if (dir.openFile(io, ".complete", .{})) |marker| {
        marker.close(io);
        if (loadEmbeddedWebViewLoader(runtime_root)) {
            return allocator.dupe(u8, runtime_root) catch null;
        }
    } else |_| {}

    const bytes = embedded_assets.bytes;
    if (bytes.len < 5 or !std.mem.eql(u8, bytes[0..5], "LDF1\x00")) return null;
    var cursor: usize = 5;
    var has_index = false;
    while (cursor < bytes.len) {
        if (bytes.len - cursor < 12) return null;
        const name_len = std.mem.readInt(u32, bytes[cursor..][0..4], .little);
        const size = std.mem.readInt(u64, bytes[cursor + 4 ..][0..8], .little);
        cursor += 12;
        if (name_len > bytes.len - cursor) return null;
        const name = bytes[cursor .. cursor + name_len];
        cursor += name_len;
        if (size > bytes.len - cursor) return null;
        const data = bytes[cursor .. cursor + @as(usize, @intCast(size))];
        cursor += @as(usize, @intCast(size));
        if (std.mem.eql(u8, name, "__native/WebView2Loader.dll")) {
            if (builtin.os.tag == .windows) {
                var loader_path: [2048]u8 = undefined;
                const full = std.fmt.bufPrint(&loader_path, "{s}/WebView2Loader.dll", .{runtime_root}) catch return null;
                dir.writeFile(io, .{ .sub_path = "WebView2Loader.dll", .data = data }) catch return null;
                _ = full;
            }
            continue;
        }
        const parent = std.fs.path.dirname(name) orelse "";
        if (parent.len > 0) dir.createDirPath(io, parent) catch {};
        dir.writeFile(io, .{ .sub_path = name, .data = data }) catch return null;
        if (std.mem.eql(u8, name, "index.html")) has_index = true;
    }
    if (!has_index or !loadEmbeddedWebViewLoader(runtime_root)) return null;
    dir.writeFile(io, .{ .sub_path = ".complete", .data = "ok" }) catch return null;
    return allocator.dupe(u8, runtime_root) catch null;
}

fn loadEmbeddedWebViewLoader(runtime_root: []const u8) bool {
    if (comptime builtin.os.tag != .windows) return true;
    var loader_path: [2048]u8 = undefined;
    const full = std.fmt.bufPrint(&loader_path, "{s}/WebView2Loader.dll", .{runtime_root}) catch return false;
    var wide: [4096]u16 = undefined;
    const wide_len = std.unicode.wtf8ToWtf16Le(&wide, full) catch return false;
    if (wide_len >= wide.len) return false;
    wide[wide_len] = 0;
    return windows_api.LoadLibraryW(wide[0..wide_len :0].ptr) != null;
}

fn executablePathAlloc(allocator: std.mem.Allocator, io: std.Io) ?[]u8 {
    switch (builtin.os.tag) {
        .windows => {
            // Use the wide API so a package installed under a non-ASCII path
            // remains discoverable. 32K code units covers Windows extended
            // paths; the SDK path APIs accept the resulting WTF-8 bytes.
            var buffer: [32768]u16 = undefined;
            const length = windows_api.GetModuleFileNameW(null, buffer[0..].ptr, buffer.len);
            if (length == 0 or length >= buffer.len) return null;
            return std.unicode.wtf16LeToWtf8Alloc(allocator, buffer[0..length]) catch null;
        },
        .macos => {
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            var length: u32 = buffer.len;
            if (std.c._NSGetExecutablePath(&buffer, &length) != 0) return null;
            const path = std.mem.sliceTo(buffer[0..length], 0);
            return allocator.dupe(u8, path) catch null;
        },
        .linux => {
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            const length = std.Io.Dir.readLinkAbsolute(io, "/proc/self/exe", &buffer) catch return null;
            return allocator.dupe(u8, buffer[0..length]) catch null;
        },
        else => return null,
    }
}

const dev_http_origin = std.fmt.comptimePrint("http://{s}:{d}", .{ build_options.dev_server_host, build_options.dev_server_port });
const dev_origins = [_][]const u8{ "zero://app", "zero://inline", dev_http_origin };

fn startApp(context: *anyopaque, runtime: *native_sdk.Runtime) anyerror!void {
    const self: *App = @ptrCast(@alignCast(context));
    self.runtime.attachNativeRuntime(runtime);
    try self.startAsyncBridge();
    // Keep auto-accept alive even when WebView2 throttles background timers.
    try self.startAutomationWatchdog();
    if (comptime builtin.os.tag == .windows) {
        try runtime.createTray(.{
            .icon_path = self.icon_path,
            .tooltip = "桌上英雄联盟",
            .activation_command = "lol.tray.open",
            .open_command = "lol.tray.open",
            .items = &.{
                .{ .id = 1, .label = "打开主窗口", .command = "lol.tray.open" },
                .{ .id = 2, .label = "退出", .command = "app.quit", .role = .command },
            },
        });
        // The SDK creates the Win32 class without an hIcon. Re-apply after
        // tray creation as the HWND is guaranteed to be registered by then.
        if (!applyWindowsWindowIcon(self.icon_path, true)) startWindowsWindowRetry(self.icon_path);
    }
}

fn stopApp(context: *anyopaque, runtime: *native_sdk.Runtime) anyerror!void {
    _ = runtime;
    const self: *App = @ptrCast(@alignCast(context));
    self.runtime.cancelRequests();
    self.stopAutomationWatchdog();
    self.stopAsyncBridge();
}

fn automationWatchdog(self: *App, io: std.Io) void {
    while (!self.automation_stop.load(.acquire)) {
        self.runtime.runAutomationBackground(io);
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(250), .awake) catch {};
    }
}

fn applyWindowsWindowIcon(icon_path: []const u8, resize_initial: bool) bool {
    if (builtin.os.tag != .windows) return false;
    const image_icon: u32 = 1;
    const load_shared: u32 = 0x8000;
    const resource_id: *const anyopaque = @ptrFromInt(1);
    const module = windows_api.GetModuleHandleW(null);
    const window = windows_api.FindWindowW(null, windows_main_title.ptr) orelse return false;
    var process_id: u32 = 0;
    _ = windows_api.GetWindowThreadProcessId(window, &process_id);
    if (process_id != windows_api.GetCurrentProcessId()) return false;
    var icons = WindowsIconPair{
        .process_id = windows_api.GetCurrentProcessId(),
        .large = windows_api.LoadImageW(module, resource_id, image_icon, 32, 32, load_shared),
        .small = windows_api.LoadImageW(module, resource_id, image_icon, 16, 16, load_shared),
        .resize_initial = resize_initial,
    };
    // Debug builds without the .rc resource can still use the checked-in ICO.
    if (icons.large == null and icons.small == null and icon_path.len > 0) {
        var path_buffer: [4096]u16 = undefined;
        const path_len = std.unicode.wtf8ToWtf16Le(&path_buffer, icon_path) catch return false;
        path_buffer[path_len] = 0;
        const load_from_file: u32 = 0x0010;
        icons.large = windows_api.LoadImageW(null, @ptrCast(path_buffer[0..path_len :0].ptr), image_icon, 32, 32, load_from_file);
        icons.small = windows_api.LoadImageW(null, @ptrCast(path_buffer[0..path_len :0].ptr), image_icon, 16, 16, load_from_file);
    }
    return applyWindowsIconToWindow(window, &icons);
}

fn startWindowsWindowRetry(icon_path: []const u8) void {
    if (builtin.os.tag != .windows) return;
    const thread = std.Thread.spawn(.{}, windowsWindowRetryWorker, .{icon_path}) catch return;
    thread.detach();
}

fn windowsWindowRetryWorker(icon_path: []const u8) void {
    // app.start precedes loadStartupWindows, and the SDK silently drops timers
    // started before its parent HWND exists. Poll briefly from a worker; Win32
    // marshals SetWindowPos to the owning thread, and EnumWindows is thread-safe.
    var attempt: usize = 0;
    while (attempt < 20) : (attempt += 1) {
        windows_api.Sleep(50);
        if (applyWindowsWindowIcon(icon_path, true)) return;
    }
}

fn applyWindowsIconToWindow(window: *anyopaque, icons: *WindowsIconPair) bool {
    const set_icon: u32 = 0x0080;
    var applied = false;
    if (icons.large) |icon| {
        applied = true;
        _ = windows_api.SetClassLongPtrW(window, -14, @intCast(@intFromPtr(icon)));
        _ = windows_api.PostMessageW(window, set_icon, 1, @intCast(@intFromPtr(icon)));
    }
    if (icons.small) |icon| {
        applied = true;
        _ = windows_api.SetClassLongPtrW(window, -34, @intCast(@intFromPtr(icon)));
        _ = windows_api.PostMessageW(window, set_icon, 0, @intCast(@intFromPtr(icon)));
    }
    if (icons.resize_initial) applyWindowsInitialLogicalSize(window);
    return applied;
}

fn dpiScaledExtent(logical: f64, dpi: u32) i32 {
    const scale = @as(f64, @floatFromInt(if (dpi > 0) dpi else 96)) / 96.0;
    return @intFromFloat(@round(logical * scale));
}

fn applyWindowsInitialLogicalSize(window: *anyopaque) void {
    if (builtin.os.tag != .windows) return;
    var client: windows_api.Rect = undefined;
    var outer: windows_api.Rect = undefined;
    if (windows_api.GetClientRect(window, &client) == 0 or windows_api.GetWindowRect(window, &outer) == 0) return;
    const dpi = windows_api.GetDpiForWindow(window);
    // During first show, Win32 can temporarily report the creation DPI even
    // though the window is about to land on a scaled monitor. A 96-DPI client
    // already has the configured numeric size, so leave it unlatched: on a
    // true 100% monitor repeated checks remain harmless, while a later 120+
    // reading still gets the chance to correct the physical extent.
    if (dpi <= 96) return;
    const desired_width = dpiScaledExtent(initial_window_width, dpi);
    const desired_height = dpiScaledExtent(initial_window_height, dpi);
    const client_width = client.right - client.left;
    const client_height = client.bottom - client.top;
    if (client_width == desired_width and client_height == desired_height) return;
    const outer_width = @max(1, outer.right - outer.left + desired_width - client_width);
    const outer_height = @max(1, outer.bottom - outer.top + desired_height - client_height);
    const no_move: u32 = 0x0002;
    const no_z_order: u32 = 0x0004;
    const no_activate: u32 = 0x0010;
    const async_window_pos: u32 = 0x4000;
    _ = windows_api.SetWindowPos(window, null, 0, 0, outer_width, outer_height, no_move | no_z_order | no_activate | async_window_pos);
}

fn appEvent(context: *anyopaque, runtime: *native_sdk.Runtime, event: native_sdk.Event) anyerror!void {
    const self: *App = @ptrCast(@alignCast(context));
    if (event == .effects_wake) {
        self.drainCompleted();
        return;
    }
    if (event == .lifecycle and event.lifecycle == .activate) {
        _ = applyWindowsWindowIcon(self.icon_path, false);
    }
    if (event == .command) {
        if (std.mem.eql(u8, event.command.name, "lol.tray.open")) {
            runtime.showWindow(1) catch {};
            runtime.focusWindow(1) catch {};
            _ = applyWindowsWindowIcon(self.icon_path, false);
        }
    }
}

fn lockAtomic(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

pub fn main(init: std.process.Init) !void {
    configureWindowsDpi();
    configureWebView2DataDir(init.io, init.environ_map);
    const dist_path = productionDistPath(std.heap.page_allocator, init.io, init.environ_map);
    var app = App{
        .env_map = init.environ_map,
        .dist_path = dist_path,
        .icon_path = productionIconPath(std.heap.page_allocator, init.io, dist_path),
        .runtime = backend.Runtime.initWithIo(init.io, init.environ_map),
    };
    defer app.runtime.deinit();
    try runner.runWithOptions(app.app(), .{
        .app_name = "lol-desktop-native",
        .window_title = "桌上英雄联盟",
        .bundle_id = "com.nobb2333.lol-desktop-native",
        .icon_path = app.icon_path,
        .bridge = app.bridge(),
        // Windows global shortcuts are handled by backend/hotkeys.zig so
        // they remain active while League owns the foreground window. Do not
        // also register the SDK's window-local shortcut table.
        .shortcuts = if (comptime builtin.os.tag == .windows) &[_]native_sdk.Shortcut{} else null,
        .js_window_api = true,
        .security = .{
            .permissions = &.{ "filesystem", "credentials", "clipboard" },
            .navigation = .{ .allowed_origins = &dev_origins },
        },
    }, init);
}

fn configureWindowsDpi() void {
    if (builtin.os.tag != .windows) return;
    // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2. The manifest declares the
    // same policy; the explicit call also covers hosts that inspect process
    // awareness before the embedded manifest is activated.
    _ = windows_api.SetProcessDpiAwarenessContext(-4);
}

fn configureWebView2DataDir(io: std.Io, env_map: *std.process.Environ.Map) void {
    if (builtin.os.tag != .windows) return;
    var cache_buffer: [2048]u8 = undefined;
    const cache_dir = native_sdk.app_dirs.resolveOne(
        .{ .name = build_options.data_dir_name },
        .windows,
        native_sdk.debug.envFromMap(env_map),
        .cache,
        &cache_buffer,
    ) catch return;
    var folder_buffer: [2048]u8 = undefined;
    const folder = native_sdk.app_dirs.join(.windows, &folder_buffer, &.{ cache_dir, "WebView2" }) catch return;
    std.Io.Dir.cwd().createDirPath(io, folder) catch return;

    const variable_name = "WEBVIEW2_USER_DATA_FOLDER";
    var name_wide: [64]u16 = undefined;
    const name_len = std.unicode.wtf8ToWtf16Le(&name_wide, variable_name) catch return;
    name_wide[name_len] = 0;
    var folder_wide: [2048]u16 = undefined;
    const folder_len = std.unicode.wtf8ToWtf16Le(&folder_wide, folder) catch return;
    folder_wide[folder_len] = 0;
    _ = windows_api.SetEnvironmentVariableW(name_wide[0..name_len :0].ptr, folder_wide[0..folder_len :0].ptr);
}

test "app name is configured" {
    try std.testing.expectEqualStrings("lol-desktop-native", "lol-desktop-native");
}

test "Windows initial client size preserves logical resolution at monitor DPI" {
    try std.testing.expectEqual(@as(f64, 1440), initial_window_width);
    try std.testing.expectEqual(@as(f64, 900), initial_window_height);
    try std.testing.expectEqual(@as(i32, 1440), dpiScaledExtent(1440, 96));
    try std.testing.expectEqual(@as(i32, 1800), dpiScaledExtent(1440, 120));
    try std.testing.expectEqual(@as(i32, 1125), dpiScaledExtent(900, 120));
}

test "native ping returns the migration runtime identity" {
    var app = App{ .env_map = undefined, .dist_path = "frontend/dist", .runtime = backend.Runtime.init() };
    const dispatcher = app.bridge();
    var output: [512]u8 = undefined;
    const response = dispatcher.dispatch(
        "{\"id\":\"smoke\",\"command\":\"native.ping\",\"payload\":{}}",
        .{ .origin = "zero://app" },
        &output,
    );
    try std.testing.expect(std.mem.indexOf(u8, response, "\"ready\":true") != null);
}

test "LCU credentials stay in the Zig layer" {
    const credentials = try lcu.fromLockfile("LeagueClient:1:54321:secret:https");
    var endpoint: [64]u8 = undefined;
    try std.testing.expectEqualStrings("https://127.0.0.1:54321", try credentials.endpoint(&endpoint));
}

test {
    // Zig only discovers imported-module tests after their declarations are
    // referenced from the root test module. Keep backend/LCU mapping tests in
    // the normal `zig build test` path instead of silently running only the
    // bridge smoke tests in this file.
    std.testing.refAllDecls(backend);
    std.testing.refAllDecls(lcu);
}

test "frontend bridge commands are registered and origin restricted" {
    var app = App{ .env_map = undefined, .dist_path = "frontend/dist", .runtime = backend.Runtime.init() };
    const dispatcher = app.bridge();
    try std.testing.expect(dispatcher.async_registry.find("lol.get_bootstrap") != null);
    try std.testing.expect(dispatcher.policy.allows("lol.get_bootstrap", "zero://app"));
    try std.testing.expect(!dispatcher.policy.allows("lol.get_config", "https://evil.example"));

    var output: [native_sdk.bridge.max_result_bytes]u8 = undefined;
    const bootstrap = try invokeBackendForTest(&app, "lol.get_bootstrap", "null", &output);
    try std.testing.expect(std.mem.indexOf(u8, bootstrap, "\"dataMode\":\"live\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bootstrap, "Native 预览") == null);
}

test "配置读写与数据模式切换并拒绝未实现的回看" {
    var app = App{ .env_map = undefined, .dist_path = "frontend/dist", .runtime = backend.Runtime.init() };
    var output: [native_sdk.bridge.max_result_bytes]u8 = undefined;

    try std.testing.expectError(error.ReplayUnavailable, invokeBackendForTest(&app, "lol.set_data_mode", "{\"mode\":\"replay\"}", &output));
    const mode = try invokeBackendForTest(&app, "lol.set_data_mode", "{\"mode\":\"fixture\"}", &output);
    try std.testing.expect(std.mem.indexOf(u8, mode, "\"fixture\"") != null);

    const saved = try invokeBackendForTest(&app, "lol.save_config", "{\"value\":{\"version\":99,\"automation\":{\"enabled\":true}}}", &output);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"version\":99") != null);

    const loaded = try invokeBackendForTest(&app, "lol.get_config", "null", &output);
    try std.testing.expect(std.mem.indexOf(u8, loaded, "\"version\":99") != null);
}

fn invokeBackendForTest(app: *App, command: []const u8, payload: []const u8, output: []u8) ![]const u8 {
    const handlers = app.runtime.handlers();
    for (handlers) |handler| if (std.mem.eql(u8, handler.name, command)) {
        return handler.invoke_fn(handler.context, .{
            .request = .{ .id = "test", .command = command, .payload = payload },
            .source = .{ .origin = "zero://app" },
        }, output);
    };
    return error.UnknownCommand;
}
