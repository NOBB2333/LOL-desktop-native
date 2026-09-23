//! 客户端启动：探测本机装了哪些「英雄联盟 / WeGame / 官方客户端」入口，并按需拉起。
//!
//! 为什么需要它：应用本来只会在客户端**已经跑起来**时接管（`lcu.zig` 靠 lockfile
//! 找凭据），可是「先开助手、客户端还没开」时压根没有 lockfile 可探，用户只能自己
//! 去桌面或 WeGame 里翻。本模块补上另一半：把**安装位置**找出来并直接启动。
//!
//! 探测口径对齐 LeagueAkari 的 `client-installation`。**注册表是主路径**——早先这里
//! 刻意不读注册表（嫌多链接一个 `advapi32`），代价是腾讯服装在非默认目录时必然漏检：
//! 实测一台机器 `WeGameApps` 并不在盘符根目录（`D:\1_Application\10_Game\WeGame\WeGameApps\英雄联盟`），
//! 扫盘候选全军覆没，`wegame.exe` 也藏在 `<根>\WeGame\wegame.exe`。这两条都只有注册表
//! 知道，所以现在按「注册表 → 安装清单 → 扫盘（仅固定盘）」的顺序认。
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

/// 注册表里的两个键（口径对齐 LeagueAkari `client-installation/context.ts`）。
///
/// - `HKCU\Software\Tencent\LOL` 的 `InstallPath` = **游戏本体安装目录**。
/// - `HKCU\wegame\DefaultIcon` 的**默认值** = `wegame.exe` 的路径。
///
/// 都在 HKCU，读它不需要任何额外权限；国服客户端安装时必写，且不受安装盘符影响。
const tencent_reg_key = "Software\\Tencent\\LOL";
const tencent_reg_value = "InstallPath";
const wegame_reg_key = "wegame\\DefaultIcon";

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
///
/// 三条信息来源按可靠性排序，逐级兜底：
/// 1. **注册表**：`HKCU\Software\Tencent\LOL` 直接给出游戏目录，`HKCU\wegame\DefaultIcon`
///    给出 `wegame.exe`。国服客户端安装时必写，且不受安装位置影响。
/// 2. **`RiotClientInstalls.json`**：官方与腾讯都会写，但腾讯写的 key 带 `../` 且会被
///    误当成官方客户端（见 `detectFromRiotManifest`）。
/// 3. **扫盘**：只在 1、2 都没认出腾讯服时才跑，且只碰固定盘。
fn detect(self: *backend.Runtime, installation: *Installation) void {
    if (builtin.os.tag != .windows) return;
    const io = self.io orelse return;
    const env = self.env_map;
    var root_storage: [path_capacity]u8 = undefined;
    const tencent_root = detectTencentByRegistry(io, &root_storage, installation);
    detectWeGame(io, env, tencent_root, installation);
    detectFromRiotManifest(io, env, installation);
    if (installation.find("tcls") == null and installation.find("wegame-launcher") == null) {
        detectTencentByDriveScan(io, installation);
    }
}

/// 读注册表拿腾讯服游戏目录，并把它的两个启动器推进清单。返回目录切片（没读到就是 null）。
///
/// 两个可执行文件各有用途：`Launcher\Client.exe` 是 TCLS 登录器，
/// `WeGameLauncher\launcher.exe` 是直接从 WeGame 拉起游戏的那个。
fn detectTencentByRegistry(io: std.Io, storage: *[path_capacity]u8, installation: *Installation) ?[]const u8 {
    const raw = readRegistryString(tencent_reg_key, tencent_reg_value, storage) orelse return null;
    var normalized_buffer: [path_capacity]u8 = undefined;
    const root = normalizePath(raw, &normalized_buffer);
    // 注册表里的值可能是卸载后留下的陈旧记录，落盘校验一下再认。
    if (!exists(io, root)) return null;
    pushJoin(io, installation, "tcls", "英雄联盟（腾讯登录器）", "注册表", root, "\\Launcher\\Client.exe");
    pushJoin(io, installation, "wegame-launcher", "英雄联盟（WeGame 启动）", "注册表", root, "\\WeGameLauncher\\launcher.exe");
    return root;
}

