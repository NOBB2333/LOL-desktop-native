//! 客户端启动：探测本机装了哪些「英雄联盟 / WeGame / 官方客户端」入口，并按需拉起。
//!
//! 为什么需要它：应用本来只会在客户端**已经跑起来**时接管（`lcu.zig` 靠 lockfile
//! 找凭据），可是「先开助手、客户端还没开」时压根没有 lockfile 可探，用户只能自己
//! 去桌面或 WeGame 里翻。本模块补上另一半：把**安装位置**找出来并直接启动。
//!
//! 探测口径对齐 LeagueAkari 的 `client-installation`，但**刻意不读注册表**：那条路
//! 要多链接一个 `advapi32`，收益只是「装在非默认目录时也能找到」。这里改用
//! 「官方安装清单 + 扫盘」，零新增依赖，代价是首次探测碰几个候选路径。
//!
//! 启动用 `CreateProcessW` 并**不持有子进程句柄**（拿到就关），进程会独立活下去，
//! 这正是「点一下就不用管了」要的语义。
const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const backend = @import("../backend.zig");

/// 最多认几个入口。现实里 TCLS / WeGameLauncher / WeGame / Riot / LeagueClient
/// 加起来也就 5 个，留点余量即可。
const max_entries = 8;
const path_capacity = 512;

/// 一个「可以启动的东西」。
///
/// `id` 是稳定标识（前端用它记住用户上次选的是哪个），`label` 是给人看的，
/// `detail` 说明这条是哪来的（安装清单 / 扫盘 / 环境变量），排查时有用。
const Entry = struct {
    id: []const u8,
    label: []const u8,
    detail: []const u8,
    path: [path_capacity]u8 = undefined,
    path_len: usize = 0,

    fn pathSlice(self: *const Entry) []const u8 {
        return self.path[0..self.path_len];
    }
};

const Installation = struct {
    entries: [max_entries]Entry = undefined,
    count: usize = 0,

    fn push(self: *Installation, id: []const u8, label: []const u8, detail: []const u8, path_value: []const u8) void {
        if (self.count >= self.entries.len) return;
        if (path_value.len == 0 or path_value.len > path_capacity) return;
        // 同一个入口在不同候选路径下可能被命中两次（比如两个盘符下都有），去重。
        for (self.entries[0..self.count]) |*existing| {
            if (std.mem.eql(u8, existing.id, id)) return;
        }
        self.entries[self.count] = .{
            .id = id,
            .label = label,
            .detail = detail,
            .path_len = path_value.len,
        };
        @memcpy(self.entries[self.count].path[0..path_value.len], path_value);
        self.count += 1;
    }

    fn find(self: *const Installation, id: []const u8) ?*const Entry {
        for (self.entries[0..self.count]) |*entry| {
            if (std.mem.eql(u8, entry.id, id)) return entry;
        }
        return null;
    }
};

/// `lol.get_client_installations` —— 本机能一键启动的入口清单。
pub fn getClientInstallations(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = backend.runtime(context);
    _ = invocation;
    var installation = Installation{};
    detect(self, &installation);
    return installationsDto(&installation, output);
}

/// `lol.launch_client` —— 启动一个入口。
///
/// 入参只有 `id`，路径一律**在本机现场重新探测**，不接受前端传路径——否则这个命令
/// 就成了「拉任意 exe」的口子。`id` 为空时按探测顺序取第一个（优先级见 `detect`）。
pub fn launchClient(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = backend.runtime(context);
    const parsed = backend.parsePayload(struct { id: []const u8 = "" }, invocation.request.payload) catch return error.InvalidRequest;
    defer parsed.deinit();
    if (builtin.os.tag != .windows) return launchResult(output, false, "只有 Windows 支持一键启动客户端", "", "");
    var installation = Installation{};
    detect(self, &installation);
    if (installation.count == 0) return launchResult(output, false, "没找到已安装的英雄联盟 / WeGame / Riot 客户端", "", "");
    const wanted = if (parsed.value.id.len > 0) parsed.value.id else installation.entries[0].id;
    const entry = installation.find(wanted) orelse
        return launchResult(output, false, "这个启动入口现在找不到了（可能被卸载或换了盘）", wanted, "");
    spawnDetached(entry) catch
        return launchResult(output, false, "启动失败：系统拒绝了创建进程", entry.id, entry.label);
    return launchResult(output, true, "", entry.id, entry.label);
}

fn launchResult(output: []u8, ok: bool, reason: []const u8, id: []const u8, label: []const u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    try writer.print("{{\"ok\":{s},\"reason\":", .{if (ok) "true" else "false"});
    try backend.jsonString(&writer, reason);
    try writer.writeAll(",\"id\":");
    try backend.jsonString(&writer, id);
    try writer.writeAll(",\"label\":");
    try backend.jsonString(&writer, label);
    try writer.writeByte('}');
    return writer.buffered();
}

/// 探测顺序就是「自动挑」的优先级：越早推入越优先。
///
/// WeGame 系（`tcls` / `wegame-launcher`）排在最前，因为国服玩家绝大多数走这条；
/// 官方 `Riot 客户端` 次之；`WeGame` 主程序垫底——它启动的是 WeGame 而非游戏本身，
/// 只在没装游戏本体时才该被自动选中。
fn detect(self: *backend.Runtime, installation: *Installation) void {
    if (builtin.os.tag != .windows) return;
    const io = self.io orelse return;
    const env = self.env_map;
    detectTencentInstallation(io, installation);
    detectOfficialRiot(io, env, installation);
    detectWeGameLauncher(io, env, installation);
}

/// 腾讯系游戏本体：`<盘>:\WeGameApps\英雄联盟`，目录名是 WeGame 的固定约定。
///
/// 两个可执行文件各有用途：`Launcher\Client.exe` 是 TCLS 登录器，
/// `WeGameLauncher\launcher.exe` 是直接从 WeGame 拉起游戏的那个。
fn detectTencentInstallation(io: std.Io, installation: *Installation) void {
    var drive: u8 = 'A';
    while (drive <= 'Z') : (drive += 1) {
        var base_buffer: [64]u8 = undefined;
        const base = std.fmt.bufPrint(&base_buffer, "{c}:\\WeGameApps\\英雄联盟", .{drive}) catch continue;
        if (!exists(io, base)) continue;
        pushJoin(io, installation, "tcls", "英雄联盟（腾讯登录器）", "WeGameApps 扫盘", base, "\\Launcher\\Client.exe");
        pushJoin(io, installation, "wegame-launcher", "英雄联盟（WeGame 启动）", "WeGameApps 扫盘", base, "\\WeGameLauncher\\launcher.exe");
        // 和 AK 一样，找到一处就够：多盘各装一份的情况极少，没必要扫完。
        if (installation.count > 0) break;
    }
}

/// 官方客户端的两样东西都写在 `%ProgramData%\RiotClientInstalls.json` 里。
///
/// `associated_client` 是「安装目录 → RiotClientServices.exe」的映射：
/// 目录下的 `LeagueClient.exe` 是游戏客户端本体，值里的 `RiotClientServices.exe`
/// 是官方启动器（启动时带 `--launch-product`）。两者都收，但按 AK 的判据把
/// **路径含「英雄联盟」的排除掉**——那是腾讯的版本，不是官方客户端。
fn detectOfficialRiot(io: std.Io, env: ?*const std.process.Environ.Map, installation: *Installation) void {
    const program_data = envValue(env, "PROGRAMDATA") orelse return;
    var manifest_buffer: [1024]u8 = undefined;
    const manifest = std.fmt.bufPrint(&manifest_buffer, "{s}\\Riot Games\\RiotClientInstalls.json", .{program_data}) catch return;
    const content = std.Io.Dir.cwd().readFileAlloc(io, manifest, std.heap.page_allocator, .limited(64 * 1024)) catch return;
    defer std.heap.page_allocator.free(content);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), content, .{}) catch return;
    if (root != .object) return;
    const associated = root.object.get("associated_client") orelse return;
    if (associated != .object) return;
    var iterator = associated.object.iterator();
    while (iterator.next()) |pair| {
        pushJoin(io, installation, "league-client", "英雄联盟（官方客户端）", "Riot 安装清单", pair.key_ptr.*, "\\LeagueClient.exe");
        const riot_client = if (pair.value_ptr.* == .string) pair.value_ptr.string else "";
        if (riot_client.len == 0) continue;
        if (std.mem.indexOf(u8, riot_client, "Riot Games") == null) continue;
        if (std.mem.indexOf(u8, riot_client, "英雄联盟") != null) continue;
        if (exists(io, riot_client)) installation.push("riot-client", "Riot 客户端", "Riot 安装清单", riot_client);
    }
}