/// WeGame 主程序。它不是游戏本体，只是「没有更好选择时」的兜底入口。
///
/// 三条来源，前两条都比扫盘准：
/// 1. 注册表 `HKCU\wegame\DefaultIcon` 的默认值**就是** `wegame.exe` 的路径。
/// 2. 从游戏目录反推：腾讯的布局固定是 `<WeGame 根>\WeGameApps\<游戏>`，所以砍掉
///    `\WeGameApps\...` 就得到 WeGame 根，`wegame.exe` 在其下的 `WeGame\` 里。
/// 3. 环境变量 + 扫盘（装法千奇百怪时的最后手段）。
fn detectWeGame(io: std.Io, env: ?*const std.process.Environ.Map, tencent_root: ?[]const u8, installation: *Installation) void {
    var storage: [1024]u8 = undefined;
    if (readRegistryString(wegame_reg_key, "", &storage)) |raw| {
        const candidate = stripIconSuffix(raw);
        if (candidate.len > 0 and exists(io, candidate)) return installation.push("wegame", "WeGame", "注册表", candidate);
    }
    if (tencent_root) |root| {
        if (weGameRootFromTencentRoot(root, &storage)) |wegame_root| {
            var buffer: [1024]u8 = undefined;
            const patterns = [_][]const u8{ "{s}\\WeGame\\wegame.exe", "{s}\\wegame.exe" };
            // `inline for`：`bufPrint` 的格式串必须是 comptime 已知的。
            inline for (patterns) |pattern| {
                if (std.fmt.bufPrint(&buffer, pattern, .{wegame_root})) |path| {
                    if (exists(io, path)) return installation.push("wegame", "WeGame", "游戏目录反推", path);
                } else |_| {}
            }
        }
    }
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
        inline for (suffixes) |suffix| {
            var buffer: [1024]u8 = undefined;
            // 不用 `catch continue`：`inline for` 里不允许运行时控制流跳出。
            if (std.fmt.bufPrint(&buffer, suffix, .{drive})) |path| {
                if (exists(io, path)) return installation.push("wegame", "WeGame", "扫盘", path);
            } else |_| {}
        }
    }
}

/// 官方与腾讯的安装位置都记在 `%ProgramData%\Riot Games\RiotClientInstalls.json`。
///
/// ⚠️ 这个文件是**两条线混在一起**的，必须分开认：
/// - 官方客户端：key 就是安装目录，目录下有 `LeagueClient.exe`，路径里**不带**「英雄联盟」。
/// - 腾讯客户端：key 形如 `<游戏目录>/riot client/../LeagueClient/`，路径里**带**「英雄联盟」，
///   归一化后落在 `<游戏目录>\LeagueClient`，真正的游戏目录是它的**上一级**。
///
/// 老代码把两者一律按「官方客户端」推入、且不做存在性校验，于是在腾讯服机器上只会得到
/// 一条**名字错、路径还带 `../`** 的条目——这正是「只检测到官方客户端、WeGame 没搜到」的成因。
/// 现在先按腾讯的标记文件（`Launcher\Client.exe`）认，认不出再按官方认。
fn detectFromRiotManifest(io: std.Io, env: ?*const std.process.Environ.Map, installation: *Installation) void {
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
        var resolved_buffer: [path_capacity * 2]u8 = undefined;
        const resolved = normalizePath(pair.key_ptr.*, &resolved_buffer);
        var parent_buffer: [path_capacity]u8 = undefined;
        const parent = parentDirectory(resolved, &parent_buffer);
        const self_tencent = hasTencentLaunchers(io, resolved);
        const parent_tencent = if (parent) |p| hasTencentLaunchers(io, p) else false;
        switch (classifyManifestEntry(resolved, self_tencent, parent_tencent)) {
            .ignore => continue,
            .tencent => {
                // parent 命中说明 key 指向的是 `<游戏目录>\LeagueClient`，真正要的是上一级。
                const game_root = if (parent_tencent) parent.? else resolved;
                pushJoin(io, installation, "tcls", "英雄联盟（腾讯登录器）", "Riot 安装清单", game_root, "\\Launcher\\Client.exe");
                pushJoin(io, installation, "wegame-launcher", "英雄联盟（WeGame 启动）", "Riot 安装清单", game_root, "\\WeGameLauncher\\launcher.exe");
                continue;
            },
            .official => {},
        }
        pushJoin(io, installation, "league-client", "英雄联盟（官方客户端）", "Riot 安装清单", resolved, "\\LeagueClient.exe");
        const riot_client = if (pair.value_ptr.* == .string) pair.value_ptr.string else "";
        if (riot_client.len == 0) continue;
        if (std.mem.indexOf(u8, riot_client, "Riot Games") == null) continue;
        if (!exists(io, riot_client)) continue;
        installation.push("riot-client", "Riot 客户端", "Riot 安装清单", riot_client);
    }
}