/// WeGame 主程序。它不是游戏本体，只是「没有更好选择时」的兜底入口。
///
/// 候选顺序：先看环境变量给出的两个 Program Files，再按盘符试 WeGame 的常见装法。
fn detectWeGameLauncher(io: std.Io, env: ?*const std.process.Environ.Map, installation: *Installation) void {
    const env_names = [_][]const u8{ "PROGRAMFILES(X86)", "PROGRAMFILES", "LOCALAPPDATA" };
    for (env_names) |name| {
        const base = envValue(env, name) orelse continue;
        var buffer: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&buffer, "{s}\\Tencent\\WeGame\\wegame.exe", .{base}) catch continue;
        if (exists(io, path)) return installation.push("wegame", "WeGame", "环境变量候选路径", path);
    }
    var drive: u8 = 'A';
    while (drive <= 'Z') : (drive += 1) {
        const suffixes = [_][]const u8{
            "{c}:\\WeGame\\wegame.exe",
            "{c}:\\Program Files (x86)\\Tencent\\WeGame\\wegame.exe",
            "{c}:\\Program Files\\Tencent\\WeGame\\wegame.exe",
            "{c}:\\Tencent\\WeGame\\wegame.exe",
        };
        // `inline for`：`bufPrint` 的格式串必须是 comptime 已知的，用普通 `for`
        // 会把 `suffix` 变成运行时值而编译不过。
        inline for (suffixes) |suffix| {
            var buffer: [1024]u8 = undefined;
            // 不用 `catch continue`：`inline for` 里不允许运行时控制流跳出。
            if (std.fmt.bufPrint(&buffer, suffix, .{drive})) |path| {
                if (exists(io, path)) return installation.push("wegame", "WeGame", "扫盘", path);
            } else |_| {}
        }
    }
}

fn pushJoin(io: std.Io, installation: *Installation, id: []const u8, label: []const u8, detail: []const u8, base: []const u8, suffix: []const u8) void {
    var buffer: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&buffer, "{s}{s}", .{ base, suffix }) catch return;
    if (exists(io, path)) installation.push(id, label, detail, path);
}

fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn envValue(env: ?*const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const map = env orelse return null;
    const value = map.get(name) orelse return null;
    return if (value.len == 0) null else value;
}

/// 起一个和本进程无关的进程。
///
/// 用 `CreateProcessW` 而不是 `std.process.Child`：后者要求 caller 最终 `wait()`，
/// 而我们要的正好相反——拉起来就撒手。这里把返回的两个句柄就地关掉，进程照常运行。
fn spawnDetached(entry: *const Entry) !void {
    const api = win;
    if (!api.available) return error.UnsupportedPlatform;
    var path_wide: [path_capacity * 2]u16 = undefined;
    const path_len = try std.unicode.utf8ToUtf16Le(&path_wide, entry.pathSlice());
    path_wide[path_len] = 0;

    // 命令行必须自带 argv[0]（Windows 的约定），带空格要加引号。
    var command_wide: [path_capacity * 3]u16 = undefined;
    var command_buffer: [path_capacity + 8]u8 = undefined;
    const command = std.fmt.bufPrint(&command_buffer, "\"{s}\"", .{entry.pathSlice()}) catch return error.PathTooLong;
    const command_len = try std.unicode.utf8ToUtf16Le(&command_wide, command);
    command_wide[command_len] = 0;

    // 工作目录给成 exe 自己所在目录：启动器经常按相对路径找同目录的配置/资源。
    var directory_buffer: [path_capacity]u8 = undefined;
    var directory_wide: [path_capacity]u16 = undefined;
    var directory_pointer: ?[*:0]const u16 = null;
    if (std.fs.path.dirname(entry.pathSlice())) |directory| {
        if (directory.len > 0 and directory.len < path_capacity) {
            @memcpy(directory_buffer[0..directory.len], directory);
            const directory_len = try std.unicode.utf8ToUtf16Le(&directory_wide, directory_buffer[0..directory.len]);
            directory_wide[directory_len] = 0;
            directory_pointer = directory_wide[0..directory_len :0].ptr;
        }
    }

    var startup = std.mem.zeroes(api.StartupInfoW);
    startup.cb = @sizeOf(api.StartupInfoW);
    var process_info = std.mem.zeroes(api.ProcessInformation);
    const created = api.CreateProcessW(
        path_wide[0..path_len :0].ptr,
        command_wide[0..command_len :0].ptr,
        null,
        null,
        0,
        0,
        null,
        directory_pointer,
        &startup,
        &process_info,
    );
    if (created == 0) return error.LaunchFailed;
    // 只管关句柄，不 Terminate：进程已经跑起来了，我们不需要再和它有任何关系。
    if (process_info.hThread) |handle| _ = api.CloseHandle(handle);
    if (process_info.hProcess) |handle| _ = api.CloseHandle(handle);
}