/// 清单里一条记录的分类。**纯逻辑**——两个「标记文件在不在」的探测结果当入参，
/// 单测就能直接喂真机上那四条样本，不必有那台机器。
const ManifestEntry = enum {
    /// 腾讯服的游戏目录（自己或上一级带 `Launcher\Client.exe`）。
    tencent,
    /// 官方客户端安装目录（`LeagueClient.exe` 就在目录里，且路径不带「英雄联盟」）。
    official,
    /// 卸载/搬迁后残留的死路径，或者两条线都认不出来的写法。
    ignore,
};

fn classifyManifestEntry(resolved: []const u8, self_has_launchers: bool, parent_has_launchers: bool) ManifestEntry {
    if (resolved.len == 0) return .ignore;
    if (self_has_launchers or parent_has_launchers) return .tencent;
    // 带「英雄联盟」的路径一定不是官方客户端——腾讯那边整棵目录树都叫这个名字。
    if (std.mem.indexOf(u8, resolved, "英雄联盟") != null) return .ignore;
    return .official;
}

/// 腾讯服游戏目录的标记：只要有 `Launcher\Client.exe` 或 `WeGameLauncher\launcher.exe` 就算。
///
/// 清单里会残留已经卸载/搬迁的旧路径（实测一台机器 4 条里有 3 条是残影），
/// 不落盘校验就会把不存在的条目摆到界面上。
fn hasTencentLaunchers(io: std.Io, base: []const u8) bool {
    if (base.len == 0) return false;
    if (existsAt(io, base, "\\Launcher\\Client.exe")) return true;
    return existsAt(io, base, "\\WeGameLauncher\\launcher.exe");
}

/// 扫盘兜底：`<盘>:\WeGameApps\英雄联盟`，目录名是 WeGame 的固定约定。
///
/// 只在注册表与清单都没认出腾讯服时跑。**盘符先过一遍 `GetDriveTypeW`**——老代码
/// A→Z 无脑 `access()`，机器上映射了网络盘时每个盘符都要等超时，这才是「高频扫描」
/// 的体感来源。找到一处就够（多盘各装一份的情况极少）。
fn detectTencentByDriveScan(io: std.Io, installation: *Installation) void {
    const api = win;
    if (!api.available) return;
    // 位图里的 1 表示该盘符存在；调用失败返回 0，那就只靠 `GetDriveTypeW` 兜。
    const mask = api.GetLogicalDrives();
    var letter: u8 = 0;
    while (letter < 26) : (letter += 1) {
        if (letter < 2) continue; // A:/B: 是软驱位，永远不是安装盘。
        if (mask != 0 and (mask & (@as(u32, 1) << @intCast(letter))) == 0) continue;
        var root_wide: [4]u16 = .{ 'A' + letter, ':', '\\', 0 };
        // 带哨兵切片：`GetDriveTypeW` 要的是 `[*:0]const u16`，直接 `&root_wide` 是
        // `*[4]u16`，编译器不认。
        if (api.GetDriveTypeW(root_wide[0..3 :0].ptr) != api.drive_fixed) continue;
        var base_buffer: [64]u8 = undefined;
        const base = std.fmt.bufPrint(&base_buffer, "{c}:\\WeGameApps\\英雄联盟", .{'A' + letter}) catch continue;
        if (!exists(io, base)) continue;
        pushJoin(io, installation, "tcls", "英雄联盟（腾讯登录器）", "WeGameApps 扫盘", base, "\\Launcher\\Client.exe");
        pushJoin(io, installation, "wegame-launcher", "英雄联盟（WeGame 启动）", "WeGameApps 扫盘", base, "\\WeGameLauncher\\launcher.exe");
        return;
    }
}

fn pushJoin(io: std.Io, installation: *Installation, id: []const u8, label: []const u8, detail: []const u8, base: []const u8, suffix: []const u8) void {
    var buffer: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&buffer, "{s}{s}", .{ base, suffix }) catch return;
    if (exists(io, path)) installation.push(id, label, detail, path);
}

fn exists(io: std.Io, path: []const u8) bool {
    if (path.len == 0) return false;
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn existsAt(io: std.Io, base: []const u8, suffix: []const u8) bool {
    var buffer: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&buffer, "{s}{s}", .{ base, suffix }) catch return false;
    return exists(io, path);
}

fn envValue(env: ?*const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const map = env orelse return null;
    const value = map.get(name) orelse return null;
    return if (value.len == 0) null else value;
}

// ---------------------------------------------------------------------------
// 路径与注册表小工具（纯逻辑，单测覆盖）
// ---------------------------------------------------------------------------

/// 读 HKCU 下的一个字符串值（`REG_SZ` / `REG_EXPAND_SZ`，后者交给系统展开）。
///
/// 失败——键或值不存在、类型不是字符串、缓冲区不够——一律返回 null：探测路径上
/// 「没有」才是常态，不该让调用方写一堆错误分支。
fn readRegistryString(sub_key: []const u8, value_name: []const u8, out: []u8) ?[]const u8 {
    const api = win;
    if (!api.available) return null;
    var key_buffer: [256]u16 = undefined;
    var name_buffer: [64]u16 = undefined;
    const key_len = std.unicode.utf8ToUtf16Le(&key_buffer, sub_key) catch return null;
    key_buffer[key_len] = 0;
    const name_len = std.unicode.utf8ToUtf16Le(&name_buffer, value_name) catch return null;
    name_buffer[name_len] = 0;

    var wide: [2048]u16 = undefined;
    var size: u32 = @intCast(wide.len * 2);
    const status = api.RegGetValueW(
        api.hkey_current_user,
        key_buffer[0..key_len :0].ptr,
        name_buffer[0..name_len :0].ptr,
        api.rrf_rt_reg_sz | api.rrf_rt_reg_expand_sz,
        null,
        @ptrCast(&wide),
        &size,
    );
    if (status != 0) return null;
    var chars = size / 2;
    while (chars > 0 and wide[chars - 1] == 0) chars -= 1;
    if (chars == 0) return null;
    const length = std.unicode.utf16LeToUtf8(out, wide[0..chars]) catch return null;
    return out[0..length];
}

/// 把注册表 / 清单里给的路径归一化成能直接用的形式。
///
/// 分隔符统一成 `\`、去掉 `.` 与 `..` 段、折叠重复分隔符、去掉结尾分隔符、盘符转大写。
/// 腾讯的清单 key 里就明摆着带 `../`（`.../riot client/../LeagueClient/`），
/// 老代码直接字符串拼接，界面上于是出现 `.../riot client/../LeagueClient/\LeagueClient.exe`
/// 这种没法看的路径。
fn normalizePath(input: []const u8, out: []u8) []const u8 {
    var length: usize = 0;
    var index: usize = 0;
    while (index < input.len) {
        if (input[index] == '/' or input[index] == '\\') {
            index += 1;
            continue;
        }
        const start = index;
        while (index < input.len and input[index] != '/' and input[index] != '\\') index += 1;
        const segment = input[start..index];
        if (std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            // 回退一整段。找不到分隔符说明当前只有盘符（`D:`），那就原地不动，
            // 免得把盘符也剪掉。
            if (std.mem.lastIndexOfScalar(u8, out[0..length], '\\')) |separator| length = separator;
            continue;
        }
        const separator_len: usize = if (length > 0) 1 else 0;
        if (length + separator_len + segment.len > out.len) break;
        if (separator_len == 1) {
            out[length] = '\\';
            length += 1;
        }
        @memcpy(out[length..][0..segment.len], segment);
        length += segment.len;
    }
    // 盘符统一大写：注册表给 `D:\...`、清单给 `d:/...`，同屏出现会很花。
    if (length >= 2 and out[1] == ':') {
        if (out[0] >= 'a' and out[0] <= 'z') out[0] -= 'a' - 'A';
    }
    return out[0..length];
}

/// 取上一级目录；已经在根上（或空）时返回 null。
fn parentDirectory(path: []const u8, out: []u8) ?[]const u8 {
    const separator = std.mem.lastIndexOfScalar(u8, path, '\\') orelse return null;
    // `D:\foo` 的上一级是 `D:`，再往上没有了。
    if (separator < 2 or separator + 1 > out.len) return null;
    @memcpy(out[0..separator], path[0..separator]);
    return out[0..separator];
}