/// Win32 声明。非 Windows 平台上整体退化成 `available = false`，调用方据此报错。
const win = if (builtin.os.tag == .windows) struct {
    const available = true;

    const StartupInfoW = extern struct {
        cb: u32,
        lpReserved: ?[*:0]u16,
        lpDesktop: ?[*:0]u16,
        lpTitle: ?[*:0]u16,
        dwX: u32,
        dwY: u32,
        dwXSize: u32,
        dwYSize: u32,
        dwXCountChars: u32,
        dwYCountChars: u32,
        dwFillAttribute: u32,
        dwFlags: u32,
        wShowWindow: u16,
        cbReserved2: u16,
        lpReserved2: ?*u8,
        hStdInput: ?*anyopaque,
        hStdOutput: ?*anyopaque,
        hStdError: ?*anyopaque,
    };

    const ProcessInformation = extern struct {
        hProcess: ?*anyopaque,
        hThread: ?*anyopaque,
        dwProcessId: u32,
        dwThreadId: u32,
    };

    extern "kernel32" fn CreateProcessW(
        application_name: ?[*:0]const u16,
        command_line: ?[*:0]u16,
        process_attributes: ?*anyopaque,
        thread_attributes: ?*anyopaque,
        inherit_handles: i32,
        creation_flags: u32,
        environment: ?*anyopaque,
        current_directory: ?[*:0]const u16,
        startup_info: *StartupInfoW,
        process_information: *ProcessInformation,
    ) callconv(.winapi) i32;

    extern "kernel32" fn CloseHandle(handle: *anyopaque) callconv(.winapi) i32;
} else struct {
    const available = false;
};

// ---------------------------------------------------------------------------
// 测试：只覆盖「不碰文件系统」的纯逻辑，现场探测靠真机验证。
// ---------------------------------------------------------------------------

fn installationsDto(installation: *const Installation, output: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll("{\"entries\":[");
    for (installation.entries[0..installation.count], 0..) |*entry, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"id\":");
        try backend.jsonString(&writer, entry.id);
        try writer.writeAll(",\"label\":");
        try backend.jsonString(&writer, entry.label);
        try writer.writeAll(",\"detail\":");
        try backend.jsonString(&writer, entry.detail);
        try writer.writeAll(",\"path\":");
        try backend.jsonString(&writer, entry.pathSlice());
        try writer.writeByte('}');
    }
    try writer.writeAll("]}");
    return writer.buffered();
}

test "入口清单：同一个 id 只保留一条，超长路径被丢弃" {
    var installation = Installation{};
    installation.push("tcls", "英雄联盟（腾讯登录器）", "WeGameApps 扫盘", "D:\\WeGameApps\\英雄联盟\\Launcher\\Client.exe");
    // 第二个盘也有同样的入口 → 不能再占一格。
    installation.push("tcls", "英雄联盟（腾讯登录器）", "WeGameApps 扫盘", "E:\\WeGameApps\\英雄联盟\\Launcher\\Client.exe");
    installation.push("wegame", "WeGame", "扫盘", "C:\\WeGame\\wegame.exe");
    try std.testing.expectEqual(@as(usize, 2), installation.count);
    try std.testing.expectEqualStrings("D:\\WeGameApps\\英雄联盟\\Launcher\\Client.exe", installation.find("tcls").?.pathSlice());

    var oversized: [path_capacity + 1]u8 = undefined;
    @memset(&oversized, 'x');
    installation.push("wegame", "WeGame", "扫盘", &oversized);
    try std.testing.expectEqual(@as(usize, 2), installation.count);
}

test "入口清单 DTO 的字段与转义" {
    var installation = Installation{};
    installation.push("riot-client", "Riot 客户端", "Riot 安装清单", "C:\\Riot Games\\Riot Client\\RiotClientServices.exe");
    var output: [1024]u8 = undefined;
    const dto = try installationsDto(&installation, &output);
    try std.testing.expectEqualStrings(
        "{\"entries\":[{\"id\":\"riot-client\",\"label\":\"Riot 客户端\",\"detail\":\"Riot 安装清单\"," ++
            "\"path\":\"C:\\\\Riot Games\\\\Riot Client\\\\RiotClientServices.exe\"}]}",
        dto,
    );
    // 反斜杠必须转义，否则前端 JSON.parse 会炸。
    try std.testing.expect(std.mem.indexOf(u8, dto, "C:\\\\Riot Games") != null);
}

test "启动结果 DTO 带上 id 与可读标签" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"ok\":true,\"reason\":\"\",\"id\":\"tcls\",\"label\":\"英雄联盟（腾讯登录器）\"}",
        try launchResult(&buffer, true, "", "tcls", "英雄联盟（腾讯登录器）"),
    );
    var buffer2: [256]u8 = undefined;
    const failed = try launchResult(&buffer2, false, "没找到已安装的英雄联盟 / WeGame / Riot 客户端", "", "");
    try std.testing.expect(std.mem.indexOf(u8, failed, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, failed, "\"id\":\"\"") != null);
}