/// 从腾讯服游戏目录反推 WeGame 根目录：`<根>\WeGameApps\<游戏>` → `<根>`。
///
/// 找不到 `\WeGameApps\` 这一段（比如游戏被单独挪出来了）就返回 null。
fn weGameRootFromTencentRoot(root: []const u8, out: []u8) ?[]const u8 {
    const marker = indexOfIgnoreCase(root, "\\wegameapps\\") orelse return null;
    if (marker == 0 or marker > out.len) return null;
    @memcpy(out[0..marker], root[0..marker]);
    return out[0..marker];
}

/// 大小写不敏感的查找（`std.ascii` 只提供 `eqlIgnoreCase`，没有 `indexOfIgnoreCase`）。
/// `needle` 得是 ASCII——这里只用来找 `\WeGameApps\` 这种目录名。
fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index..][0..needle.len], needle)) return index;
    }
    return null;
}

/// 去掉 `DefaultIcon` 值里的引号与图标序号。
///
/// 两种形态都要认：`"D:\...\wegame.exe",0`（经典写法）和 `D:\...\wegame.exe`
/// （实测机器上就是不带的）。AK 只用正则匹配带引号的那种，不带引号时就静默
/// 拿不到 WeGame 路径——这里顺手补上。
fn stripIconSuffix(raw: []const u8) []const u8 {
    var value = std.mem.trim(u8, raw, " \t");
    if (value.len >= 2 and value[0] == '"') {
        if (std.mem.indexOfScalarPos(u8, value, 1, '"')) |closing| return value[1..closing];
    }
    if (std.mem.lastIndexOfScalar(u8, value, ',')) |comma| {
        const tail = value[comma + 1 ..];
        var digits_only = tail.len > 0;
        for (tail) |character| {
            if (character < '0' or character > '9') digits_only = false;
        }
        if (digits_only) value = std.mem.trimEnd(u8, value[0..comma], " \t");
    }
    return value;
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

    /// `HKEY_CURRENT_USER` 的句柄常量（`WinReg.h` 里的 `HKEY_CURRENT_USER`）。
    const hkey_current_user: *anyopaque = @ptrFromInt(0x80000001);
    /// `RRF_RT_REG_SZ` / `RRF_RT_REG_EXPAND_SZ`：限定只接受这两种字符串类型。
    const rrf_rt_reg_sz: u32 = 0x00000002;
    const rrf_rt_reg_expand_sz: u32 = 0x00000004;

    /// `advapi32!RegGetValueW` —— 一次调用完成「开键 + 读值 + 关句柄」。
    /// 比 `RegOpenKeyExW` + `RegQueryValueExW` + `RegCloseKey` 少三个可能失败的步骤，
    /// 也就少一条只在出错时才走的释放路径。
    extern "advapi32" fn RegGetValueW(
        key: *anyopaque,
        sub_key: [*:0]const u16,
        value_name: [*:0]const u16,
        flags: u32,
        value_type: ?*u32,
        data: ?[*]u8,
        data_size: *u32,
    ) callconv(.winapi) i32;

    /// 扫盘前先问系统「哪些盘符存在」——位图，**不发任何 I/O**。
    extern "kernel32" fn GetLogicalDrives() u32;
    /// `DRIVE_FIXED`：本地固定盘。网络盘/光驱/可移动盘一律跳过。
    const drive_fixed: u32 = 3;
    extern "kernel32" fn GetDriveTypeW(root_path_name: [*:0]const u16) callconv(.winapi) u32;
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

test "路径归一化：折叠 `..`、统一分隔符、盘符大写" {
    var buffer: [512]u8 = undefined;
    // 实测机器上清单里的原样：小写盘符 + `/` + `riot client/../LeagueClient/`。
    try std.testing.expectEqualStrings(
        "D:\\1_Application\\10_Game\\WeGame\\WeGameApps\\英雄联盟\\LeagueClient",
        normalizePath("d:/1_Application/10_Game/WeGame/WeGameApps/英雄联盟/riot client/../LeagueClient/", &buffer),
    );
    try std.testing.expectEqualStrings(
        "C:\\Riot Games\\League of Legends",
        normalizePath("C:\\Riot Games\\League of Legends\\", &buffer),
    );
    try std.testing.expectEqualStrings("D:\\foo\\bar", normalizePath("D:\\foo\\.\\bar", &buffer));
    try std.testing.expectEqualStrings("D:\\foo", normalizePath("D:\\\\foo", &buffer));
    // 只有盘符时不能被 `..` 剪没。
    try std.testing.expectEqualStrings("D:", normalizePath("D:\\..", &buffer));
}

test "取上一级目录" {
    var buffer: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "D:\\1_Application\\10_Game\\WeGame\\WeGameApps\\英雄联盟",
        parentDirectory("D:\\1_Application\\10_Game\\WeGame\\WeGameApps\\英雄联盟\\LeagueClient", &buffer).?,
    );
    try std.testing.expectEqualStrings("D:", parentDirectory("D:\\foo", &buffer).?);
    // 盘符之上没有了。
    try std.testing.expect(parentDirectory("D:", &buffer) == null);
    try std.testing.expect(parentDirectory("", &buffer) == null);
}

test "从游戏目录反推 WeGame 根目录" {
    var buffer: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "D:\\1_Application\\10_Game\\WeGame",
        weGameRootFromTencentRoot("D:\\1_Application\\10_Game\\WeGame\\WeGameApps\\英雄联盟", &buffer).?,
    );
    // 大小写不敏感：清单里出现过全小写的 `wegameapps`。
    try std.testing.expectEqualStrings(
        "D:\\1_Application\\10_Game\\WeGame",
        weGameRootFromTencentRoot("D:\\1_Application\\10_Game\\WeGame\\wegameapps\\英雄联盟", &buffer).?,
    );
    try std.testing.expectEqualStrings("D:", weGameRootFromTencentRoot("D:\\WeGameApps\\英雄联盟", &buffer).?);
    // 游戏被单独挪出来时没有这一段可砍。
    try std.testing.expect(weGameRootFromTencentRoot("D:\\Games\\LoL", &buffer) == null);
}

test "DefaultIcon 值的引号与图标序号都要剥掉" {
    // 经典写法：`"...",<图标序号>`。
    try std.testing.expectEqualStrings("D:\\a\\wegame.exe", stripIconSuffix("\"D:\\a\\wegame.exe\",0"));
    // 实测机器上就是不带的（AK 的正则在这里会空手而归）。
    try std.testing.expectEqualStrings("D:\\a\\wegame.exe", stripIconSuffix("D:\\a\\wegame.exe"));
    try std.testing.expectEqualStrings("D:\\a\\wegame.exe", stripIconSuffix("D:\\a\\wegame.exe,0"));
    try std.testing.expectEqualStrings("D:\\a\\wegame.exe", stripIconSuffix("  \"D:\\a\\wegame.exe\"  "));
}

test "清单分类：腾讯服的记录不能当成官方客户端" {
    var buffer: [512]u8 = undefined;
    // 真机上那四条的字面形态：都是腾讯服（路径带「英雄联盟」），归一化后落到 `<游戏目录>\LeagueClient`。
    const resolved = normalizePath("d:/1_application/10_game/wegame/wegameapps/英雄联盟/riot client/../LeagueClient/", &buffer);
    try std.testing.expectEqualStrings(
        "D:\\1_application\\10_game\\wegame\\wegameapps\\英雄联盟\\LeagueClient",
        resolved,
    );
    // 游戏目录上有 TCLS 标记 → 这是腾讯服，绝不能标成「官方客户端」。
    try std.testing.expectEqual(ManifestEntry.tencent, classifyManifestEntry(resolved, false, true));

    // 卸载后残留的死路径：路径还带「英雄联盟」但目录早没了 → 直接忽略，别摆到界面上。
    try std.testing.expectEqual(ManifestEntry.ignore, classifyManifestEntry(resolved, false, false));

    // 官方客户端：不带「英雄联盟」、目录里就有 LeagueClient.exe。
    var official_buffer: [512]u8 = undefined;
    const official = normalizePath("C:/Riot Games/League of Legends/", &official_buffer);
    try std.testing.expectEqualStrings("C:\\Riot Games\\League of Legends", official);
    try std.testing.expectEqual(ManifestEntry.official, classifyManifestEntry(official, false, false));

    // key 直接就是腾讯服游戏目录的写法也要认。
    try std.testing.expectEqual(ManifestEntry.tencent, classifyManifestEntry(official, true, false));
    try std.testing.expectEqual(ManifestEntry.ignore, classifyManifestEntry("", false, false));
}
