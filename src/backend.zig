const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const lcu = @import("lcu");
const storage = @import("storage");
const build_options = @import("build_options");
const automation_service = @import("backend/automation.zig");
const champion_mapper = @import("backend/champions.zig");
const encounter_service = @import("backend/encounters.zig");
const lcu_events = @import("backend/events.zig");
const native_input = @import("backend/input.zig");
const shortcut_service = @import("backend/shortcuts.zig");
const hotkey_service = @import("backend/hotkeys.zig");
const jungle_analysis = @import("backend/jungle_analysis.zig");
const recent_tags = @import("backend/recent_tags.zig");

const fallback_data_dir = std.fmt.comptimePrint(".{s}", .{build_options.data_dir_name});
const path_capacity = 2048;
const live_lobby_capacity = 512 * 1024;
const encounter_retention_ms: i64 = 365 * std.time.ms_per_day;

pub const command_names = [_][]const u8{
    "lol.get_bootstrap",
    "lol.get_config",
    "lol.save_config",
    "lol.set_shortcut_capture",
    "lol.set_data_mode",
    "lol.refresh_connection",
    "lol.get_live_lobby",
    "lol.get_live_roster",
    "lol.get_match_history",
    "lol.get_champions",
    "lol.get_asset",
    "lol.get_encounters",
    "lol.get_friends",
    "lol.get_friend_last_game",
    "lol.delete_friend",
    "lol.get_bp_history",
    "lol.save_match_export",
    "lol.send_shortcut",
    "lol.preview_shortcut",
    "lol.run_automation",
    "lol.validate_shortcut_template",
    "lol.check_update",
    "lol.open_game_view",
    "lol.get_lcu_events",
    "lol.get_shortcut_events",
};

const default_config =
    "{\"version\":17,\"appearance\":{\"theme\":\"system\",\"colorMode\":\"dark\",\"compact\":false}," ++
    "\"connection\":{\"kind\":\"local\",\"sshTarget\":\"\",\"identityFile\":\"\",\"forwardedPort\":0}," ++
    "\"automation\":{\"enabled\":false,\"advisoryMode\":true,\"autoAccept\":false,\"autoAcceptDelaySeconds\":0,\"autoPick\":false,\"autoPickDelaySeconds\":1,\"autoPickStrategy\":\"show-and-lock-in\",\"autoBan\":false,\"pickChampionIds\":[],\"banChampionIds\":[],\"shortcutSendIntervalMs\":250,\"shortcutRecentGameCount\":5,\"shortcuts\":[{\"id\":\"encounter\",\"label\":\"发送遇到记录\",\"key\":\"Ctrl+F8\",\"target\":\"encounter\",\"template\":\"{encounter}\",\"enabled\":true},{\"id\":\"premade\",\"label\":\"发送已知组队\",\"key\":\"Ctrl+F9\",\"target\":\"premade\",\"template\":\"{position} {name}：组队 {premade}\",\"enabled\":true},{\"id\":\"jungle-preference\",\"label\":\"发送打野偏好\",\"key\":\"Ctrl+F10\",\"target\":\"jungle\",\"template\":\"{name}：{jungle_preference}\",\"enabled\":true},{\"id\":\"enemy\",\"label\":\"发送敌方评估\",\"key\":\"Ctrl+F11\",\"target\":\"enemy\",\"template\":\"{team}{position} {current_champion}：{rank} {recent_wins}胜{recent_losses}负，{recent_games}\",\"enabled\":true},{\"id\":\"ally\",\"label\":\"发送我方评估\",\"key\":\"Ctrl+F12\",\"target\":\"ally\",\"template\":\"{team}{position} {current_champion}：{rank} {recent_wins}胜{recent_losses}负，{recent_games}\",\"enabled\":true},{\"id\":\"open-game\",\"label\":\"打开对局速看\",\"key\":\"Ctrl+F1\",\"target\":\"lobby\",\"template\":\"对局速看：{team} {name}\",\"enabled\":true}]}," ++
    "\"providers\":{\"statsProvider\":\"auto\",\"requestTimeoutSeconds\":6,\"cacheTtlMinutes\":120,\"hideUnfinishedMatches\":false,\"clearLobbyAfterGame\":true}," ++
    "\"ai\":{\"enabled\":false,\"provider\":\"deepseek\",\"protocol\":\"openai\",\"baseUrl\":\"https://api.deepseek.com\",\"model\":\"deepseek-v4-flash\",\"apiKey\":\"\",\"automaticPregameAnalysis\":false}}";

const fixture_connection =
    "{\"status\":\"disconnected\",\"phase\":\"Fixture\",\"summonerName\":\"Native 预览\",\"gameName\":\"Native 预览\",\"tagLine\":\"NATIVE\",\"summonerLevel\":null,\"profileIconId\":null,\"platformId\":null,\"region\":null,\"presence\":\"online\",\"soloRank\":null,\"flexRank\":null,\"queueLabel\":null,\"message\":\"Native SDK Fixture：尚未连接 LCU\",\"checkedAt\":\"1970-01-01T00:00:00.000Z\"}";

const disconnected_connection =
    "{\"status\":\"disconnected\",\"phase\":null,\"summonerName\":null,\"gameName\":null,\"tagLine\":null,\"summonerLevel\":null,\"profileIconId\":null,\"platformId\":null,\"region\":null,\"presence\":\"offline\",\"soloRank\":null,\"flexRank\":null,\"queueLabel\":null,\"message\":\"未检测到 League Client\",\"checkedAt\":\"1970-01-01T00:00:00.000Z\"}";

const empty_summary = "{\"side\":\"ally\",\"score\":0,\"title\":\"暂无实时数据\",\"focusPlayerPuuid\":null,\"strengths\":[],\"risks\":[],\"composition\":{\"early\":0,\"mid\":0,\"late\":0,\"teamfight\":0}}";
const empty_enemy_summary = "{\"side\":\"enemy\",\"score\":0,\"title\":\"暂无实时数据\",\"focusPlayerPuuid\":null,\"strengths\":[],\"risks\":[],\"composition\":{\"early\":0,\"mid\":0,\"late\":0,\"teamfight\":0}}";
const empty_lobby =
    "{\"id\":\"native-fixture\",\"queueId\":0,\"gameMode\":\"Native SDK Fixture\",\"phase\":\"Fixture\",\"ally\":[],\"enemy\":[]," ++
    "\"allySummary\":" ++ empty_summary ++ ",\"enemySummary\":" ++ empty_summary ++ ",\"layoutKind\":\"generic\",\"teams\":[],\"recentMatch\":null,\"generatedAt\":\"1970-01-01T00:00:00.000Z\",\"isFixture\":true}";

pub const Runtime = struct {
    // Native bridge work runs off the window thread. Runtime owns mutable
    // buffers and a single SQLite connection, so commands still execute in a
    // deterministic order without blocking the Win32/WebView message loop.
    command_mutex: std.atomic.Mutex = .unlocked,
    // Manual bridge calls and the host-side automation watchdog share this
    // single-flight lock so a ready-check is never submitted twice at once.
    automation_mutex: std.atomic.Mutex = .unlocked,
    mode: Mode = .live,
    config: [65536]u8 = undefined,
    config_len: usize = 0,
    io: ?std.Io = null,
    env_map: ?*const std.process.Environ.Map = null,
    data_dir_path: [path_capacity]u8 = undefined,
    data_dir_path_len: usize = 0,
    config_path_buffer: [path_capacity]u8 = undefined,
    config_path_len: usize = 0,
    database_path_buffer: [path_capacity]u8 = undefined,
    database_path_len: usize = 0,
    encounters_path_buffer: [path_capacity]u8 = undefined,
    encounters_path_len: usize = 0,
    bp_history_path_buffer: [path_capacity]u8 = undefined,
    bp_history_path_len: usize = 0,
    storage: ?storage.Store = null,
    connection: [16384]u8 = undefined,
    connection_len: usize = 0,
    live_lobby: [live_lobby_capacity]u8 = undefined,
    live_lobby_len: usize = 0,
    // Champ-select disappears during the hand-off to the game client. Keep
    // that higher-quality roster separately so a transient gameflow/live
    // client response cannot make the live page empty.
    champ_select_lobby: [live_lobby_capacity]u8 = undefined,
    champ_select_lobby_len: usize = 0,
    champ_select_game_id: i64 = 0,
    last_live_phase: [32]u8 = undefined,
    last_live_phase_len: usize = 0,
    champ_select_handoff_active: bool = false,
    live_roster_hash: u64 = 0,
    live_lobby_enriched: bool = false,
    live_owner_puuid: [128]u8 = undefined,
    live_owner_puuid_len: usize = 0,
    event_state: lcu_events.State = .{},
    native_runtime: ?*native_sdk.Runtime = null,
    shortcut_capture_active: bool = false,
    // The watchdog runs independently of bridge commands. Keep the discovered
    // credentials alive between ticks so a PowerShell process scan cannot add
    // seconds of jitter to the configured ready-check delay.
    automation_client: ?lcu.Client = null,

    pub const Mode = enum { live, fixture, replay };

    pub fn init() Runtime {
        var state = Runtime{};
        state.setDataPaths(fallback_data_dir) catch unreachable;
        @memcpy(state.config[0..default_config.len], default_config);
        state.config_len = default_config.len;
        @memcpy(state.connection[0..disconnected_connection.len], disconnected_connection);
        state.connection_len = disconnected_connection.len;
        return state;
    }

    pub fn initWithIo(io: std.Io, env_map: *std.process.Environ.Map) Runtime {
        var state = init();
        state.io = io;
        state.env_map = env_map;
        var resolved_buffer: [path_capacity]u8 = undefined;
        if (native_sdk.app_dirs.resolveOne(
            .{ .name = build_options.data_dir_name },
            native_sdk.app_dirs.currentPlatform(),
            native_sdk.debug.envFromMap(env_map),
            .data,
            &resolved_buffer,
        )) |resolved| {
            state.setDataPaths(resolved) catch {};
        } else |_| {}
        std.Io.Dir.cwd().createDirPath(io, state.dataDir()) catch {};
        if (storage.Store.open(std.heap.page_allocator, io, state.databasePath())) |store| {
            state.storage = store;
            if (state.storage) |*store_ptr| {
                // Restore the last complete roster before the first LCU request.
                // The owner marker is checked again when current-summoner arrives,
                // so an account switch cannot display another account's lobby.
                if (store_ptr.get("liveLobby", "ownerPuuid") catch null) |owner| {
                    defer std.heap.page_allocator.free(owner);
                    if (owner.len <= state.live_owner_puuid.len) {
                        @memcpy(state.live_owner_puuid[0..owner.len], owner);
                        state.live_owner_puuid_len = owner.len;
                    }
                }
                if (store_ptr.get("liveLobby", "current") catch null) |lobby| {
                    defer std.heap.page_allocator.free(lobby);
                    if (lobby.len <= state.live_lobby.len and state.live_owner_puuid_len > 0) {
                        @memcpy(state.live_lobby[0..lobby.len], lobby);
                        state.live_lobby_len = lobby.len;
                        state.live_lobby_enriched = true;
                        if (lobbyIsChampSelectSnapshot(lobby)) {
                            @memcpy(state.champ_select_lobby[0..lobby.len], lobby);
                            state.champ_select_lobby_len = lobby.len;
                            state.champ_select_game_id = lobbyGameId(lobby);
                            observeLivePhase(&state, "ChampSelect");
                        }
                    }
                }
            }
        } else |_| {}
        var config_loaded = false;
        if (state.storage) |*store| if (store.get("config", "current") catch null) |saved| {
            defer std.heap.page_allocator.free(saved);
            if (saved.len <= state.config.len) {
                if (std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, saved, .{}) catch null) |parsed| {
                    parsed.deinit();
                    @memcpy(state.config[0..saved.len], saved);
                    state.config_len = saved.len;
                    config_loaded = true;
                }
            }
        };
        if (state.storage) |*store| if (store.get("settings", "dataMode") catch null) |saved| {
            defer std.heap.page_allocator.free(saved);
            if (std.json.parseFromSliceLeaky([]const u8, std.heap.page_allocator, saved, .{}) catch null) |saved_mode| {
                state.mode = std.meta.stringToEnum(Mode, saved_mode) orelse state.mode;
            }
        };
        if (!config_loaded) {
            if (std.Io.Dir.cwd().readFileAlloc(io, state.configPath(), std.heap.page_allocator, .limited(state.config.len))) |saved| {
                defer std.heap.page_allocator.free(saved);
                if (saved.len <= state.config.len) {
                    if (std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, saved, .{}) catch null) |parsed| {
                        parsed.deinit();
                        @memcpy(state.config[0..saved.len], saved);
                        state.config_len = saved.len;
                    }
                }
            } else |_| {}
        }
        return state;
    }

    pub fn deinit(self: *Runtime) void {
        if (self.automation_client) |*client| client.deinit();
        self.automation_client = null;
        if (self.storage) |*store| store.deinit();
        self.storage = null;
    }

    pub fn attachNativeRuntime(self: *Runtime, native_runtime: *native_sdk.Runtime) void {
        self.native_runtime = native_runtime;
        configureShortcuts(self) catch {};
    }

    /// Run the automation state machine from a host watchdog rather than a
    /// WebView timer. The config is copied while holding the command lock, so
    /// the LCU request itself never blocks bridge/UI commands or races a save.
    pub fn runAutomationBackground(self: *Runtime, io: std.Io) void {
        var config_snapshot: [65536]u8 = undefined;
        var config_len: usize = 0;
        lockBackendMutex(&self.command_mutex);
        if (self.mode != .live or self.config_len > config_snapshot.len) {
            self.command_mutex.unlock();
            return;
        }
        config_len = self.config_len;
        @memcpy(config_snapshot[0..config_len], self.config[0..config_len]);
        self.command_mutex.unlock();

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const config = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), config_snapshot[0..config_len], .{}) catch return;
        const automation = configAutomation(config) orelse return;
        if (automation != .object or !jsonBool(automation, "enabled") or jsonBool(automation, "advisoryMode")) return;
        if (!jsonBool(automation, "autoAccept") and !jsonBool(automation, "autoPick") and !jsonBool(automation, "autoBan")) return;

        // A manual `run_automation` call may already be waiting on the LCU.
        // The watchdog is periodic, so skip this tick instead of spinning and
        // consuming a core while the request completes.
        if (!self.automation_mutex.tryLock()) return;
        defer self.automation_mutex.unlock();
        const client = self.ensureAutomationClient(io, config_snapshot[0..config_len]) catch return;
        var output: [4096]u8 = undefined;
        _ = automation_service.run(io, client.*, config_snapshot[0..config_len], &output) catch |err| {
            if (isAutomationClientFailure(err)) self.dropAutomationClient();
        };
    }

    fn ensureAutomationClient(self: *Runtime, io: std.Io, config_json: []const u8) !*lcu.Client {
        if (self.automation_client == null) {
            self.automation_client = try discoverClientWithConfig(self, io, config_json);
        }
        return &self.automation_client.?;
    }

    fn dropAutomationClient(self: *Runtime) void {
        if (self.automation_client) |*client| client.deinit();
        self.automation_client = null;
    }

    pub fn modeName(self: *const Runtime) []const u8 {
        return switch (self.mode) {
            .live => "live",
            .fixture => "fixture",
            .replay => "replay",
        };
    }

    fn setDataPaths(self: *Runtime, root: []const u8) !void {
        if (root.len > self.data_dir_path.len) return error.PathTooLong;
        @memcpy(self.data_dir_path[0..root.len], root);
        self.data_dir_path_len = root.len;
        const platform = native_sdk.app_dirs.currentPlatform();
        self.config_path_len = (try native_sdk.app_dirs.join(platform, &self.config_path_buffer, &.{ self.dataDir(), "config.json" })).len;
        self.database_path_len = (try native_sdk.app_dirs.join(platform, &self.database_path_buffer, &.{ self.dataDir(), "lol-desktop.sqlite3" })).len;
        self.encounters_path_len = (try native_sdk.app_dirs.join(platform, &self.encounters_path_buffer, &.{ self.dataDir(), "encounters.json" })).len;
        self.bp_history_path_len = (try native_sdk.app_dirs.join(platform, &self.bp_history_path_buffer, &.{ self.dataDir(), "bp-history.json" })).len;
    }

    pub fn dataDir(self: *const Runtime) []const u8 {
        return self.data_dir_path[0..self.data_dir_path_len];
    }

    pub fn configPath(self: *const Runtime) []const u8 {
        return self.config_path_buffer[0..self.config_path_len];
    }

    pub fn databasePath(self: *const Runtime) []const u8 {
        return self.database_path_buffer[0..self.database_path_len];
    }

    fn encountersPath(self: *const Runtime) []const u8 {
        return self.encounters_path_buffer[0..self.encounters_path_len];
    }

    fn bpHistoryPath(self: *const Runtime) []const u8 {
        return self.bp_history_path_buffer[0..self.bp_history_path_len];
    }

    pub fn handlers(self: *Runtime) [command_names.len]native_sdk.bridge.Handler {
        return .{
            .{ .name = "lol.get_bootstrap", .context = self, .invoke_fn = getBootstrap },
            .{ .name = "lol.get_config", .context = self, .invoke_fn = getConfig },
            .{ .name = "lol.save_config", .context = self, .invoke_fn = saveConfig },
            .{ .name = "lol.set_shortcut_capture", .context = self, .invoke_fn = setShortcutCapture },
            .{ .name = "lol.set_data_mode", .context = self, .invoke_fn = setDataMode },
            .{ .name = "lol.refresh_connection", .context = self, .invoke_fn = refreshConnection },
            .{ .name = "lol.get_live_lobby", .context = self, .invoke_fn = getLiveLobby },
            .{ .name = "lol.get_live_roster", .context = self, .invoke_fn = getLiveRoster },
            .{ .name = "lol.get_match_history", .context = self, .invoke_fn = getMatches },
            .{ .name = "lol.get_champions", .context = self, .invoke_fn = getChampions },
            .{ .name = "lol.get_asset", .context = self, .invoke_fn = getAsset },
            .{ .name = "lol.get_encounters", .context = self, .invoke_fn = getEncounters },
            .{ .name = "lol.get_friends", .context = self, .invoke_fn = getFriends },
            .{ .name = "lol.get_friend_last_game", .context = self, .invoke_fn = getFriendLastGame },
            .{ .name = "lol.delete_friend", .context = self, .invoke_fn = deleteFriend },
            .{ .name = "lol.get_bp_history", .context = self, .invoke_fn = getBpHistory },
            .{ .name = "lol.save_match_export", .context = self, .invoke_fn = saveMatchExport },
            .{ .name = "lol.send_shortcut", .context = self, .invoke_fn = sendShortcut },
            .{ .name = "lol.preview_shortcut", .context = self, .invoke_fn = previewShortcut },
            .{ .name = "lol.run_automation", .context = self, .invoke_fn = runAutomation },
            .{ .name = "lol.validate_shortcut_template", .context = self, .invoke_fn = validateShortcut },
            .{ .name = "lol.check_update", .context = self, .invoke_fn = checkUpdate },
            .{ .name = "lol.open_game_view", .context = self, .invoke_fn = openGameView },
            .{ .name = "lol.get_lcu_events", .context = self, .invoke_fn = getLcuEvents },
            .{ .name = "lol.get_shortcut_events", .context = self, .invoke_fn = getShortcutEvents },
        };
    }
};

fn runtime(context: *anyopaque) *Runtime {
    return @ptrCast(@alignCast(context));
}

fn lockBackendMutex(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

fn isAutomationClientFailure(err: anyerror) bool {
    return err == error.LcuRequestFailed or err == error.LcuInvalidResponse or
        err == error.LcuNotRunning or err == error.InputSimulationFailed;
}

fn discoverClient(self: *const Runtime, io: std.Io) !lcu.Client {
    return discoverClientWithConfig(self, io, self.config[0..self.config_len]);
}

fn discoverClientWithConfig(self: *const Runtime, io: std.Io, config_json: []const u8) !lcu.Client {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const config = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), config_json, .{}) catch std.json.Value{ .null = {} };
    const connection = nestedObject(config, "connection");
    if (connection) |value| if (std.ascii.eqlIgnoreCase(jsonField(value, "kind"), "ssh")) {
        const target = jsonField(value, "sshTarget");
        if (std.mem.trim(u8, target, " \t\r\n").len == 0) return error.LcuSshTargetMissing;
        const port_value = jsonInt(value, "forwardedPort");
        const forwarded_port: u16 = if (port_value > 0 and port_value <= 65535) @intCast(port_value) else 0;
        if (lcu.Client.discoverRemote(
            std.heap.page_allocator,
            io,
            target,
            jsonField(value, "identityFile"),
            forwarded_port,
            requestTimeoutMsFromConfig(config),
            build_options.lcu_verify_tls,
        )) |remote| return remote else |remote_error| {
            if (builtin.os.tag != .windows) return remote_error;
        }
    };
    var client = try lcu.Client.discover(std.heap.page_allocator, io, build_options.lcu_lockfile_paths, self.env_map);
    client.timeout_ms = requestTimeoutMsFromConfig(config);
    client.verify_tls = build_options.lcu_verify_tls;
    return client;
}

fn runtimeConnectionIsSsh(self: *const Runtime) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const config = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), self.config[0..self.config_len], .{}) catch return false;
    const connection = nestedObject(config, "connection") orelse return false;
    return std.ascii.eqlIgnoreCase(jsonField(connection, "kind"), "ssh");
}

fn runtimeRequestTimeoutMs(self: *const Runtime) u32 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const config = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), self.config[0..self.config_len], .{}) catch
        return build_options.lcu_request_timeout_ms;
    return requestTimeoutMsFromConfig(config);
}

fn requestTimeoutMsFromConfig(config: std.json.Value) u32 {
    const providers = nestedObject(config, "providers") orelse return build_options.lcu_request_timeout_ms;
    const seconds = jsonInt(providers, "requestTimeoutSeconds");
    if (seconds <= 0) return build_options.lcu_request_timeout_ms;
    return @intCast(@min(@as(i64, 30_000), @max(@as(i64, 1_000), seconds * 1_000)));
}

fn runtimeCacheTtlMillis(self: *const Runtime) i64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const config = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), self.config[0..self.config_len], .{}) catch return 120 * std.time.ms_per_min;
    const providers = nestedObject(config, "providers") orelse return 120 * std.time.ms_per_min;
    const minutes = jsonInt(providers, "cacheTtlMinutes");
    return @max(@as(i64, std.time.ms_per_min), @min(@as(i64, 7 * std.time.ms_per_day), minutes * std.time.ms_per_min));
}

fn runtimeHideUnfinishedMatches(self: *const Runtime) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const config = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), self.config[0..self.config_len], .{}) catch return false;
    const providers = nestedObject(config, "providers") orelse return false;
    return jsonBool(providers, "hideUnfinishedMatches");
}

fn runtimeNowMillis(self: *const Runtime) i64 {
    const io = self.io orelse return 0;
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
}

fn getBootstrap(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    _ = invocation;
    const self = runtime(context);
    const connection = if (self.mode == .fixture or self.mode == .replay)
        fixture_connection
    else
        self.connection[0..self.connection_len];

    // Bootstrap is rendered before the query layer has completed its first
    // request. Include the last local snapshots here so a transient LCU
    // disconnect does not leave the dashboard empty while the cache fallback
    // is being resolved.
    const matches_buffer = std.heap.page_allocator.alloc(u8, 512 * 1024) catch null;
    defer if (matches_buffer) |value| std.heap.page_allocator.free(value);
    const cached_matches = if (self.mode == .live) if (matches_buffer) |buffer| cachedMatchesPage(self, 0, 10, buffer) else null else null;
    const encounters_buffer = std.heap.page_allocator.alloc(u8, 256 * 1024) catch null;
    defer if (encounters_buffer) |value| std.heap.page_allocator.free(value);
    const derived_encounters = if (self.mode == .live) if (encounters_buffer) |buffer| cachedEncountersFromMatches(self, buffer) else null else null;
    var stored_encounters: ?[]u8 = null;
    if (derived_encounters == null) if (self.storage) |*store| {
        stored_encounters = store.get("history", "encounters") catch null;
    };
    defer if (stored_encounters) |value| std.heap.page_allocator.free(value);

    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll("{\"dataMode\":");
    try jsonString(&writer, self.modeName());
    try writer.writeAll(",\"dashboard\":{\"connection\":");
    try writer.writeAll(connection);
    try writer.writeAll(",\"recentMatches\":");
    try writer.writeAll(cached_matches orelse "[]");
    try writer.writeAll(",\"recentEncounters\":");
    try writer.writeAll(derived_encounters orelse stored_encounters orelse "[]");
    try writer.writeAll(",\"patch\":\"\",\"cachedChampions\":0},\"configPath\":");
    try jsonString(&writer, self.configPath());
    try writer.writeAll(",\"databasePath\":");
    try jsonString(&writer, self.databasePath());
    try writer.writeAll(",\"appDataPath\":");
    try jsonString(&writer, self.dataDir());
    try writer.writeAll(",\"appVersion\":\"2.0.0\"}");
    return writer.buffered();
}

fn getConfig(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    _ = invocation;
    const self = runtime(context);
    @memcpy(output[0..self.config_len], self.config[0..self.config_len]);
    return output[0..self.config_len];
}

const SavePayload = struct { value: std.json.Value };
const ModePayload = struct { mode: []const u8 };
const TemplatePayload = struct { template: []const u8 };

fn parsePayload(comptime T: type, payload: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, std.heap.page_allocator, payload, .{ .ignore_unknown_fields = true });
}

fn saveConfig(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = runtime(context);
    const parsed = parsePayload(SavePayload, invocation.request.payload) catch return error.InvalidConfig;
    var writer = std.Io.Writer.fixed(output);
    var stringify = std.json.Stringify{ .writer = &writer, .options = .{} };
    stringify.write(parsed.value) catch return error.InvalidConfig;
    const serialized = writer.buffered();
    if (serialized.len > self.config.len) return error.ConfigTooLarge;
    // A connection kind/port can change from the settings page while the
    // watchdog is holding old LCU credentials. Drop that client at the config
    // boundary so the next automation tick discovers the new endpoint.
    lockBackendMutex(&self.automation_mutex);
    self.dropAutomationClient();
    self.automation_mutex.unlock();
    @memcpy(self.config[0..serialized.len], serialized);
    self.config_len = serialized.len;
    if (!self.shortcut_capture_active) try configureShortcuts(self);
    if (self.io) |io| {
        std.Io.Dir.cwd().createDirPath(io, self.dataDir()) catch return error.ConfigPersistenceFailed;
        if (self.storage) |*store| store.put("config", "current", serialized) catch return error.ConfigPersistenceFailed;
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = self.configPath(), .data = serialized }) catch return error.ConfigPersistenceFailed;
    }
    return serialized;
}

fn shortcutBinding(value: []const u8) ?struct { key: []const u8, modifiers: native_sdk.ShortcutModifiers } {
    const remaining = std.mem.trim(u8, value, " \t\r\n");
    if (remaining.len == 0) return null;
    var modifiers: native_sdk.ShortcutModifiers = .{};
    var key: []const u8 = "";
    var parts = std.mem.splitScalar(u8, remaining, '+');
    while (parts.next()) |part_value| {
        const part = std.mem.trim(u8, part_value, " \t\r\n");
        if (part.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(part, "CommandOrControl") or std.ascii.eqlIgnoreCase(part, "CmdOrCtrl") or std.ascii.eqlIgnoreCase(part, "Ctrl")) {
            modifiers.primary = true;
        } else if (std.ascii.eqlIgnoreCase(part, "Control")) {
            modifiers.control = true;
        } else if (std.ascii.eqlIgnoreCase(part, "Command") or std.ascii.eqlIgnoreCase(part, "Meta") or std.ascii.eqlIgnoreCase(part, "Win")) {
            modifiers.command = true;
        } else if (std.ascii.eqlIgnoreCase(part, "Alt") or std.ascii.eqlIgnoreCase(part, "Option")) {
            modifiers.option = true;
        } else if (std.ascii.eqlIgnoreCase(part, "Shift")) {
            modifiers.shift = true;
        } else if (key.len == 0) {
            key = part;
        } else return null;
    }
    if (key.len == 0) return null;
    return .{ .key = key, .modifiers = modifiers };
}

fn configureShortcuts(self: *Runtime) !void {
    const native_runtime = self.native_runtime orelse return;
    // Native SDK shortcuts are window-local on Windows and cannot observe
    // key presses while League owns the foreground window. Keep that table
    // empty and use the dedicated low-level listener instead.
    try native_runtime.options.platform.services.configureShortcuts(&.{});
    if (self.shortcut_capture_active) {
        hotkey_service.setCapture(true);
        return;
    }
    hotkey_service.setCapture(false);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const config = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), self.config[0..self.config_len], .{}) catch return error.InvalidConfig;
    const automation = configAutomation(config) orelse {
        hotkey_service.configure(&.{}) catch return error.InvalidShortcut;
        return;
    };
    const values = automation.object.get("shortcuts") orelse {
        hotkey_service.configure(&.{}) catch return error.InvalidShortcut;
        return;
    };
    if (values != .array) return error.InvalidConfig;
    var shortcuts: [32]hotkey_service.Shortcut = undefined;
    var count: usize = 0;
    for (values.array.items) |item| {
        if (item != .object or !jsonBool(item, "enabled")) continue;
        const id = jsonField(item, "id");
        if (shortcutBinding(jsonField(item, "key")) == null) continue;
        if (id.len == 0 or count >= shortcuts.len) return error.InvalidShortcut;
        shortcuts[count] = .{ .id = id, .key = jsonField(item, "key") };
        count += 1;
    }
    hotkey_service.configure(shortcuts[0..count]) catch return error.InvalidShortcut;
}

fn setShortcutCapture(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = runtime(context);
    const payload = parsePayload(struct { active: bool = false }, invocation.request.payload) catch return error.InvalidRequest;
    self.shortcut_capture_active = payload.active;
    try configureShortcuts(self);
    return std.fmt.bufPrint(output, "null", .{});
}

fn setDataMode(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = runtime(context);
    const parsed = parsePayload(ModePayload, invocation.request.payload) catch return error.InvalidDataMode;
    const mode: Runtime.Mode = std.meta.stringToEnum(Runtime.Mode, parsed.mode) orelse return error.InvalidDataMode;
    self.mode = mode;
    if (mode == .live) {
        @memcpy(self.connection[0..disconnected_connection.len], disconnected_connection);
        self.connection_len = disconnected_connection.len;
    } else {
        @memcpy(self.connection[0..fixture_connection.len], fixture_connection);
        self.connection_len = fixture_connection.len;
    }
    if (self.storage) |*store| {
        var encoded: [32]u8 = undefined;
        const value = std.fmt.bufPrint(&encoded, "\"{s}\"", .{self.modeName()}) catch return error.InvalidDataMode;
        store.put("settings", "dataMode", value) catch return error.ConfigPersistenceFailed;
    }
    return std.fmt.bufPrint(output, "\"{s}\"", .{self.modeName()});
}

fn refreshConnection(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = runtime(context);
    _ = invocation;
    if (self.mode == .live) {
        if (self.io) |io| {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const allocator = arena.allocator();
            var client = discoverClient(self, io) catch |err| return connectionErrorDto(self, output, "disconnected", err);
            defer client.deinit();
            const summoner = client.get("/lol-summoner/v1/current-summoner") catch |err| return connectionErrorDto(self, output, "error", err);
            defer std.heap.page_allocator.free(summoner);
            const phase = client.get("/lol-gameflow/v1/gameflow-phase") catch |err| return connectionErrorDto(self, output, "error", err);
            defer std.heap.page_allocator.free(phase);
            const chat_owned: ?[]u8 = client.get("/lol-chat/v1/me") catch null;
            defer if (chat_owned) |value| std.heap.page_allocator.free(value);
            const ranked_owned: ?[]u8 = client.get("/lol-ranked/v1/current-ranked-stats") catch null;
            defer if (ranked_owned) |value| std.heap.page_allocator.free(value);
            var lobby_owned: ?[]u8 = null;
            const phase_value = std.json.parseFromSliceLeaky(std.json.Value, allocator, phase, .{}) catch null;
            if (phase_value) |value| if (value == .string and std.mem.eql(u8, value.string, "Lobby")) {
                lobby_owned = client.get("/lol-lobby/v2/lobby") catch null;
            };
            defer if (lobby_owned) |value| std.heap.page_allocator.free(value);
            // Match history has its own bridge command and cache. Pulling 50
            // games on every five-second connection refresh serializes all
            // live-roster work behind a large request in the synchronous host.
            const result = connectionDtoDetailedAt(summoner, phase, chat_owned orelse "{}", ranked_owned orelse "{}", lobby_owned orelse "{}", "{}", runtimeNowMillis(self), output) catch |err| return connectionErrorDto(self, output, "error", err);
            cacheConnection(self, result);
            return result;
        }
        return connectionErrorDto(self, output, "disconnected", error.LcuNotRunning);
    }
    @memcpy(output[0..fixture_connection.len], fixture_connection);
    return output[0..fixture_connection.len];
}

fn cacheConnection(self: *Runtime, value: []const u8) void {
    if (value.len > self.connection.len) return;
    @memcpy(self.connection[0..value.len], value);
    self.connection_len = value.len;
}

fn connectionErrorDto(self: *Runtime, output: []u8, status: []const u8, err: anyerror) []const u8 {
    var writer = std.Io.Writer.fixed(output);
    writer.writeAll("{\"status\":") catch return output[0..0];
    jsonString(&writer, status) catch return output[0..0];
    writer.writeAll(",\"phase\":null,\"summonerName\":null,\"gameName\":null,\"tagLine\":null,\"summonerLevel\":null,\"profileIconId\":null,\"platformId\":null,\"region\":null,\"presence\":\"offline\",\"soloRank\":null,\"flexRank\":null,\"queueLabel\":null,\"message\":") catch return output[0..0];
    var message: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&message, "LCU 连接失败：{s}", .{@errorName(err)}) catch "LCU 连接失败";
    jsonString(&writer, text) catch return output[0..0];
    writer.writeAll(",\"checkedAt\":") catch return output[0..0];
    writeIsoTimestamp(&writer, runtimeNowMillis(self)) catch return output[0..0];
    writer.writeByte('}') catch return output[0..0];
    const result = writer.buffered();
    cacheConnection(self, result);
    return result;
}

fn getLiveLobby(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    return getLiveLobbyInternal(context, invocation, output, true);
}

fn getLiveLobbyInternal(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8, enrich: bool) anyerror![]const u8 {
    const self = runtime(context);
    if (self.mode == .live) {
        _ = invocation;
        if (self.io) |io| {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const allocator = arena.allocator();
            var client = discoverClient(self, io) catch {
                if (self.live_lobby_len > 0) return liveLobbyCacheWithPhase(self, "InProgress", output) catch error.LcuNotRunning;
                return error.LcuNotRunning;
            };
            defer client.deinit();
            const phase_json = client.get("/lol-gameflow/v1/gameflow-phase") catch {
                if (self.live_lobby_len > 0) return liveLobbyCacheWithPhase(self, "InProgress", output) catch error.LcuRequestFailed;
                return error.LcuRequestFailed;
            };
            defer std.heap.page_allocator.free(phase_json);
            const phase_value = std.json.parseFromSliceLeaky(std.json.Value, allocator, phase_json, .{}) catch return error.LcuInvalidResponse;
            const phase = if (phase_value == .string) phase_value.string else "Unknown";
            observeLivePhase(self, phase);
            const current = client.get("/lol-summoner/v1/current-summoner") catch null;
            defer if (current) |value| std.heap.page_allocator.free(value);
            updateLiveLobbyOwner(self, current);
            if (enrich) if (current) |value| primeCurrentHistory(self, client, value);

            // The champ-select session disappears as soon as the game client
            // starts. Route each phase to the endpoint that owns that data and
            // retain the last good snapshot during the short transition.
            const should_probe_live = shouldProbeLiveData(phase);
            const session = if (std.mem.eql(u8, phase, "ChampSelect") or std.mem.eql(u8, phase, "ReadyCheck"))
                client.get("/lol-champ-select/v1/session") catch null
            else if (should_probe_live)
                client.get("/lol-gameflow/v1/session") catch null
            else
                null;
            defer if (session) |value| std.heap.page_allocator.free(value);
            if (session) |value| {
                const session_game_id = gameIdFromSessionJson(value);
                invalidateMismatchedLobbyCaches(self, session_game_id);
            }

            // Gameflow often collapses to one participant after the game
            // client launches. The local Live Client Data API is the same
            // authoritative in-game roster source used by the Rust build.
            if (should_probe_live) {
                var live_client = client;
                live_client.timeout_ms = @min(client.timeout_ms, build_options.lcu_live_probe_timeout_ms);
                const live_data = if (runtimeConnectionIsSsh(self)) null else live_client.getLocalUrl(build_options.lcu_live_client_data_url) catch null;
                defer if (live_data) |value| std.heap.page_allocator.free(value);
                if (live_data) |value| {
                    const roster_hash = liveClientRosterHash(value, session);
                    if (roster_hash != 0) {
                        if (self.live_roster_hash == roster_hash and self.live_lobby_len > 0 and (!enrich or self.live_lobby_enriched)) {
                            return liveLobbyCacheWithPhase(self, phase, output) catch copyJson(self.live_lobby[0..self.live_lobby_len], output);
                        }
                        const catalog = client.get("/lol-game-data/assets/v1/champion-summary.json") catch null;
                        defer if (catalog) |catalog_json| std.heap.page_allocator.free(catalog_json);
                        const queues = client.get("/lol-game-data/assets/v1/queues.json") catch null;
                        defer if (queues) |queue_json| std.heap.page_allocator.free(queue_json);
                        const inferred_phase = if (isActiveLivePhase(phase)) phase else "InProgress";
                        const result = liveClientEnvelope(self, client, value, session, inferred_phase, current, catalog orelse "[]", queues orelse "[]", output, enrich) catch null;
                        if (result) |lobby| {
                            if (betterCachedLiveLobby(self, lobby, phase, enrich, output)) |cached| return cached;
                            if (self.live_lobby_len > 0 and lobbyRosterCount(lobby) < lobbyRosterCount(self.live_lobby[0..self.live_lobby_len])) {
                                return liveLobbyCacheWithPhase(self, phase, output) catch copyJson(self.live_lobby[0..self.live_lobby_len], output);
                            }
                            const merged = mergeWithBestLiveCache(self, lobby, enrich, output) catch lobby;
                            self.live_roster_hash = roster_hash;
                            self.live_lobby_enriched = enrich;
                            cacheLiveLobby(self, merged);
                            return merged;
                        }
                    }
                }
            } else {
                self.live_roster_hash = 0;
                self.live_lobby_enriched = false;
            }

            if (session) |value| {
                const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, value, .{}) catch null;
                const has_roster = parsed != null and parsed.? == .object and sessionHasRoster(parsed.?);
                if (has_roster or std.mem.eql(u8, phase, "ChampSelect") or std.mem.eql(u8, phase, "ReadyCheck")) {
                    const catalog = client.get("/lol-game-data/assets/v1/champion-summary.json") catch null;
                    defer if (catalog) |catalog_json| std.heap.page_allocator.free(catalog_json);
                    const queues = client.get("/lol-game-data/assets/v1/queues.json") catch null;
                    defer if (queues) |queue_json| std.heap.page_allocator.free(queue_json);
                    const custom_lobby = if (std.mem.eql(u8, phase, "ChampSelect") or std.mem.eql(u8, phase, "ReadyCheck"))
                        client.get("/lol-lobby/v2/lobby") catch null
                    else
                        null;
                    defer if (custom_lobby) |custom_json| std.heap.page_allocator.free(custom_json);
                    if (std.mem.eql(u8, phase, "ChampSelect") or std.mem.eql(u8, phase, "ReadyCheck")) {
                        persistBpSnapshot(self, value, catalog orelse "[]");
                    }
                    const session_phase = if (isActiveLivePhase(phase) or !should_probe_live) phase else "InProgress";
                    const result = liveSessionEnvelopePhaseContext(self, client, value, custom_lobby, session_phase, current, catalog orelse "[]", queues orelse "[]", output, enrich) catch return error.LcuInvalidResponse;
                    if (std.mem.eql(u8, phase, "ChampSelect") or std.mem.eql(u8, phase, "ReadyCheck")) {
                        // Fast roster refreshes must not overwrite a richer
                        // enriched snapshot with the same ten placeholders.
                        const merged = mergeWithBestLiveCache(self, result, enrich, output) catch result;
                        cacheChampSelectLobby(self, merged);
                        return merged;
                    }
                    if (should_probe_live and lobbyRosterCount(result) < 10) {
                        // Gameflow can temporarily expose only the local
                        // participant. Prefer a fuller spectator roster, then
                        // the last owned snapshot from the same game.
                        for ([_][]const u8{
                            "/lol-spectator/v1/spectator/metadata",
                            "/lol-spectator/v1/spectator/game",
                        }) |endpoint| {
                            const spectator = client.get(endpoint) catch continue;
                            defer std.heap.page_allocator.free(spectator);
                            if (rawRosterCount(spectator) <= lobbyRosterCount(result)) continue;
                            const spectator_phase = if (isActiveLivePhase(phase)) phase else "WatchInProgress";
                            const spectator_result = liveSessionEnvelopePhaseContext(self, client, spectator, null, spectator_phase, current, catalog orelse "[]", queues orelse "[]", output, enrich) catch continue;
                            const merged = mergeWithBestLiveCache(self, spectator_result, enrich, output) catch spectator_result;
                            self.live_lobby_enriched = enrich;
                            cacheLiveLobby(self, merged);
                            return merged;
                        }
                        if (betterCachedLiveLobby(self, result, phase, enrich, output)) |cached| return cached;
                    }
                    const merged = mergeWithBestLiveCache(self, result, enrich, output) catch result;
                    self.live_lobby_enriched = enrich;
                    cacheLiveLobby(self, merged);
                    return merged;
                }
            }

            // Spectator clients expose their roster through a separate API;
            // gameflow may legally contain only game metadata.
            if (should_probe_live) for ([_][]const u8{
                "/lol-spectator/v1/spectator/metadata",
                "/lol-spectator/v1/spectator/game",
            }) |endpoint| {
                const spectator = client.get(endpoint) catch continue;
                defer std.heap.page_allocator.free(spectator);
                const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, spectator, .{}) catch continue;
                if (parsed != .object or !sessionHasRoster(parsed)) continue;
                const spectator_phase = if (isActiveLivePhase(phase)) phase else "WatchInProgress";
                const result = liveSessionEnvelopePhase(spectator, spectator_phase, current, output) catch continue;
                const merged = mergeWithBestLiveCache(self, result, false, output) catch result;
                self.live_lobby_enriched = false;
                cacheLiveLobby(self, merged);
                return merged;
            };

            if (self.live_lobby_len > 0) {
                return liveLobbyCacheWithPhase(self, phase, output) catch {
                    @memcpy(output[0..self.live_lobby_len], self.live_lobby[0..self.live_lobby_len]);
                    return output[0..self.live_lobby_len];
                };
            }
            if (isActiveLivePhase(phase) and self.champ_select_lobby_len > 0) {
                return liveLobbyCacheWithPhaseBuffer(self.champ_select_lobby[0..self.champ_select_lobby_len], phase, output) catch {
                    return copyJson(self.champ_select_lobby[0..self.champ_select_lobby_len], output);
                };
            }
            return error.LcuRequestFailed;
        }
        return error.LcuNotRunning;
    }
    _ = invocation;
    @memcpy(output[0..empty_lobby.len], empty_lobby);
    return output[0..empty_lobby.len];
}

fn isActiveLivePhase(phase: []const u8) bool {
    return std.mem.eql(u8, phase, "InProgress") or
        std.mem.eql(u8, phase, "GameStart") or
        std.mem.eql(u8, phase, "Reconnect") or
        std.mem.eql(u8, phase, "EndOfGame") or
        std.mem.eql(u8, phase, "PreEndOfGame") or
        std.mem.eql(u8, phase, "WaitingForStats") or
        std.mem.eql(u8, phase, "WatchInProgress") or
        std.mem.eql(u8, phase, "Spectating") or
        std.mem.eql(u8, phase, "Watching");
}

fn isChampSelectPhase(phase: []const u8) bool {
    return std.mem.eql(u8, phase, "ChampSelect") or std.mem.eql(u8, phase, "ReadyCheck");
}

fn observeLivePhase(self: *Runtime, phase: []const u8) void {
    const previous = self.last_live_phase[0..self.last_live_phase_len];
    if (isChampSelectPhase(phase)) {
        self.champ_select_handoff_active = false;
    } else if (isActiveLivePhase(phase) and isChampSelectPhase(previous)) {
        self.champ_select_handoff_active = true;
    } else if (!isActiveLivePhase(phase)) {
        self.champ_select_handoff_active = false;
    }
    const length = @min(phase.len, self.last_live_phase.len);
    @memcpy(self.last_live_phase[0..length], phase[0..length]);
    self.last_live_phase_len = length;
}

fn clearChampSelectLobby(self: *Runtime) void {
    self.champ_select_lobby_len = 0;
    self.champ_select_game_id = 0;
    self.champ_select_handoff_active = false;
}

fn clearLiveLobby(self: *Runtime) void {
    self.live_lobby_len = 0;
    self.live_roster_hash = 0;
    self.live_lobby_enriched = false;
}

fn invalidateMismatchedLobbyCaches(self: *Runtime, session_game_id: i64) void {
    if (session_game_id <= 0) return;
    if (self.live_lobby_len > 0) {
        const cached_game_id = lobbyGameId(self.live_lobby[0..self.live_lobby_len]);
        if (cached_game_id > 0 and cached_game_id != session_game_id) clearLiveLobby(self);
    }
    // ChampSelect and gameflow can expose different numeric IDs during the
    // hand-off. Keep the just-observed ten-player snapshot until a complete
    // in-game roster replaces it; outside that transition, an ID mismatch is
    // a real new game and the old snapshot must not leak into it.
    if (!self.champ_select_handoff_active and self.champ_select_lobby_len > 0 and
        self.champ_select_game_id > 0 and self.champ_select_game_id != session_game_id)
    {
        clearChampSelectLobby(self);
    }
}

fn shouldProbeLiveData(phase: []const u8) bool {
    return !std.mem.eql(u8, phase, "ChampSelect") and
        !std.mem.eql(u8, phase, "ReadyCheck");
}

fn rawRosterCount(value: []const u8) usize {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), value, .{}) catch return 0;
    if (parsed != .object) return 0;
    var team_count: usize = 0;
    if (sessionTeamValue(parsed, "teamOne", "ally")) |team| team_count += team.array.items.len;
    if (sessionTeamValue(parsed, "teamTwo", "enemy")) |team| team_count += team.array.items.len;
    var flat_count: usize = 0;
    if (sessionFlatRosterValue(parsed)) |flat| flat_count = flat.array.items.len;
    return @max(team_count, flat_count);
}

fn isSpectatorPhase(phase: []const u8) bool {
    return std.mem.eql(u8, phase, "WatchInProgress") or
        std.mem.eql(u8, phase, "Spectating") or
        std.mem.eql(u8, phase, "Watching");
}

fn lobbyIdsCompatible(left: []const u8, right: []const u8) bool {
    const left_id = lobbyGameId(left);
    const right_id = lobbyGameId(right);
    return left_id == 0 or right_id == 0 or left_id == right_id;
}

fn betterCachedLiveLobby(self: *const Runtime, candidate: []const u8, phase: []const u8, dynamic_enriched: bool, output: []u8) ?[]const u8 {
    const candidate_count = lobbyRosterCount(candidate);
    var best: ?[]const u8 = null;
    var best_count = candidate_count;
    if (self.live_lobby_len > 0) {
        const cached = self.live_lobby[0..self.live_lobby_len];
        const count = lobbyRosterCount(cached);
        if (count > best_count and lobbyIdsCompatible(candidate, cached)) {
            best = cached;
            best_count = count;
        }
    }
    if (self.champ_select_lobby_len > 0) {
        const cached = self.champ_select_lobby[0..self.champ_select_lobby_len];
        const count = lobbyRosterCount(cached);
        const handoff = self.champ_select_handoff_active and isActiveLivePhase(phase) and lobbyIsChampSelectSnapshot(cached);
        if ((count > best_count or (handoff and !dynamic_enriched and count == best_count)) and
            (lobbyIdsCompatible(candidate, cached) or handoff)) best = cached;
    }
    const cached = best orelse return null;
    return liveLobbyCacheWithPhaseBuffer(cached, phase, output) catch
        (copyJson(cached, output) catch return null);
}

fn profileArrayLen(value: std.json.Value, name: []const u8) usize {
    if (value != .object) return 0;
    const array = value.object.get(name) orelse return 0;
    return if (array == .array) array.array.items.len else 0;
}

fn profileIdentityQuality(value: std.json.Value) u8 {
    const puuid = identityPuuid(value);
    if (puuid.len == 0 or std.mem.indexOf(u8, puuid, "-slot-") != null) return 0;
    _ = std.fmt.parseInt(u64, puuid, 10) catch return 2;
    return 1;
}

fn profileHasKnownName(value: std.json.Value) bool {
    const name = jsonField(value, "gameName");
    if (name.len == 0 or std.mem.eql(u8, name, "未知玩家")) return false;
    return !std.mem.startsWith(u8, name, "蓝方玩家") and !std.mem.startsWith(u8, name, "红方玩家");
}

fn profileHasKnownPosition(value: std.json.Value) bool {
    const position = playerPosition(value);
    for ([_][]const u8{ "TOP", "JUNGLE", "MIDDLE", "MID", "BOTTOM", "BOT", "ADC", "UTILITY", "SUPPORT" }) |known| {
        if (std.ascii.eqlIgnoreCase(position, known)) return true;
    }
    return false;
}

fn arrayFieldHasItems(value: std.json.Value, name: []const u8) bool {
    if (value != .object) return false;
    const array = value.object.get(name) orelse return false;
    return array == .array and array.array.items.len > 0;
}

fn copyObjectField(target: *std.json.Value, source: std.json.Value, name: []const u8) void {
    if (target.* != .object or source != .object) return;
    const source_value = source.object.get(name) orelse return;
    const target_value = target.object.getPtr(name) orelse return;
    target_value.* = source_value;
}

fn overlayDynamicProfile(target: *std.json.Value, dynamic: std.json.Value) void {
    if (target.* != .object or dynamic != .object) return;
    if (profileIdentityQuality(dynamic) >= profileIdentityQuality(target.*)) copyObjectField(target, dynamic, "puuid");
    if (profileHasKnownName(dynamic)) copyObjectField(target, dynamic, "gameName");
    if (jsonField(dynamic, "tagLine").len > 0) copyObjectField(target, dynamic, "tagLine");
    if (jsonBool(dynamic, "isBot")) copyObjectField(target, dynamic, "isBot");
    if (jsonInt(dynamic, "championId") > 0) {
        copyObjectField(target, dynamic, "championId");
        copyObjectField(target, dynamic, "championName");
    }
    if (jsonInt(dynamic, "profileIconId") > 0) copyObjectField(target, dynamic, "profileIconId");
    if (profileHasKnownPosition(dynamic)) {
        if (jsonField(dynamic, "assignedPosition").len > 0) {
            copyObjectField(target, dynamic, "assignedPosition");
        } else if (target.object.getPtr("assignedPosition")) |assigned| {
            assigned.* = .{ .string = playerPosition(dynamic) };
        }
    }
    // Live Client can be the only source that still exposes summoner spells
    // after champ-select. Preserve that signal when enriching a cached
    // profile so Smite-based jungle targeting does not fall back to array
    // order on the next shortcut send.
    if (arrayFieldHasItems(dynamic, "summonerSpells")) copyObjectField(target, dynamic, "summonerSpells");
    if (arrayFieldHasItems(dynamic, "spells")) copyObjectField(target, dynamic, "spells");
    if (jsonBool(dynamic, "isPremade")) copyObjectField(target, dynamic, "isPremade");
    if (jsonField(dynamic, "premadeGroup").len > 0) copyObjectField(target, dynamic, "premadeGroup");
    if (!arrayFieldHasItems(target.*, "premadeWith") and arrayFieldHasItems(dynamic, "premadeWith")) copyObjectField(target, dynamic, "premadeWith");
    copyObjectField(target, dynamic, "side");
}

fn mergeLobbyProfile(base: std.json.Value, dynamic: std.json.Value, dynamic_enriched: bool) std.json.Value {
    const dynamic_complete = jsonBool(dynamic, "dataComplete") or arrayFieldHasItems(dynamic, "recentMatches");
    var merged = if (dynamic_enriched and dynamic_complete) dynamic else base;
    if (dynamic_enriched and dynamic_complete) {
        if (profileIdentityQuality(merged) < profileIdentityQuality(base)) copyObjectField(&merged, base, "puuid");
        if (!profileHasKnownName(merged) and profileHasKnownName(base)) copyObjectField(&merged, base, "gameName");
        if (jsonField(merged, "tagLine").len == 0) copyObjectField(&merged, base, "tagLine");
        if (jsonInt(merged, "championId") <= 0 and jsonInt(base, "championId") > 0) {
            copyObjectField(&merged, base, "championId");
            copyObjectField(&merged, base, "championName");
        }
        if (!profileHasKnownPosition(merged) and profileHasKnownPosition(base)) copyObjectField(&merged, base, "assignedPosition");
        if (!arrayFieldHasItems(merged, "summonerSpells") and arrayFieldHasItems(base, "summonerSpells")) copyObjectField(&merged, base, "summonerSpells");
        if (!arrayFieldHasItems(merged, "spells") and arrayFieldHasItems(base, "spells")) copyObjectField(&merged, base, "spells");
        if (jsonBool(base, "isPremade")) copyObjectField(&merged, base, "isPremade");
        if (jsonField(merged, "premadeGroup").len == 0 and jsonField(base, "premadeGroup").len > 0) copyObjectField(&merged, base, "premadeGroup");
        if (!arrayFieldHasItems(merged, "premadeWith") and arrayFieldHasItems(base, "premadeWith")) copyObjectField(&merged, base, "premadeWith");
        return merged;
    }
    overlayDynamicProfile(&merged, dynamic);
    return merged;
}

fn mergeLobbyTeam(allocator: std.mem.Allocator, base: std.json.Value, dynamic: *std.json.Value, dynamic_enriched: bool) !void {
    if (base != .array or dynamic.* != .array) return;

    // Rust keeps the richer topology as the primary array when the Live
    // Client response is sparse. Build that same primary array here and
    // overlay dynamic champion/identity fields onto matched seats. This is
    // important during GameStart/InProgress, where allPlayers can briefly
    // contain only the local participant.
    const live_is_topology = dynamic.array.items.len >= base.array.items.len;
    const primary = if (live_is_topology) dynamic.array.items else base.array.items;
    const fallback = if (live_is_topology) base.array.items else dynamic.array.items;
    var used: [16]bool = [_]bool{false} ** 16;
    var merged = std.json.Array.init(allocator);
    try merged.ensureTotalCapacity(primary.len);
    for (primary, 0..) |member, index| {
        var matched: ?usize = null;
        for (fallback, 0..) |candidate, candidate_index| {
            if (candidate_index >= used.len or used[candidate_index] or candidate != .object or member != .object) continue;
            if (livePlayerMatches(member, candidate) or sameRosterSlot(member, candidate)) {
                matched = candidate_index;
                break;
            }
        }
        if (matched == null and index < fallback.len and index < used.len) {
            const unresolved = !profileHasKnownName(member) or profileIdentityQuality(member) < 2;
            if (unresolved) matched = index;
        }
        if (matched) |fallback_index| {
            used[fallback_index] = true;
            const value = if (live_is_topology)
                mergeLobbyProfile(fallback[fallback_index], member, dynamic_enriched)
            else
                mergeLobbyProfile(member, fallback[fallback_index], dynamic_enriched);
            try merged.append(value);
        } else {
            try merged.append(member);
        }
    }
    dynamic.* = .{ .array = merged };
}

fn sameRosterSlot(left: std.json.Value, right: std.json.Value) bool {
    if (left != .object or right != .object) return false;
    const left_cell = if (left.object.get("cellId") != null) jsonInt(left, "cellId") else -1;
    const right_cell = if (right.object.get("cellId") != null) jsonInt(right, "cellId") else -1;
    if (left_cell >= 0 and right_cell >= 0 and left_cell == right_cell) return true;
    const left_champion = jsonInt(left, "championId");
    const right_champion = jsonInt(right, "championId");
    return left_champion > 0 and right_champion > 0 and left_champion == right_champion;
}

/// Merge a fresh topology with the last same-game profile snapshot. Fast
/// gameflow/live-client responses own champion, team and slot fields, while
/// the cached snapshot keeps rank/history data until enrichment catches up.
fn mergeLiveLobbySnapshots(base_json: []const u8, dynamic_json: []const u8, dynamic_enriched: bool, output: []u8) ![]const u8 {
    return mergeLiveLobbySnapshotsPolicy(base_json, dynamic_json, dynamic_enriched, false, output);
}

fn mergeLiveLobbySnapshotsPolicy(base_json: []const u8, dynamic_json: []const u8, dynamic_enriched: bool, allow_handoff_ids: bool, output: []u8) ![]const u8 {
    if (!allow_handoff_ids and !lobbyIdsCompatible(base_json, dynamic_json)) return copyJson(dynamic_json, output);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const base = std.json.parseFromSliceLeaky(std.json.Value, allocator, base_json, .{}) catch return error.LcuInvalidResponse;
    // Most callers produced the dynamic JSON directly in `output`; retain a
    // private copy before stringifying the merged tree back into that buffer.
    const dynamic_copy = try allocator.dupe(u8, dynamic_json);
    var dynamic = std.json.parseFromSliceLeaky(std.json.Value, allocator, dynamic_copy, .{}) catch return error.LcuInvalidResponse;
    if (base != .object or dynamic != .object) return error.LcuInvalidResponse;
    for ([_][]const u8{ "ally", "enemy" }) |name| {
        const base_team = base.object.get(name) orelse continue;
        const dynamic_team = dynamic.object.getPtr(name) orelse continue;
        try mergeLobbyTeam(allocator, base_team, dynamic_team, dynamic_enriched);
    }
    if (jsonInt(dynamic, "queueId") <= 0 and jsonInt(base, "queueId") > 0) copyObjectField(&dynamic, base, "queueId");
    const dynamic_mode = jsonField(dynamic, "gameMode");
    if (dynamic_mode.len == 0 or std.ascii.eqlIgnoreCase(dynamic_mode, "CLASS") or std.ascii.eqlIgnoreCase(dynamic_mode, "CLASSIC")) {
        if (jsonField(base, "gameMode").len > 0) copyObjectField(&dynamic, base, "gameMode");
    }
    if (dynamic.object.get("recentMatch")) |recent| if (recent == .null) copyObjectField(&dynamic, base, "recentMatch");
    if (dynamic.object.getPtr("teams")) |teams| if (teams.* == .array) {
        for (teams.array.items) |*team| {
            if (team.* != .object) continue;
            const side = jsonField(team.*, "side");
            const source_name = if (std.mem.eql(u8, side, "ally")) "ally" else if (std.mem.eql(u8, side, "enemy")) "enemy" else continue;
            if (dynamic.object.get(source_name)) |players| {
                if (team.object.getPtr("players")) |target| target.* = players;
            }
        }
    };
    var writer = std.Io.Writer.fixed(output);
    var stringify = std.json.Stringify{ .writer = &writer, .options = .{} };
    try stringify.write(dynamic);
    return writer.buffered();
}

fn mergeWithBestLiveCache(self: *const Runtime, candidate: []const u8, dynamic_enriched: bool, output: []u8) ![]const u8 {
    var best: ?[]const u8 = null;
    var best_count: usize = 0;
    if (self.live_lobby_len > 0) {
        const cached = self.live_lobby[0..self.live_lobby_len];
        if (lobbyIdsCompatible(candidate, cached)) {
            best = cached;
            best_count = lobbyRosterCount(cached);
        }
    }
    if (self.champ_select_lobby_len > 0) {
        const cached = self.champ_select_lobby[0..self.champ_select_lobby_len];
        const count = lobbyRosterCount(cached);
        const handoff = self.champ_select_handoff_active and lobbyIsActiveSnapshot(candidate) and lobbyIsChampSelectSnapshot(cached);
        if (count > best_count and (lobbyIdsCompatible(candidate, cached) or handoff)) best = cached;
    }
    const cached = best orelse return copyJson(candidate, output);
    const allow_handoff_ids = self.champ_select_handoff_active and lobbyIsActiveSnapshot(candidate) and lobbyIsChampSelectSnapshot(cached);
    return mergeLiveLobbySnapshotsPolicy(cached, candidate, dynamic_enriched, allow_handoff_ids, output);
}

fn cacheLiveLobby(self: *Runtime, value: []const u8) void {
    if (value.len > self.live_lobby.len) return;
    // Never let an empty or sparse transition response replace a useful
    // snapshot. The frontend can render the previous snapshot while LCU is
    // changing phases.
    if (self.live_lobby_len > 0 and lobbyRosterCount(value) < lobbyRosterCount(self.live_lobby[0..self.live_lobby_len])) {
        const previous_id = lobbyGameId(self.live_lobby[0..self.live_lobby_len]);
        const next_id = lobbyGameId(value);
        if (previous_id == 0 or next_id == 0 or previous_id == next_id) return;
    }
    @memcpy(self.live_lobby[0..value.len], value);
    self.live_lobby_len = value.len;
    if (self.storage) |*store| {
        store.put("liveLobby", "current", value) catch {};
        if (self.live_owner_puuid_len > 0) store.put("liveLobby", "ownerPuuid", self.live_owner_puuid[0..self.live_owner_puuid_len]) catch {};
    }
    if (self.champ_select_handoff_active and self.live_lobby_enriched and lobbyIsActiveSnapshot(value) and
        lobbyRosterCount(value) >= lobbyRosterCount(self.champ_select_lobby[0..self.champ_select_lobby_len]))
    {
        clearChampSelectLobby(self);
    }
}

fn cacheChampSelectLobby(self: *Runtime, value: []const u8) void {
    if (value.len > self.champ_select_lobby.len) return;
    if (self.champ_select_lobby_len > 0 and lobbyRosterCount(value) < lobbyRosterCount(self.champ_select_lobby[0..self.champ_select_lobby_len])) return;
    @memcpy(self.champ_select_lobby[0..value.len], value);
    self.champ_select_lobby_len = value.len;
    self.champ_select_game_id = lobbyGameId(value);
    if (self.storage) |*store| {
        store.put("liveLobby", "current", value) catch {};
        if (self.live_owner_puuid_len > 0) store.put("liveLobby", "ownerPuuid", self.live_owner_puuid[0..self.live_owner_puuid_len]) catch {};
    }
}

fn updateLiveLobbyOwner(self: *Runtime, current_json: ?[]const u8) void {
    const text = current_json orelse return;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const current = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), text, .{}) catch return;
    const puuid = identityPuuid(firstJsonValue(current));
    if (puuid.len == 0 or puuid.len > self.live_owner_puuid.len) return;
    if (self.live_owner_puuid_len == 0) {
        if (self.storage) |*store| {
            if (store.get("liveLobby", "ownerPuuid") catch null) |stored_owner| {
                defer std.heap.page_allocator.free(stored_owner);
                if (std.mem.eql(u8, stored_owner, puuid) and stored_owner.len <= self.live_owner_puuid.len) {
                    @memcpy(self.live_owner_puuid[0..stored_owner.len], stored_owner);
                    self.live_owner_puuid_len = stored_owner.len;
                    if (self.live_lobby_len == 0) if (store.get("liveLobby", "current") catch null) |stored_lobby| {
                        defer std.heap.page_allocator.free(stored_lobby);
                        if (stored_lobby.len <= self.live_lobby.len) {
                            @memcpy(self.live_lobby[0..stored_lobby.len], stored_lobby);
                            self.live_lobby_len = stored_lobby.len;
                            self.live_lobby_enriched = true;
                            if (lobbyIsChampSelectSnapshot(stored_lobby)) {
                                @memcpy(self.champ_select_lobby[0..stored_lobby.len], stored_lobby);
                                self.champ_select_lobby_len = stored_lobby.len;
                                self.champ_select_game_id = lobbyGameId(stored_lobby);
                                observeLivePhase(self, "ChampSelect");
                            }
                        }
                    };
                }
            }
        }
    }
    if (self.live_owner_puuid_len > 0 and !std.mem.eql(u8, self.live_owner_puuid[0..self.live_owner_puuid_len], puuid)) {
        clearLiveLobby(self);
        clearChampSelectLobby(self);
        self.last_live_phase_len = 0;
    }
    @memcpy(self.live_owner_puuid[0..puuid.len], puuid);
    self.live_owner_puuid_len = puuid.len;
    if (self.storage) |*store| store.put("liveLobby", "ownerPuuid", puuid) catch {};
}

fn lobbyRosterCount(value: []const u8) usize {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), value, .{}) catch return 0;
    if (parsed != .object) return 0;
    var count: usize = 0;
    for ([_][]const u8{ "ally", "enemy" }) |name| {
        if (parsed.object.get(name)) |team| {
            if (team == .array) count += team.array.items.len;
        }
    }
    return count;
}

fn lobbyPhaseMatches(value: []const u8, expected: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), value, .{}) catch return false;
    return parsed == .object and std.mem.eql(u8, jsonField(parsed, "phase"), expected);
}

fn lobbyIsChampSelectSnapshot(value: []const u8) bool {
    return lobbyPhaseMatches(value, "ChampSelect") or lobbyPhaseMatches(value, "ReadyCheck");
}

fn lobbyIsActiveSnapshot(value: []const u8) bool {
    inline for ([_][]const u8{
        "GameStart",       "InProgress",      "Reconnect",  "EndOfGame", "PreEndOfGame",
        "WaitingForStats", "WatchInProgress", "Spectating", "Watching",
    }) |phase| {
        if (lobbyPhaseMatches(value, phase)) return true;
    }
    return false;
}

fn lobbyGameId(value: []const u8) i64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), value, .{}) catch return 0;
    if (parsed != .object) return 0;
    const id = jsonInt(parsed, "id");
    if (id > 0) return id;
    const game_id = jsonInt(parsed, "gameId");
    if (game_id > 0) return game_id;
    if (nestedObject(parsed, "gameData")) |game_data| {
        const nested_game_id = jsonInt(game_data, "gameId");
        if (nested_game_id > 0) return nested_game_id;
    }
    return 0;
}

fn gameIdFromSessionJson(value: []const u8) i64 {
    return lobbyGameId(value);
}

fn liveLobbyCacheWithPhase(self: *const Runtime, phase: []const u8, output: []u8) ![]const u8 {
    return liveLobbyCacheWithPhaseBuffer(self.live_lobby[0..self.live_lobby_len], phase, output);
}

fn liveLobbyCacheWithPhaseBuffer(cached: []const u8, phase: []const u8, output: []u8) ![]const u8 {
    const marker = "\"phase\":";
    const marker_index = std.mem.indexOf(u8, cached, marker) orelse return error.InvalidCachedLobby;
    const value_start = marker_index + marker.len;
    if (value_start >= cached.len or cached[value_start] != '"') return error.InvalidCachedLobby;
    const value_end = std.mem.indexOfScalarPos(u8, cached, value_start + 1, '"') orelse return error.InvalidCachedLobby;
    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll(cached[0..value_start]);
    try jsonString(&writer, phase);
    try writer.writeAll(cached[value_end + 1 ..]);
    return writer.buffered();
}

fn sessionHasRoster(session: std.json.Value) bool {
    if (session != .object) return false;
    if (sessionTeamValue(session, "teamOne", "ally")) |team| if (team.array.items.len > 0) return true;
    if (sessionTeamValue(session, "teamTwo", "enemy")) |team| if (team.array.items.len > 0) return true;
    if (sessionFlatRosterValue(session)) |roster| if (roster.array.items.len > 0) return true;
    for ([_][]const u8{ "myTeam", "theirTeam", "teamOne", "teamTwo", "participants", "players", "playerRoster", "playerChampionSelections" }) |name| {
        if (session.object.get(name)) |value| if (arrayLike(value)) |array| if (array.array.items.len > 0) return true;
        if (nestedObject(session, "gameData")) |game_data| if (game_data.object.get(name)) |value| if (arrayLike(value)) |array| if (array.array.items.len > 0) return true;
    }
    return false;
}

fn getLiveRoster(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    // This command is polled immediately on LCU events. Return the roster
    // topology without the per-player rank/history lookups; the regular lobby
    // request enriches those cards in the background and the frontend merges
    // the two snapshots by PUUID.
    return getLiveLobbyInternal(context, invocation, output, false);
}

fn getMatches(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = runtime(context);
    if (self.mode == .live) {
        const request = parsePayload(struct { summonerName: ?[]const u8 = null, page: usize = 0, pageSize: usize = 20 }, invocation.request.payload) catch return error.InvalidRequest;
        const page_size = @max(@as(usize, 1), @min(request.pageSize, @as(usize, 100)));
        const offset = request.page * page_size;
        const explicit_subject = if (request.summonerName) |value| blk: {
            const trimmed = std.mem.trim(u8, value, " \t\r\n");
            break :blk if (trimmed.len > 0) trimmed else null;
        } else null;
        if (explicit_subject) |subject| {
            if (std.mem.indexOfScalar(u8, subject, '#') == null) return error.FullRiotIdRequired;
        }
        if (self.io) |io| {
            var client = discoverClient(self, io) catch {
                if (cachedMatchesPageForSubject(self, explicit_subject, offset, page_size, output)) |cached| return cached;
                return error.LcuNotRunning;
            };
            defer client.deinit();
            const me = client.get("/lol-summoner/v1/current-summoner") catch {
                if (cachedMatchesPageForSubject(self, explicit_subject, offset, page_size, output)) |cached| return cached;
                return error.LcuRequestFailed;
            };
            defer std.heap.page_allocator.free(me);
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const parsed_current = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), me, .{}) catch return error.LcuInvalidResponse;
            const current = firstJsonValue(parsed_current);
            if (current != .object) return error.LcuInvalidResponse;

            var target_owned: ?[]u8 = null;
            defer if (target_owned) |value| std.heap.page_allocator.free(value);
            var target = current;
            if (explicit_subject) |subject| {
                var encoded_buffer: [1536]u8 = undefined;
                const encoded = percentEncodeQuery(subject, &encoded_buffer) catch return error.InvalidRiotId;
                var target_path_buffer: [1792]u8 = undefined;
                const target_path = std.fmt.bufPrint(&target_path_buffer, "/lol-summoner/v1/summoners?name={s}", .{encoded}) catch return error.InvalidRiotId;
                target_owned = client.get(target_path) catch {
                    if (cachedMatchesPageForSubject(self, explicit_subject, offset, page_size, output)) |cached| return cached;
                    return error.SummonerLookupFailed;
                };
                const parsed_target = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), target_owned.?, .{}) catch return error.LcuInvalidResponse;
                target = firstJsonValue(parsed_target);
            }

            const puuid = identityPuuid(target);
            if (puuid.len > 0) {
                var path_buf: [512]u8 = undefined;
                // LCU caches the first window requested for a PUUID. Always
                // prime the complete history window and paginate the decoded
                // result locally; otherwise an early dashboard request can
                // pin every later page to one or three games.
                const path = std.fmt.bufPrint(&path_buf, "/lol-match-history/v1/products/lol/{s}/matches?begIndex=0&endIndex=49", .{puuid}) catch return error.LcuInvalidResponse;
                const lcu_history = client.get(path) catch {
                    if (cachedMatchesPageForSubject(self, explicit_subject, offset, page_size, output)) |cached| return cached;
                    return error.LcuRequestFailed;
                };
                defer std.heap.page_allocator.free(lcu_history);
                const sgp_history: ?[]u8 = fetchSgpHistory(client, current, lcu_history, puuid, 0, 50) catch null;
                defer if (sgp_history) |history| std.heap.page_allocator.free(history);
                const history = sgp_history orelse lcu_history;
                var cached_catalog: ?[]u8 = null;
                const champion_catalog = client.get("/lol-game-data/assets/v1/champion-summary.json") catch blk: {
                    if (self.storage) |*store| cached_catalog = store.get("cache", "champions") catch null;
                    break :blk null;
                };
                defer if (champion_catalog) |catalog| std.heap.page_allocator.free(catalog);
                defer if (cached_catalog) |catalog| std.heap.page_allocator.free(catalog);
                if (self.storage) |*store| {
                    // Do not replace a known-good snapshot with an empty
                    // gateway response during an entitlement or reconnect
                    // window. The next request can still use the old history
                    // while LCU/SGP recovers.
                    if (explicit_subject) |subject| {
                        if (historyHasGames(history)) store.put("playerHistory", puuid, history) catch {};
                        store.put("historySubject", subject, puuid) catch {};
                    } else {
                        if (historyHasGames(history)) store.put("matches", "current", history) catch {};
                        store.put("matches", "currentPuuid", puuid) catch {};
                    }
                }
                if (explicit_subject == null and historyHasGames(history)) persistEncountersFromHistory(self, history, puuid);
                const catalog_json = champion_catalog orelse cached_catalog orelse "[]";
                const dto = matchHistoryDtoPageFiltered(history, catalog_json, puuid, offset, page_size, runtimeHideUnfinishedMatches(self), output) catch |err| {
                    // A gateway response can be valid JSON but still use a
                    // shape the local DTO parser does not understand. Keep
                    // the LCU payload as a deterministic fallback.
                    if (sgp_history != null) return matchHistoryDtoPageFiltered(lcu_history, catalog_json, puuid, offset, page_size, runtimeHideUnfinishedMatches(self), output) catch return err;
                    return err;
                };
                if (dto.len > 2 or sgp_history == null or !historyHasGames(lcu_history)) {
                    if (dto.len <= 2) if (cachedMatchesPageForSubject(self, explicit_subject, offset, page_size, output)) |cached| return cached;
                    return dto;
                }
                // Treat an empty SGP page as unavailable. This is common
                // during an entitlement refresh and must not hide the LCU
                // history that is already available locally.
                return matchHistoryDtoPageFiltered(lcu_history, catalog_json, puuid, offset, page_size, runtimeHideUnfinishedMatches(self), output);
            }
        }
        if (cachedMatchesPageForSubject(self, explicit_subject, offset, page_size, output)) |cached| return cached;
        return error.LcuNotRunning;
    }
    return std.fmt.bufPrint(output, "[]", .{});
}

fn cachedMatchesPage(self: *Runtime, offset: usize, limit: usize, output: []u8) ?[]const u8 {
    return cachedMatchesPageForSubject(self, null, offset, limit, output);
}

fn cachedMatchesPageForSubject(self: *Runtime, subject: ?[]const u8, offset: usize, limit: usize, output: []u8) ?[]const u8 {
    const store = if (self.storage) |*value| value else return null;
    const mapped_puuid = if (subject) |value| (store.get("historySubject", value) catch return null) orelse return null else null;
    defer if (mapped_puuid) |value| std.heap.page_allocator.free(value);
    const history = if (mapped_puuid) |puuid|
        (store.get("playerHistory", puuid) catch return null) orelse return null
    else
        (store.get("matches", "current") catch return null) orelse return null;
    defer std.heap.page_allocator.free(history);
    const current_puuid = if (mapped_puuid == null) store.get("matches", "currentPuuid") catch null else null;
    const puuid: ?[]const u8 = mapped_puuid orelse current_puuid;
    defer if (current_puuid) |value| std.heap.page_allocator.free(value);
    const catalog = store.get("cache", "champions") catch null;
    defer if (catalog) |value| std.heap.page_allocator.free(value);
    return matchHistoryDtoPageFiltered(history, catalog orelse "[]", puuid orelse "", offset, limit, runtimeHideUnfinishedMatches(self), output) catch null;
}

const sgp_user_agent = "LeagueOfLegendsClient/15.0.0.0 (rcp-be-lol-match-history)";

fn fetchSgpHistory(client: lcu.Client, current: std.json.Value, lcu_history_json: []const u8, target_puuid: []const u8, start: usize, count: usize) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ranked_json = try client.get("/lol-ranked/v1/current-ranked-stats");
    defer std.heap.page_allocator.free(ranked_json);
    const ranked = std.json.parseFromSliceLeaky(std.json.Value, allocator, ranked_json, .{}) catch return error.LcuInvalidResponse;
    const lcu_history = std.json.parseFromSliceLeaky(std.json.Value, allocator, lcu_history_json, .{}) catch return error.LcuInvalidResponse;
    const platform_id = firstPlatformId(&.{ current, ranked, lcu_history });
    const host = sgpHost(platform_id) orelse return error.UnsupportedRegion;
    if (target_puuid.len == 0) return error.LcuInvalidResponse;

    const entitlement_json = try client.get("/entitlements/v1/token");
    defer std.heap.page_allocator.free(entitlement_json);
    const entitlement = std.json.parseFromSliceLeaky(std.json.Value, allocator, entitlement_json, .{}) catch return error.LcuInvalidResponse;
    const token = jsonField(entitlement, "accessToken");
    if (token.len == 0) return error.LcuInvalidResponse;

    var url_buffer: [2048]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "https://{s}/match-history-query/v1/products/lol/player/{s}/SUMMARY?startIndex={d}&count={d}", .{ host, target_puuid, start, count });
    return client.getBearerUrl(url, token, sgp_user_agent);
}

fn sgpHost(platform_id: []const u8) ?[]const u8 {
    const normalized = if (std.ascii.startsWithIgnoreCase(platform_id, "TENCENT_")) platform_id[8..] else platform_id;
    if (std.ascii.eqlIgnoreCase(normalized, "HN1")) return "hn1-k8s-sgp.lol.qq.com:21019";
    if (std.ascii.eqlIgnoreCase(normalized, "HN10")) return "hn10-k8s-sgp.lol.qq.com:21019";
    if (std.ascii.eqlIgnoreCase(normalized, "NJ100")) return "nj100-sgp.lol.qq.com:21019";
    if (std.ascii.eqlIgnoreCase(normalized, "GZ100")) return "gz100-sgp.lol.qq.com:21019";
    if (std.ascii.eqlIgnoreCase(normalized, "CQ100")) return "cq100-sgp.lol.qq.com:21019";
    if (std.ascii.eqlIgnoreCase(normalized, "TJ100")) return "tj100-sgp.lol.qq.com:21019";
    if (std.ascii.eqlIgnoreCase(normalized, "TJ101")) return "tj101-sgp.lol.qq.com:21019";
    if (std.ascii.eqlIgnoreCase(normalized, "BGP2")) return "bgp2-k8s-sgp.lol.qq.com:21019";
    return null;
}

fn getChampions(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = runtime(context);
    _ = invocation;
    if (self.mode == .live) {
        if (self.io) |io| {
            var client = discoverClient(self, io) catch {
                if (self.storage) |*store| if (store.get("cache", "champions") catch null) |cached| {
                    defer std.heap.page_allocator.free(cached);
                    const stats = store.get("cache", "opgg-ranked-emerald-plus") catch null;
                    defer if (stats) |value| std.heap.page_allocator.free(value);
                    const updated_seconds = store.getUpdatedAt("cache", "opgg-ranked-emerald-plus") catch null;
                    const fetched_at = (updated_seconds orelse 0) * std.time.ms_per_s;
                    const expires_at = fetched_at + runtimeCacheTtlMillis(self);
                    const stale = stats != null and runtimeNowMillis(self) > expires_at;
                    return champion_mapper.dtoWithStats(cached, stats, .{
                        .source = if (stale) "sqlite-stale" else "sqlite-fresh",
                        .stats_source = if (stats != null) "sqlite" else "unavailable",
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
                cached_stats = store.get("cache", "opgg-ranked-emerald-plus") catch null;
                cached_at = ((store.getUpdatedAt("cache", "opgg-ranked-emerald-plus") catch null) orelse 0) * std.time.ms_per_s;
            }
            if (cached_stats) |value| if (!champion_mapper.hasRankedStats(value)) {
                std.heap.page_allocator.free(value);
                cached_stats = null;
                cached_at = 0;
            };
            const now = runtimeNowMillis(self);
            const ttl = runtimeCacheTtlMillis(self);
            const cache_fresh = cached_stats != null and cached_at > 0 and now <= cached_at + ttl;
            var fetched_stats: ?[]u8 = null;
            defer if (fetched_stats) |value| std.heap.page_allocator.free(value);
            var fetch_failed = false;
            if (!cache_fresh) {
                fetched_stats = client.getPublicUrl("https://lol-api-champion.op.gg/api/global/champions/ranked?tier=emerald_plus", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) lol-desktop-native/2.0") catch blk: {
                    fetch_failed = true;
                    break :blk null;
                };
                if (fetched_stats) |stats| {
                    if (champion_mapper.hasRankedStats(stats)) {
                        if (self.storage) |*store| store.put("cache", "opgg-ranked-emerald-plus", stats) catch {};
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

fn getAsset(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = runtime(context);
    const payload = parsePayload(struct { kind: []const u8 = "", id: i64 = 0 }, invocation.request.payload) catch return error.InvalidAsset;
    if (payload.id <= 0) return error.InvalidAsset;
    const kind = assetKind(payload.kind) orelse return error.InvalidAsset;
    if (self.io) |io| {
        var client = discoverClient(self, io) catch return communityDragonAsset(kind, payload.id, output);
        defer client.deinit();
        const bytes = fetchLcuAsset(client, kind, payload.id) catch return communityDragonAsset(kind, payload.id, output);
        defer std.heap.page_allocator.free(bytes);
        return assetDataDto(kind, payload.id, bytes, output);
    }
    return communityDragonAsset(kind, payload.id, output);
}

const AssetKind = enum { champion, item, spell, perk, profile };

fn assetKind(value: []const u8) ?AssetKind {
    return std.meta.stringToEnum(AssetKind, value);
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
        if (entry != .object or jsonInt(entry, "id") != id) continue;
        const icon_path = jsonField(entry, "iconPath");
        if (icon_path.len == 0 or !std.mem.startsWith(u8, icon_path, "/")) return error.AssetNotFound;
        return client.get(icon_path);
    }
    return error.AssetNotFound;
}

fn assetDataDto(kind: AssetKind, id: i64, bytes: []const u8, output: []u8) ![]const u8 {
    const is_jpeg = bytes.len >= 3 and bytes[0] == 0xff and bytes[1] == 0xd8 and bytes[2] == 0xff;
    const is_png = bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n");
    if (!is_jpeg and !is_png) return error.AssetNotFound;
    const mime = if (is_jpeg) "image/jpeg" else "image/png";
    const prefix = try std.fmt.bufPrint(output, "{{\"kind\":\"{s}\",\"id\":{d},\"mimeType\":\"{s}\",\"dataUrl\":\"data:{s};base64,", .{ @tagName(kind), id, mime, mime });
    const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
    const suffix = "\",\"source\":\"lcu\"}";
    if (prefix.len + encoded_len + suffix.len > output.len) return error.ResponseTooLarge;
    _ = std.base64.standard.Encoder.encode(output[prefix.len..][0..encoded_len], bytes);
    @memcpy(output[prefix.len + encoded_len ..][0..suffix.len], suffix);
    return output[0 .. prefix.len + encoded_len + suffix.len];
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
    return std.fmt.bufPrint(output, "{{\"kind\":\"{s}\",\"id\":{d},\"mimeType\":\"{s}\",\"dataUrl\":\"https://raw.communitydragon.org/latest/plugins/rcp-be-lol-game-data/global/default/v1/{s}/{d}.{s}\",\"source\":\"communitydragon\"}}", .{ @tagName(kind), id, mime, folder, id, extension });
}

fn encounterArchiveResponse(self: *Runtime, archive: []const u8, target_puuid: []const u8, max_games: usize, output: []u8) ?[]const u8 {
    var owner: ?[]u8 = null;
    if (self.storage) |*store| owner = store.get("matches", "currentPuuid") catch null;
    defer if (owner) |value| std.heap.page_allocator.free(value);
    var cutoff_buffer: [64]u8 = undefined;
    var cutoff_writer = std.Io.Writer.fixed(&cutoff_buffer);
    const now = runtimeNowMillis(self);
    if (now > encounter_retention_ms) writeIsoTimestamp(&cutoff_writer, now - encounter_retention_ms) catch return null;
    var limit = max_games;
    while (limit > 0) {
        if (encounter_service.queryArchive(archive, owner orelse "", target_puuid, cutoff_writer.buffered(), limit, output)) |response| {
            return response;
        } else |_| {
            // The Native bridge owns a fixed response buffer. Preserve whole
            // matches and reduce the page size instead of emitting partial JSON.
            if (limit == 1) return null;
            limit = @max(limit / 2, 1);
        }
    }
    return null;
}

fn cachedEncounterResponse(self: *Runtime, target_puuid: []const u8, max_games: usize, output: []u8) ?[]const u8 {
    const buffer = std.heap.page_allocator.alloc(u8, 1024 * 1024) catch return null;
    defer std.heap.page_allocator.free(buffer);
    const derived = cachedEncountersFromMatches(self, buffer) orelse return null;
    return encounterArchiveResponse(self, derived, target_puuid, max_games, output);
}

fn getEncounters(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = runtime(context);
    const payload = parsePayload(struct { puuid: ?[]const u8 = null, limitGames: i64 = 100 }, invocation.request.payload) catch return error.InvalidRequest;
    const target_puuid = payload.puuid orelse "";
    const max_games: usize = @intCast(std.math.clamp(payload.limitGames, @as(i64, 1), @as(i64, 100)));
    // A previous native build wrote an empty encounter snapshot before the
    // first live history request completed. Treat an empty snapshot as a
    // miss, otherwise the homepage can remain blank forever after that first
    // failed request. Live mode always refreshes from LCU first and only uses
    // a non-empty snapshot as a fallback.
    var cached: ?[]u8 = null;
    if (self.storage) |*store| cached = store.get("history", "encounters") catch null;
    defer if (cached) |value| std.heap.page_allocator.free(value);
    if (self.io) |io| {
        if (std.Io.Dir.cwd().readFileAlloc(io, self.encountersPath(), std.heap.page_allocator, .limited(4 * 1024 * 1024))) |value| {
            if (value.len > 2) {
                if (cached == null) cached = value else std.heap.page_allocator.free(value);
            } else {
                std.heap.page_allocator.free(value);
            }
        } else |_| {}
        if (self.mode == .live) {
            if (discoverClient(self, io)) |client_value| {
                var client = client_value;
                defer client.deinit();
                const me = client.get("/lol-summoner/v1/current-summoner") catch {
                    if (cachedEncounterResponse(self, target_puuid, max_games, output)) |derived| return derived;
                    if (cached) |value| if (value.len > 2) return encounterArchiveResponse(self, value, target_puuid, max_games, output) orelse std.fmt.bufPrint(output, "[]", .{});
                    return std.fmt.bufPrint(output, "[]", .{});
                };
                defer std.heap.page_allocator.free(me);
                var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer arena.deinit();
                const me_value = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), me, .{}) catch return error.LcuInvalidResponse;
                const puuid = if (me_value == .object) jsonField(me_value, "puuid") else "";
                if (puuid.len > 0) {
                    if (self.storage) |*store| store.put("matches", "currentPuuid", puuid) catch {};
                    var history_path: [512]u8 = undefined;
                    const path = std.fmt.bufPrint(&history_path, "/lol-match-history/v1/products/lol/{s}/matches?begIndex=0&endIndex=20", .{puuid}) catch return error.LcuInvalidResponse;
                    const lcu_history: ?[]u8 = client.get(path) catch null;
                    defer if (lcu_history) |history| std.heap.page_allocator.free(history);
                    const sgp_history: ?[]u8 = fetchSgpHistory(client, me_value, lcu_history orelse "{}", puuid, 0, 20) catch null;
                    defer if (sgp_history) |history| std.heap.page_allocator.free(history);
                    const history = preferredHistory(lcu_history, sgp_history) orelse {
                        if (cachedEncounterResponse(self, target_puuid, max_games, output)) |derived| return derived;
                        if (cached) |value| if (value.len > 2) return encounterArchiveResponse(self, value, target_puuid, max_games, output) orelse std.fmt.bufPrint(output, "[]", .{});
                        return std.fmt.bufPrint(output, "[]", .{});
                    };
                    if (self.storage) |*store| {
                        store.put("matches", "current", history) catch {};
                        store.put("matches", "currentPuuid", puuid) catch {};
                    }
                    const encounter_catalog = if (self.storage) |*store| store.get("cache", "champions") catch null else null;
                    defer if (encounter_catalog) |value| std.heap.page_allocator.free(value);
                    const derived_buffer = std.heap.page_allocator.alloc(u8, 1024 * 1024) catch return error.ResponseTooLarge;
                    defer std.heap.page_allocator.free(derived_buffer);
                    const derived = encounter_service.fromHistory(history, puuid, encounter_catalog orelse "[]", derived_buffer) catch return error.LcuInvalidResponse;
                    if (derived.len > 2) {
                        _ = updateEncounterArchive(self, derived, null);
                        if (self.storage) |*store| {
                            const latest = store.get("history", "encounters") catch null;
                            defer if (latest) |value| std.heap.page_allocator.free(value);
                            if (latest) |archive| if (encounterArchiveResponse(self, archive, target_puuid, max_games, output)) |response| return response;
                        }
                        return encounterArchiveResponse(self, derived, target_puuid, max_games, output) orelse std.fmt.bufPrint(output, "[]", .{});
                    }
                    if (cachedEncounterResponse(self, target_puuid, max_games, output)) |fallback| return fallback;
                    if (cached) |value| if (value.len > 2) return encounterArchiveResponse(self, value, target_puuid, max_games, output) orelse std.fmt.bufPrint(output, "[]", .{});
                    return std.fmt.bufPrint(output, "[]", .{});
                }
            } else |_| {}
        }
    }
    if (cachedEncounterResponse(self, target_puuid, max_games, output)) |derived| return derived;
    if (cached) |value| if (value.len > 2) return encounterArchiveResponse(self, value, target_puuid, max_games, output) orelse std.fmt.bufPrint(output, "[]", .{});
    return std.fmt.bufPrint(output, "[]", .{});
}

fn getFriends(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = runtime(context);
    _ = invocation;
    if (self.mode != .live) return std.fmt.bufPrint(output, "{{\"groups\":[],\"friends\":[]}}", .{});
    const io = self.io orelse return error.LcuNotRunning;
    var client = discoverClient(self, io) catch return error.LcuNotRunning;
    defer client.deinit();
    const groups_json = client.get("/lol-chat/v1/friend-groups") catch return error.LcuRequestFailed;
    defer std.heap.page_allocator.free(groups_json);
    const friends_json = client.get("/lol-chat/v1/friends") catch return error.LcuRequestFailed;
    defer std.heap.page_allocator.free(friends_json);
    const giftable_json = client.get("/lol-store/v1/giftablefriends") catch null;
    defer if (giftable_json) |value| std.heap.page_allocator.free(value);
    return friendToolsDto(self, groups_json, friends_json, giftable_json orelse "[]", output);
}

fn friendToolsDto(self: *Runtime, groups_json: []const u8, friends_json: []const u8, giftable_json: []const u8, output: []u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const groups = std.json.parseFromSliceLeaky(std.json.Value, allocator, groups_json, .{}) catch return error.LcuInvalidResponse;
    const friends = std.json.parseFromSliceLeaky(std.json.Value, allocator, friends_json, .{}) catch return error.LcuInvalidResponse;
    const giftable = std.json.parseFromSliceLeaky(std.json.Value, allocator, giftable_json, .{}) catch std.json.Value{ .null = {} };
    if (groups != .array or friends != .array) return error.LcuInvalidResponse;
    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll("{\"groups\":[");
    var first = true;
    for (groups.array.items) |group| {
        if (group != .object) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.print("{{\"id\":{d},\"name\":", .{jsonInt(group, "id")});
        try jsonString(&writer, jsonField(group, "name"));
        try writer.print(",\"priority\":{d}}}", .{jsonInt(group, "priority")});
    }
    try writer.writeAll("],\"friends\":[");
    first = true;
    for (friends.array.items) |friend| {
        if (friend != .object) continue;
        const id = jsonField(friend, "id");
        const puuid = jsonField(friend, "puuid");
        if (id.len == 0 or puuid.len == 0) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.writeAll("{\"id\":");
        try jsonString(&writer, id);
        try writer.writeAll(",\"puuid\":");
        try jsonString(&writer, puuid);
        try writer.print(",\"summonerId\":{d},\"gameName\":", .{jsonInt(friend, "summonerId")});
        try jsonString(&writer, if (jsonField(friend, "gameName").len > 0) jsonField(friend, "gameName") else jsonField(friend, "name"));
        try writer.writeAll(",\"gameTag\":");
        try jsonString(&writer, jsonField(friend, "gameTag"));
        try writer.print(",\"icon\":{d},\"groupId\":{d},\"availability\":", .{ jsonInt(friend, "icon"), jsonInt(friend, "groupId") });
        try jsonString(&writer, jsonField(friend, "availability"));
        try writer.writeAll(",\"friendsSince\":");
        if (giftableFriendSince(giftable, jsonInt(friend, "summonerId"))) |since| try jsonString(&writer, since) else try writer.writeAll("null");
        try writer.writeAll(",\"lastGameAt\":");
        if (cachedFriendLastGame(self, puuid)) |cached| {
            defer std.heap.page_allocator.free(cached);
            const cached_value = std.json.parseFromSliceLeaky(std.json.Value, allocator, cached, .{}) catch std.json.Value{ .null = {} };
            const last_game = jsonField(cached_value, "lastGameAt");
            if (last_game.len > 0) try jsonString(&writer, last_game) else try writer.writeAll("null");
        } else try writer.writeAll("null");
        try writer.writeByte('}');
    }
    try writer.writeAll("]}");
    return writer.buffered();
}

fn giftableFriendSince(giftable: std.json.Value, summoner_id: i64) ?[]const u8 {
    if (giftable != .array or summoner_id <= 0) return null;
    for (giftable.array.items) |friend| if (jsonInt(friend, "summonerId") == summoner_id) {
        const value = jsonField(friend, "friendsSince");
        if (value.len > 0) return value;
    };
    return null;
}

fn cachedFriendLastGame(self: *Runtime, puuid: []const u8) ?[]u8 {
    const store = if (self.storage) |*value| value else return null;
    return store.get("friendLastGame", puuid) catch null;
}

fn getFriendLastGame(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = runtime(context);
    const payload = parsePayload(struct { puuid: []const u8 = "", force: bool = false }, invocation.request.payload) catch return error.InvalidRequest;
    if (payload.puuid.len == 0) return error.InvalidRequest;
    if (!payload.force) if (self.storage) |*store| {
        const updated_at = store.getUpdatedAt("friendLastGame", payload.puuid) catch null;
        const now_seconds = @divTrunc(runtimeNowMillis(self), std.time.ms_per_s);
        if (updated_at != null and now_seconds - updated_at.? < 6 * std.time.s_per_hour) if (cachedFriendLastGame(self, payload.puuid)) |cached| {
            defer std.heap.page_allocator.free(cached);
            return copyJson(cached, output);
        };
    };
    if (self.mode != .live) return friendLastGameDto(payload.puuid, "[]", output);
    const io = self.io orelse return error.LcuNotRunning;
    var client = discoverClient(self, io) catch return error.LcuNotRunning;
    defer client.deinit();
    var path_buffer: [768]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "/lol-match-history/v1/products/lol/{s}/matches?begIndex=0&endIndex=0", .{payload.puuid}) catch return error.InvalidRequest;
    const lcu_history = client.get(path) catch null;
    defer if (lcu_history) |value| std.heap.page_allocator.free(value);
    var history = lcu_history orelse "{}";
    var sgp_history: ?[]u8 = null;
    defer if (sgp_history) |value| std.heap.page_allocator.free(value);
    if (!historyHasGames(history)) {
        const current_json = client.get("/lol-summoner/v1/current-summoner") catch null;
        defer if (current_json) |value| std.heap.page_allocator.free(value);
        if (current_json) |value| {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const current = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), value, .{}) catch std.json.Value{ .null = {} };
            sgp_history = fetchSgpHistory(client, current, history, payload.puuid, 0, 1) catch null;
            if (sgp_history) |sgp| {
                if (historyHasGames(sgp)) history = sgp;
            }
        }
    }
    const result = try friendLastGameDto(payload.puuid, history, output);
    if (self.storage) |*store| store.put("friendLastGame", payload.puuid, result) catch {};
    return result;
}

fn friendLastGameDto(puuid: []const u8, history_json: []const u8, output: []u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), history_json, .{}) catch std.json.Value{ .null = {} };
    const list = historyGames(root);
    var timestamp: i64 = 0;
    if (list) |games| if (games.array.items.len > 0) {
        const game = unwrapHistoryGame(arena.allocator(), games.array.items[0]) orelse std.json.Value{ .null = {} };
        timestamp = if (jsonInt(game, "gameCreation") > 0) jsonInt(game, "gameCreation") else jsonInt(game, "gameStartTimestamp");
    };
    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll("{\"puuid\":");
    try jsonString(&writer, puuid);
    try writer.writeAll(",\"lastGameAt\":");
    if (timestamp > 0) try writeIsoTimestamp(&writer, timestamp) else try writer.writeAll("null");
    try writer.writeByte('}');
    return writer.buffered();
}

fn historyGames(root: std.json.Value) ?std.json.Value {
    if (root == .array) return root;
    if (root != .object) return null;
    const games = root.object.get("games") orelse return null;
    if (games == .array) return games;
    if (games == .object) {
        const nested = games.object.get("games") orelse return null;
        return if (nested == .array) nested else null;
    }
    return null;
}

fn unwrapHistoryGame(allocator: std.mem.Allocator, entry: std.json.Value) ?std.json.Value {
    if (entry != .object) return null;
    const payload = entry.object.get("json") orelse return entry;
    return switch (payload) {
        .object => payload,
        .string => |encoded| std.json.parseFromSliceLeaky(std.json.Value, allocator, encoded, .{}) catch null,
        else => entry,
    };
}

fn deleteFriend(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = runtime(context);
    const payload = parsePayload(struct { id: []const u8 = "" }, invocation.request.payload) catch return error.InvalidRequest;
    if (self.mode != .live or payload.id.len == 0 or std.mem.indexOfScalar(u8, payload.id, '/') != null) return error.InvalidRequest;
    const io = self.io orelse return error.LcuNotRunning;
    var client = discoverClient(self, io) catch return error.LcuNotRunning;
    defer client.deinit();
    var path_buffer: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "/lol-chat/v1/friends/{s}", .{payload.id}) catch return error.InvalidRequest;
    const response = client.delete(path) catch return error.LcuRequestFailed;
    defer std.heap.page_allocator.free(response);
    return std.fmt.bufPrint(output, "{{\"deleted\":true}}", .{});
}

fn cachedEncountersFromMatches(self: *Runtime, output: []u8) ?[]const u8 {
    const store = if (self.storage) |*value| value else return null;
    const history = (store.get("matches", "current") catch return null) orelse return null;
    defer std.heap.page_allocator.free(history);
    const puuid = (store.get("matches", "currentPuuid") catch return null) orelse return null;
    defer std.heap.page_allocator.free(puuid);
    const catalog = store.get("cache", "champions") catch null;
    defer if (catalog) |value| std.heap.page_allocator.free(value);
    const derived = encounter_service.fromHistory(history, puuid, catalog orelse "[]", output) catch return null;
    if (derived.len > 2) return updateEncounterArchive(self, derived, output) orelse derived;
    return derived;
}

fn persistEncountersFromHistory(self: *Runtime, history: []const u8, puuid: []const u8) void {
    const buffer = std.heap.page_allocator.alloc(u8, 1024 * 1024) catch return;
    defer std.heap.page_allocator.free(buffer);
    const catalog = if (self.storage) |*store| store.get("cache", "champions") catch null else null;
    defer if (catalog) |value| std.heap.page_allocator.free(value);
    const derived = encounter_service.fromHistory(history, puuid, catalog orelse "[]", buffer) catch return;
    if (derived.len > 2) _ = updateEncounterArchive(self, derived, null);
}

fn updateEncounterArchive(self: *Runtime, newest: []const u8, output: ?[]u8) ?[]const u8 {
    const store = if (self.storage) |*value| value else return null;
    const existing = store.get("history", "encounters") catch null;
    defer if (existing) |value| std.heap.page_allocator.free(value);
    var cutoff_buffer: [64]u8 = undefined;
    var cutoff_writer = std.Io.Writer.fixed(&cutoff_buffer);
    const now = runtimeNowMillis(self);
    if (now > encounter_retention_ms) writeIsoTimestamp(&cutoff_writer, now - encounter_retention_ms) catch return null;
    const merged_buffer = std.heap.page_allocator.alloc(u8, 4 * 1024 * 1024) catch return null;
    defer std.heap.page_allocator.free(merged_buffer);
    const owner = store.get("matches", "currentPuuid") catch null;
    defer if (owner) |value| std.heap.page_allocator.free(value);
    const merged = encounter_service.mergeArchive(existing orelse "[]", newest, owner orelse "", cutoff_writer.buffered(), merged_buffer) catch return null;
    store.put("history", "encounters", merged) catch return null;
    const destination = output orelse return null;
    if (merged.len > destination.len) return null;
    @memcpy(destination[0..merged.len], merged);
    return destination[0..merged.len];
}

fn mergeEncounterArchive(existing_json: []const u8, newest_json: []const u8, cutoff_iso: []const u8, output: []u8) ![]const u8 {
    return encounter_service.mergeArchive(existing_json, newest_json, "", cutoff_iso, output);
}

fn encountersFromHistory(json: []const u8, self_puuid: []const u8, output: []u8) ![]const u8 {
    return encounter_service.fromHistory(json, self_puuid, "[]", output);
}

fn persistBpSnapshot(self: *Runtime, session_json: []const u8, catalog_json: []const u8) void {
    const store = if (self.storage) |*value| value else return;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const session = std.json.parseFromSliceLeaky(std.json.Value, allocator, session_json, .{}) catch return;
    const catalog = std.json.parseFromSliceLeaky(std.json.Value, allocator, catalog_json, .{}) catch std.json.Value{ .null = {} };
    if (session != .object) return;
    var record: [16 * 1024]u8 = undefined;
    var record_writer = std.Io.Writer.fixed(&record);
    const now_millis: i64 = if (self.io) |io| @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms)) else 0;
    if (!(tryRecord(&record_writer, session, catalog, now_millis) catch return)) return;
    const record_json = record_writer.buffered();
    const record_value = std.json.parseFromSliceLeaky(std.json.Value, allocator, record_json, .{}) catch return;
    const record_id = jsonField(record_value, "id");
    var combined: [64 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&combined);
    writer.writeByte('[') catch return;
    writer.writeAll(record_json) catch return;
    var count: usize = 1;
    if (store.get("history", "bp") catch null) |previous| {
        defer std.heap.page_allocator.free(previous);
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, previous, .{}) catch null;
        if (parsed != null and parsed.? == .array) for (parsed.?.array.items) |item| {
            if (count >= 50 or item != .object or std.mem.eql(u8, jsonField(item, "id"), record_id)) continue;
            writer.writeByte(',') catch return;
            var stringify = std.json.Stringify{ .writer = &writer, .options = .{} };
            stringify.write(item) catch return;
            count += 1;
        };
    }
    writer.writeByte(']') catch return;
    store.put("history", "bp", writer.buffered()) catch {};
}

fn tryRecord(writer: *std.Io.Writer, session: std.json.Value, catalog: std.json.Value, now_millis: i64) !bool {
    const ally = session.object.get("myTeam");
    const enemy = session.object.get("theirTeam");
    if (!completeChampionTeam(ally) or !completeChampionTeam(enemy)) return false;
    try writer.writeAll("{\"id\":");
    const game_data = nestedObject(session, "gameData") orelse std.json.Value{ .null = {} };
    const game_id = if (jsonInt(session, "gameId") > 0) jsonInt(session, "gameId") else jsonInt(game_data, "gameId");
    if (game_id > 0) {
        try writer.print("\"{d}\"", .{game_id});
    } else {
        try writer.writeAll("\"champ-select\"");
    }
    const queue = nestedObject(game_data, "queue") orelse std.json.Value{ .null = {} };
    const queue_id = if (jsonInt(session, "queueId") > 0) jsonInt(session, "queueId") else if (jsonInt(game_data, "queueId") > 0) jsonInt(game_data, "queueId") else jsonInt(queue, "id");
    const raw_mode = if (jsonField(session, "gameMode").len > 0) jsonField(session, "gameMode") else if (jsonField(game_data, "gameMode").len > 0) jsonField(game_data, "gameMode") else if (jsonField(queue, "gameMode").len > 0) jsonField(queue, "gameMode") else "League of Legends";
    try writer.print(",\"queueId\":{d},\"gameMode\":", .{queue_id});
    try jsonString(writer, queueName(queue_id, raw_mode));
    try writer.writeAll(",\"allyChampionIds\":");
    try writeChampionIds(writer, ally);
    try writer.writeAll(",\"allyChampions\":");
    try writeChampionNames(writer, ally, catalog);
    try writer.writeAll(",\"enemyChampionIds\":");
    try writeChampionIds(writer, enemy);
    try writer.writeAll(",\"enemyChampions\":");
    try writeChampionNames(writer, enemy, catalog);
    try writer.writeAll(",\"allyScore\":0,\"enemyScore\":0,\"aiSummary\":null,\"createdAt\":");
    try writeIsoTimestamp(writer, now_millis);
    try writer.writeByte('}');
    return true;
}

fn completeChampionTeam(value: ?std.json.Value) bool {
    const team = value orelse return false;
    if (team != .array or team.array.items.len == 0) return false;
    for (team.array.items) |participant| if (participant == .object and selectedChampionId(participant) <= 0) return false else if (participant != .object) return false;
    return true;
}

fn writeChampionIds(writer: *std.Io.Writer, value: ?std.json.Value) !void {
    try writer.writeByte('[');
    if (value) |array| if (array == .array) {
        var first = true;
        for (array.array.items) |participant| {
            if (participant != .object) continue;
            const id = selectedChampionId(participant);
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.print("{d}", .{id});
        }
    };
    try writer.writeByte(']');
}

fn writeChampionNames(writer: *std.Io.Writer, value: ?std.json.Value, catalog: std.json.Value) !void {
    try writer.writeByte('[');
    if (value) |array| if (array == .array) {
        var first = true;
        for (array.array.items) |participant| {
            if (participant != .object) continue;
            const id = selectedChampionId(participant);
            if (id <= 0) continue;
            if (!first) try writer.writeByte(',');
            first = false;
            try jsonString(writer, catalogChampionName(catalog, id, "未知英雄"));
        }
    };
    try writer.writeByte(']');
}

fn bpChampionIds(record: std.json.Value, field: []const u8) ?std.json.Value {
    if (record != .object) return null;
    const ids = record.object.get(field) orelse return null;
    if (ids != .array or ids.array.items.len == 0) return null;
    for (ids.array.items) |id| {
        const numeric = switch (id) {
            .integer => |value| value,
            .float => |value| @as(i64, @intFromFloat(value)),
            else => 0,
        };
        if (numeric <= 0) return null;
    }
    return ids;
}

fn writeBpChampionNames(writer: *std.Io.Writer, ids: std.json.Value, names: ?std.json.Value, catalog: std.json.Value) !void {
    try writer.writeByte('[');
    for (ids.array.items, 0..) |id_value, index| {
        if (index > 0) try writer.writeByte(',');
        const champion_id = switch (id_value) {
            .integer => |value| value,
            .float => |value| @as(i64, @intFromFloat(value)),
            else => 0,
        };
        var recorded_name: []const u8 = "";
        if (names) |array| if (array == .array and index < array.array.items.len) {
            const name = array.array.items[index];
            if (name == .string) recorded_name = std.mem.trim(u8, name.string, " \t\r\n");
        };
        const catalog_name = catalogChampionName(catalog, champion_id, recorded_name);
        if (catalog_name.len > 0 and !std.mem.eql(u8, catalog_name, "未知英雄")) {
            try jsonString(writer, catalog_name);
        } else {
            var fallback: [48]u8 = undefined;
            try jsonString(writer, try std.fmt.bufPrint(&fallback, "英雄 #{d}", .{champion_id}));
        }
    }
    try writer.writeByte(']');
}

fn writeNormalizedBpRecord(writer: *std.Io.Writer, record: std.json.Value, ally_ids: std.json.Value, enemy_ids: std.json.Value, catalog: std.json.Value) !void {
    const id = jsonField(record, "id");
    const queue_id = jsonInt(record, "queueId");
    try writer.writeAll("{\"id\":");
    try jsonString(writer, id);
    try writer.print(",\"queueId\":{d},\"gameMode\":", .{queue_id});
    try jsonString(writer, queueName(queue_id, jsonField(record, "gameMode")));
    try writer.writeAll(",\"allyChampionIds\":");
    var stringify = std.json.Stringify{ .writer = writer, .options = .{} };
    try stringify.write(ally_ids);
    try writer.writeAll(",\"allyChampions\":");
    try writeBpChampionNames(writer, ally_ids, record.object.get("allyChampions"), catalog);
    try writer.writeAll(",\"enemyChampionIds\":");
    stringify = .{ .writer = writer, .options = .{} };
    try stringify.write(enemy_ids);
    try writer.writeAll(",\"enemyChampions\":");
    try writeBpChampionNames(writer, enemy_ids, record.object.get("enemyChampions"), catalog);
    try writer.print(",\"allyScore\":{d},\"enemyScore\":{d},\"aiSummary\":", .{ jsonFloat(record, "allyScore"), jsonFloat(record, "enemyScore") });
    if (record.object.get("aiSummary")) |summary| {
        stringify = .{ .writer = writer, .options = .{} };
        try stringify.write(summary);
    } else try writer.writeAll("null");
    try writer.writeAll(",\"createdAt\":");
    const created_at = jsonField(record, "createdAt");
    try jsonString(writer, if (created_at.len > 0) created_at else "1970-01-01T00:00:00.000Z");
    try writer.writeByte('}');
}

/// Upgrade the early snapshot format at the read boundary. Those builds wrote
/// the same partial ChampSelect record repeatedly and left champion names
/// empty. Keep valid picks, recover names from the cached catalog, and expose
/// at most one record for each real game without deleting the user's DB.
fn normalizeBpHistory(history_json: []const u8, catalog_json: []const u8, output: []u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const history = std.json.parseFromSliceLeaky(std.json.Value, allocator, history_json, .{}) catch return error.LcuInvalidResponse;
    const catalog = std.json.parseFromSliceLeaky(std.json.Value, allocator, catalog_json, .{}) catch std.json.Value{ .null = {} };
    if (history != .array) return error.LcuInvalidResponse;
    var seen_ids: [50][]const u8 = undefined;
    var seen_count: usize = 0;
    var writer = std.Io.Writer.fixed(output);
    try writer.writeByte('[');
    var count: usize = 0;
    for (history.array.items) |record| {
        if (count >= 50 or record != .object) break;
        const id = jsonField(record, "id");
        const ally_ids = bpChampionIds(record, "allyChampionIds") orelse continue;
        const enemy_ids = bpChampionIds(record, "enemyChampionIds") orelse continue;
        if (id.len == 0) continue;
        var duplicate = false;
        for (seen_ids[0..seen_count]) |seen| if (std.mem.eql(u8, seen, id)) {
            duplicate = true;
            break;
        };
        if (duplicate) continue;
        seen_ids[seen_count] = id;
        seen_count += 1;
        if (count > 0) try writer.writeByte(',');
        try writeNormalizedBpRecord(&writer, record, ally_ids, enemy_ids, catalog);
        count += 1;
    }
    try writer.writeByte(']');
    return writer.buffered();
}

fn getBpHistory(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = runtime(context);
    _ = invocation;
    if (self.storage) |*store| if (store.get("history", "bp") catch null) |value| {
        defer std.heap.page_allocator.free(value);
        const catalog = store.get("cache", "champions") catch null;
        defer if (catalog) |json| std.heap.page_allocator.free(json);
        const normalized = try normalizeBpHistory(value, catalog orelse "[]", output);
        if (!std.mem.eql(u8, normalized, value)) store.put("history", "bp", normalized) catch {};
        return normalized;
    };
    if (self.io) |io| {
        if (std.Io.Dir.cwd().readFileAlloc(io, self.bpHistoryPath(), std.heap.page_allocator, .limited(output.len))) |value| {
            defer std.heap.page_allocator.free(value);
            var catalog: ?[]u8 = null;
            if (self.storage) |*store| catalog = store.get("cache", "champions") catch null;
            defer if (catalog) |json| std.heap.page_allocator.free(json);
            const normalized = try normalizeBpHistory(value, catalog orelse "[]", output);
            if (self.storage) |*store| store.put("history", "bp", normalized) catch {};
            return normalized;
        } else |_| {}
    }
    return std.fmt.bufPrint(output, "[]", .{});
}

fn saveMatchExport(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = runtime(context);
    const payload = parsePayload(struct { gameId: i64 = 0, format: []const u8 = "json", content: []const u8 = "" }, invocation.request.payload) catch return error.InvalidExport;
    if (self.io) |io| {
        var export_dir: [512]u8 = undefined;
        const export_path = native_sdk.app_dirs.join(native_sdk.app_dirs.currentPlatform(), &export_dir, &.{ self.dataDir(), "exports" }) catch return error.ExportFailed;
        std.Io.Dir.cwd().createDirPath(io, export_path) catch return error.ExportFailed;
        var file_name: [64]u8 = undefined;
        const file_name_value = std.fmt.bufPrint(&file_name, "{d}.{s}", .{ payload.gameId, payload.format }) catch return error.InvalidExport;
        var path_buf: [path_capacity]u8 = undefined;
        const path = native_sdk.app_dirs.join(native_sdk.app_dirs.currentPlatform(), &path_buf, &.{ export_path, file_name_value }) catch return error.InvalidExport;
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = payload.content }) catch return error.ExportFailed;
        var writer = std.Io.Writer.fixed(output);
        jsonString(&writer, path) catch return error.ExportFailed;
        return writer.buffered();
    }
    return std.fmt.bufPrint(output, "\"\"", .{});
}

fn resolveShortcutLobby(self: *Runtime, context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) ![]const u8 {
    var best: ?[]const u8 = null;
    var best_count: usize = 0;
    if (self.live_lobby_len > 0) {
        const cached = self.live_lobby[0..self.live_lobby_len];
        best = cached;
        best_count = lobbyRosterCount(cached);
    }
    if (self.champ_select_lobby_len > 0) {
        const cached = self.champ_select_lobby[0..self.champ_select_lobby_len];
        const count = lobbyRosterCount(cached);
        const handoff = self.champ_select_handoff_active and lobbyIsChampSelectSnapshot(cached);
        if (count > best_count and (best == null or lobbyIdsCompatible(best.?, cached) or handoff)) {
            best = cached;
            best_count = count;
        }
    }
    if (best != null and best_count > 0) return best.?;
    return getLiveLobbyInternal(context, invocation, output, true);
}

fn sendShortcut(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = runtime(context);
    const payload = parsePayload(struct { shortcutId: []const u8 = "", premadeSide: ?[]const u8 = null }, invocation.request.payload) catch return error.InvalidShortcut;
    if (self.mode != .live) {
        if (shortcutUsesEncounter(self, payload.shortcutId)) return std.fmt.bufPrint(output, "[]", .{});
        return shortcut_service.buildLines(
            self.config[0..self.config_len],
            payload.shortcutId,
            empty_lobby,
            if (self.mode == .replay) "Replay" else "Fixture",
            .{ .sample_when_empty = true },
            output,
        );
    }
    if (self.io) |io| {
        var client = discoverClient(self, io) catch return error.LcuNotRunning;
        defer client.deinit();
        const phase_json = client.get("/lol-gameflow/v1/gameflow-phase") catch return error.LcuRequestFailed;
        defer std.heap.page_allocator.free(phase_json);
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const phase_value = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), phase_json, .{}) catch return error.LcuInvalidResponse;
        const phase = if (phase_value == .string) phase_value.string else "Unknown";
        const lobby_buffer = std.heap.page_allocator.alloc(u8, live_lobby_capacity) catch return error.ShortcutUnavailable;
        defer std.heap.page_allocator.free(lobby_buffer);
        var lobby_json = resolveShortcutLobby(self, context, invocation, lobby_buffer) catch return error.ShortcutUnavailable;
        // A champ-select snapshot commonly has no summoner-spell fields. For
        // jungle-aware shortcuts, refresh the lightweight live roster before
        // rendering so Smite detection cannot fall back to an old first-slot
        // snapshot after the game has started.
        var fresh_jungle_lobby: ?[]u8 = null;
        var fresh_jungle_merged: ?[]u8 = null;
        defer if (fresh_jungle_lobby) |value| std.heap.page_allocator.free(value);
        defer if (fresh_jungle_merged) |value| std.heap.page_allocator.free(value);
        if (shortcutUsesJungleTemplate(self, payload.shortcutId)) {
            fresh_jungle_lobby = std.heap.page_allocator.alloc(u8, live_lobby_capacity) catch null;
            if (fresh_jungle_lobby) |buffer| {
                if (getLiveLobbyInternal(context, invocation, buffer, false)) |fresh| {
                    if (lobbyRosterCount(fresh) >= lobbyRosterCount(lobby_json)) {
                        // Keep the enriched snapshot's spell/position fields
                        // when the fast response only contains slot and
                        // champion data. Replacing equal-sized arrays here
                        // was the last path that made jungle targeting fall
                        // back to the first player.
                        fresh_jungle_merged = std.heap.page_allocator.alloc(u8, live_lobby_capacity) catch null;
                        if (fresh_jungle_merged) |merged_buffer| {
                            lobby_json = mergeLiveLobbySnapshots(lobby_json, fresh, false, merged_buffer) catch fresh;
                        } else {
                            lobby_json = fresh;
                        }
                    }
                } else |_| {}
            }
        }
        const analyzed_lobby_buffer = std.heap.page_allocator.alloc(u8, live_lobby_capacity) catch return error.ShortcutUnavailable;
        defer std.heap.page_allocator.free(analyzed_lobby_buffer);
        const shortcut_lobby = prepareJungleShortcutLobby(self, client, payload.shortcutId, lobby_json, analyzed_lobby_buffer) catch lobby_json;
        var lines_buffer: [128 * 1024]u8 = undefined;
        const lines_json = if (shortcutUsesEncounter(self, payload.shortcutId)) blk: {
            const archive = if (self.storage) |*store| store.get("history", "encounters") catch null else null;
            defer if (archive) |value| std.heap.page_allocator.free(value);
            const owner = if (self.storage) |*store| store.get("matches", "currentPuuid") catch null else null;
            defer if (owner) |value| std.heap.page_allocator.free(value);
            break :blk shortcut_service.buildEncounterLinesOwned(archive orelse "[]", shortcut_lobby, owner orelse "", &lines_buffer) catch return error.InvalidShortcut;
        } else shortcut_service.buildLines(self.config[0..self.config_len], payload.shortcutId, shortcut_lobby, phase, .{ .premade_side = payload.premadeSide }, &lines_buffer) catch return error.InvalidShortcut;
        const lines = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), lines_json, .{}) catch return error.InvalidShortcut;
        if (lines != .array or lines.array.items.len == 0) return error.ShortcutUnavailable;
        const cfg = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), self.config[0..self.config_len], .{}) catch return error.InvalidConfig;
        const interval_ms = std.math.clamp(configAutomationInt(cfg, "shortcutSendIntervalMs", 250), @as(i64, 250), @as(i64, 5000));
        if (std.mem.eql(u8, phase, "InProgress") or std.mem.eql(u8, phase, "GameStart")) {
            native_input.sendChatLines(io, lines, interval_ms) catch |err| return err;
            return copyJson(lines_json, output);
        }
        if (!std.mem.eql(u8, phase, "ChampSelect") and !std.mem.eql(u8, phase, "ReadyCheck")) return error.ShortcutUnavailable;
        const conversations_json = client.get("/lol-chat/v1/conversations") catch return error.LcuRequestFailed;
        defer std.heap.page_allocator.free(conversations_json);
        const conversations = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), conversations_json, .{}) catch return error.LcuInvalidResponse;
        const conversation_id = findConversationId(conversations, "championSelect") orelse return error.ChatUnavailable;
        var response = std.Io.Writer.fixed(output);
        try response.writeByte('[');
        var first = true;
        for (lines.array.items) |line| {
            if (line != .string or line.string.len == 0) continue;
            if (!first) {
                try response.writeByte(',');
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(interval_ms), .awake) catch {};
            }
            var body: [32 * 1024]u8 = undefined;
            var body_writer = std.Io.Writer.fixed(&body);
            try body_writer.writeAll("{\"body\":");
            try jsonString(&body_writer, line.string);
            try body_writer.writeAll(",\"type\":\"chat\"}");
            const body_json = body_writer.buffered();
            var endpoint: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&endpoint, "/lol-chat/v1/conversations/{s}/messages", .{conversation_id}) catch return error.ResponseTooLarge;
            const sent = client.post(path, body_json) catch return error.LcuRequestFailed;
            std.heap.page_allocator.free(sent);
            try jsonString(&response, line.string);
            first = false;
        }
        try response.writeByte(']');
        return response.buffered();
    }
    return error.LcuNotRunning;
}

fn shortcutUsesJungleTemplate(self: *Runtime, shortcut_id: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const config = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), self.config[0..self.config_len], .{}) catch return false;
    const automation = configAutomation(config) orelse return false;
    const shortcuts = automation.object.get("shortcuts") orelse return false;
    if (shortcuts != .array) return false;
    for (shortcuts.array.items) |shortcut| {
        if (shortcut != .object or !std.mem.eql(u8, jsonField(shortcut, "id"), shortcut_id)) continue;
        return std.mem.indexOf(u8, jsonField(shortcut, "template"), "{jungle_preference}") != null;
    }
    return false;
}

fn shortcutUsesEncounter(self: *Runtime, shortcut_id: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const config = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), self.config[0..self.config_len], .{}) catch return false;
    const automation = configAutomation(config) orelse return false;
    const shortcuts = automation.object.get("shortcuts") orelse return false;
    if (shortcuts != .array) return false;
    for (shortcuts.array.items) |shortcut| {
        if (shortcut != .object or !std.mem.eql(u8, jsonField(shortcut, "id"), shortcut_id)) continue;
        return std.mem.eql(u8, jsonField(shortcut, "target"), "encounter");
    }
    return false;
}

fn runAutomation(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = runtime(context);
    _ = invocation;
    const io = self.io orelse return error.LcuNotRunning;
    // This handler is allowed to run without the bridge worker's global
    // command lock. Take a coherent config snapshot before the network work
    // so save_config can proceed while ReadyCheck or champion-select is
    // waiting on LCU.
    var config_snapshot: [65536]u8 = undefined;
    var config_len: usize = 0;
    lockBackendMutex(&self.command_mutex);
    if (self.mode != .live) {
        self.command_mutex.unlock();
        return std.fmt.bufPrint(output, "[]", .{});
    }
    config_len = self.config_len;
    @memcpy(config_snapshot[0..config_len], self.config[0..config_len]);
    self.command_mutex.unlock();

    lockBackendMutex(&self.automation_mutex);
    defer self.automation_mutex.unlock();
    const client = self.ensureAutomationClient(io, config_snapshot[0..config_len]) catch return error.LcuNotRunning;
    return automation_service.run(io, client.*, config_snapshot[0..config_len], output) catch |err| {
        if (isAutomationClientFailure(err)) self.dropAutomationClient();
        return err;
    };
}

fn previewShortcut(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = runtime(context);
    const payload = parsePayload(struct { shortcutId: []const u8 = "" }, invocation.request.payload) catch return error.InvalidShortcut;
    const lobby_buffer = std.heap.page_allocator.alloc(u8, live_lobby_capacity) catch return error.ShortcutUnavailable;
    defer std.heap.page_allocator.free(lobby_buffer);
    var client_value: ?lcu.Client = null;
    defer if (client_value) |*client| client.deinit();
    const lobby_json = if (self.mode == .live) blk: {
        const raw = resolveShortcutLobby(self, context, invocation, lobby_buffer) catch return error.ShortcutUnavailable;
        const io = self.io orelse break :blk raw;
        client_value = discoverClient(self, io) catch break :blk raw;
        break :blk raw;
    } else empty_lobby;
    const analyzed_lobby_buffer = std.heap.page_allocator.alloc(u8, live_lobby_capacity) catch return error.ShortcutUnavailable;
    defer std.heap.page_allocator.free(analyzed_lobby_buffer);
    const shortcut_lobby = if (client_value) |client|
        prepareJungleShortcutLobby(self, client, payload.shortcutId, lobby_json, analyzed_lobby_buffer) catch lobby_json
    else
        lobby_json;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const lobby = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), shortcut_lobby, .{}) catch return error.InvalidShortcut;
    const phase = if (jsonField(lobby, "phase").len > 0) jsonField(lobby, "phase") else if (self.mode == .replay) "Replay" else "Fixture";
    if (shortcutUsesEncounter(self, payload.shortcutId)) {
        const archive = if (self.storage) |*store| store.get("history", "encounters") catch null else null;
        defer if (archive) |value| std.heap.page_allocator.free(value);
        const owner = if (self.storage) |*store| store.get("matches", "currentPuuid") catch null else null;
        defer if (owner) |value| std.heap.page_allocator.free(value);
        return shortcut_service.buildEncounterLinesOwned(archive orelse "[]", shortcut_lobby, owner orelse "", output);
    }
    return shortcut_service.buildLines(
        self.config[0..self.config_len],
        payload.shortcutId,
        shortcut_lobby,
        phase,
        .{ .require_enabled = false, .sample_when_empty = self.mode != .live },
        output,
    );
}

const JungleSgpContext = struct {
    host: []const u8,
    platform_id: []const u8,
    token: []const u8,
};

fn prepareJungleShortcutLobby(self: *Runtime, client: lcu.Client, shortcut_id: []const u8, lobby_json: []const u8, output: []u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const config = std.json.parseFromSliceLeaky(std.json.Value, allocator, self.config[0..self.config_len], .{}) catch return error.InvalidConfig;
    const automation = configAutomation(config) orelse return lobby_json;
    const shortcuts = if (automation.object.get("shortcuts")) |value| if (value == .array) value else return lobby_json else return lobby_json;
    var target: []const u8 = "";
    var uses_jungle = false;
    for (shortcuts.array.items) |shortcut| {
        if (shortcut != .object or !std.mem.eql(u8, jsonField(shortcut, "id"), shortcut_id)) continue;
        const template = jsonField(shortcut, "template");
        const configured_target = jsonField(shortcut, "target");
        target = if (std.mem.eql(u8, shortcut_id, "jungle-preference") or
            (std.mem.eql(u8, configured_target, "custom") and std.mem.indexOf(u8, template, "{jungle_preference}") != null))
            "jungle"
        else
            configured_target;
        uses_jungle = std.mem.indexOf(u8, template, "{jungle_preference}") != null;
        break;
    }
    if (!uses_jungle) return lobby_json;

    var lobby = std.json.parseFromSliceLeaky(std.json.Value, allocator, lobby_json, .{}) catch return error.LcuInvalidResponse;
    if (lobby != .object) return lobby_json;
    const sgp_context = prepareJungleSgpContext(self, client, allocator);
    if (std.mem.eql(u8, target, "ally") or std.mem.eql(u8, target, "lobby") or std.mem.eql(u8, target, "jungle") or std.mem.eql(u8, target, "custom")) {
        // A missing SGP detail for one side must not discard the other side's
        // already-rendered jungle preference. Each player gets fallback text
        // from the local aggregate when the remote detail request fails.
        analyzeJungleShortcutTeam(self, client, sgp_context, &lobby, "ally", target, allocator) catch {};
    }
    if (std.mem.eql(u8, target, "enemy") or std.mem.eql(u8, target, "lobby") or std.mem.eql(u8, target, "jungle")) {
        analyzeJungleShortcutTeam(self, client, sgp_context, &lobby, "enemy", target, allocator) catch {};
    }
    var writer = std.Io.Writer.fixed(output);
    var stringify = std.json.Stringify{ .writer = &writer, .options = .{} };
    try stringify.write(lobby);
    return writer.buffered();
}

fn prepareJungleSgpContext(self: *Runtime, client: lcu.Client, allocator: std.mem.Allocator) ?JungleSgpContext {
    const connection = std.json.parseFromSliceLeaky(std.json.Value, allocator, self.connection[0..self.connection_len], .{}) catch std.json.Value{ .null = {} };
    var platform_id = firstPlatformId(&.{connection});
    if (platform_id.len == 0) {
        const current_json = client.get("/lol-summoner/v1/current-summoner") catch return null;
        defer std.heap.page_allocator.free(current_json);
        const current = std.json.parseFromSliceLeaky(std.json.Value, allocator, current_json, .{}) catch return null;
        platform_id = firstPlatformId(&.{current});
    }
    const host = sgpHost(platform_id) orelse return null;
    const entitlement_json = client.get("/entitlements/v1/token") catch return null;
    defer std.heap.page_allocator.free(entitlement_json);
    const entitlement = std.json.parseFromSliceLeaky(std.json.Value, allocator, entitlement_json, .{}) catch return null;
    const token = jsonField(entitlement, "accessToken");
    if (token.len == 0) return null;
    const normalized_platform = if (std.ascii.startsWithIgnoreCase(platform_id, "TENCENT_")) platform_id[8..] else platform_id;
    return .{
        .host = allocator.dupe(u8, host) catch return null,
        .platform_id = allocator.dupe(u8, normalized_platform) catch return null,
        .token = allocator.dupe(u8, token) catch return null,
    };
}

fn analyzeJungleShortcutTeam(
    self: *Runtime,
    client: lcu.Client,
    sgp_context: ?JungleSgpContext,
    lobby: *std.json.Value,
    field: []const u8,
    target: []const u8,
    allocator: std.mem.Allocator,
) !void {
    const players = if (lobby.* == .object) lobby.object.getPtr(field) orelse return else return;
    if (players.* != .array) return;
    // Prefer Smite whenever the team payload exposes it. Position values are
    // often stale during the transition into gameflow and can point at the
    // first roster seat even though another player owns the jungle loadout.
    var smite_count: usize = 0;
    for (players.array.items) |candidate| {
        if (candidate == .object and shortcut_service.hasSmitePlayer(candidate)) smite_count += 1;
    }
    const use_smite = smite_count > 0;
    for (players.array.items, 0..) |player_value, index| {
        if (player_value != .object) continue;
        if (std.mem.eql(u8, target, "jungle")) {
            if (use_smite) {
                if (!shortcut_service.hasSmitePlayer(player_value)) continue;
            } else if (!playerIsJungle(player_value)) continue;
        }
        if (std.mem.eql(u8, target, "custom") and index > 0) break;
        const puuid = jsonField(player_value, "puuid");
        const champion_id = jsonInt(player_value, "championId");
        var aggregate = jungle_analysis.Aggregate{};
        if (puuid.len > 0 and champion_id > 0) if (player_value.object.get("recentMatches")) |matches| if (matches == .array) {
            var analyzed: usize = 0;
            for (matches.array.items) |match| {
                if (analyzed == 10) break;
                if (match != .object or jsonInt(match, "gameId") <= 0 or jsonInt(match, "championId") != champion_id or !isJunglePosition(jsonField(match, "position"))) continue;
                if (addJungleGameDetails(self, client, sgp_context, &aggregate, jsonInt(match, "gameId"), puuid)) analyzed += 1;
            }
        };
        var text_buffer: [4096]u8 = undefined;
        var text_writer = std.Io.Writer.fixed(&text_buffer);
        try aggregate.writeText(&text_writer, champion_id > 0);
        const text_copy = try allocator.dupe(u8, text_writer.buffered());
        try players.array.items[index].object.put(allocator, "jungleShortcutText", .{ .string = text_copy });
    }
}

fn addJungleGameDetails(self: *Runtime, client: lcu.Client, sgp_context: ?JungleSgpContext, aggregate: *jungle_analysis.Aggregate, game_id: i64, puuid: []const u8) bool {
    var key_buffer: [32]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buffer, "{d}", .{game_id}) catch return false;
    if (self.storage) |*store| if (store.get("jungleDetails", key) catch null) |cached| {
        defer std.heap.page_allocator.free(cached);
        if (aggregate.addDetails(cached, puuid)) return true;
    };
    if (sgp_context) |sgp| {
        var url_buffer: [2048]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buffer, "https://{s}/match-history-query/v1/products/lol/{s}_{d}/DETAILS", .{ sgp.host, sgp.platform_id, game_id }) catch "";
        if (url.len > 0) {
            const details = client.getBearerUrl(url, sgp.token, sgp_user_agent) catch null;
            if (details) |value| {
                defer std.heap.page_allocator.free(value);
                if (aggregate.addDetails(value, puuid)) {
                    if (self.storage) |*store| store.put("jungleDetails", key, value) catch {};
                    return true;
                }
            }
        }
    }

    var timeline_path_buffer: [256]u8 = undefined;
    const timeline_path = std.fmt.bufPrint(&timeline_path_buffer, "/lol-match-history/v1/game-timelines/{d}", .{game_id}) catch return false;
    const timeline = client.get(timeline_path) catch return false;
    defer std.heap.page_allocator.free(timeline);
    var game_path_buffer: [256]u8 = undefined;
    const game_path = std.fmt.bufPrint(&game_path_buffer, "/lol-match-history/v1/games/{d}", .{game_id}) catch return false;
    const game_json = client.get(game_path) catch return false;
    defer std.heap.page_allocator.free(game_json);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const game = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), game_json, .{}) catch return false;
    const participants = if (game == .object) game.object.get("participants") orelse return false else return false;
    const participant = participantForPuuid(game, participants, puuid);
    const participant_id = jsonInt(participant, "participantId");
    return aggregate.addTimeline(timeline, participant_id);
}

fn enrichRecentGankMetrics(self: *Runtime, client: lcu.Client, sgp_context: ?JungleSgpContext, recent_json: []const u8, puuid: []const u8, output: []u8) !?[]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = std.json.parseFromSliceLeaky(std.json.Value, allocator, recent_json, .{}) catch return null;
    if (root != .array) return null;

    var inspected: usize = 0;
    var samples: usize = 0;
    for (root.array.items) |*match| {
        if (inspected >= 5 or samples >= 3) break;
        if (match.* != .object or jsonInt(match.*, "gameId") <= 0 or
            jsonInt(match.*, "durationMinutes") <= 0 or
            isJunglePosition(jsonField(match.*, "position"))) continue;
        inspected += 1;
        const metric = earlyDeathGankMetric(self, client, sgp_context, jsonInt(match.*, "gameId"), puuid) orelse continue;
        try match.object.put(allocator, "earlyDeathsWithEnemyJungler", .{ .integer = @intCast(metric) });
        samples += 1;
    }
    if (samples == 0) return null;

    var writer = std.Io.Writer.fixed(output);
    var stringify = std.json.Stringify{ .writer = &writer, .options = .{} };
    try stringify.write(root);
    return writer.buffered();
}

fn earlyDeathGankMetric(self: *Runtime, client: lcu.Client, sgp_context: ?JungleSgpContext, game_id: i64, puuid: []const u8) ?usize {
    var metric_key_buffer: [256]u8 = undefined;
    const metric_key = std.fmt.bufPrint(&metric_key_buffer, "{d}:{s}", .{ game_id, puuid }) catch return null;
    if (self.storage) |*store| if (store.get("gankMetric", metric_key) catch null) |cached| {
        defer std.heap.page_allocator.free(cached);
        const value = std.mem.trim(u8, cached, " \t\r\n");
        if (std.fmt.parseUnsigned(usize, value, 10) catch null) |metric| return metric;
    };

    var details_key_buffer: [32]u8 = undefined;
    const details_key = std.fmt.bufPrint(&details_key_buffer, "{d}", .{game_id}) catch return null;
    if (self.storage) |*store| if (store.get("jungleDetails", details_key) catch null) |cached| {
        defer std.heap.page_allocator.free(cached);
        if (jungle_analysis.earlyDeathsFromDetails(cached, puuid)) |metric| {
            cacheGankMetric(self, metric_key, metric);
            return metric;
        }
    };

    if (sgp_context) |sgp| {
        var url_buffer: [2048]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buffer, "https://{s}/match-history-query/v1/products/lol/{s}_{d}/DETAILS", .{ sgp.host, sgp.platform_id, game_id }) catch "";
        if (url.len > 0) if (client.getBearerUrl(url, sgp.token, sgp_user_agent) catch null) |details| {
            defer std.heap.page_allocator.free(details);
            if (jungle_analysis.earlyDeathsFromDetails(details, puuid)) |metric| {
                if (self.storage) |*store| store.put("jungleDetails", details_key, details) catch {};
                cacheGankMetric(self, metric_key, metric);
                return metric;
            }
        };
    }

    var timeline_path_buffer: [256]u8 = undefined;
    const timeline_path = std.fmt.bufPrint(&timeline_path_buffer, "/lol-match-history/v1/game-timelines/{d}", .{game_id}) catch return null;
    const timeline = client.get(timeline_path) catch return null;
    defer std.heap.page_allocator.free(timeline);
    var game_path_buffer: [256]u8 = undefined;
    const game_path = std.fmt.bufPrint(&game_path_buffer, "/lol-match-history/v1/games/{d}", .{game_id}) catch return null;
    const game_json = client.get(game_path) catch return null;
    defer std.heap.page_allocator.free(game_json);
    const metric = jungle_analysis.earlyDeathsFromTimeline(timeline, game_json, puuid) orelse return null;
    cacheGankMetric(self, metric_key, metric);
    return metric;
}

fn cacheGankMetric(self: *Runtime, key: []const u8, metric: usize) void {
    const store = if (self.storage) |*value| value else return;
    var value_buffer: [32]u8 = undefined;
    const value = std.fmt.bufPrint(&value_buffer, "{d}", .{metric}) catch return;
    store.put("gankMetric", key, value) catch {};
}

fn validateShortcut(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    _ = context;
    const parsed = parsePayload(TemplatePayload, invocation.request.payload) catch return error.InvalidTemplate;
    return shortcut_service.validationDto(parsed.template, output);
}

fn checkUpdate(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = runtime(context);
    _ = invocation;
    const io = self.io orelse return error.IoFailure;
    if (build_options.update_check_url.len == 0) return std.fmt.bufPrint(output, "null", .{});
    // Public HTTP does not use LCU credentials; reuse only the transport so
    // TLS, timeouts and response limits stay in the native layer.
    const public_client = lcu.Client{
        .allocator = std.heap.page_allocator,
        .io = io,
        .credentials = .{ .port = 0, .token = "", .protocol = "https" },
        .timeout_ms = build_options.lcu_request_timeout_ms,
        .verify_tls = true,
    };
    const response = try public_client.getPublicUrl(build_options.update_check_url, "lol-desktop-native/2.0");
    defer std.heap.page_allocator.free(response);
    return updateDto(response, output);
}

fn openGameView(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self = runtime(context);
    _ = invocation;
    const native_runtime = self.native_runtime orelse return error.RuntimeUnavailable;
    try native_runtime.showWindow(1);
    try native_runtime.focusWindow(1);
    return std.fmt.bufPrint(output, "true", .{});
}

fn updateDto(response: []const u8, output: []u8) ![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, response, .{}) catch return error.InvalidUpdateResponse;
    defer parsed.deinit();
    const version = jsonField(parsed.value, "version");
    if (version.len == 0 or compareVersions(version, "2.0.0") <= 0) return std.fmt.bufPrint(output, "null", .{});
    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll("{\"version\":");
    try jsonString(&writer, version);
    try writer.writeByte('}');
    return writer.buffered();
}

fn compareVersions(left: []const u8, right: []const u8) i8 {
    const normalized_left = if (left.len > 0 and (left[0] == 'v' or left[0] == 'V')) left[1..] else left;
    const normalized_right = if (right.len > 0 and (right[0] == 'v' or right[0] == 'V')) right[1..] else right;
    var left_parts = std.mem.splitScalar(u8, normalized_left, '.');
    var right_parts = std.mem.splitScalar(u8, normalized_right, '.');
    var index: usize = 0;
    while (index < 3) : (index += 1) {
        const left_part = left_parts.next() orelse "0";
        const right_part = right_parts.next() orelse "0";
        const left_number = numericVersionPart(left_part);
        const right_number = numericVersionPart(right_part);
        if (left_number > right_number) return 1;
        if (left_number < right_number) return -1;
    }
    return 0;
}

fn numericVersionPart(value: []const u8) u32 {
    var end: usize = 0;
    while (end < value.len and std.ascii.isDigit(value[end])) : (end += 1) {}
    return std.fmt.parseInt(u32, value[0..end], 10) catch 0;
}

fn getLcuEvents(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    _ = invocation;
    const self = runtime(context);
    if (self.mode != .live) return std.fmt.bufPrint(output, "[]", .{});
    if (self.io) |io| {
        var client = discoverClient(self, io) catch return error.LcuNotRunning;
        defer client.deinit();
        return lcu_events.poll(&self.event_state, client, output);
    }
    return error.LcuNotRunning;
}

fn getShortcutEvents(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    _ = context;
    _ = invocation;
    return hotkey_service.drainJson(output);
}

fn copyJson(value: []const u8, output: []u8) ![]const u8 {
    _ = std.json.parseFromSliceLeaky(std.json.Value, std.heap.page_allocator, value, .{}) catch return error.LcuInvalidResponse;
    if (value.len > output.len) return error.ResponseTooLarge;
    // Envelope builders commonly return a slice of `output` and then pass it
    // through a cache merge. A different-game branch may therefore copy a
    // buffer onto itself; memmove also covers partial overlap.
    @memmove(output[0..value.len], value);
    return output[0..value.len];
}

fn jsonBool(value: std.json.Value, name: []const u8) bool {
    if (value != .object) return false;
    const item = value.object.get(name) orelse return false;
    return item == .bool and item.bool;
}

fn jsonFloat(value: std.json.Value, name: []const u8) f64 {
    if (value != .object) return 0;
    const item = value.object.get(name) orelse return 0;
    return switch (item) {
        .integer => |n| @floatFromInt(n),
        .float => |n| n,
        .string => |text| std.fmt.parseFloat(f64, text) catch 0,
        else => 0,
    };
}

fn nestedObject(value: std.json.Value, name: []const u8) ?std.json.Value {
    if (value != .object) return null;
    const item = value.object.get(name) orelse return null;
    return if (item == .object) item else null;
}

fn nestedInt(value: std.json.Value, nested: []const u8, name: []const u8) i64 {
    if (nestedObject(value, nested)) |object| return jsonInt(object, name);
    return 0;
}

fn nestedArrayFirstInt(value: std.json.Value, nested: []const u8, name: []const u8) i64 {
    if (value != .object) return 0;
    const array = value.object.get(nested) orelse return 0;
    if (array != .array or array.array.items.len == 0) return 0;
    return jsonInt(array.array.items[0], name);
}

fn nestedBool(value: std.json.Value, nested: []const u8, name: []const u8) bool {
    if (nestedObject(value, nested)) |object| return jsonBool(object, name);
    return false;
}

fn nestedString(value: std.json.Value, nested: []const u8, name: []const u8) []const u8 {
    if (nestedObject(value, nested)) |object| return jsonField(object, name);
    return "";
}

fn statInt(value: std.json.Value, name: []const u8) i64 {
    if (nestedObject(value, "stats")) |stats| if (stats.object.get(name) != null) return jsonInt(stats, name);
    return jsonInt(value, name);
}

fn statBool(value: std.json.Value, name: []const u8) bool {
    if (nestedObject(value, "stats")) |stats| if (stats.object.get(name) != null) return jsonBool(stats, name);
    return jsonBool(value, name);
}

fn statFloat(value: std.json.Value, name: []const u8) f64 {
    if (nestedObject(value, "stats")) |stats| if (stats.object.get(name) != null) return jsonFloat(stats, name);
    return jsonFloat(value, name);
}

fn teamStat(value: ?std.json.Value, team_id: i64, name: []const u8) i64 {
    const participants = value orelse return 0;
    if (participants != .array) return 0;
    var total: i64 = 0;
    for (participants.array.items) |participant| {
        if (participant == .object and jsonInt(participant, "teamId") == team_id) total += statInt(participant, name);
    }
    return total;
}

fn ratio(value: i64, total: i64) f64 {
    if (total <= 0 or value <= 0) return 0;
    return @as(f64, @floatFromInt(value)) / @as(f64, @floatFromInt(total));
}

fn participantScore(participant: std.json.Value, team_damage: i64) f64 {
    const kills = statInt(participant, "kills");
    const deaths = statInt(participant, "deaths");
    const assists = statInt(participant, "assists");
    const damage_share = ratio(statInt(participant, "totalDamageDealtToChampions"), team_damage);
    return @as(f64, @floatFromInt(kills + assists)) / @as(f64, @floatFromInt(@max(deaths, 1))) + damage_share * 10;
}

fn bestTeamScore(participants: ?std.json.Value, team_id: i64, team_damage: i64) f64 {
    const values = participants orelse return 0;
    if (values != .array) return 0;
    var best: f64 = 0;
    for (values.array.items) |participant| {
        if (participant == .object and jsonInt(participant, "teamId") == team_id) best = @max(best, participantScore(participant, team_damage));
    }
    return best;
}

fn teamParticipantCount(participants: ?std.json.Value, team_id: i64) usize {
    const values = participants orelse return 0;
    if (values != .array) return 0;
    var count: usize = 0;
    for (values.array.items) |participant| {
        if (participant == .object and jsonInt(participant, "teamId") == team_id) count += 1;
    }
    return count;
}

fn towerLeader(participants: ?std.json.Value, current: std.json.Value) bool {
    const value = statInt(current, "damageDealtToTurrets");
    if (value <= 0) return false;
    const values = participants orelse return false;
    if (values != .array) return false;
    for (values.array.items) |participant| if (participant == .object and statInt(participant, "damageDealtToTurrets") > value) return false;
    return true;
}

fn matchPerformance(win: bool, kills: i64, deaths: i64, assists: i64, damage_share: f64) []const u8 {
    const kda = @as(f64, @floatFromInt(kills + assists)) / @as(f64, @floatFromInt(@max(deaths, 1)));
    if (win and (kda >= 4 or damage_share >= 0.3)) return "carry";
    if (!win and kda < 1.5 and damage_share < 0.18) return "struggling";
    if (!win) return "carried";
    return "solid";
}

/// Keep the live payload's team summaries compatible with the Rust analysis
/// layer. The native host receives the same enriched player cards, so the
/// summary can be derived without another LCU request.
fn writeLiveTeamSummary(writer: *std.Io.Writer, side: []const u8, players_json: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), players_json, .{}) catch std.json.Value{ .null = {} };
    var score_total: f64 = 0;
    var count: usize = 0;
    var focus_score: f64 = std.math.inf(f64);
    var focus_puuid: []const u8 = "";
    var strengths: [3][]const u8 = .{ "", "", "" };
    var risks: [3][]const u8 = .{ "", "", "" };
    var strengths_len: usize = 0;
    var risks_len: usize = 0;
    if (root == .array) for (root.array.items) |player| {
        if (player != .object) continue;
        count += 1;
        const score = if (nestedObject(player, "score")) |value| jsonFloat(value, "total") else jsonFloat(player, "score");
        score_total += score;
        if (score < focus_score) {
            focus_score = score;
            focus_puuid = jsonField(player, "puuid");
        }
        if (player.object.get("tags")) |tags| if (tags == .array) for (tags.array.items) |tag| {
            if (tag != .object) continue;
            const label = jsonField(tag, "label");
            if (label.len == 0) continue;
            const tone = jsonField(tag, "tone");
            const target = if (std.ascii.eqlIgnoreCase(tone, "success") or std.ascii.eqlIgnoreCase(tone, "info")) &strengths else &risks;
            const target_len = if (target == &strengths) &strengths_len else &risks_len;
            if (target_len.* < target.len) {
                target[target_len.*] = label;
                target_len.* += 1;
            }
        };
    };
    const score = if (count > 0) score_total / @as(f64, @floatFromInt(count)) else 0;
    const title = if (count == 0) "暂无队伍数据" else if (score >= 75) "状态占优" else if (score < 55) "需要关注" else "整体均衡";
    try writer.writeAll("{\"side\":");
    try jsonString(writer, side);
    try writer.print(",\"score\":{d:.1},\"title\":", .{score});
    try jsonString(writer, title);
    try writer.writeAll(",\"focusPlayerPuuid\":");
    if (focus_puuid.len > 0) try jsonString(writer, focus_puuid) else try writer.writeAll("null");
    try writer.writeAll(",\"strengths\":[");
    if (strengths_len == 0 and count > 0) {
        try jsonString(writer, "整体状态稳定");
    } else {
        for (strengths[0..strengths_len], 0..) |value, index| {
            if (index > 0) try writer.writeByte(',');
            try jsonString(writer, value);
        }
    }
    try writer.writeAll("],\"risks\":[");
    if (risks_len == 0) {
        try jsonString(writer, if (count == 0) "等待玩家信息" else "暂无明显风险");
    } else {
        for (risks[0..risks_len], 0..) |value, index| {
            if (index > 0) try writer.writeByte(',');
            try jsonString(writer, value);
        }
    }
    try writer.writeAll("],\"composition\":{\"early\":0,\"mid\":0,\"late\":0,\"teamfight\":0}}");
}

fn writeBanNames(writer: *std.Io.Writer, game: std.json.Value, catalog: std.json.Value) !void {
    try writer.writeByte('[');
    var first = true;
    if (game == .object) if (game.object.get("teams")) |teams| if (teams == .array) for (teams.array.items) |team| {
        if (team != .object) continue;
        if (team.object.get("bans")) |bans| if (bans == .array) for (bans.array.items) |ban| {
            const id = jsonInt(ban, "championId");
            if (id <= 0) continue;
            if (!first) try writer.writeByte(',');
            first = false;
            try jsonString(writer, catalogChampionName(catalog, id, jsonField(ban, "championName")));
        };
    };
    try writer.writeByte(']');
}

fn writeBanDetails(writer: *std.Io.Writer, game: std.json.Value, catalog: std.json.Value, self_team_id: i64) !void {
    try writer.writeByte('[');
    var first = true;
    if (game == .object) if (game.object.get("teams")) |teams| if (teams == .array) for (teams.array.items) |team| {
        if (team != .object) continue;
        const side = if (jsonInt(team, "teamId") == self_team_id) "ally" else "enemy";
        if (team.object.get("bans")) |bans| if (bans == .array) for (bans.array.items) |ban| {
            const id = jsonInt(ban, "championId");
            if (id <= 0) continue;
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.writeAll("{\"id\":");
            try writer.print("{d},\"name\":", .{id});
            try jsonString(writer, catalogChampionName(catalog, id, jsonField(ban, "championName")));
            try writer.writeAll(",\"iconUrl\":\"\",\"side\":");
            try jsonString(writer, side);
            try writer.writeAll(",\"pickTurn\":");
            if (jsonInt(ban, "pickTurn") > 0) try writer.print("{d}", .{jsonInt(ban, "pickTurn")}) else try writer.writeAll("null");
            try writer.writeAll(",\"bannedBy\":");
            const banned_by = if (jsonField(ban, "bannedBy").len > 0) jsonField(ban, "bannedBy") else jsonField(ban, "summonerName");
            if (banned_by.len > 0) try jsonString(writer, banned_by) else try writer.writeAll("null");
            try writer.writeByte('}');
        };
    };
    try writer.writeByte(']');
}

fn writeParticipant(writer: *std.Io.Writer, participant: std.json.Value, self_team_id: i64, catalog: std.json.Value, identity_override: ?std.json.Value, all_participants: ?std.json.Value) !void {
    const identity = identity_override orelse nestedObject(participant, "identity");
    const player = if (identity) |value| nestedObject(value, "player") orelse value else std.json.Value{ .null = {} };
    const puuid = if (jsonField(participant, "puuid").len > 0) jsonField(participant, "puuid") else if (player != .null and jsonField(player, "puuid").len > 0) jsonField(player, "puuid") else if (identity) |value| jsonField(value, "puuid") else "";
    const game_name = if (jsonField(participant, "gameName").len > 0) jsonField(participant, "gameName") else if (jsonField(participant, "riotIdGameName").len > 0) jsonField(participant, "riotIdGameName") else if (jsonField(participant, "summonerName").len > 0) jsonField(participant, "summonerName") else if (player != .null and jsonField(player, "gameName").len > 0) jsonField(player, "gameName") else if (player != .null and jsonField(player, "riotIdGameName").len > 0) jsonField(player, "riotIdGameName") else if (identity) |value| jsonField(value, "summonerName") else "未知玩家";
    const champion_id = jsonInt(participant, "championId");
    const champion_name = catalogChampionName(catalog, champion_id, jsonField(participant, "championName"));
    const kills = statInt(participant, "kills");
    const deaths = statInt(participant, "deaths");
    const assists = statInt(participant, "assists");
    const damage = statInt(participant, "totalDamageDealtToChampions");
    const taken = statInt(participant, "totalDamageTaken");
    const gold = statInt(participant, "goldEarned");
    const cs = statInt(participant, "totalMinionsKilled") + statInt(participant, "neutralMinionsKilledToTeamJungle");
    const win = statBool(participant, "win");
    const team_id = jsonInt(participant, "teamId");
    const team_damage = teamStat(all_participants, team_id, "totalDamageDealtToChampions");
    const team_taken = teamStat(all_participants, team_id, "totalDamageTaken");
    const team_kills = teamStat(all_participants, team_id, "kills");
    const position = participantPosition(participant);
    try writer.writeAll("{\"puuid\":");
    try jsonString(writer, puuid);
    try writer.writeAll(",\"gameName\":");
    try jsonString(writer, game_name);
    try writer.print(",\"isBot\":{},\"championId\":{d},\"championName\":", .{ jsonBool(participant, "isBot"), champion_id });
    try jsonString(writer, champion_name);
    try writer.writeAll(",\"side\":");
    try jsonString(writer, if (team_id == self_team_id) "ally" else "enemy");
    try writer.writeAll(",\"position\":");
    try jsonString(writer, position);
    try writer.print(",\"kills\":{d},\"deaths\":{d},\"assists\":{d},\"damageDealt\":{d},\"damageTaken\":{d},\"goldEarned\":{d},\"cs\":{d},\"win\":{},\"items\":", .{ kills, deaths, assists, damage, taken, gold, cs, win });
    try writeItems(writer, participant);
    try writer.writeAll(",\"summonerSpells\":");
    try writeSummonerSpells(writer, participant);
    try writer.writeAll(",\"runes\":");
    try writeRunes(writer, participant);
    try writer.print(",\"heal\":{d},\"damageShare\":{d:.4},\"damageTakenShare\":{d:.4},\"killParticipation\":{d:.4},\"towerDamage\":{d},\"turretKills\":{d},\"wardsPlaced\":{d},\"wardsKilled\":{d},\"visionScore\":{d},\"visionWardsBought\":{d},\"sightWardsBought\":{d}}}", .{ statInt(participant, "totalHeal"), ratio(damage, team_damage), ratio(taken, team_taken), ratio(kills + assists, team_kills), statInt(participant, "damageDealtToTurrets"), statInt(participant, "turretKills"), statInt(participant, "wardsPlaced"), statInt(participant, "wardsKilled"), statInt(participant, "visionScore"), statInt(participant, "visionWardsBoughtInGame"), statInt(participant, "sightWardsBoughtInGame") });
}

fn participantPosition(participant: std.json.Value) []const u8 {
    for ([_][]const u8{ "teamPosition", "individualPosition", "positionAssignedByMatchmaking", "position", "lane" }) |field| {
        const value = jsonField(participant, field);
        if (value.len > 0 and !std.ascii.eqlIgnoreCase(value, "NONE") and !std.ascii.eqlIgnoreCase(value, "INVALID")) return value;
    }
    if (nestedObject(participant, "timeline")) |timeline| {
        const lane = jsonField(timeline, "lane");
        const role = jsonField(timeline, "role");
        if (std.ascii.eqlIgnoreCase(lane, "BOTTOM") and std.ascii.eqlIgnoreCase(role, "DUO_SUPPORT")) return "UTILITY";
        if (lane.len > 0 and !std.ascii.eqlIgnoreCase(lane, "NONE") and !std.ascii.eqlIgnoreCase(lane, "INVALID")) return lane;
    }
    return "";
}

fn writeItems(writer: *std.Io.Writer, participant: std.json.Value) !void {
    try writer.writeByte('[');
    var first = true;
    for (0..7) |index| {
        var field_buffer: [16]u8 = undefined;
        const field = try std.fmt.bufPrint(&field_buffer, "item{d}", .{index});
        const id = statInt(participant, field);
        if (id <= 0) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.print("{{\"id\":{d},\"name\":\"\",\"iconUrl\":\"\"}}", .{id});
    }
    try writer.writeByte(']');
}

const SummonerSpellWriter = struct {
    writer: *std.Io.Writer,
    first: bool = true,
    emitted_ids: [4]i64 = [_]i64{0} ** 4,
    emitted_count: usize = 0,

    fn emit(self: *SummonerSpellWriter, value: std.json.Value) !void {
        const id = summonerSpellId(value);
        if (id <= 0 or self.emitted_count == self.emitted_ids.len) return;
        for (self.emitted_ids[0..self.emitted_count]) |existing| if (existing == id) return;
        self.emitted_ids[self.emitted_count] = id;
        self.emitted_count += 1;
        if (!self.first) try self.writer.writeByte(',');
        self.first = false;
        try self.writer.print("{{\"id\":{d},\"name\":", .{id});
        const name = summonerSpellName(value);
        if (name.len > 0) try jsonString(self.writer, name) else try self.writer.writeAll("\"\"");
        try self.writer.writeAll(",\"iconUrl\":\"\"}");
    }
};

fn collectSummonerSpells(state: *SummonerSpellWriter, participant: std.json.Value) !void {
    if (participant != .object) return;
    // Champ-select and gameflow have used all of these spell field names over
    // time. Normalize them before the DTO reaches shortcut targeting so
    // Smite detection does not depend on one particular client build.
    for ([_][]const u8{
        "spell1Id",         "spell2Id",         "summonerSpellOneId", "summonerSpellTwoId",
        "summonerSpell1Id", "summonerSpell2Id", "spell1",             "spell2",
        "summonerSpellOne", "summonerSpellTwo",
    }) |field| {
        const value = participant.object.get(field) orelse continue;
        // Match-history participants may nest the numeric IDs under `stats`,
        // while champ-select normally keeps them at the participant root.
        try state.emit(value);
    }
    for ([_][]const u8{ "summonerSpells", "spells" }) |field| {
        const values = participant.object.get(field) orelse continue;
        if (values == .array) for (values.array.items) |spell| try state.emit(spell);
    }
    // A few lobby responses wrap the actionable fields one level deeper. Keep
    // traversing only the known identity wrappers to avoid scanning arbitrary
    // match payloads and accidentally treating unrelated ids as spells.
    for ([_][]const u8{ "summoner", "player" }) |field| {
        if (nestedObject(participant, field)) |nested| try collectSummonerSpells(state, nested);
    }
    if (participant.object.get("playerSlots")) |slots| if (slots == .array) {
        for (slots.array.items) |slot| try collectSummonerSpells(state, slot);
    };
}

fn writeSummonerSpells(writer: *std.Io.Writer, participant: std.json.Value) !void {
    try writer.writeByte('[');
    var state = SummonerSpellWriter{ .writer = writer };
    try collectSummonerSpells(&state, participant);
    try writer.writeByte(']');
}

fn summonerSpellId(value: std.json.Value) i64 {
    return switch (value) {
        .integer => |number| number,
        .float => |number| @intFromFloat(number),
        .string => |text| blk: {
            const trimmed = std.mem.trim(u8, text, " \t\r\n");
            if (std.fmt.parseInt(i64, trimmed, 10) catch null) |id| break :blk id;
            if (std.ascii.eqlIgnoreCase(trimmed, "SMITE") or
                std.ascii.eqlIgnoreCase(trimmed, "SUMMONERSMITE") or
                std.mem.eql(u8, trimmed, "惩戒")) break :blk 11;
            break :blk 0;
        },
        .object => blk: {
            const id = jsonInt(value, "id");
            if (id > 0) break :blk id;
            for ([_][]const u8{
                "spellId",            "summonerSpellId",  "key",
                "spell1Id",           "spell2Id",         "summonerSpellOneId",
                "summonerSpellTwoId", "summonerSpell1Id", "summonerSpell2Id",
                "name",               "rawName",          "displayName",
                "spellName",
            }) |field| {
                if (value.object.get(field)) |item| {
                    const nested = summonerSpellId(item);
                    if (nested > 0) break :blk nested;
                }
            }
            break :blk 0;
        },
        .array => |items| blk: {
            for (items.items) |item| {
                const id = summonerSpellId(item);
                if (id > 0) break :blk id;
            }
            break :blk 0;
        },
        else => 0,
    };
}

fn summonerSpellName(value: std.json.Value) []const u8 {
    if (value != .object) return "";
    for ([_][]const u8{ "name", "displayName", "spellName", "rawName" }) |field| {
        const name = jsonField(value, field);
        if (name.len > 0) return name;
    }
    return "";
}

fn writeRunes(writer: *std.Io.Writer, participant: std.json.Value) !void {
    try writer.writeByte('[');
    var first = true;
    if (nestedObject(participant, "perks")) |perks| if (perks.object.get("styles")) |styles| if (styles == .array) {
        for (styles.array.items) |style| {
            if (style != .object) continue;
            const style_id = jsonInt(style, "style");
            const selections = style.object.get("selections") orelse continue;
            if (selections != .array) continue;
            for (selections.array.items) |selection| {
                const id = jsonInt(selection, "perk");
                if (id <= 0) continue;
                if (!first) try writer.writeByte(',');
                first = false;
                try writer.print("{{\"id\":{d},\"name\":\"\",\"style\":\"{d}\",\"iconUrl\":\"\"}}", .{ id, style_id });
            }
        }
    };
    try writer.writeByte(']');
}

fn matchHistoryDto(json: []const u8, output: []u8) ![]const u8 {
    return matchHistoryDtoPage(json, "[]", "", 0, std.math.maxInt(usize), output);
}

fn historyHasGames(json: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{}) catch return false;
    if (root == .array) return root.array.items.len > 0;
    if (root != .object) return false;
    const games = root.object.get("games") orelse return false;
    if (games == .array) return games.array.items.len > 0;
    if (games == .object) if (games.object.get("games")) |nested| if (nested == .array) return nested.array.items.len > 0;
    return false;
}

fn preferredHistory(lcu_history: ?[]const u8, sgp_history: ?[]const u8) ?[]const u8 {
    if (sgp_history) |history| if (historyHasGames(history)) return history;
    if (lcu_history) |history| if (historyHasGames(history)) return history;
    return null;
}

fn matchHistoryDtoPage(json: []const u8, catalog_json: []const u8, self_puuid: []const u8, offset: usize, limit: usize, output: []u8) ![]const u8 {
    return matchHistoryDtoPageFiltered(json, catalog_json, self_puuid, offset, limit, false, output);
}

fn matchHistoryDtoPageFiltered(json: []const u8, catalog_json: []const u8, self_puuid: []const u8, offset: usize, limit: usize, hide_unfinished: bool, output: []u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{}) catch return error.LcuInvalidResponse;
    const catalog = std.json.parseFromSliceLeaky(std.json.Value, allocator, catalog_json, .{}) catch return error.LcuInvalidResponse;
    var games: ?std.json.Value = null;
    if (root == .array) games = root else if (root == .object) {
        if (root.object.get("games")) |value| games = if (value == .array) value else if (value == .object) value.object.get("games") else null;
    }
    const list = games orelse return std.fmt.bufPrint(output, "[]", .{});
    if (list != .array) return std.fmt.bufPrint(output, "[]", .{});
    var writer = std.Io.Writer.fixed(output);
    try writer.writeByte('[');
    var first = true;
    var game_index: usize = 0;
    var emitted: usize = 0;
    for (list.array.items) |entry| {
        const game = if (entry == .object) if (entry.object.get("json")) |payload| switch (payload) {
            .string => |encoded| std.json.parseFromSliceLeaky(std.json.Value, allocator, encoded, .{}) catch continue,
            .object => payload,
            else => entry,
        } else entry else entry;
        if (game != .object) continue;
        if (hide_unfinished and isHiddenHistoryGame(game)) continue;
        const current_index = game_index;
        game_index += 1;
        if (current_index < offset) continue;
        if (emitted >= limit) break;
        emitted += 1;
        if (!first) try writer.writeByte(',');
        first = false;
        const game_id = jsonInt(game, "gameId");
        const duration = jsonInt(game, "gameDuration");
        const queue_id = jsonInt(game, "queueId");
        const mode = queueLabelFromGame(game);
        const participants = game.object.get("participants");
        const first_participant = if (participants) |value| participantForPuuid(game, value, self_puuid) else std.json.Value{ .null = {} };
        const win = if (first_participant != .null) statBool(first_participant, "win") else false;
        const kills = if (first_participant != .null) statInt(first_participant, "kills") else 0;
        const deaths = if (first_participant != .null) statInt(first_participant, "deaths") else 0;
        const assists = if (first_participant != .null) statInt(first_participant, "assists") else 0;
        const damage = if (first_participant != .null) statInt(first_participant, "totalDamageDealtToChampions") else 0;
        const taken = if (first_participant != .null) statInt(first_participant, "totalDamageTaken") else 0;
        const gold = if (first_participant != .null) statInt(first_participant, "goldEarned") else 0;
        const cs = if (first_participant != .null) statInt(first_participant, "totalMinionsKilled") + statInt(first_participant, "neutralMinionsKilledToTeamJungle") else 0;
        const champion_id = if (first_participant != .null) jsonInt(first_participant, "championId") else 0;
        const champion_name = if (first_participant != .null) catalogChampionName(catalog, champion_id, jsonField(first_participant, "championName")) else "未知英雄";
        const position = if (first_participant != .null) participantPosition(first_participant) else "";
        const self_team_id = if (first_participant != .null) jsonInt(first_participant, "teamId") else 100;
        const team_damage = teamStat(participants, self_team_id, "totalDamageDealtToChampions");
        const team_taken = teamStat(participants, self_team_id, "totalDamageTaken");
        const team_kills = teamStat(participants, self_team_id, "kills");
        const damage_share = ratio(damage, team_damage);
        const taken_share = ratio(taken, team_taken);
        const kill_participation = ratio(kills + assists, team_kills);
        const performance = matchPerformance(win, kills, deaths, assists, damage_share);
        const is_mvp = first_participant != .null and teamParticipantCount(participants, self_team_id) >= 2 and
            participantScore(first_participant, team_damage) >= bestTeamScore(participants, self_team_id, team_damage);
        try writer.print("{{\"gameId\":{d},\"championId\":{d},\"championName\":", .{ game_id, champion_id });
        try jsonString(&writer, champion_name);
        try writer.writeAll(",\"position\":");
        try jsonString(&writer, position);
        try writer.print(",\"queueId\":{d},\"queueName\":", .{queue_id});
        try jsonString(&writer, mode);
        try writer.writeAll(",\"result\":");
        try jsonString(&writer, if (duration == 0) "未完成" else if (win) "胜利" else "失败");
        try writer.print(",\"kda\":\"{d}/{d}/{d}\",\"kills\":{d},\"deaths\":{d},\"assists\":{d},", .{ kills, deaths, assists, kills, deaths, assists });
        try writer.print("\"durationMinutes\":{d},\"items\":", .{@divTrunc(duration, 60)});
        try writeItems(&writer, first_participant);
        try writer.writeAll(",\"summonerSpells\":");
        try writeSummonerSpells(&writer, first_participant);
        try writer.writeAll(",\"runes\":");
        try writeRunes(&writer, first_participant);
        try writer.print(",\"damageDealt\":{d},\"damageTaken\":{d},\"damageTakenShare\":{d:.4},\"heal\":{d},\"goldEarned\":{d},\"cs\":{d},\"towerDamage\":{d},\"turretKills\":{d},\"towerLeader\":{s},\"damageShare\":{d:.4},\"killParticipation\":{d:.4},\"performance\":", .{ damage, taken, taken_share, statInt(first_participant, "totalHeal"), gold, cs, statInt(first_participant, "damageDealtToTurrets"), statInt(first_participant, "turretKills"), if (towerLeader(participants, first_participant)) "true" else "false", damage_share, kill_participation });
        try jsonString(&writer, performance);
        try writer.writeAll(",\"mvp\":");
        if (is_mvp and duration > 0) try jsonString(&writer, if (win) "MVP" else "SVP") else try writer.writeAll("null");
        try writer.print(",\"teamKills\":{d},\"participants\":", .{team_kills});
        try writer.writeByte('[');
        if (participants) |value| if (value == .array) {
            var participant_first = true;
            for (value.array.items) |participant| {
                if (participant != .object) continue;
                if (!participant_first) try writer.writeByte(',');
                participant_first = false;
                const identity = participantIdentityForId(game, jsonInt(participant, "participantId"));
                try writeParticipant(&writer, participant, self_team_id, catalog, identity, participants);
            }
        };
        try writer.writeAll("],\"bans\":");
        try writeBanNames(&writer, game, catalog);
        try writer.writeAll(",\"banDetails\":");
        try writeBanDetails(&writer, game, catalog, self_team_id);
        try writer.writeAll(",\"playedAt\":");
        const created_at = if (jsonInt(game, "gameCreation") > 0) jsonInt(game, "gameCreation") else jsonInt(game, "gameStartTimestamp");
        try writeIsoTimestamp(&writer, created_at);
        try writer.writeAll(",\"dataStatus\":{\"source\":\"lcu\",\"fetchedAt\":\"1970-01-01T00:00:00.000Z\",\"expiresAt\":null,\"isStale\":false,\"error\":null}} ");
    }
    try writer.writeByte(']');
    return writer.buffered();
}

fn participantForPuuid(game: std.json.Value, participants: std.json.Value, puuid: []const u8) std.json.Value {
    if (participants != .array or participants.array.items.len == 0) return .{ .null = {} };
    if (puuid.len > 0) {
        for (participants.array.items) |participant| {
            if (participant != .object) continue;
            const identity = participantIdentityForId(game, jsonInt(participant, "participantId"));
            const player = if (identity) |value| nestedObject(value, "player") orelse value else std.json.Value{ .null = {} };
            const candidate = if (jsonField(participant, "puuid").len > 0)
                jsonField(participant, "puuid")
            else if (jsonField(participant, "playerPuuid").len > 0)
                jsonField(participant, "playerPuuid")
            else if (player != .null)
                jsonField(player, "puuid")
            else
                "";
            if (std.mem.eql(u8, candidate, puuid)) return participant;
        }
    }
    // LCU summary payloads sometimes identify the requested player through a
    // game-level participantId instead of repeating the PUUID on every row.
    const requested_participant_id = jsonInt(game, "participantId");
    if (requested_participant_id > 0) for (participants.array.items) |participant| {
        if (participant == .object and jsonInt(participant, "participantId") == requested_participant_id) return participant;
    };
    // A detailed ten-player payload must not silently attribute the first
    // participant's KDA to the requested player when PUUIDs are absent or
    // stale. Single-participant summaries are the only safe fallback.
    if (participants.array.items.len == 1) return participants.array.items[0];
    return .{ .null = {} };
}

fn participantIdentityForId(game: std.json.Value, participant_id: i64) ?std.json.Value {
    if (game != .object or participant_id <= 0) return null;
    const identities = game.object.get("participantIdentities") orelse return null;
    if (identities != .array) return null;
    for (identities.array.items) |identity| {
        if (identity == .object and jsonInt(identity, "participantId") == participant_id) return identity;
    }
    return null;
}

fn catalogChampionName(catalog: std.json.Value, champion_id: i64, fallback: []const u8) []const u8 {
    if (catalog == .array) {
        for (catalog.array.items) |champion| {
            if (champion == .object and jsonInt(champion, "id") == champion_id) {
                const name = jsonField(champion, "name");
                if (name.len > 0) return name;
            }
        }
    }
    if (fallback.len > 0) return fallback;
    return "未知英雄";
}

fn writeIsoTimestamp(writer: *std.Io.Writer, epoch_millis: i64) !void {
    if (epoch_millis <= 0) return writer.writeAll("\"1970-01-01T00:00:00.000Z\"");
    const seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(@divTrunc(epoch_millis, 1000)) };
    const day = seconds.getEpochDay().calculateYearDay();
    const month = day.calculateMonthDay();
    const clock = seconds.getDaySeconds();
    // Keep the fractional part unsigned. Zig's signed integer formatter can
    // emit a leading `+` when zero-padding a positive i64, producing values
    // such as `.+766Z` that JavaScript cannot parse as an ISO timestamp.
    const millis: u16 = @intCast(@mod(epoch_millis, 1000));
    try writer.print("\"{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z\"", .{
        day.year,
        @intFromEnum(month.month),
        month.day_index + 1,
        clock.getHoursIntoDay(),
        clock.getMinutesIntoHour(),
        clock.getSecondsIntoMinute(),
        millis,
    });
}

fn writeRuntimeTimestamp(writer: *std.Io.Writer, self: ?*Runtime) !void {
    try writeIsoTimestamp(writer, if (self) |runtime_value| runtimeNowMillis(runtime_value) else 0);
}

fn configAutomation(config: std.json.Value) ?std.json.Value {
    if (config != .object) return null;
    const automation = config.object.get("automation") orelse return null;
    return automation;
}

fn configAutomationInt(config: std.json.Value, field: []const u8, fallback: i64) i64 {
    const automation = configAutomation(config) orelse return fallback;
    if (automation != .object) return fallback;
    const value = automation.object.get(field) orelse return fallback;
    return switch (value) {
        .integer => |n| n,
        .float => |n| @intFromFloat(n),
        else => fallback,
    };
}

fn findConversationId(value: std.json.Value, conversation_type: []const u8) ?[]const u8 {
    if (value != .array) return null;
    for (value.array.items) |conversation| {
        if (conversation != .object) continue;
        if (!std.mem.eql(u8, jsonField(conversation, "type"), conversation_type)) continue;
        const id = jsonField(conversation, "id");
        if (id.len > 0) return id;
    }
    return null;
}

fn jsonString(writer: *std.Io.Writer, value: []const u8) !void {
    var stringify = std.json.Stringify{ .writer = writer, .options = .{} };
    try stringify.write(value);
}

fn jsonField(value: std.json.Value, name: []const u8) []const u8 {
    if (value != .object) return "";
    const item = value.object.get(name) orelse return "";
    return if (item == .string) item.string else "";
}

const RiotIdentity = struct {
    name: []const u8 = "",
    tag: []const u8 = "",
};

fn splitRiotId(value: []const u8) RiotIdentity {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (std.mem.lastIndexOfScalar(u8, trimmed, '#')) |separator| {
        return .{
            .name = std.mem.trim(u8, trimmed[0..separator], " \t\r\n"),
            .tag = std.mem.trim(u8, trimmed[separator + 1 ..], " \t\r\n"),
        };
    }
    return .{ .name = trimmed };
}

fn riotIdentity(value: std.json.Value) RiotIdentity {
    if (value != .object) return .{};
    const composite_source = if (jsonField(value, "riotId").len > 0)
        jsonField(value, "riotId")
    else if (jsonField(value, "summonerName").len > 0)
        jsonField(value, "summonerName")
    else
        jsonField(value, "displayName");
    const composite = splitRiotId(composite_source);
    const explicit_source = if (jsonField(value, "riotIdGameName").len > 0)
        jsonField(value, "riotIdGameName")
    else if (jsonField(value, "gameName").len > 0)
        jsonField(value, "gameName")
    else
        "";
    const explicit = splitRiotId(explicit_source);
    const direct_name = if (explicit.name.len > 0) explicit.name else composite.name;
    const direct_tag = if (jsonField(value, "riotIdTagLine").len > 0)
        jsonField(value, "riotIdTagLine")
    else if (jsonField(value, "riotIdTagline").len > 0)
        jsonField(value, "riotIdTagline")
    else if (jsonField(value, "tagLine").len > 0)
        jsonField(value, "tagLine")
    else if (explicit.tag.len > 0)
        explicit.tag
    else
        composite.tag;
    if (direct_name.len > 0 or direct_tag.len > 0) return .{ .name = direct_name, .tag = direct_tag };
    if (nestedObject(value, "summoner")) |summoner| return riotIdentity(summoner);
    if (nestedObject(value, "player")) |player| return riotIdentity(player);
    return .{};
}

fn identityPuuid(value: std.json.Value) []const u8 {
    if (value != .object) return "";
    for ([_][]const u8{ "puuid", "obfuscatedPuuid", "botUuid", "botId" }) |field| {
        if (jsonField(value, field).len > 0) return jsonField(value, field);
    }
    if (nestedObject(value, "summoner")) |summoner| return identityPuuid(summoner);
    if (nestedObject(value, "player")) |player| return identityPuuid(player);
    return "";
}

const puuid_obfuscation_key = [_]u8{ 0x81, 0x70, 0x76, 0xa9, 0xf4, 0x51, 0x50, 0x9b, 0x95, 0x98, 0x68, 0x13, 0xce, 0x91, 0x17, 0xe7 };

/// ChampSelect can expose only `obfuscatedPuuid`. Rust decrypts that UUID
/// before rank/history requests; doing the same here prevents an encrypted
/// identifier from being sent to the summoner and match-history endpoints.
fn resolvedIdentityPuuid(value: std.json.Value, buffer: *[36]u8) []const u8 {
    if (value != .object) return "";
    const direct = jsonField(value, "puuid");
    if (direct.len > 0) return direct;
    for ([_][]const u8{ "botUuid", "botId" }) |field| {
        const bot_id = jsonField(value, field);
        if (bot_id.len > 0) return bot_id;
    }
    const obfuscated = jsonField(value, "obfuscatedPuuid");
    if (obfuscated.len > 0) return deobfuscatePuuid(obfuscated, buffer) orelse "";
    if (nestedObject(value, "summoner")) |summoner| {
        const nested = resolvedIdentityPuuid(summoner, buffer);
        if (nested.len > 0) return nested;
    }
    if (nestedObject(value, "player")) |player| return resolvedIdentityPuuid(player, buffer);
    return "";
}

fn deobfuscatePuuid(value: []const u8, output: *[36]u8) ?[]const u8 {
    var raw: [16]u8 = undefined;
    var nibble_index: usize = 0;
    var byte_value: u8 = 0;
    for (std.mem.trim(u8, value, " \t\r\n")) |character| {
        if (character == '-') continue;
        const nibble = std.fmt.charToDigit(character, 16) catch return null;
        if (nibble_index >= 32) return null;
        if (nibble_index % 2 == 0) {
            byte_value = @as(u8, @intCast(nibble)) << 4;
        } else {
            byte_value |= @as(u8, @intCast(nibble));
            raw[nibble_index / 2] = byte_value;
        }
        nibble_index += 1;
    }
    if (nibble_index != 32) return null;

    var decrypted: [16]u8 = undefined;
    for (&decrypted, raw, puuid_obfuscation_key) |*target, byte, key| target.* = byte ^ key;
    if (decrypted[6] >> 4 != 5 or decrypted[8] >> 6 != 0b10) return null;

    const hex = "0123456789abcdef";
    var cursor: usize = 0;
    for (decrypted, 0..) |byte, index| {
        if (index == 4 or index == 6 or index == 8 or index == 10) {
            output[cursor] = '-';
            cursor += 1;
        }
        output[cursor] = hex[byte >> 4];
        output[cursor + 1] = hex[byte & 0x0f];
        cursor += 2;
    }
    return output[0..cursor];
}

fn identityNumericId(value: std.json.Value) i64 {
    if (value != .object) return 0;
    for ([_][]const u8{ "summonerId", "accountId", "id" }) |field| {
        if (jsonInt(value, field) > 0) return jsonInt(value, field);
    }
    if (nestedObject(value, "summoner")) |summoner| return identityNumericId(summoner);
    if (nestedObject(value, "player")) |player| return identityNumericId(player);
    return 0;
}

fn isNumericIdentity(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |character| if (!std.ascii.isDigit(character)) return false;
    return true;
}

fn writeIdentityString(writer: *std.Io.Writer, value: std.json.Value) !bool {
    var puuid_buffer: [36]u8 = undefined;
    const puuid = resolvedIdentityPuuid(value, &puuid_buffer);
    if (puuid.len > 0) {
        try jsonString(writer, puuid);
        return true;
    }
    const numeric = identityNumericId(value);
    if (numeric > 0) {
        var buffer: [32]u8 = undefined;
        try jsonString(writer, try std.fmt.bufPrint(&buffer, "{d}", .{numeric}));
        return true;
    }
    try jsonString(writer, "");
    return false;
}

/// Live Client uses ORDER/CHAOS, while gameflow and older endpoints use
/// BLUE/RED, 100/200, or ally/enemy labels. Return a canonical side when
/// the value is recognizable and -1 for an unknown/custom team string.
fn liveTeamSide(value: []const u8) i8 {
    const normalized = std.mem.trim(u8, value, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(normalized, "ORDER") or
        std.ascii.eqlIgnoreCase(normalized, "BLUE") or
        std.ascii.eqlIgnoreCase(normalized, "ALLY") or
        std.ascii.eqlIgnoreCase(normalized, "TEAMONE") or
        std.ascii.eqlIgnoreCase(normalized, "100")) return 0;
    if (std.ascii.eqlIgnoreCase(normalized, "CHAOS") or
        std.ascii.eqlIgnoreCase(normalized, "RED") or
        std.ascii.eqlIgnoreCase(normalized, "ENEMY") or
        std.ascii.eqlIgnoreCase(normalized, "TEAMTWO") or
        std.ascii.eqlIgnoreCase(normalized, "200")) return 1;
    return -1;
}

fn teamIdSide(team_id: i64) i8 {
    return switch (team_id) {
        100, 1 => 0,
        200, 2 => 1,
        else => -1,
    };
}

fn sameLiveTeam(left: []const u8, right: []const u8) bool {
    const left_side = liveTeamSide(left);
    const right_side = liveTeamSide(right);
    if (left_side >= 0 and right_side >= 0) return left_side == right_side;
    return left.len > 0 and std.ascii.eqlIgnoreCase(std.mem.trim(u8, left, " \t\r\n"), std.mem.trim(u8, right, " \t\r\n"));
}

fn knownQueueName(queue_id: i64) ?[]const u8 {
    return switch (queue_id) {
        0 => "自定义房间",
        2, 14, 31, 32, 33, 41, 42, 52, 400, 410, 430 => "召唤师峡谷匹配",
        4, 6, 420 => "单双排",
        440 => "灵活排位",
        65, 67, 70, 72, 450 => "极地大乱斗",
        490 => "快速模式",
        700, 7000 => "冠军杯赛",
        830 => "入门人机",
        840 => "新手人机",
        850 => "一般人机",
        900, 1900 => "无限火力",
        1020 => "克隆大作战",
        1300 => "极限闪击",
        1400 => "终极魔典",
        1700, 1710 => "斗魂竞技场",
        1810, 1820, 1830, 1840 => "无尽狂潮",
        2000, 2010, 2020 => "新手教程",
        3000 => "魄罗王大乱斗",
        3140 => "多人训练模式",
        4310 => "经典模式",
        else => null,
    };
}

fn queueName(queue_id: i64, mode: []const u8) []const u8 {
    const normalized = std.mem.trim(u8, mode, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(normalized, "KIWI")) return "海克斯大乱斗";
    if (queue_id > 0) if (knownQueueName(queue_id)) |name| return name;
    if (std.ascii.eqlIgnoreCase(normalized, "CLASSIC") or
        std.ascii.eqlIgnoreCase(normalized, "CLASS") or
        std.ascii.startsWithIgnoreCase(normalized, "CLASSIC_")) return "召唤师峡谷";
    if (std.ascii.eqlIgnoreCase(normalized, "ARAM")) return "极地大乱斗";
    if (std.ascii.eqlIgnoreCase(normalized, "CHERRY")) return "斗魂竞技场";
    if (std.ascii.eqlIgnoreCase(normalized, "URF")) return "无限火力";
    if (std.ascii.eqlIgnoreCase(normalized, "ONEFORALL")) return "克隆大作战";
    if (std.ascii.eqlIgnoreCase(normalized, "NEXUSBLITZ")) return "极限闪击";
    if (std.ascii.eqlIgnoreCase(normalized, "ULTBOOK")) return "终极魔典";
    if (std.ascii.eqlIgnoreCase(normalized, "KINGPORO")) return "魄罗王大乱斗";
    if (std.ascii.eqlIgnoreCase(normalized, "PRACTICETOOL")) return "训练模式";
    if (std.ascii.eqlIgnoreCase(normalized, "TUTORIAL")) return "新手教程";
    if (std.ascii.eqlIgnoreCase(normalized, "SWARM") or std.ascii.eqlIgnoreCase(normalized, "STRAWBERRY")) return "无尽狂潮";
    if (std.ascii.eqlIgnoreCase(normalized, "DOOMBOTS")) return "末日人机";
    if (std.ascii.eqlIgnoreCase(normalized, "ODYSSEY")) return "奥德赛";
    if (std.ascii.eqlIgnoreCase(normalized, "LEAGUE OF LEGENDS")) return "召唤师峡谷";
    if (normalized.len > 0) return normalized;
    if (queue_id == 0) return "自定义房间";
    if (queue_id > 0) return "未知模式";
    return "未知模式";
}

fn queueNameFromCatalog(catalog: std.json.Value, queue_id: i64, mode: []const u8) []const u8 {
    // Queue 0 is ambiguous: it is used for custom games, but Live Client
    // Data also omits queueId while still reporting an authoritative mode.
    if (queue_id > 0) if (knownQueueName(queue_id)) |name| return name;
    if (catalog == .array and queue_id > 0) for (catalog.array.items) |entry| {
        if (entry != .object or jsonInt(entry, "id") != queue_id) continue;
        for ([_][]const u8{ "name", "shortName", "description" }) |field| {
            const label = jsonField(entry, field);
            // Queue catalogs may contain internal mode identifiers such as
            // CLASS/CLASSIC. Always run catalog labels through the same
            // canonical mapper used by history and the frontend so those
            // values never leak into the user-facing game header.
            if (label.len > 0) return queueName(queue_id, label);
        }
    };
    return queueName(queue_id, mode);
}

fn jsonInt(value: std.json.Value, name: []const u8) i64 {
    if (value != .object) return 0;
    const item = value.object.get(name) orelse return 0;
    return switch (item) {
        .integer => |n| n,
        .float => |n| @intFromFloat(n),
        .string => |text| std.fmt.parseInt(i64, std.mem.trim(u8, text, " \t\r\n"), 10) catch 0,
        else => 0,
    };
}

fn queueLabelFromGame(game: std.json.Value) []const u8 {
    if (game != .object) return "未知模式";
    const queue_id = jsonInt(game, "queueId");
    for ([_][]const u8{ "queueName", "queueDescription", "gameModeName", "mapName" }) |field| {
        const value = jsonField(game, field);
        if (value.len > 0) return queueName(queue_id, value);
    }
    return queueName(queue_id, jsonField(game, "gameMode"));
}

fn connectionDto(summoner_json: []const u8, phase_json: []const u8, output: []u8) ![]const u8 {
    return connectionDtoDetailed(summoner_json, phase_json, "{}", "{}", "{}", "{}", output);
}

fn connectionDtoDetailed(summoner_json: []const u8, phase_json: []const u8, chat_json: []const u8, ranked_json: []const u8, lobby_json: []const u8, history_json: []const u8, output: []u8) ![]const u8 {
    return connectionDtoDetailedAt(summoner_json, phase_json, chat_json, ranked_json, lobby_json, history_json, 0, output);
}

fn connectionDtoDetailedAt(summoner_json: []const u8, phase_json: []const u8, chat_json: []const u8, ranked_json: []const u8, lobby_json: []const u8, history_json: []const u8, now_millis: i64, output: []u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const summoner = std.json.parseFromSliceLeaky(std.json.Value, allocator, summoner_json, .{}) catch return error.LcuInvalidResponse;
    const phase = std.json.parseFromSliceLeaky(std.json.Value, allocator, phase_json, .{}) catch return error.LcuInvalidResponse;
    const chat = std.json.parseFromSliceLeaky(std.json.Value, allocator, chat_json, .{}) catch .null;
    const ranked = std.json.parseFromSliceLeaky(std.json.Value, allocator, ranked_json, .{}) catch .null;
    const lobby = std.json.parseFromSliceLeaky(std.json.Value, allocator, lobby_json, .{}) catch .null;
    const history = std.json.parseFromSliceLeaky(std.json.Value, allocator, history_json, .{}) catch .null;
    if (summoner != .object) return error.LcuInvalidResponse;
    const phase_name = if (phase == .string) phase.string else "Unknown";
    const identity = riotIdentity(summoner);
    const display_name = identity.name;
    const platform_id = firstPlatformId(&.{ summoner, chat, ranked, lobby, history });
    const presence = if (std.mem.eql(u8, phase_name, "ChampSelect")) "champSelect" else if (std.mem.eql(u8, phase_name, "ReadyCheck")) "readyCheck" else if (std.mem.eql(u8, phase_name, "Lobby") or std.mem.eql(u8, phase_name, "Matchmaking")) "inQueue" else if (std.mem.eql(u8, phase_name, "InProgress") or std.mem.eql(u8, phase_name, "GameStart")) "inGame" else if (std.mem.eql(u8, phase_name, "WatchInProgress") or std.mem.eql(u8, phase_name, "Spectating") or std.mem.eql(u8, phase_name, "Watching")) "spectating" else if (std.mem.eql(u8, phase_name, "EndOfGame") or std.mem.eql(u8, phase_name, "PreEndOfGame")) "endOfGame" else "online";
    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll("{\"status\":\"connected\",\"phase\":");
    try jsonString(&writer, phase_name);
    try writer.writeAll(",\"summonerName\":");
    try jsonString(&writer, display_name);
    try writer.writeAll(",\"gameName\":");
    try jsonString(&writer, identity.name);
    try writer.writeAll(",\"tagLine\":");
    try jsonString(&writer, identity.tag);
    try writer.writeAll(",\"summonerLevel\":");
    try writeNullableInt(&writer, summoner, "summonerLevel");
    try writer.writeAll(",\"profileIconId\":");
    try writeNullableInt(&writer, summoner, "profileIconId");
    try writer.writeAll(",\"platformId\":");
    if (platform_id.len == 0) try writer.writeAll("null") else try jsonString(&writer, platform_id);
    try writer.writeAll(",\"region\":");
    if (platform_id.len == 0) try writer.writeAll("null") else try jsonString(&writer, platform_id);
    try writer.writeAll(",\"presence\":");
    try jsonString(&writer, presence);
    try writer.writeAll(",\"soloRank\":");
    try writeRank(&writer, ranked, "RANKED_SOLO_5x5");
    try writer.writeAll(",\"flexRank\":");
    try writeRank(&writer, ranked, "RANKED_FLEX_SR");
    try writer.writeAll(",\"queueLabel\":");
    const queue_label = if (jsonField(chat, "gameQueueType").len > 0) jsonField(chat, "gameQueueType") else if (jsonField(lobby, "gameMode").len > 0) jsonField(lobby, "gameMode") else "";
    if (queue_label.len == 0) try writer.writeAll("null") else try jsonString(&writer, queue_label);
    try writer.writeAll(",\"message\":\"LCU 已连接\",\"checkedAt\":");
    try writeIsoTimestamp(&writer, now_millis);
    try writer.writeByte('}');
    return writer.buffered();
}

fn firstPlatformId(values: []const std.json.Value) []const u8 {
    for (values) |value| {
        const direct = if (jsonField(value, "platformId").len > 0) jsonField(value, "platformId") else if (jsonField(value, "platformID").len > 0) jsonField(value, "platformID") else if (jsonField(value, "region").len > 0) jsonField(value, "region") else if (jsonField(value, "platform").len > 0) jsonField(value, "platform") else "";
        if (direct.len > 0) return direct;
        if (value == .object) {
            if (value.object.get("gameConfig")) |config| {
                const nested = firstPlatformId(&.{config});
                if (nested.len > 0) return nested;
            }
        }
    }
    return "";
}

fn writeNullableInt(writer: *std.Io.Writer, value: std.json.Value, name: []const u8) !void {
    if (value != .object or value.object.get(name) == null) return writer.writeAll("null");
    const number = jsonInt(value, name);
    if (number <= 0) return writer.writeAll("null");
    try writer.print("{d}", .{number});
}

fn writeRank(writer: *std.Io.Writer, ranked: std.json.Value, queue_type: []const u8) !void {
    const queue = rankQueueValue(ranked, queue_type) orelse return writer.writeAll("null");
    const actual = if (jsonField(queue, "queueType").len > 0) jsonField(queue, "queueType") else queue_type;
    const tier = jsonField(queue, "tier");
    if (tier.len == 0 or std.ascii.eqlIgnoreCase(tier, "UNRANKED") or std.ascii.eqlIgnoreCase(tier, "NA")) return writer.writeAll("null");
    const division = if (jsonField(queue, "rank").len > 0) jsonField(queue, "rank") else jsonField(queue, "division");
    try writer.writeAll("{\"queueType\":");
    try jsonString(writer, actual);
    try writer.writeAll(",\"tier\":");
    try jsonString(writer, tier);
    try writer.writeAll(",\"division\":");
    try jsonString(writer, division);
    try writer.print(",\"leaguePoints\":{d},\"wins\":{d},\"losses\":{d}}}", .{ jsonInt(queue, "leaguePoints"), jsonInt(queue, "wins"), jsonInt(queue, "losses") });
}

fn liveSessionEnvelope(session_json: []const u8, output: []u8) ![]const u8 {
    return liveSessionEnvelopePhase(session_json, "ChampSelect", null, output);
}

fn liveClientRosterHash(live_json: []const u8, session_json: ?[]const u8) u64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), live_json, .{}) catch return 0;
    if (root != .object) return 0;
    const players = root.object.get("allPlayers") orelse return 0;
    if (players != .array or players.array.items.len == 0) return 0;
    var hasher = std.hash.Wyhash.init(0);
    for (players.array.items) |player| {
        if (player != .object) continue;
        hasher.update(identityPuuid(player));
        hasher.update(jsonField(player, "riotId"));
        const identity = riotIdentity(player);
        hasher.update(identity.name);
        hasher.update(identity.tag);
        hasher.update(jsonField(player, "team"));
        hasher.update(jsonField(player, "rawChampionName"));
        hasher.update(jsonField(player, "championName"));
    }
    if (session_json) |session| hasher.update(session);
    return hasher.final();
}

fn liveClientEnvelope(self: *Runtime, client: lcu.Client, live_json: []const u8, session_json: ?[]const u8, phase: []const u8, current_json: ?[]const u8, catalog_json: []const u8, queue_catalog_json: []const u8, output: []u8, enrich: bool) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = std.json.parseFromSliceLeaky(std.json.Value, allocator, live_json, .{}) catch return error.LcuInvalidResponse;
    if (root != .object) return error.LcuInvalidResponse;
    const players = root.object.get("allPlayers") orelse return error.LcuInvalidResponse;
    if (players != .array or players.array.items.len == 0) return error.LcuInvalidResponse;
    const current_value = if (current_json) |value| std.json.parseFromSliceLeaky(std.json.Value, allocator, value, .{}) catch std.json.Value{ .null = {} } else std.json.Value{ .null = {} };
    const current = firstJsonValue(current_value);
    const catalog = std.json.parseFromSliceLeaky(std.json.Value, allocator, catalog_json, .{}) catch std.json.Value{ .null = {} };
    const queue_catalog = std.json.parseFromSliceLeaky(std.json.Value, allocator, queue_catalog_json, .{}) catch std.json.Value{ .null = {} };
    const session = if (session_json) |value| std.json.parseFromSliceLeaky(std.json.Value, allocator, value, .{}) catch std.json.Value{ .null = {} } else std.json.Value{ .null = {} };
    const active = root.object.get("activePlayer") orelse std.json.Value{ .null = {} };

    var current_team: []const u8 = "";
    var current_player_found = false;
    for (players.array.items) |player| {
        if (livePlayerMatches(player, current)) {
            current_team = jsonField(player, "team");
            current_player_found = true;
            break;
        }
    }
    if (current == .null) for (players.array.items) |player| {
        if (livePlayerMatches(player, active)) {
            current_team = jsonField(player, "team");
            current_player_found = true;
            break;
        }
    };
    // Rust rejects a Live Client overlay when a known local account cannot be
    // found in its roster. Falling back to the first array item can silently
    // flip ally/enemy because allPlayers ordering is not an ownership signal.
    // Live Client Data can briefly publish the roster before its active-player
    // identity catches up with current-summoner. Keep this topology and merge
    // it with the prior same-game snapshot instead of blanking the live page.
    if (current != .null and !current_player_found) return error.LcuInvalidResponse;
    if (current_team.len == 0) return error.LcuInvalidResponse;

    // Build each team once so the same normalized roster can be exposed both
    // through the legacy ally/enemy fields and the Rust-compatible `teams`
    // collection.
    const ally_json = std.heap.page_allocator.alloc(u8, 512 * 1024) catch return error.ResponseTooLarge;
    defer std.heap.page_allocator.free(ally_json);
    const enemy_json = std.heap.page_allocator.alloc(u8, 512 * 1024) catch return error.ResponseTooLarge;
    defer std.heap.page_allocator.free(enemy_json);
    const sgp_context = if (enrich) prepareJungleSgpContext(self, client, allocator) else null;
    var ally_writer = std.Io.Writer.fixed(ally_json);
    try writeLiveClientProfiles(self, client, sgp_context, &ally_writer, players, current_team, true, current, catalog, enrich);
    const ally_value = ally_writer.buffered();
    var enemy_writer = std.Io.Writer.fixed(enemy_json);
    try writeLiveClientProfiles(self, client, sgp_context, &enemy_writer, players, current_team, false, current, catalog, enrich);
    const enemy_value = enemy_writer.buffered();

    const game_data = nestedObject(root, "gameData") orelse std.json.Value{ .null = {} };
    const session_game_data = nestedObject(session, "gameData") orelse std.json.Value{ .null = {} };
    const queue = nestedObject(session_game_data, "queue") orelse std.json.Value{ .null = {} };
    const queue_id = if (jsonInt(queue, "id") > 0) jsonInt(queue, "id") else if (jsonInt(session_game_data, "queueId") > 0) jsonInt(session_game_data, "queueId") else if (jsonInt(session, "queueId") > 0) jsonInt(session, "queueId") else jsonInt(root, "queueId");
    const raw_mode = if (jsonField(game_data, "gameMode").len > 0) jsonField(game_data, "gameMode") else if (jsonField(queue, "gameMode").len > 0) jsonField(queue, "gameMode") else if (jsonField(session, "gameMode").len > 0) jsonField(session, "gameMode") else if (jsonField(root, "gameMode").len > 0) jsonField(root, "gameMode") else "League of Legends";
    const mode = queueNameFromCatalog(queue_catalog, queue_id, raw_mode);
    const game_id = if (jsonInt(session_game_data, "gameId") > 0) jsonInt(session_game_data, "gameId") else if (jsonInt(game_data, "gameId") > 0) jsonInt(game_data, "gameId") else if (jsonInt(session, "gameId") > 0) jsonInt(session, "gameId") else if (jsonInt(root, "gameId") > 0) jsonInt(root, "gameId") else 0;

    if (enrich and game_id > 0) persistLiveLobbyEncounters(self, players, current, current_team, game_id, queue_id, mode, catalog);

    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll("{\"id\":");
    if (game_id > 0) {
        var id: [32]u8 = undefined;
        try jsonString(&writer, try std.fmt.bufPrint(&id, "{d}", .{game_id}));
    } else try jsonString(&writer, "live-client");
    try writer.print(",\"queueId\":{d},\"gameMode\":", .{queue_id});
    try jsonString(&writer, mode);
    try writer.writeAll(",\"phase\":");
    try jsonString(&writer, phase);
    try writer.writeAll(",\"ally\":");
    try writer.writeAll(ally_value);
    try writer.writeAll(",\"enemy\":");
    try writer.writeAll(enemy_value);
    try writer.writeAll(",\"allySummary\":");
    try writeLiveTeamSummary(&writer, "ally", ally_value);
    try writer.writeAll(",\"enemySummary\":");
    try writeLiveTeamSummary(&writer, "enemy", enemy_value);
    try writer.writeAll(",\"layoutKind\":\"classic\",\"teams\":[{\"id\":\"ally\",\"label\":");
    try jsonString(&writer, if (isSpectatorPhase(phase)) "蓝方阵容" else "我方阵容");
    try writer.writeAll(",\"side\":\"ally\",\"players\":");
    try writer.writeAll(ally_value);
    try writer.writeAll(",\"summary\":");
    try writeLiveTeamSummary(&writer, "ally", ally_value);
    try writer.writeAll("},{\"id\":\"enemy\",\"label\":");
    try jsonString(&writer, if (isSpectatorPhase(phase)) "红方阵容" else "敌方阵容");
    try writer.writeAll(",\"side\":\"enemy\",\"players\":");
    try writer.writeAll(enemy_value);
    try writer.writeAll(",\"summary\":");
    try writeLiveTeamSummary(&writer, "enemy", enemy_value);
    try writer.writeAll("}],\"recentMatch\":");
    try writeCachedLatestMatch(self, &writer);
    try writer.writeAll(",\"generatedAt\":");
    try writeIsoTimestamp(&writer, runtimeNowMillis(self));
    try writer.writeAll(",\"isFixture\":false}");
    return writer.buffered();
}

fn persistLiveLobbyEncounters(self: *Runtime, players: std.json.Value, current: std.json.Value, current_team: []const u8, game_id: i64, queue_id: i64, queue_name: []const u8, catalog: std.json.Value) void {
    if (self.storage == null or players != .array or game_id <= 0) return;
    var current_puuid_buffer: [36]u8 = undefined;
    const current_puuid = resolvedIdentityPuuid(current, &current_puuid_buffer);
    if (current_puuid.len == 0) return;
    if (self.storage) |*store| store.put("matches", "currentPuuid", current_puuid) catch {};
    var self_player = current;
    for (players.array.items) |player| if (player == .object and livePlayerMatches(player, current)) {
        self_player = player;
        break;
    };
    const self_current_identity = riotIdentity(current);
    const self_live_identity = riotIdentity(self_player);
    const self_name = if (self_current_identity.name.len > 0) self_current_identity.name else if (self_live_identity.name.len > 0) self_live_identity.name else "未知玩家";
    const self_tag = if (self_current_identity.tag.len > 0) self_current_identity.tag else self_live_identity.tag;
    const self_champion_id = liveChampionId(self_player, catalog);
    const self_champion_name = if (self_champion_id > 0) catalogChampionName(catalog, self_champion_id, jsonField(self_player, "championName")) else championDisplayName(jsonField(self_player, "championName"), "未知英雄");
    const self_position = playerPosition(self_player);
    var output: [512 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    writer.writeByte('[') catch return;
    var first = true;
    var timestamp_buffer: [64]u8 = undefined;
    var timestamp_writer = std.Io.Writer.fixed(&timestamp_buffer);
    writeIsoTimestamp(&timestamp_writer, runtimeNowMillis(self)) catch return;
    const encountered_at = timestamp_writer.buffered();
    for (players.array.items) |player| {
        if (player != .object) continue;
        var player_puuid_buffer: [36]u8 = undefined;
        const puuid = resolvedIdentityPuuid(player, &player_puuid_buffer);
        if (puuid.len == 0 or std.mem.indexOf(u8, puuid, "-slot-") != null or samePuuid(puuid, current_puuid)) continue;
        const identity = riotIdentity(player);
        const team = jsonField(player, "team");
        const same_team = if (team.len > 0)
            sameLiveTeam(team, current_team)
        else blk: {
            const player_side = teamIdSide(jsonInt(player, "teamId"));
            const current_side = liveTeamSide(current_team);
            break :blk player_side >= 0 and current_side >= 0 and player_side == current_side;
        };
        const side = if (same_team) "ally" else "enemy";
        const champion_id = liveChampionId(player, catalog);
        const champion_name = if (champion_id > 0) catalogChampionName(catalog, champion_id, jsonField(player, "championName")) else championDisplayName(jsonField(player, "championName"), "未知英雄");
        if (!first) writer.writeByte(',') catch return;
        first = false;
        writer.print("{{\"gameId\":{d},\"queueId\":{d},\"queueName\":", .{ game_id, queue_id }) catch return;
        jsonString(&writer, if (queue_name.len > 0) queue_name else "对局") catch return;
        writer.writeAll(",\"selfPuuid\":") catch return;
        jsonString(&writer, current_puuid) catch return;
        writer.writeAll(",\"selfGameName\":") catch return;
        jsonString(&writer, self_name) catch return;
        writer.writeAll(",\"selfTagLine\":") catch return;
        jsonString(&writer, self_tag) catch return;
        writer.print(",\"selfChampionId\":{d},\"selfChampionName\":", .{self_champion_id}) catch return;
        jsonString(&writer, self_champion_name) catch return;
        writer.writeAll(",\"selfPosition\":") catch return;
        jsonString(&writer, self_position) catch return;
        writer.writeAll(",\"puuid\":") catch return;
        jsonString(&writer, puuid) catch return;
        writer.writeAll(",\"gameName\":") catch return;
        jsonString(&writer, if (identity.name.len > 0) identity.name else "未知玩家") catch return;
        writer.writeAll(",\"tagLine\":") catch return;
        jsonString(&writer, identity.tag) catch return;
        writer.print(",\"championId\":{d},\"championName\":", .{champion_id}) catch return;
        jsonString(&writer, champion_name) catch return;
        writer.writeAll(",\"side\":") catch return;
        jsonString(&writer, side) catch return;
        writer.writeAll(",\"position\":") catch return;
        jsonString(&writer, playerPosition(player)) catch return;
        writer.writeAll(",\"result\":null,\"liveSnapshot\":true,\"encounteredAt\":") catch return;
        writer.writeAll(encountered_at) catch return;
        writer.writeByte('}') catch return;
    }
    writer.writeByte(']') catch return;
    const records = writer.buffered();
    if (records.len > 2) _ = updateEncounterArchive(self, records, null);
}

fn livePlayerMatches(player: std.json.Value, identity: std.json.Value) bool {
    if (player != .object or identity != .object) return false;
    var player_puuid_buffer: [36]u8 = undefined;
    var identity_puuid_buffer: [36]u8 = undefined;
    const player_puuid = resolvedIdentityPuuid(player, &player_puuid_buffer);
    const identity_puuid = resolvedIdentityPuuid(identity, &identity_puuid_buffer);
    if (player_puuid.len > 0 and identity_puuid.len > 0) return samePuuid(player_puuid, identity_puuid);
    const player_id = identityNumericId(player);
    const identity_id = identityNumericId(identity);
    if (player_id > 0 and identity_id > 0) return player_id == identity_id;
    const player_riot = riotIdentity(player);
    const identity_riot = riotIdentity(identity);
    if (player_riot.name.len == 0 or identity_riot.name.len == 0 or
        !std.ascii.eqlIgnoreCase(player_riot.name, identity_riot.name)) return false;
    return player_riot.tag.len == 0 or identity_riot.tag.len == 0 or
        std.ascii.eqlIgnoreCase(player_riot.tag, identity_riot.tag);
}

/// Return the most recent decoded match snapshot for the live page. The
/// history endpoint is already fetched while enriching the current player;
/// reusing that SQLite snapshot keeps the game view populated during the
/// ChampSelect -> InProgress hand-off without another network round trip.
fn writeCachedLatestMatch(self: *Runtime, writer: *std.Io.Writer) !void {
    const store = if (self.storage) |*value| value else {
        try writer.writeAll("null");
        return;
    };
    const history = store.get("matches", "current") catch null orelse {
        try writer.writeAll("null");
        return;
    };
    defer std.heap.page_allocator.free(history);
    const puuid = store.get("matches", "currentPuuid") catch null;
    defer if (puuid) |value| std.heap.page_allocator.free(value);
    if (puuid == null or puuid.?.len == 0) {
        try writer.writeAll("null");
        return;
    }
    const catalog = store.get("cache", "champions") catch null;
    defer if (catalog) |value| std.heap.page_allocator.free(value);
    const buffer = std.heap.page_allocator.alloc(u8, 512 * 1024) catch {
        try writer.writeAll("null");
        return;
    };
    defer std.heap.page_allocator.free(buffer);
    const dto = matchHistoryDtoPage(history, catalog orelse "[]", puuid.?, 0, 1, buffer) catch {
        try writer.writeAll("null");
        return;
    };
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), dto, .{}) catch {
        try writer.writeAll("null");
        return;
    };
    if (parsed != .array or parsed.array.items.len == 0) {
        try writer.writeAll("null");
        return;
    }
    var stringify = std.json.Stringify{ .writer = writer, .options = .{} };
    try stringify.write(parsed.array.items[0]);
}

fn writeLiveClientProfiles(self: *Runtime, client: lcu.Client, sgp_context: ?JungleSgpContext, writer: *std.Io.Writer, players: std.json.Value, current_team: []const u8, ally: bool, current: std.json.Value, catalog: std.json.Value, enrich: bool) !void {
    try writer.writeByte('[');
    var first = true;
    var side_index: usize = 0;
    for (players.array.items) |player| {
        if (player != .object) continue;
        const same_team = sameLiveTeam(jsonField(player, "team"), current_team);
        if (same_team != ally) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writeLiveClientProfile(self, client, sgp_context, writer, player, if (ally) "ally" else "enemy", side_index, current, catalog, enrich, players);
        side_index += 1;
    }
    try writer.writeByte(']');
}

fn writeLiveClientProfile(self: *Runtime, client: lcu.Client, sgp_context: ?JungleSgpContext, writer: *std.Io.Writer, player: std.json.Value, side: []const u8, index: usize, current: std.json.Value, catalog: std.json.Value, enrich: bool, group_members: ?std.json.Value) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const summoner = nestedObject(player, "summoner") orelse player;
    const player_identity = riotIdentity(player);
    const summoner_identity = riotIdentity(summoner);
    const game_name = if (player_identity.name.len > 0) player_identity.name else summoner_identity.name;
    const tag_line = if (player_identity.tag.len > 0) player_identity.tag else summoner_identity.tag;
    const is_bot = isBotMember(player) or std.ascii.eqlIgnoreCase(tag_line, "BOT");
    const is_current = livePlayerMatches(player, current);
    var player_puuid_buffer: [36]u8 = undefined;
    const player_puuid = resolvedIdentityPuuid(player, &player_puuid_buffer);
    const player_numeric_identity = identityNumericId(player);

    var identity_owned: ?[]u8 = null;
    defer if (identity_owned) |value| std.heap.page_allocator.free(value);
    var identity = if (is_current) current else std.json.Value{ .null = {} };
    if (enrich and !is_bot and !is_current) {
        // A stable PUUID is the most reliable identity key. ChampSelect often
        // omits Riot ID text, and name lookup is not consistently supported by
        // every regional client build.
        // Live Client already supplies Riot ID and PUUID for most players.
        // Resolving the same PUUID through /summoner adds one serial request
        // per card; only fall back when the roster omitted a display name.
        if (player_puuid.len > 0 and game_name.len == 0 and !isNumericIdentity(player_puuid)) {
            var path_buffer: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buffer, "/lol-summoner/v2/summoners/puuid/{s}", .{player_puuid}) catch "";
            if (path.len > 0) identity_owned = client.get(path) catch null;
        }
        var riot_id_buffer: [512]u8 = undefined;
        if (identity_owned == null and game_name.len > 0) {
            const riot_id = if (tag_line.len > 0) std.fmt.bufPrint(&riot_id_buffer, "{s}#{s}", .{ game_name, tag_line }) catch game_name else game_name;
            var encoded_buffer: [1536]u8 = undefined;
            if (percentEncodeQuery(riot_id, &encoded_buffer)) |encoded| {
                var path_buffer: [1792]u8 = undefined;
                const path = std.fmt.bufPrint(&path_buffer, "/lol-summoner/v1/summoners?name={s}", .{encoded}) catch "";
                if (path.len > 0) identity_owned = client.get(path) catch null;
            } else |_| {}
        }
        // Gameflow team members often contain only a numeric summonerId once
        // the client enters InProgress. Resolve that stable id when Riot ID
        // text is unavailable so the card still gets PUUID, rank and history.
        if (identity_owned == null and player_numeric_identity > 0) {
            var path_buffer: [256]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buffer, "/lol-summoner/v1/summoners/{d}", .{player_numeric_identity}) catch "";
            if (path.len > 0) identity_owned = client.get(path) catch null;
        }
        if (identity_owned) |value| {
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, value, .{}) catch std.json.Value{ .null = {} };
            identity = firstJsonValue(parsed);
        }
    }

    var identity_puuid_buffer: [36]u8 = undefined;
    const resolved_identity_puuid = if (identity != .null) resolvedIdentityPuuid(identity, &identity_puuid_buffer) else "";
    const puuid = if (resolved_identity_puuid.len > 0) resolved_identity_puuid else player_puuid;
    const numeric_identity = if (identity != .null and identityNumericId(identity) > 0) identityNumericId(identity) else player_numeric_identity;
    const resolved_identity = if (identity != .null) riotIdentity(identity) else RiotIdentity{};
    const resolved_name = if (resolved_identity.name.len > 0) resolved_identity.name else game_name;
    const resolved_tag = if (resolved_identity.tag.len > 0) resolved_identity.tag else tag_line;
    const profile_icon_id = if (identity != .null and jsonInt(identity, "profileIconId") > 0) jsonInt(identity, "profileIconId") else if (jsonInt(player, "profileIconId") > 0) jsonInt(player, "profileIconId") else jsonInt(summoner, "profileIconId");
    const champion_id = liveChampionId(player, catalog);
    const raw_champion_name = if (jsonField(player, "championName").len > 0) jsonField(player, "championName") else jsonField(player, "rawChampionName");
    const champion_name = if (champion_id > 0) catalogChampionName(catalog, champion_id, raw_champion_name) else championDisplayName(raw_champion_name, "已选择");
    const position = if (playerPosition(player).len > 0) playerPosition(player) else "NONE";

    var rank_owned: ?[]u8 = null;
    defer if (rank_owned) |value| std.heap.page_allocator.free(value);
    var ranked = std.json.Value{ .null = {} };
    if (enrich and !is_bot and puuid.len > 0) {
        if (self.storage) |*store| {
            rank_owned = store.get("playerRank", puuid) catch null;
            if (rank_owned) |value| ranked = std.json.parseFromSliceLeaky(std.json.Value, allocator, value, .{}) catch std.json.Value{ .null = {} };
        }
        var path_buffer: [512]u8 = undefined;
        if (rank_owned == null) {
            const path = std.fmt.bufPrint(&path_buffer, "/lol-ranked/v1/ranked-stats/{s}", .{puuid}) catch "";
            if (path.len > 0) rank_owned = client.get(path) catch null;
            if (rank_owned) |value| {
                ranked = std.json.parseFromSliceLeaky(std.json.Value, allocator, value, .{}) catch std.json.Value{ .null = {} };
                if (ranked != .null) if (self.storage) |*store| store.put("playerRank", puuid, value) catch {};
            }
        }
    }
    const solo = rankQueueValue(ranked, "RANKED_SOLO_5x5");

    var history_owned = if (enrich and !is_bot and puuid.len > 0) cachedPlayerHistory(self, puuid, is_current) else null;
    defer if (history_owned) |value| std.heap.page_allocator.free(value);
    if (enrich and !is_bot and puuid.len > 0 and history_owned == null) {
        var path_buffer: [768]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buffer, "/lol-match-history/v1/products/lol/{s}/matches?begIndex=0&endIndex=19", .{puuid}) catch "";
        if (path.len > 0) history_owned = client.get(path) catch null;
        if (history_owned) |value| if (self.storage) |*store| store.put(if (is_current) "matches" else "playerHistory", if (is_current) "current" else puuid, value) catch {};
    }

    // Tencent clients can return an empty LCU match-history envelope for
    // other players even though SGP has the same data. Rust builds one SGP
    // context per lobby and uses it as the fallback; keep the same provider
    // behavior here so cards do not lose recentMatches after GameStart.
    var sgp_history_owned: ?[]u8 = null;
    defer if (sgp_history_owned) |value| std.heap.page_allocator.free(value);
    if (enrich and !is_bot and puuid.len > 0 and
        (history_owned == null or !historyHasGames(history_owned.?)))
    {
        sgp_history_owned = fetchSgpHistory(client, current, history_owned orelse "{}", puuid, 0, 20) catch null;
        if (sgp_history_owned) |value| {
            if (historyHasGames(value)) {
                if (self.storage) |*store| {
                    store.put(if (is_current) "matches" else "playerHistory", if (is_current) "current" else puuid, value) catch {};
                    if (is_current) store.put("matches", "currentPuuid", puuid) catch {};
                }
            } else {
                std.heap.page_allocator.free(value);
                sgp_history_owned = null;
            }
        }
    }
    const preferred_history = preferredHistory(history_owned, sgp_history_owned) orelse history_owned;

    var recent_owned: ?[]u8 = null;
    defer if (recent_owned) |value| std.heap.page_allocator.free(value);
    var recent_json: []const u8 = "[]";
    var recent_count: usize = 0;
    if (preferred_history) |history| {
        recent_owned = std.heap.page_allocator.alloc(u8, 256 * 1024) catch null;
        if (recent_owned) |buffer| {
            var recent_writer = std.Io.Writer.fixed(buffer);
            // Keep enough history for the live-page stepper (1..20). The
            // shortcut formatter still limits its own statistics to the
            // configured recent-game count.
            recent_count = writeRecentMatches(&recent_writer, history, catalog, puuid, 20) catch 0;
            recent_json = recent_writer.buffered();
        }
    }

    var gank_metrics_owned: ?[]u8 = null;
    defer if (gank_metrics_owned) |value| std.heap.page_allocator.free(value);
    if (enrich and !is_bot and puuid.len > 0 and recent_count > 0 and !isJunglePosition(position)) {
        gank_metrics_owned = std.heap.page_allocator.alloc(u8, 256 * 1024) catch null;
        if (gank_metrics_owned) |buffer| {
            if (enrichRecentGankMetrics(self, client, sgp_context, recent_json, puuid, buffer) catch null) |enriched| {
                recent_json = enriched;
            }
        }
    }

    try writer.writeAll("{\"puuid\":");
    if (puuid.len > 0) try jsonString(writer, puuid) else if (numeric_identity > 0) {
        var numeric_buffer: [32]u8 = undefined;
        try jsonString(writer, try std.fmt.bufPrint(&numeric_buffer, "{d}", .{numeric_identity}));
    } else {
        var synthetic: [128]u8 = undefined;
        const value = std.fmt.bufPrint(&synthetic, "{s}-{s}-{d}", .{ side, if (is_bot) "bot" else "slot", index }) catch side;
        try jsonString(writer, value);
    }
    try writer.writeAll(",\"gameName\":");
    try jsonString(writer, if (resolved_name.len > 0) resolved_name else "未知玩家");
    try writer.writeAll(",\"tagLine\":");
    try jsonString(writer, resolved_tag);
    try writer.print(",\"isBot\":{},\"championId\":{d},\"championName\":", .{ is_bot, champion_id });
    try jsonString(writer, champion_name);
    try writer.print(",\"profileIconId\":{d},\"assignedPosition\":", .{profile_icon_id});
    try jsonString(writer, position);
    // Preserve summoner spells in the live roster. Champ-select may not
    // provide an assigned position yet, so shortcut targeting can identify
    // the jungler from Smite (spell id 11) instead of array order.
    try writer.writeAll(",\"summonerSpells\":");
    try writeSummonerSpells(writer, player);
    try writer.writeAll(",\"rankTier\":");
    try jsonString(writer, if (solo) |value| if (jsonField(value, "tier").len > 0) jsonField(value, "tier") else "UNRANKED" else "UNRANKED");
    try writer.writeAll(",\"rankDivision\":");
    try jsonString(writer, if (solo) |value| if (jsonField(value, "rank").len > 0) jsonField(value, "rank") else jsonField(value, "division") else "");
    try writer.print(",\"leaguePoints\":{d},\"wins\":{d},\"losses\":{d},\"soloRank\":", .{ if (solo) |value| jsonInt(value, "leaguePoints") else 0, if (solo) |value| jsonInt(value, "wins") else 0, if (solo) |value| jsonInt(value, "losses") else 0 });
    try writeRank(writer, ranked, "RANKED_SOLO_5x5");
    try writer.writeAll(",\"flexRank\":");
    try writeRank(writer, ranked, "RANKED_FLEX_SR");
    try writer.writeAll(",\"recentMatches\":");
    try writer.writeAll(recent_json);
    try writer.writeAll(",\"topChampions\":");
    try writeRecentChampionUsage(writer, recent_json);
    try writer.writeAll(",\"score\":");
    try writeRecentScore(writer, recent_json);
    const encounter = encounterProfileSummary(self, puuid);
    try writer.writeAll(",\"tags\":");
    try writeRecentTags(writer, recent_json, position, champion_id, encounter);
    try writer.writeAll(",\"junglePreference\":");
    try writeJunglePreference(writer, recent_json, champion_id);
    try writeEncounterProfileFields(writer, encounter);
    try writePremadeFields(writer, player, group_members);
    try writer.writeAll(",\"positionGames\":");
    try writer.print("{d},\"positionWinRate\":{d:.4},\"currentChampionGames\":{d},\"currentChampionWinRate\":{d:.4},\"championPoolConcentration\":{d:.4},\"dataComplete\":", .{ recentPositionGames(recent_json, position), recentPositionWinRate(recent_json, position), recentChampionGames(recent_json, champion_id), recentChampionWinRate(recent_json, champion_id), recentChampionConcentration(recent_json) });
    try writer.writeAll(if (is_bot or recent_count > 0) "true" else "false");
    try writer.writeAll(",\"unavailableSources\":[");
    var missing = false;
    if (!is_bot and ranked == .null) {
        try jsonString(writer, "rank");
        missing = true;
    }
    if (!is_bot and recent_count == 0) {
        if (missing) try writer.writeByte(',');
        try jsonString(writer, "recentMatches");
    }
    try writer.writeAll("],\"dataStatus\":{\"source\":\"lcu\",\"fetchedAt\":");
    try writeIsoTimestamp(writer, runtimeNowMillis(self));
    try writer.writeAll(",\"expiresAt\":null,\"isStale\":false,\"error\":null},\"side\":");
    try jsonString(writer, side);
    try writer.writeByte('}');
}

fn cachedPlayerHistory(self: *Runtime, puuid: []const u8, is_current: bool) ?[]u8 {
    const store = if (self.storage) |*value| value else return null;
    if (is_current) {
        const owner = store.get("matches", "currentPuuid") catch null orelse return null;
        defer std.heap.page_allocator.free(owner);
        if (owner.len == 0 or !std.mem.eql(u8, owner, puuid)) return null;
    }
    return store.get(if (is_current) "matches" else "playerHistory", if (is_current) "current" else puuid) catch null;
}

const EncounterSummary = recent_tags.EncounterSummary;

fn encounterProfileSummary(self: *Runtime, puuid: []const u8) EncounterSummary {
    var summary = EncounterSummary{};
    var encounters_owned: ?[]u8 = null;
    defer if (encounters_owned) |value| std.heap.page_allocator.free(value);
    if (puuid.len > 0) if (self.storage) |*store| {
        const owner = store.get("matches", "currentPuuid") catch null;
        defer if (owner) |value| std.heap.page_allocator.free(value);
        encounters_owned = store.get("history", "encounters") catch null;
        if (encounters_owned) |json| {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{}) catch std.json.Value{ .null = {} };
            if (parsed == .array) for (parsed.array.items) |record| {
                if (record != .object or !samePuuid(jsonField(record, "puuid"), puuid)) continue;
                if (owner) |current_owner| if (!samePuuid(jsonField(record, "selfPuuid"), current_owner)) continue;
                summary.count += 1;
                const encountered_at = jsonField(record, "encounteredAt");
                const latest = summary.latestValue();
                if (encountered_at.len > 0 and encountered_at.len <= summary.latest.len and (latest.len == 0 or std.mem.order(u8, encountered_at, latest) == .gt)) {
                    @memcpy(summary.latest[0..encountered_at.len], encountered_at);
                    summary.latest_len = encountered_at.len;
                }
            };
            return summary;
        }
    };
    return summary;
}

fn writeEncounterProfileFields(writer: *std.Io.Writer, summary: EncounterSummary) !void {
    try writer.print(",\"encounterCount\":{d},\"lastEncounteredAt\":", .{summary.count});
    if (summary.latest_len > 0) try jsonString(writer, summary.latestValue()) else try writer.writeAll("null");
}

fn primeCurrentHistory(self: *Runtime, client: lcu.Client, current_json: []const u8) void {
    const store = if (self.storage) |*value| value else return;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const current = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), current_json, .{}) catch return;
    const identity = firstJsonValue(current);
    if (identity != .object) return;
    const puuid = jsonField(identity, "puuid");
    if (puuid.len == 0) return;

    // Do not spend another request when the dashboard already primed the same
    // account. A changed Riot account must replace the owner marker before its
    // history is exposed to the live page.
    const owner = store.get("matches", "currentPuuid") catch null;
    defer if (owner) |value| std.heap.page_allocator.free(value);
    if (owner) |value| if (std.mem.eql(u8, value, puuid)) {
        if (store.get("matches", "current") catch null) |history| {
            defer std.heap.page_allocator.free(history);
            if (historyHasGames(history)) return;
        }
    };

    var path_buffer: [768]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "/lol-match-history/v1/products/lol/{s}/matches?begIndex=0&endIndex=49", .{puuid}) catch return;
    const lcu_history = client.get(path) catch null;
    defer if (lcu_history) |history| std.heap.page_allocator.free(history);
    const sgp_history: ?[]u8 = fetchSgpHistory(client, identity, lcu_history orelse "{}", puuid, 0, 50) catch null;
    defer if (sgp_history) |history| std.heap.page_allocator.free(history);
    const history = preferredHistory(lcu_history, sgp_history) orelse return;
    store.put("matches", "current", history) catch return;
    store.put("matches", "currentPuuid", puuid) catch {};
    persistEncountersFromHistory(self, history, puuid);
}

fn firstJsonValue(value: std.json.Value) std.json.Value {
    return if (value == .array and value.array.items.len > 0) value.array.items[0] else value;
}

fn percentEncodeQuery(value: []const u8, output: []u8) ![]const u8 {
    const digits = "0123456789ABCDEF";
    var cursor: usize = 0;
    for (value) |byte| {
        const unreserved = std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~';
        if (unreserved) {
            if (cursor >= output.len) return error.NoSpaceLeft;
            output[cursor] = byte;
            cursor += 1;
        } else {
            if (cursor + 3 > output.len) return error.NoSpaceLeft;
            output[cursor] = '%';
            output[cursor + 1] = digits[byte >> 4];
            output[cursor + 2] = digits[byte & 0x0f];
            cursor += 3;
        }
    }
    return output[0..cursor];
}

fn liveChampionId(player: std.json.Value, catalog: std.json.Value) i64 {
    const selected_id = selectedChampionId(player);
    if (selected_id > 0) return selected_id;
    const raw = if (jsonField(player, "rawChampionName").len > 0) jsonField(player, "rawChampionName") else jsonField(player, "championName");
    const alias = championDisplayName(raw, "");
    const localized = jsonField(player, "championName");
    if (catalog == .array) for (catalog.array.items) |champion| {
        if (champion != .object) continue;
        if ((alias.len > 0 and std.ascii.eqlIgnoreCase(alias, jsonField(champion, "alias"))) or
            (alias.len > 0 and std.ascii.eqlIgnoreCase(alias, jsonField(champion, "name"))) or
            (localized.len > 0 and std.mem.eql(u8, localized, jsonField(champion, "name"))) or
            (localized.len > 0 and std.ascii.eqlIgnoreCase(localized, jsonField(champion, "alias")))) return jsonInt(champion, "id");
    };
    return 0;
}

fn selectedChampionId(player: std.json.Value) i64 {
    if (jsonInt(player, "championId") > 0) return jsonInt(player, "championId");
    // ChampSelect exposes hovers/intents before the pick is committed. Rust
    // uses the same fallback so portraits update without waiting for gameflow.
    if (jsonInt(player, "championPickIntent") > 0) return jsonInt(player, "championPickIntent");
    if (jsonInt(player, "botChampionId") > 0) return jsonInt(player, "botChampionId");
    return nestedArrayFirstInt(player, "playerSlots", "championId");
}

fn championDisplayName(value: []const u8, fallback: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return fallback;
    if (std.mem.lastIndexOfScalar(u8, trimmed, '_')) |separator| {
        const suffix = std.mem.trim(u8, trimmed[separator + 1 ..], " \t\r\n");
        if (suffix.len > 0 and (std.ascii.startsWithIgnoreCase(trimmed, "game_character_") or
            std.ascii.startsWithIgnoreCase(trimmed, "champion_"))) return suffix;
    }
    return trimmed;
}

fn rankQueueValue(ranked: std.json.Value, queue_type: []const u8) ?std.json.Value {
    if (ranked == .object) {
        if (ranked.object.get("queueMap")) |queue_map| if (queue_map == .object) {
            if (queue_map.object.get(queue_type)) |queue| if (queue == .object) return queue;
        };
        const actual = if (jsonField(ranked, "queueType").len > 0) jsonField(ranked, "queueType") else jsonField(ranked, "queue");
        if (std.mem.eql(u8, actual, queue_type)) return ranked;
    }
    const queues = if (ranked == .array)
        ranked
    else if (ranked == .object)
        ranked.object.get("queues") orelse return null
    else
        return null;
    if (queues != .array) return null;
    for (queues.array.items) |queue| {
        const actual = if (jsonField(queue, "queueType").len > 0) jsonField(queue, "queueType") else jsonField(queue, "queue");
        if (std.mem.eql(u8, actual, queue_type)) return queue;
    }
    return null;
}

fn writeRecentMatches(writer: *std.Io.Writer, history_json: []const u8, catalog: std.json.Value, puuid: []const u8, limit: usize) !usize {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = std.json.parseFromSliceLeaky(std.json.Value, allocator, history_json, .{}) catch {
        try writer.writeAll("[]");
        return 0;
    };
    const games_value = if (root == .array) root else if (root == .object) root.object.get("games") orelse std.json.Value{ .null = {} } else std.json.Value{ .null = {} };
    const games = if (games_value == .object) games_value.object.get("games") orelse std.json.Value{ .null = {} } else games_value;
    try writer.writeByte('[');
    if (games != .array) {
        try writer.writeByte(']');
        return 0;
    }
    var count: usize = 0;
    for (games.array.items) |entry| {
        if (count >= limit) break;
        const game = if (entry == .object) if (entry.object.get("json")) |payload| switch (payload) {
            .string => |encoded| std.json.parseFromSliceLeaky(std.json.Value, allocator, encoded, .{}) catch continue,
            .object => payload,
            else => entry,
        } else entry else entry;
        if (game != .object) continue;
        // Live scouting follows the Rust implementation and excludes custom,
        // training, aborted, and sub-minute records from the ten-game sample.
        if (isHiddenHistoryGame(game)) continue;
        const participants = game.object.get("participants") orelse continue;
        const participant = participantForPuuid(game, participants, puuid);
        if (participant == .null) continue;
        if (count > 0) try writer.writeByte(',');
        count += 1;
        const champion_id = jsonInt(participant, "championId");
        const duration = if (jsonInt(game, "gameDuration") > 0) jsonInt(game, "gameDuration") else jsonInt(participant, "timePlayed");
        const team_id = jsonInt(participant, "teamId");
        const damage = statInt(participant, "totalDamageDealtToChampions");
        const taken = statInt(participant, "totalDamageTaken");
        const kills = statInt(participant, "kills");
        const deaths = statInt(participant, "deaths");
        const assists = statInt(participant, "assists");
        const team_damage = teamStat(participants, team_id, "totalDamageDealtToChampions");
        const team_kills = teamStat(participants, team_id, "kills");
        const explicit_damage_share = statFloat(participant, "damageDealtToChampionsRate");
        const damage_share = if (explicit_damage_share > 0)
            if (explicit_damage_share > 1) explicit_damage_share / 100.0 else explicit_damage_share
        else
            ratio(damage, team_damage);
        const kill_participation = ratio(kills + assists, team_kills);
        const performance = matchPerformance(statBool(participant, "win"), kills, deaths, assists, damage_share);
        const is_mvp = teamParticipantCount(participants, team_id) >= 2 and
            participantScore(participant, team_damage) >= bestTeamScore(participants, team_id, team_damage);
        try writer.print("{{\"gameId\":{d},\"championId\":{d},\"championName\":", .{ jsonInt(game, "gameId"), champion_id });
        try jsonString(writer, catalogChampionName(catalog, champion_id, jsonField(participant, "championName")));
        try writer.writeAll(",\"queueName\":");
        try jsonString(writer, queueLabelFromGame(game));
        try writer.writeAll(",\"position\":");
        try jsonString(writer, participantPosition(participant));
        try writer.print(",\"kills\":{d},\"deaths\":{d},\"assists\":{d},\"durationMinutes\":{d},\"items\":", .{ kills, deaths, assists, @divTrunc(duration, 60) });
        try writeItems(writer, participant);
        try writer.writeAll(",\"summonerSpells\":");
        try writeSummonerSpells(writer, participant);
        try writer.writeAll(",\"runes\":");
        try writeRunes(writer, participant);
        try writer.print(",\"damageDealt\":{d},\"damageTaken\":{d},\"heal\":{d},\"goldEarned\":{d},\"cs\":{d},\"damageShare\":{d:.4},\"killParticipation\":{d:.4}", .{ damage, taken, statInt(participant, "totalHeal"), statInt(participant, "goldEarned"), statInt(participant, "totalMinionsKilled") + statInt(participant, "neutralMinionsKilled"), damage_share, kill_participation });
        for ([_][]const u8{
            "soloKills",
            "takedownsFirstXMinutes",
            "jungleCsBefore10Minutes",
            "alliedJungleMonsterKills",
            "enemyJungleMonsterKills",
            "dragonTakedowns",
            "baronTakedowns",
            "riftHeraldTakedowns",
            "scuttleCrabKills",
        }) |field| {
            try writer.writeByte(',');
            try jsonString(writer, field);
            try writer.writeByte(':');
            try writeChallengeNumber(writer, participant, field);
        }
        try writer.writeAll(",\"performance\":");
        try jsonString(writer, performance);
        try writer.writeAll(",\"mvp\":");
        if (is_mvp and duration >= 60) try jsonString(writer, if (statBool(participant, "win")) "MVP" else "SVP") else try writer.writeAll("null");
        try writer.writeAll(",\"win\":");
        try writer.writeAll(if (statBool(participant, "win")) "true" else "false");
        try writer.writeAll(",\"playedAt\":");
        const created_at = if (jsonInt(game, "gameCreation") > 0) jsonInt(game, "gameCreation") else jsonInt(game, "gameStartTimestamp");
        try writeIsoTimestamp(writer, created_at);
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
    return count;
}

fn challengeValue(participant: std.json.Value, name: []const u8) ?f64 {
    if (nestedObject(participant, "challenges")) |challenges| {
        if (challenges.object.get(name) != null) {
            const value = jsonFloat(challenges, name);
            if (std.math.isFinite(value) and value >= 0) return value;
        }
    }
    if (nestedObject(participant, "stats")) |stats| if (nestedObject(stats, "challenges")) |challenges| {
        if (challenges.object.get(name) != null) {
            const value = jsonFloat(challenges, name);
            if (std.math.isFinite(value) and value >= 0) return value;
        }
    };
    return null;
}

fn writeChallengeNumber(writer: *std.Io.Writer, participant: std.json.Value, name: []const u8) !void {
    if (challengeValue(participant, name)) |value| {
        try writer.print("{d:.4}", .{value});
    } else {
        try writer.writeAll("null");
    }
}

fn containsHiddenMatchLabel(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return std.mem.indexOf(u8, trimmed, "训练") != null or
        std.mem.indexOf(u8, trimmed, "自定义") != null or
        std.ascii.indexOfIgnoreCase(trimmed, "practice") != null or
        std.ascii.indexOfIgnoreCase(trimmed, "tutorial") != null or
        std.ascii.indexOfIgnoreCase(trimmed, "custom") != null;
}

fn isHiddenHistoryGame(game: std.json.Value) bool {
    if (game != .object) return true;
    if (jsonInt(game, "gameDuration") < 60) return true;
    if (jsonBool(game, "gameEndedInEarlySurrender")) return true;
    if (game.object.get("participants")) |participants| if (participants == .array) for (participants.array.items) |participant| {
        if (jsonBool(participant, "gameEndedInEarlySurrender")) return true;
    };
    for ([_][]const u8{ "endOfGameResult", "gameEndReason", "terminationReason" }) |field| {
        const value = jsonField(game, field);
        if (std.ascii.indexOfIgnoreCase(value, "ABORT") != null or
            std.ascii.indexOfIgnoreCase(value, "TOOFEWPLAYERS") != null or
            std.ascii.indexOfIgnoreCase(value, "EARLYEXIT") != null) return true;
    }
    switch (jsonInt(game, "queueId")) {
        0, 2000, 2010, 2020, 3140 => return true,
        else => {},
    }
    if (containsHiddenMatchLabel(queueLabelFromGame(game))) return true;
    for ([_][]const u8{ "queueName", "queueDescription", "gameModeName", "gameMode", "gameType", "mapName", "status", "result" }) |field| {
        if (containsHiddenMatchLabel(jsonField(game, field))) return true;
    }
    return false;
}

const RecentStats = struct { count: usize = 0, wins: usize = 0, kda_total: f64 = 0 };

fn recentStats(json: []const u8) RecentStats {
    var stats = RecentStats{};
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{}) catch return stats;
    if (root != .array) return stats;
    for (root.array.items) |match| {
        if (match != .object) continue;
        stats.count += 1;
        if (jsonBool(match, "win")) stats.wins += 1;
        const deaths = jsonInt(match, "deaths");
        stats.kda_total += @as(f64, @floatFromInt(jsonInt(match, "kills") + jsonInt(match, "assists"))) / @as(f64, @floatFromInt(@max(deaths, 1)));
    }
    return stats;
}

const JungleChampion = struct {
    id: i64 = 0,
    name: []const u8 = "",
    games: usize = 0,
    wins: usize = 0,
};

fn writeJunglePreference(writer: *std.Io.Writer, json: []const u8, current_champion_id: i64) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{}) catch {
        try writer.writeAll("null");
        return;
    };
    if (root != .array) {
        try writer.writeAll("null");
        return;
    }

    var sample_size: usize = 0;
    var wins: usize = 0;
    var kda_total: f64 = 0;
    var participation_total: f64 = 0;
    var cs_per_minute_total: f64 = 0;
    var early_total: f64 = 0;
    var early_count: usize = 0;
    var objective_total: f64 = 0;
    var objective_count: usize = 0;
    var enemy_jungle_total: f64 = 0;
    var enemy_jungle_count: usize = 0;
    var current_champion_games: usize = 0;
    var champions: [20]JungleChampion = [_]JungleChampion{.{}} ** 20;
    var champion_count: usize = 0;

    for (root.array.items) |match| {
        if (match != .object or jsonInt(match, "durationMinutes") <= 0 or !isJunglePosition(jsonField(match, "position"))) continue;
        sample_size += 1;
        const won = jsonBool(match, "win");
        if (won) wins += 1;
        const deaths = @max(jsonInt(match, "deaths"), 1);
        kda_total += @as(f64, @floatFromInt(jsonInt(match, "kills") + jsonInt(match, "assists"))) / @as(f64, @floatFromInt(deaths));
        participation_total += jsonFloat(match, "killParticipation");
        cs_per_minute_total += @as(f64, @floatFromInt(jsonInt(match, "cs"))) / @as(f64, @floatFromInt(@max(jsonInt(match, "durationMinutes"), 1)));
        if (jsonOptionalFloat(match, "takedownsFirstXMinutes")) |value| {
            early_total += value;
            early_count += 1;
        }
        var objectives: f64 = 0;
        var has_objectives = false;
        for ([_][]const u8{ "dragonTakedowns", "baronTakedowns", "riftHeraldTakedowns" }) |field| if (jsonOptionalFloat(match, field)) |value| {
            objectives += value;
            has_objectives = true;
        };
        if (has_objectives) {
            objective_total += objectives;
            objective_count += 1;
        }
        if (jsonOptionalFloat(match, "enemyJungleMonsterKills")) |value| {
            enemy_jungle_total += value;
            enemy_jungle_count += 1;
        }

        const champion_id = jsonInt(match, "championId");
        if (champion_id == current_champion_id) current_champion_games += 1;
        var champion_index: ?usize = null;
        for (champions[0..champion_count], 0..) |champion, index| if (champion.id == champion_id) {
            champion_index = index;
            break;
        };
        if (champion_index == null and champion_count < champions.len) {
            champion_index = champion_count;
            champions[champion_count].id = champion_id;
            champions[champion_count].name = jsonField(match, "championName");
            champion_count += 1;
        }
        if (champion_index) |index| {
            champions[index].games += 1;
            if (won) champions[index].wins += 1;
        }
    }
    if (sample_size == 0) {
        try writer.writeAll("null");
        return;
    }

    const sample = @as(f64, @floatFromInt(sample_size));
    const average_kda = kda_total / sample;
    const average_participation = participation_total / sample;
    const average_cs = cs_per_minute_total / sample;
    const average_early: ?f64 = if (early_count > 0) early_total / @as(f64, @floatFromInt(early_count)) else null;
    const average_objectives: ?f64 = if (objective_count > 0) objective_total / @as(f64, @floatFromInt(objective_count)) else null;
    const average_enemy_jungle: ?f64 = if (enemy_jungle_count > 0) enemy_jungle_total / @as(f64, @floatFromInt(enemy_jungle_count)) else null;
    const style: []const u8 = if ((average_early orelse 0) >= 2 or average_participation >= 0.62) "tempo" else if (average_cs >= 6.5 and average_participation < 0.55) "farm" else "balanced";
    const label: []const u8 = if (std.mem.eql(u8, style, "tempo")) "节奏带动型" else if (std.mem.eql(u8, style, "farm")) "发育控图型" else "均衡型";

    try writer.print("{{\"sampleSize\":{d},\"wins\":{d},\"winRate\":{d:.4},\"style\":", .{ sample_size, wins, @as(f64, @floatFromInt(wins)) / sample });
    try jsonString(writer, style);
    try writer.writeAll(",\"label\":");
    try jsonString(writer, label);
    var evidence_buffer: [512]u8 = undefined;
    var evidence_writer = std.Io.Writer.fixed(&evidence_buffer);
    try evidence_writer.print("近{d}场打野，参团 {d:.0}%，分均补刀 {d:.1}", .{ sample_size, average_participation * 100, average_cs });
    if (average_early) |value| try evidence_writer.print("，前期场均参与击杀 {d:.1}", .{value});
    if (average_objectives) |value| try evidence_writer.print("，场均资源参与 {d:.1}", .{value});
    if (average_enemy_jungle) |value| if (value >= 3) try evidence_writer.print("，场均反野 {d:.1}", .{value});
    try writer.writeAll(",\"evidence\":");
    try jsonString(writer, evidence_writer.buffered());
    try writer.print(",\"averageKda\":{d:.1},\"averageKillParticipation\":{d:.4},\"averageCsPerMinute\":{d:.1},\"averageEarlyTakedowns\":", .{ average_kda, average_participation, average_cs });
    try writeOptionalFloat(writer, average_early);
    try writer.writeAll(",\"averageObjectiveTakedowns\":");
    try writeOptionalFloat(writer, average_objectives);
    try writer.writeAll(",\"averageEnemyJungleMonsters\":");
    try writeOptionalFloat(writer, average_enemy_jungle);
    try writer.writeAll(",\"mainChampions\":[");
    var emitted: usize = 0;
    var used: [20]bool = [_]bool{false} ** 20;
    while (emitted < @min(champion_count, 3)) : (emitted += 1) {
        var best: ?usize = null;
        for (champions[0..champion_count], 0..) |champion, index| {
            if (used[index]) continue;
            if (best == null or champion.games > champions[best.?].games or (champion.games == champions[best.?].games and champion.wins > champions[best.?].wins)) best = index;
        }
        const index = best orelse break;
        used[index] = true;
        const champion = champions[index];
        if (emitted > 0) try writer.writeByte(',');
        try writer.print("{{\"championId\":{d},\"championName\":", .{champion.id});
        try jsonString(writer, champion.name);
        try writer.print(",\"games\":{d},\"wins\":{d},\"winRate\":{d:.4}}}", .{ champion.games, champion.wins, @as(f64, @floatFromInt(champion.wins)) / @as(f64, @floatFromInt(@max(champion.games, 1))) });
    }
    try writer.print("],\"currentChampionGames\":{d}}}", .{current_champion_games});
}

fn isJunglePosition(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "JUNGLE") or std.ascii.eqlIgnoreCase(value, "JUG");
}

fn samePuuid(left: []const u8, right: []const u8) bool {
    return left.len > 0 and right.len > 0 and
        std.ascii.eqlIgnoreCase(std.mem.trim(u8, left, " \t\r\n"), std.mem.trim(u8, right, " \t\r\n"));
}

fn playerPosition(value: std.json.Value) []const u8 {
    for ([_][]const u8{ "assignedPosition", "position", "botPosition", "teamPosition", "role", "firstPositionPreference", "secondPositionPreference" }) |field| {
        const position = jsonField(value, field);
        if (position.len > 0 and !isUnknownPosition(position)) return position;
    }
    return "";
}

fn isUnknownPosition(value: []const u8) bool {
    const normalized = std.mem.trim(u8, value, " \t\r\n");
    return std.ascii.eqlIgnoreCase(normalized, "NONE") or
        std.ascii.eqlIgnoreCase(normalized, "UNKNOWN") or
        std.ascii.eqlIgnoreCase(normalized, "UNASSIGNED");
}

fn playerIsJungle(value: std.json.Value) bool {
    return shortcut_service.isJunglePlayer(value);
}

fn jsonOptionalFloat(value: std.json.Value, name: []const u8) ?f64 {
    if (value != .object) return null;
    const item = value.object.get(name) orelse return null;
    const number: f64 = switch (item) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        .string => |text| std.fmt.parseFloat(f64, text) catch return null,
        else => return null,
    };
    return if (std.math.isFinite(number) and number >= 0) number else null;
}

fn writeOptionalFloat(writer: *std.Io.Writer, value: ?f64) !void {
    if (value) |number| try writer.print("{d:.1}", .{number}) else try writer.writeAll("null");
}

fn recentPositionGames(json: []const u8, position: []const u8) usize {
    if (position.len == 0) return 0;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{}) catch return 0;
    if (root != .array) return 0;
    var count: usize = 0;
    for (root.array.items) |match| {
        if (match == .object and std.ascii.eqlIgnoreCase(jsonField(match, "position"), position)) {
            count += 1;
        }
    }
    return count;
}

fn recentPositionWinRate(json: []const u8, position: []const u8) f64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{}) catch return 0;
    if (root != .array) return 0;
    var games: usize = 0;
    var wins: usize = 0;
    for (root.array.items) |match| {
        if (match != .object or position.len == 0 or !std.ascii.eqlIgnoreCase(jsonField(match, "position"), position)) continue;
        games += 1;
        if (jsonBool(match, "win")) wins += 1;
    }
    if (games == 0) return 0;
    return @as(f64, @floatFromInt(wins)) / @as(f64, @floatFromInt(games));
}

fn recentChampionGames(json: []const u8, champion_id: i64) usize {
    if (champion_id <= 0) return 0;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{}) catch return 0;
    if (root != .array) return 0;
    var count: usize = 0;
    for (root.array.items) |match| {
        if (match == .object and jsonInt(match, "championId") == champion_id) {
            count += 1;
        }
    }
    return count;
}

fn recentChampionWinRate(json: []const u8, champion_id: i64) f64 {
    if (champion_id <= 0) return 0;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{}) catch return 0;
    if (root != .array) return 0;
    var games: usize = 0;
    var wins: usize = 0;
    for (root.array.items) |match| {
        if (match != .object or jsonInt(match, "championId") != champion_id) continue;
        games += 1;
        if (jsonBool(match, "win")) wins += 1;
    }
    if (games == 0) return 0;
    return @as(f64, @floatFromInt(wins)) / @as(f64, @floatFromInt(games));
}

fn recentChampionConcentration(json: []const u8) f64 {
    return recent_tags.championConcentration(json);
}

fn writeRecentChampionUsage(writer: *std.Io.Writer, json: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{}) catch {
        try writer.writeAll("[]");
        return;
    };
    if (root != .array) {
        try writer.writeAll("[]");
        return;
    }
    var ids: [32]i64 = .{0} ** 32;
    var names: [32][]const u8 = undefined;
    var games: [32]usize = .{0} ** 32;
    var wins: [32]usize = .{0} ** 32;
    var length: usize = 0;
    for (root.array.items) |match| {
        if (match != .object) continue;
        const id = jsonInt(match, "championId");
        var index: ?usize = null;
        for (ids[0..length], 0..) |known, candidate| if (known == id) {
            index = candidate;
            break;
        };
        const actual = index orelse if (length < ids.len) blk: {
            ids[length] = id;
            names[length] = jsonField(match, "championName");
            length += 1;
            break :blk length - 1;
        } else continue;
        games[actual] += 1;
        if (jsonBool(match, "win")) wins[actual] += 1;
    }
    // Stable, deterministic ordering by sample count then original order.
    var order: [32]usize = undefined;
    for (0..length) |index| order[index] = index;
    for (0..length) |left| for (left + 1..length) |right| if (games[order[right]] > games[order[left]]) {
        const swap = order[left];
        order[left] = order[right];
        order[right] = swap;
    };
    try writer.writeByte('[');
    for (order[0..@min(length, 5)], 0..) |index, emitted| {
        if (emitted > 0) try writer.writeByte(',');
        try writer.print("{{\"championId\":{d},\"championName\":", .{ids[index]});
        try jsonString(writer, if (names[index].len > 0) names[index] else "未知英雄");
        try writer.print(",\"games\":{d},\"wins\":{d},\"winRate\":{d:.4}}}", .{ games[index], wins[index], @as(f64, @floatFromInt(wins[index])) / @as(f64, @floatFromInt(@max(games[index], 1))) });
    }
    try writer.writeByte(']');
}

fn writeRecentScore(writer: *std.Io.Writer, json: []const u8) !void {
    const stats = recentStats(json);
    if (stats.count == 0) {
        try writer.writeAll("{\"total\":0,\"confidence\":0,\"components\":[]}");
        return;
    }
    const win_rate = @as(f64, @floatFromInt(stats.wins)) / @as(f64, @floatFromInt(stats.count));
    const average_kda = stats.kda_total / @as(f64, @floatFromInt(stats.count));
    const total = @min(100.0, @max(0.0, 35.0 + win_rate * 45.0 + @min(average_kda, 5.0) * 4.0));
    try writer.print("{{\"total\":{d:.1},\"confidence\":{d:.1},\"components\":[{{\"key\":\"recent\",\"label\":\"近期战绩\",\"score\":{d:.1},\"maxScore\":60,\"evidence\":\"近{d}场胜率 {d:.0}%\"}},{{\"key\":\"kda\",\"label\":\"KDA\",\"score\":{d:.1},\"maxScore\":40,\"evidence\":\"平均 KDA {d:.2}\"}}]}}", .{ total, @min(100.0, @as(f64, @floatFromInt(stats.count * 10))), win_rate * 60.0, stats.count, win_rate * 100.0, @min(40.0, average_kda * 4.0), average_kda });
}

fn writeRecentTags(writer: *std.Io.Writer, json: []const u8, assigned_position: []const u8, current_champion_id: i64, encounter: EncounterSummary) !void {
    return recent_tags.write(writer, json, assigned_position, current_champion_id, encounter);
}

fn liveSessionEnvelopePhase(session_json: []const u8, phase: []const u8, current_json: ?[]const u8, output: []u8) ![]const u8 {
    return liveSessionEnvelopePhaseContext(null, null, session_json, null, phase, current_json, "[]", "[]", output, true);
}

fn liveSessionEnvelopePhaseContext(self: ?*Runtime, client: ?lcu.Client, session_json: []const u8, custom_lobby_json: ?[]const u8, phase: []const u8, current_json: ?[]const u8, catalog_json: []const u8, queue_catalog_json: []const u8, output: []u8, enrich: bool) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const session = std.json.parseFromSliceLeaky(std.json.Value, allocator, session_json, .{}) catch return error.LcuInvalidResponse;
    if (session != .object) return error.LcuInvalidResponse;
    const catalog = std.json.parseFromSliceLeaky(std.json.Value, allocator, catalog_json, .{}) catch std.json.Value{ .null = {} };
    const queue_catalog = std.json.parseFromSliceLeaky(std.json.Value, allocator, queue_catalog_json, .{}) catch std.json.Value{ .null = {} };
    const game_data = nestedObject(session, "gameData");
    const queue_id = if (game_data) |value| if (nestedObject(value, "queue")) |queue| if (jsonInt(queue, "id") > 0) jsonInt(queue, "id") else jsonInt(value, "queueId") else jsonInt(value, "queueId") else if (jsonInt(session, "queueId") > 0) jsonInt(session, "queueId") else jsonInt(session, "gameQueueConfigId");
    const game_mode = if (game_data) |value| if (nestedObject(value, "queue")) |queue| if (jsonField(queue, "gameMode").len > 0) jsonField(queue, "gameMode") else jsonField(value, "gameMode") else jsonField(value, "gameMode") else if (jsonField(session, "gameMode").len > 0) jsonField(session, "gameMode") else jsonField(session, "mapName");
    const resolved_mode = queueNameFromCatalog(queue_catalog, queue_id, if (game_mode.len > 0) game_mode else "League of Legends");
    const game_id = if (game_data) |value| if (jsonInt(value, "gameId") > 0) jsonInt(value, "gameId") else jsonInt(session, "gameId") else jsonInt(session, "gameId");
    const current = if (current_json) |current_text| std.json.parseFromSliceLeaky(std.json.Value, allocator, current_text, .{}) catch std.json.Value{ .null = {} } else std.json.Value{ .null = {} };
    const ally_value = if (std.mem.eql(u8, phase, "ChampSelect") or std.mem.eql(u8, phase, "ReadyCheck"))
        session.object.get("myTeam")
    else
        sessionTeamValue(session, "teamOne", "ally");
    const enemy_value = if (std.mem.eql(u8, phase, "ChampSelect") or std.mem.eql(u8, phase, "ReadyCheck"))
        session.object.get("theirTeam")
    else
        sessionTeamValue(session, "teamTwo", "enemy");
    var ally = ally_value;
    var enemy = enemy_value;
    var custom_roster = false;
    if (custom_lobby_json) |custom_text| {
        const custom = std.json.parseFromSliceLeaky(std.json.Value, allocator, custom_text, .{}) catch std.json.Value{ .null = {} };
        var custom_teams = customLobbyRosters(custom);
        const party_members = try partyLobbyMembers(allocator, custom);
        if (current != .null and !arrayContainsIdentity(custom_teams.ally, current) and arrayContainsIdentity(custom_teams.enemy, current)) {
            const swapped = custom_teams.ally;
            custom_teams.ally = custom_teams.enemy;
            custom_teams.enemy = swapped;
        }
        if (customRosterIsAuthoritative(custom_teams.ally, custom_teams.enemy, ally, enemy, current)) {
            ally = custom_teams.ally;
            enemy = custom_teams.enemy;
            custom_roster = true;
        } else {
            // ChampSelect owns the visible floor order, while the lobby DTO is
            // often the only source of party identifiers. Overlay only those
            // fields so the local player remains part of the detected premade
            // without replacing the champ-select topology.
            ally = try mergeRosterPartyMetadata(allocator, ally, custom_teams.ally);
            enemy = try mergeRosterPartyMetadata(allocator, enemy, custom_teams.enemy);
        }
        // A normal matchmaking lobby exposes the premade only through the
        // root `members` array plus one root partyId. Those members all belong
        // to the local party and must be overlaid after either roster path.
        ally = try mergeRosterPartyMetadata(allocator, ally, party_members);
    }
    var flat_selections: ?std.json.Value = null;
    if (!custom_roster) if (game_data) |value| if (value.object.get("playerChampionSelections")) |selections| {
        // Gameflow can expose one team before the other while its flat
        // selections list already contains all ten slots. Use that list for
        // the incomplete side as well as for an entirely empty roster.
        if (arrayLike(selections)) |array| {
            const ally_count = if (ally) |team| if (arrayLike(team)) |array_value| array_value.array.items.len else 0 else 0;
            const enemy_count = if (enemy) |team| if (arrayLike(team)) |array_value| array_value.array.items.len else 0 else 0;
            if (array.array.items.len > 0 and (ally == null or enemy == null or ally_count == 0 or enemy_count == 0)) flat_selections = array;
        }
    };
    if (!custom_roster and flat_selections == null) {
        const ally_count = if (ally) |team| if (arrayLike(team)) |array_value| array_value.array.items.len else 0 else 0;
        const enemy_count = if (enemy) |team| if (arrayLike(team)) |array_value| array_value.array.items.len else 0 else 0;
        if (ally_count == 0 or enemy_count == 0) flat_selections = sessionFlatRosterValue(session);
    }
    if (current != .null) {
        if (!arrayContainsIdentity(ally, current) and arrayContainsIdentity(enemy, current)) {
            const swapped = ally;
            ally = enemy;
            enemy = swapped;
        }
    }
    var ally_count = if (ally) |team| if (arrayLike(team)) |array_value| array_value.array.items.len else 0 else 0;
    var enemy_count = if (enemy) |team| if (arrayLike(team)) |array_value| array_value.array.items.len else 0 else 0;
    // Match Rust's fill_roster_side: gameflow can expose one real player (or
    // one team) while playerChampionSelections already contains ten seats.
    // Keep the real entries and fill only missing seats from the matching
    // half, so the opponent never disappears at GameStart.
    if (flat_selections) |flat| if (flat == .array and flat.array.items.len >= 10) {
        if (ally_count < 5) {
            ally = try fillRosterSideValue(allocator, ally, flat, 0, 5);
            ally_count = if (ally) |team| if (arrayLike(team)) |array_value| array_value.array.items.len else 0 else 0;
        }
        if (enemy_count < 5) {
            enemy = try fillRosterSideValue(allocator, enemy, flat, 5, 5);
            enemy_count = if (enemy) |team| if (arrayLike(team)) |array_value| array_value.array.items.len else 0 else 0;
        }
    };
    // Gameflow can briefly omit only the local participant while retaining the
    // other nine seats. Rust keeps the current account on our side so the live
    // card and ally-targeted shortcuts do not disappear during that snapshot.
    // A spectator is not a participant and must never be injected.
    try injectCurrentPlayerValue(allocator, &ally, enemy, current, isSpectatorPhase(phase));
    ally_count = if (ally) |team| if (arrayLike(team)) |array_value| array_value.array.items.len else 0 else 0;
    enemy_count = if (enemy) |team| if (arrayLike(team)) |array_value| array_value.array.items.len else 0 else 0;
    // A flat game-start selection list is also supported when only one side
    // exists, but it must not replace an already populated topology.
    const ally_from_flat = flat_selections != null and ally_count == 0;
    const enemy_from_flat = flat_selections != null and enemy_count == 0;

    const ally_json = std.heap.page_allocator.alloc(u8, 512 * 1024) catch return error.ResponseTooLarge;
    defer std.heap.page_allocator.free(ally_json);
    const enemy_json = std.heap.page_allocator.alloc(u8, 512 * 1024) catch return error.ResponseTooLarge;
    defer std.heap.page_allocator.free(enemy_json);
    const sgp_context = if (enrich and self != null and client != null)
        prepareJungleSgpContext(self.?, client.?, allocator)
    else
        null;
    var ally_writer = std.Io.Writer.fixed(ally_json);
    if (enrich and self != null and client != null) {
        if (ally_from_flat) try writeProfileArraySelectionEnriched(self.?, client.?, sgp_context, &ally_writer, flat_selections.?, "ally", current, catalog) else try writeProfileArrayEnriched(self.?, client.?, sgp_context, &ally_writer, ally, "ally", current, catalog);
    } else if (ally_from_flat) try writeProfileArraySelection(&ally_writer, flat_selections.?, "ally", catalog) else try writeProfileArray(&ally_writer, ally, "ally", catalog);
    const ally_json_value = ally_writer.buffered();
    var enemy_writer = std.Io.Writer.fixed(enemy_json);
    if (enrich and self != null and client != null) {
        if (enemy_from_flat) try writeProfileArraySelectionEnriched(self.?, client.?, sgp_context, &enemy_writer, flat_selections.?, "enemy", current, catalog) else try writeProfileArrayEnriched(self.?, client.?, sgp_context, &enemy_writer, enemy, "enemy", current, catalog);
    } else if (enemy_from_flat) try writeProfileArraySelection(&enemy_writer, flat_selections.?, "enemy", catalog) else try writeProfileArray(&enemy_writer, enemy, "enemy", catalog);
    const enemy_json_value = enemy_writer.buffered();

    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll("{\"id\":");
    if (game_id > 0) {
        var id_buffer: [32]u8 = undefined;
        try jsonString(&writer, try std.fmt.bufPrint(&id_buffer, "{d}", .{game_id}));
    } else try jsonString(&writer, "lcu-session");
    try writer.writeAll(",\"queueId\":");
    try writer.print("{d}", .{queue_id});
    try writer.writeAll(",\"gameMode\":");
    try jsonString(&writer, resolved_mode);
    try writer.writeAll(",\"phase\":");
    try jsonString(&writer, phase);
    try writer.writeAll(",\"ally\":");
    try writer.writeAll(ally_json_value);
    try writer.writeAll(",\"enemy\":");
    try writer.writeAll(enemy_json_value);
    try writer.writeAll(",\"allySummary\":");
    try writeLiveTeamSummary(&writer, "ally", ally_json_value);
    try writer.writeAll(",\"enemySummary\":");
    try writeLiveTeamSummary(&writer, "enemy", enemy_json_value);
    try writer.writeAll(",\"layoutKind\":\"classic\",\"teams\":[{\"id\":\"ally\",\"label\":");
    try jsonString(&writer, if (isSpectatorPhase(phase)) "蓝方阵容" else "我方阵容");
    try writer.writeAll(",\"side\":\"ally\",\"players\":");
    try writer.writeAll(ally_json_value);
    try writer.writeAll(",\"summary\":");
    try writeLiveTeamSummary(&writer, "ally", ally_json_value);
    try writer.writeAll("},{\"id\":\"enemy\",\"label\":");
    try jsonString(&writer, if (isSpectatorPhase(phase)) "红方阵容" else "敌方阵容");
    try writer.writeAll(",\"side\":\"enemy\",\"players\":");
    try writer.writeAll(enemy_json_value);
    try writer.writeAll(",\"summary\":");
    try writeLiveTeamSummary(&writer, "enemy", enemy_json_value);
    try writer.writeAll("}],\"recentMatch\":");
    if (self) |runtime_value| try writeCachedLatestMatch(runtime_value, &writer) else try writer.writeAll("null");
    try writer.writeAll(",\"generatedAt\":");
    try writeRuntimeTimestamp(&writer, self);
    try writer.writeAll(",\"isFixture\":false}");
    return writer.buffered();
}

fn fillRosterSideValue(allocator: std.mem.Allocator, real: ?std.json.Value, selections: std.json.Value, start: usize, max_len: usize) !?std.json.Value {
    const selection_array = if (selections == .array) selections.array.items else return real;
    var merged = std.json.Array.init(allocator);
    if (real) |candidate| if (arrayLike(candidate)) |array| {
        try merged.ensureTotalCapacity(@min(max_len, array.array.items.len + max_len));
        for (array.array.items) |member| {
            if (merged.items.len >= max_len) break;
            try merged.append(member);
        }
    };
    const end = @min(selection_array.len, start + max_len);
    var index = start;
    while (index < end and merged.items.len < max_len) : (index += 1) {
        const selection = selection_array[index];
        var duplicate = false;
        for (merged.items) |member| {
            if (livePlayerMatches(member, selection) or sameRosterSlot(member, selection)) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) try merged.append(selection);
    }
    return .{ .array = merged };
}

fn injectCurrentPlayerValue(allocator: std.mem.Allocator, ally: *?std.json.Value, enemy: ?std.json.Value, current: std.json.Value, spectator: bool) !void {
    if (spectator or current != .object or arrayContainsIdentity(ally.*, current) or arrayContainsIdentity(enemy, current)) return;

    var players = std.json.Array.init(allocator);
    if (ally.*) |candidate| if (arrayLike(candidate)) |array| {
        try players.ensureTotalCapacity(@max(@as(usize, 1), array.array.items.len));
        for (array.array.items) |member| try players.append(member);
    };
    if (players.items.len < 5) {
        try players.insert(0, current);
    } else {
        const replace_index = for (players.items, 0..) |member, index| {
            if (unresolvedRosterMember(member)) break index;
        } else return;
        players.items[replace_index] = current;
    }
    ally.* = .{ .array = players };
}

fn unresolvedRosterMember(member: std.json.Value) bool {
    if (member != .object) return true;
    const puuid = identityPuuid(member);
    if (puuid.len > 0 and std.mem.indexOf(u8, puuid, "-slot-") == null) return false;
    const name = riotIdentity(member).name;
    return name.len == 0 or std.mem.eql(u8, name, "未知玩家") or
        std.mem.startsWith(u8, name, "蓝方玩家") or std.mem.startsWith(u8, name, "红方玩家");
}

fn writeProfileArrayEnriched(self: *Runtime, client: lcu.Client, sgp_context: ?JungleSgpContext, writer: *std.Io.Writer, value: ?std.json.Value, side: []const u8, current: std.json.Value, catalog: std.json.Value) !void {
    try writer.writeByte('[');
    if (value) |candidate| if (arrayLike(candidate)) |array| {
        var first = true;
        var index: usize = 0;
        for (array.array.items) |participant| {
            if (participant != .object) continue;
            if (!first) try writer.writeByte(',');
            first = false;
            try writeLiveClientProfile(self, client, sgp_context, writer, participant, side, index, current, catalog, true, array);
            index += 1;
        }
    };
    try writer.writeByte(']');
}

fn writeProfileArraySelectionEnriched(self: *Runtime, client: lcu.Client, sgp_context: ?JungleSgpContext, writer: *std.Io.Writer, value: std.json.Value, side: []const u8, current: std.json.Value, catalog: std.json.Value) !void {
    try writer.writeByte('[');
    if (arrayLike(value)) |array| {
        var first = true;
        var side_index: usize = 0;
        for (array.array.items, 0..) |participant, index| {
            if (participant != .object) continue;
            const team_id = jsonInt(participant, "teamId");
            const include = if (teamIdSide(team_id) >= 0)
                (std.mem.eql(u8, side, "ally") and teamIdSide(team_id) == 0) or (std.mem.eql(u8, side, "enemy") and teamIdSide(team_id) == 1)
            else if (std.mem.eql(u8, side, "ally")) index < 5 else index >= 5;
            if (!include) continue;
            if (!first) try writer.writeByte(',');
            first = false;
            try writeLiveClientProfile(self, client, sgp_context, writer, participant, side, side_index, current, catalog, true, array);
            side_index += 1;
        }
    }
    try writer.writeByte(']');
}

fn writeProfileArraySelection(writer: *std.Io.Writer, value: std.json.Value, side: []const u8, catalog: std.json.Value) !void {
    try writer.writeByte('[');
    if (arrayLike(value)) |array| {
        var first = true;
        var side_index: usize = 0;
        for (array.array.items, 0..) |participant, index| {
            if (participant != .object) continue;
            const team_id = jsonInt(participant, "teamId");
            const include = if (teamIdSide(team_id) >= 0)
                (std.mem.eql(u8, side, "ally") and teamIdSide(team_id) == 0) or (std.mem.eql(u8, side, "enemy") and teamIdSide(team_id) == 1)
            else if (std.mem.eql(u8, side, "ally")) index < 5 else index >= 5;
            if (!include) continue;
            if (!first) try writer.writeByte(',');
            first = false;
            try writeProfileWithGroupIndexed(writer, participant, side, side_index, catalog, array);
            side_index += 1;
        }
    }
    try writer.writeByte(']');
}

fn sessionTeamValue(session: std.json.Value, name: []const u8, side: []const u8) ?std.json.Value {
    const aliases = if (std.mem.eql(u8, side, "ally"))
        [_][]const u8{ name, "myTeam", "blueTeam", "blue" }
    else
        [_][]const u8{ name, "theirTeam", "redTeam", "red" };
    for (aliases) |alias| if (session.object.get(alias)) |value| if (arrayLike(value)) |array| return array;
    // Some gameflow builds expose the same topology using champ-select names
    // even after the phase has moved to InProgress.
    if (nestedObject(session, "gameData")) |game_data| {
        for (aliases) |alias| if (game_data.object.get(alias)) |value| if (arrayLike(value)) |array| return array;
        if (game_data.object.get("playerRoster")) |roster| if (roster == .object) {
            for (aliases) |alias| if (roster.object.get(alias)) |value| if (arrayLike(value)) |array| return array;
        };
    }
    if (nestedObject(session, "playerRoster")) |roster| {
        for (aliases) |alias| if (roster.object.get(alias)) |value| if (arrayLike(value)) |array| return array;
    }
    return null;
}

fn sessionFlatRosterValue(session: std.json.Value) ?std.json.Value {
    if (session != .object) return null;
    for ([_][]const u8{ "playerChampionSelections", "participants", "players" }) |name| {
        if (session.object.get(name)) |value| if (arrayLike(value)) |array| if (array.array.items.len > 0) return array;
    }
    if (session.object.get("playerRoster")) |roster| {
        if (arrayLike(roster)) |array| if (array.array.items.len > 0) return array;
    }
    if (nestedObject(session, "gameData")) |game_data| {
        for ([_][]const u8{ "playerChampionSelections", "participants", "players" }) |name| {
            if (game_data.object.get(name)) |value| if (arrayLike(value)) |array| if (array.array.items.len > 0) return array;
        }
        if (game_data.object.get("playerRoster")) |roster| {
            if (arrayLike(roster)) |array| if (array.array.items.len > 0) return array;
        }
    }
    return null;
}

const CustomLobbyRosters = struct {
    ally: ?std.json.Value = null,
    enemy: ?std.json.Value = null,
};

fn customLobbyRosters(lobby: std.json.Value) CustomLobbyRosters {
    if (lobby != .object) return .{};
    const config = nestedObject(lobby, "gameConfig") orelse lobby;
    return .{
        .ally = customTeamValue(config, [_][]const u8{ "customTeam100", "team100", "blueTeam" }),
        .enemy = customTeamValue(config, [_][]const u8{ "customTeam200", "team200", "redTeam" }),
    };
}

fn partyLobbyMembers(allocator: std.mem.Allocator, lobby: std.json.Value) !?std.json.Value {
    if (lobby != .object) return null;
    const raw_members = lobby.object.get("members") orelse return null;
    const members = arrayLike(raw_members) orelse return null;
    const party_id = jsonField(lobby, "partyId");
    const local_member = nestedObject(lobby, "localMember");

    var normalized = std.json.Array.init(allocator);
    try normalized.ensureTotalCapacity(members.array.items.len + @as(usize, if (local_member != null) 1 else 0));
    var contains_local = false;
    for (members.array.items) |member| {
        var value = member;
        if (value == .object and premadeGroupValue(value) == null) try value.object.put(allocator, "partyId", .{ .string = party_id });
        if (local_member) |local| if (samePremadeMember(value, local)) {
            contains_local = true;
        };
        try normalized.append(value);
    }
    // Some client versions keep the current account only in `localMember`.
    // Add it to the party metadata source so group output includes the user,
    // while the visible ChampSelect roster still owns the floor order.
    if (local_member) |local| if (!contains_local) {
        var value = local;
        if (premadeGroupValue(value) == null and party_id.len > 0) try value.object.put(allocator, "partyId", .{ .string = party_id });
        try normalized.append(value);
    };
    return .{ .array = normalized };
}

fn customTeamValue(value: std.json.Value, keys: [3][]const u8) ?std.json.Value {
    if (value != .object) return null;
    for (keys) |key| if (value.object.get(key)) |candidate| if (arrayLike(candidate)) |array| return array;
    return null;
}

fn rosterValueLen(value: ?std.json.Value) usize {
    if (value) |candidate| if (arrayLike(candidate)) |array| return array.array.items.len;
    return 0;
}

fn rosterValueBotCount(value: ?std.json.Value) usize {
    var count: usize = 0;
    if (value) |candidate| if (arrayLike(candidate)) |array| for (array.array.items) |member| {
        if (isBotMember(member)) count += 1;
    };
    return count;
}

fn customRosterIsAuthoritative(candidate_ally: ?std.json.Value, candidate_enemy: ?std.json.Value, fallback_ally: ?std.json.Value, fallback_enemy: ?std.json.Value, current: std.json.Value) bool {
    const candidate_count = rosterValueLen(candidate_ally) + rosterValueLen(candidate_enemy);
    if (candidate_count == 0) return false;
    const candidate_has_current = current != .null and (arrayContainsIdentity(candidate_ally, current) or arrayContainsIdentity(candidate_enemy, current));
    const candidate_bots = rosterValueBotCount(candidate_ally) + rosterValueBotCount(candidate_enemy);
    const fallback_count = rosterValueLen(fallback_ally) + rosterValueLen(fallback_enemy);
    return (candidate_has_current and candidate_count > 1) or candidate_bots > 0 or candidate_count >= fallback_count;
}

fn mergeRosterPartyMetadata(allocator: std.mem.Allocator, roster: ?std.json.Value, lobby_roster: ?std.json.Value) !?std.json.Value {
    const source = if (lobby_roster) |value| arrayLike(value) else null;
    const target = if (roster) |value| arrayLike(value) else null;
    if (source == null or target == null) return roster;

    var merged = std.json.Array.init(allocator);
    try merged.ensureTotalCapacity(target.?.array.items.len);
    for (target.?.array.items) |member| {
        var enriched = member;
        if (member == .object) for (source.?.array.items) |candidate| {
            if (candidate != .object or !(samePremadeMember(member, candidate) or sameRosterSlot(member, candidate))) continue;
            try overlayRosterPartyMetadata(allocator, &enriched, candidate);
            break;
        };
        try merged.append(enriched);
    }
    return .{ .array = merged };
}

fn overlayRosterPartyMetadata(allocator: std.mem.Allocator, target: *std.json.Value, source: std.json.Value) !void {
    if (target.* != .object or source != .object) return;
    for ([_][]const u8{ "teamParticipantId", "partyId", "partyID", "premadeGroupId", "premadeId", "isPremade", "premade" }) |name| {
        const value = memberFieldValue(source, name) orelse continue;
        try target.object.put(allocator, name, value);
    }
}

fn isBotMember(value: std.json.Value) bool {
    if (value != .object) return false;
    if (jsonBool(value, "isBot") or jsonBool(value, "bot") or std.ascii.eqlIgnoreCase(jsonField(value, "type"), "BOT")) return true;
    for ([_][]const u8{ "botUuid", "botId" }) |field| {
        const item = value.object.get(field) orelse continue;
        switch (item) {
            .string => |text| if (std.mem.trim(u8, text, " \t\r\n").len > 0) return true,
            .integer => |number| if (number != 0) return true,
            .float => |number| if (number != 0) return true,
            else => {},
        }
    }
    for ([_][]const u8{ "botDifficulty", "botSkillLevel" }) |field| {
        const text = jsonField(value, field);
        if (text.len > 0 and !std.ascii.eqlIgnoreCase(text, "NONE")) return true;
    }
    if (nestedObject(value, "player")) |player| return isBotMember(player);
    return false;
}

/// LCU has shipped both raw arrays and wrapper objects (`players`,
/// `participants`, or `members`) for the same roster fields. Return the
/// underlying array without allocating a second JSON tree.
fn arrayLike(value: std.json.Value) ?std.json.Value {
    if (value == .array) return value;
    if (value != .object) return null;
    for ([_][]const u8{ "players", "participants", "members", "team", "roster" }) |name| {
        if (value.object.get(name)) |nested| if (nested == .array) return nested;
    }
    return null;
}

fn memberFieldValue(member: std.json.Value, name: []const u8) ?std.json.Value {
    if (member != .object) return null;
    if (member.object.get(name)) |value| if (value != .null) return value;
    if (nestedObject(member, "summoner")) |summoner| if (summoner.object.get(name)) |value| if (value != .null) return value;
    if (nestedObject(member, "player")) |player| if (player.object.get(name)) |value| if (value != .null) return value;
    return null;
}

fn premadeGroupValue(member: std.json.Value) ?std.json.Value {
    for ([_][]const u8{ "teamParticipantId", "partyId", "partyID", "premadeGroupId", "premadeId" }) |name| {
        const value = memberFieldValue(member, name) orelse continue;
        switch (value) {
            .string => |text| if (text.len > 0 and !std.mem.eql(u8, text, "0")) return value,
            .integer => |number| if (number != 0) return value,
            .float => |number| if (number != 0) return value,
            else => {},
        }
    }
    return null;
}

fn normalizedMemberIdEqual(left: std.json.Value, right: std.json.Value) bool {
    if (left == .string and right == .string) return std.mem.eql(u8, left.string, right.string);
    const left_number: ?i64 = switch (left) {
        .integer => |number| number,
        .float => |number| @intFromFloat(number),
        .string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        else => null,
    };
    const right_number: ?i64 = switch (right) {
        .integer => |number| number,
        .float => |number| @intFromFloat(number),
        .string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        else => null,
    };
    return left_number != null and right_number != null and left_number.? != 0 and left_number.? == right_number.?;
}

fn samePremadeGroup(left: std.json.Value, right: std.json.Value) bool {
    const left_group = premadeGroupValue(left) orelse return false;
    const right_group = premadeGroupValue(right) orelse return false;
    return normalizedMemberIdEqual(left_group, right_group);
}

fn explicitPremade(member: std.json.Value) bool {
    for ([_][]const u8{ "isPremade", "premade" }) |name| {
        const value = memberFieldValue(member, name) orelse continue;
        if (value == .bool and value.bool) return true;
    }
    return false;
}

fn samePremadeMember(left: std.json.Value, right: std.json.Value) bool {
    if (livePlayerMatches(left, right)) return true;
    const left_id = identityNumericId(left);
    const right_id = identityNumericId(right);
    if (left_id > 0 and right_id > 0) return left_id == right_id;
    const left_riot = riotIdentity(left);
    const right_riot = riotIdentity(right);
    if (left_riot.name.len == 0 or right_riot.name.len == 0 or !std.ascii.eqlIgnoreCase(left_riot.name, right_riot.name)) return false;
    return left_riot.tag.len == 0 or right_riot.tag.len == 0 or std.ascii.eqlIgnoreCase(left_riot.tag, right_riot.tag);
}

fn premadeDisplayName(member: std.json.Value) []const u8 {
    const identity = riotIdentity(member);
    if (identity.name.len > 0) return identity.name;
    for ([_][]const u8{ "gameName", "displayName", "summonerName", "name" }) |name| {
        const value = memberFieldValue(member, name) orelse continue;
        if (value == .string and value.string.len > 0) return splitRiotId(value.string).name;
    }
    return "";
}

fn writePremadeFields(writer: *std.Io.Writer, participant: std.json.Value, members_value: ?std.json.Value) !void {
    const members = if (members_value) |value| arrayLike(value) else null;
    // Champ-select participants and custom-lobby members are two different
    // DTOs. The participant often lacks partyId even though the lobby member
    // has it, so resolve the effective group through the shared identity first.
    var participant_group: ?std.json.Value = premadeGroupValue(participant);
    if (participant_group == null) if (members) |array| for (array.array.items) |member| {
        if (samePremadeMember(participant, member)) if (premadeGroupValue(member)) |group| {
            participant_group = group;
            break;
        };
    };
    var group_size: usize = 0;
    if (members) |array| {
        if (participant_group) |group| {
            for (array.array.items) |member| {
                if (premadeGroupValue(member)) |member_group| {
                    if (normalizedMemberIdEqual(group, member_group)) group_size += 1;
                }
            }
        } else {
            for (array.array.items) |member| {
                if (samePremadeGroup(participant, member)) group_size += 1;
            }
        }
    }
    const is_premade = group_size > 1 or explicitPremade(participant);
    try writer.writeAll(",\"isPremade\":");
    try writer.writeAll(if (is_premade) "true" else "null");
    try writer.writeAll(",\"premadeGroup\":");
    if (group_size > 1) {
        const group = participant_group.?;
        switch (group) {
            .string => |value| try jsonString(writer, value),
            .integer => |value| {
                var buffer: [32]u8 = undefined;
                try jsonString(writer, try std.fmt.bufPrint(&buffer, "{d}", .{value}));
            },
            .float => |value| {
                var buffer: [64]u8 = undefined;
                try jsonString(writer, try std.fmt.bufPrint(&buffer, "{d}", .{value}));
            },
            else => try writer.writeAll("null"),
        }
    } else try writer.writeAll("null");
    try writer.writeAll(",\"premadeWith\":[");
    var first = true;
    if (group_size > 1) if (members) |array| for (array.array.items) |member| {
        const member_group = premadeGroupValue(member) orelse continue;
        if (participant_group) |group| {
            if (!normalizedMemberIdEqual(group, member_group)) continue;
        } else if (!samePremadeGroup(participant, member)) continue;
        if (samePremadeMember(participant, member)) continue;
        const name = premadeDisplayName(member);
        if (name.len == 0 or std.mem.eql(u8, name, "未知玩家")) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try jsonString(writer, name);
    };
    try writer.writeByte(']');

    // Templates used for ally/enemy assessment should remain useful during
    // champ-select, where Riot IDs may be hidden or contain invalid chat
    // characters. Expose stable role labels alongside the legacy names.
    try writer.writeAll(",\"premadePositions\":[");
    var position_first = true;
    if (group_size > 1) if (members) |array| for (array.array.items) |member| {
        const member_group = premadeGroupValue(member) orelse continue;
        if (participant_group) |group| {
            if (!normalizedMemberIdEqual(group, member_group)) continue;
        } else if (!samePremadeGroup(participant, member)) continue;
        if (samePremadeMember(participant, member)) continue;
        const position = premadePositionLabel(member);
        if (position.len == 0) continue;
        if (!position_first) try writer.writeByte(',');
        position_first = false;
        try jsonString(writer, position);
    };
    try writer.writeByte(']');
}

fn premadePositionLabel(member: std.json.Value) []const u8 {
    const position = playerPosition(member);
    if (std.ascii.eqlIgnoreCase(position, "TOP")) return "上路";
    if (std.ascii.eqlIgnoreCase(position, "JUNGLE") or std.ascii.eqlIgnoreCase(position, "JUG")) return "打野";
    if (std.ascii.eqlIgnoreCase(position, "MIDDLE") or std.ascii.eqlIgnoreCase(position, "MID")) return "中路";
    if (std.ascii.eqlIgnoreCase(position, "BOTTOM") or std.ascii.eqlIgnoreCase(position, "BOT") or std.ascii.eqlIgnoreCase(position, "ADC")) return "下路";
    if (std.ascii.eqlIgnoreCase(position, "UTILITY") or std.ascii.eqlIgnoreCase(position, "SUPPORT") or std.ascii.eqlIgnoreCase(position, "SUP")) return "辅助";
    return "";
}

fn arrayContainsIdentity(value: ?std.json.Value, current: std.json.Value) bool {
    const array = value orelse return false;
    if (array != .array) return false;
    for (array.array.items) |item| {
        if (item != .object) continue;
        if (livePlayerMatches(item, current)) return true;
    }
    return false;
}

test "maps LCU match history into frontend summaries" {
    const input = "{\"games\":{\"games\":[{\"gameId\":42,\"gameDuration\":900,\"queueId\":420,\"gameMode\":\"CLASSIC\",\"participants\":[{\"puuid\":\"p1\",\"gameName\":\"Player\",\"championId\":103,\"championName\":\"Ahri\",\"teamId\":100,\"stats\":{\"kills\":3,\"deaths\":1,\"assists\":7,\"win\":true}}]}]}}";
    var output: [8192]u8 = undefined;
    const result = try matchHistoryDto(input, &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    parsed.deinit();
    try std.testing.expect(std.mem.indexOf(u8, result, "\"gameId\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"result\":\"胜利\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"queueName\":\"单双排\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"puuid\":\"p1\"") != null);
}

test "canonicalizes queue ids and raw LCU modes" {
    try std.testing.expectEqualStrings("单双排", queueName(420, "CLASSIC"));
    try std.testing.expectEqualStrings("召唤师峡谷", queueName(0, "CLASS"));
    try std.testing.expectEqualStrings("极地大乱斗", queueName(450, "CLASSIC"));
    try std.testing.expectEqualStrings("无尽狂潮", queueName(9999, "SWARM"));
    try std.testing.expectEqualStrings("海克斯大乱斗", queueName(9999, "KIWI"));
    try std.testing.expectEqualStrings("新模式", queueName(9999, "新模式"));
}

test "maps queue catalog labels without exposing LCU class names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const catalog = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "[{\"id\":9999,\"name\":\"特殊轮换模式\"}]", .{});
    try std.testing.expectEqualStrings("特殊轮换模式", queueNameFromCatalog(catalog, 9999, "CLASS"));
    try std.testing.expectEqualStrings("召唤师峡谷", queueNameFromCatalog(catalog, 0, "CLASS"));
}

test "recent analysis emits solo threat from exact timeline data" {
    const recent =
        "[" ++
        "{\"durationMinutes\":30,\"win\":true,\"deaths\":2,\"soloKills\":1,\"position\":\"MIDDLE\",\"championId\":103}," ++
        "{\"durationMinutes\":31,\"win\":true,\"deaths\":3,\"soloKills\":1,\"position\":\"MID\",\"championId\":103}," ++
        "{\"durationMinutes\":29,\"win\":false,\"deaths\":4,\"soloKills\":0.5,\"position\":\"MIDDLE\",\"championId\":112}" ++
        "]";
    var output: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try writeRecentTags(&writer, recent, "MIDDLE", 103, .{});
    const tags = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, tags, "\"key\":\"soloThreat\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tags, "\"label\":\"单杀威胁\"") != null);
}

test "recent analysis caps aggregate evidence at five tags" {
    const match = "{\"durationMinutes\":20,\"win\":true,\"deaths\":8,\"kills\":10,\"assists\":10,\"killParticipation\":0.8,\"damageShare\":0.32,\"cs\":180,\"soloKills\":1,\"earlyDeathsWithEnemyJungler\":2,\"position\":\"TOP\",\"championId\":86}";
    const recent = "[" ++ match ++ "," ++ match ++ "," ++ match ++ "," ++ match ++ "," ++ match ++ "]";
    var output: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try writeRecentTags(&writer, recent, "MIDDLE", 103, .{});
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, writer.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 5), parsed.value.array.items.len);
    try std.testing.expectEqualStrings("soloThreat", jsonField(parsed.value.array.items[0], "key"));
    try std.testing.expectEqualStrings("easyGank", jsonField(parsed.value.array.items[1], "key"));
    try std.testing.expectEqualStrings("highDeaths", jsonField(parsed.value.array.items[2], "key"));
    try std.testing.expectEqualStrings("highParticipation", jsonField(parsed.value.array.items[3], "key"));
    try std.testing.expectEqualStrings("damageCore", jsonField(parsed.value.array.items[4], "key"));
}

test "persists complete BP picks with game id localized names and queue label" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const session = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"gameData\":{\"gameId\":901046007021,\"queue\":{\"id\":420,\"gameMode\":\"CLASS\"}},\"myTeam\":[{\"championId\":0,\"championPickIntent\":103}],\"theirTeam\":[{\"championId\":112}]}", .{});
    const catalog = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "[{\"id\":103,\"name\":\"九尾妖狐\"},{\"id\":112,\"name\":\"奥术先驱\"}]", .{});
    var output: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try std.testing.expect(try tryRecord(&writer, session, catalog, 1_788_000_000_123));
    const result = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, result, "\"id\":\"901046007021\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"gameMode\":\"单双排\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"allyChampionIds\":[103]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"allyChampions\":[\"九尾妖狐\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"enemyChampions\":[\"奥术先驱\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "1970-01-01") == null);
}

test "ChampSelect hover maps to the live player champion before lock-in" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const participant = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"puuid\":\"hover-player\",\"gameName\":\"亮出英雄\",\"championId\":0,\"championPickIntent\":103,\"assignedPosition\":\"MIDDLE\"}", .{});
    const catalog = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "[{\"id\":103,\"name\":\"九尾妖狐\"}]", .{});
    var output: [16 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try writeProfile(&writer, participant, "ally", catalog);
    const result = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, result, "\"championId\":103") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"championName\":\"九尾妖狐\"") != null);
}

test "does not persist BP until both teams have committed or intended champions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const session = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"myTeam\":[{\"championId\":103}],\"theirTeam\":[{\"championId\":0}]}", .{});
    var output: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try std.testing.expect(!(try tryRecord(&writer, session, std.json.Value{ .null = {} }, 1)));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
}

test "normalizes legacy BP snapshots and deduplicates real game ids" {
    const history =
        "[" ++
        "{\"id\":\"champ-select\",\"queueId\":0,\"gameMode\":\"League of Legends\",\"allyChampionIds\":[],\"allyChampions\":[],\"enemyChampionIds\":[],\"enemyChampions\":[]}," ++
        "{\"id\":\"901\",\"queueId\":3140,\"gameMode\":\"League of Legends\",\"allyChampionIds\":[103],\"allyChampions\":[],\"enemyChampionIds\":[112],\"enemyChampions\":[],\"allyScore\":42,\"enemyScore\":40,\"aiSummary\":null,\"createdAt\":\"2026-08-29T12:00:00.000Z\"}," ++
        "{\"id\":\"901\",\"queueId\":3140,\"gameMode\":\"CLASS\",\"allyChampionIds\":[1],\"allyChampions\":[\"黑暗之女\"],\"enemyChampionIds\":[2],\"enemyChampions\":[\"狂战士\"]}," ++
        "{\"id\":\"partial\",\"queueId\":420,\"gameMode\":\"CLASSIC\",\"allyChampionIds\":[103],\"allyChampions\":[],\"enemyChampionIds\":[0],\"enemyChampions\":[]}" ++
        "]";
    const catalog = "[{\"id\":103,\"name\":\"九尾妖狐\"},{\"id\":112,\"name\":\"奥术先驱\"}]";
    var output: [8192]u8 = undefined;
    const result = try normalizeBpHistory(history, catalog, &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    const record = parsed.value.array.items[0];
    try std.testing.expectEqualStrings("901", jsonField(record, "id"));
    try std.testing.expectEqualStrings("多人训练模式", jsonField(record, "gameMode"));
    try std.testing.expectEqualStrings("九尾妖狐", record.object.get("allyChampions").?.array.items[0].string);
    try std.testing.expectEqualStrings("奥术先驱", record.object.get("enemyChampions").?.array.items[0].string);
}

test "maps OP.GG champion stats onto the native champion DTO" {
    const champions = "[{\"id\":103,\"name\":\"阿狸\",\"alias\":\"Ahri\",\"roles\":[\"mage\"]}]";
    const opgg = "{\"data\":[{\"id\":103,\"average_stats\":{\"play\":38724,\"win_rate\":0.511233,\"pick_rate\":0.0987179,\"ban_rate\":0.0296314,\"kda\":2.538608,\"tier\":1},\"positions\":[{\"name\":\"SUPPORT\",\"stats\":{\"play\":100,\"win_rate\":0.48,\"pick_rate\":0.01,\"ban_rate\":0.03,\"kda\":2.1,\"role_rate\":0.1,\"tier_data\":{\"tier\":4}}},{\"name\":\"MID\",\"stats\":{\"play\":36969,\"win_rate\":0.52,\"pick_rate\":0.08,\"ban_rate\":0.03,\"kda\":3.25,\"role_rate\":0.9,\"tier_data\":{\"tier\":2,\"rank\":1,\"rank_prev_patch\":2}}}],\"roles\":[]}],\"meta\":{\"version\":\"16.17\"}}";
    var output: [4096]u8 = undefined;
    const result = try champion_mapper.dtoWithStats(champions, opgg, .{ .fetched_at_millis = 1_625_159_473_123 }, &output);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"tier\":\"T2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"winRate\":0.520000") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"pickRate\":0.080000") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"banRate\":0.030000") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"kda\":3.250000") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"roles\":[\"UTILITY\",\"MIDDLE\"]") != null);
}

test "reads ranked queueMap payloads used by current LCU builds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ranked = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"queueMap\":{\"RANKED_SOLO_5x5\":{\"tier\":\"EMERALD\",\"division\":\"II\",\"leaguePoints\":63}}}", .{});
    const solo = rankQueueValue(ranked, "RANKED_SOLO_5x5").?;
    try std.testing.expectEqualStrings("EMERALD", jsonField(solo, "tier"));
    try std.testing.expectEqual(@as(i64, 63), jsonInt(solo, "leaguePoints"));
}

test "merges fast in-game fields without erasing enriched player history" {
    const base = "{\"id\":\"123\",\"queueId\":420,\"gameMode\":\"单双排\",\"phase\":\"ChampSelect\",\"ally\":[{\"puuid\":\"resolved\",\"gameName\":\"玩家\",\"tagLine\":\"HN1\",\"isBot\":false,\"championId\":103,\"championName\":\"阿狸\",\"profileIconId\":7,\"assignedPosition\":\"MIDDLE\",\"rankTier\":\"EMERALD\",\"recentMatches\":[{\"gameId\":9}],\"dataComplete\":true,\"isPremade\":true,\"premadeWith\":[\"队友\"],\"side\":\"ally\"}],\"enemy\":[],\"teams\":[{\"side\":\"ally\",\"players\":[]}],\"recentMatch\":{\"gameId\":8}}";
    const fast = "{\"id\":\"123\",\"queueId\":420,\"gameMode\":\"CLASS\",\"phase\":\"InProgress\",\"ally\":[{\"puuid\":\"123456\",\"gameName\":\"未知玩家\",\"tagLine\":\"\",\"isBot\":false,\"championId\":112,\"championName\":\"奥术先驱\",\"profileIconId\":0,\"assignedPosition\":\"NONE\",\"rankTier\":\"\",\"recentMatches\":[],\"dataComplete\":false,\"isPremade\":null,\"premadeWith\":[],\"side\":\"ally\"}],\"enemy\":[],\"teams\":[{\"side\":\"ally\",\"players\":[]}],\"recentMatch\":null}";
    var output: [16 * 1024]u8 = undefined;
    const result = try mergeLiveLobbySnapshots(base, fast, false, &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    const player = parsed.value.object.get("ally").?.array.items[0];
    try std.testing.expectEqualStrings("resolved", jsonField(player, "puuid"));
    try std.testing.expectEqualStrings("EMERALD", jsonField(player, "rankTier"));
    try std.testing.expectEqual(@as(i64, 112), jsonInt(player, "championId"));
    try std.testing.expectEqual(@as(usize, 1), player.object.get("recentMatches").?.array.items.len);
    try std.testing.expect(jsonBool(player, "isPremade"));
    try std.testing.expectEqualStrings("单双排", jsonField(parsed.value, "gameMode"));
    try std.testing.expect(parsed.value.object.get("recentMatch").? != .null);
}

test "preserves live-client Smite fields when overlaying cached lobby profiles" {
    const base = "{\"id\":\"123\",\"ally\":[{\"puuid\":\"jungler\",\"gameName\":\"打野\",\"assignedPosition\":\"NONE\",\"summonerSpells\":[]}],\"enemy\":[]}";
    const dynamic = "{\"id\":\"123\",\"ally\":[{\"puuid\":\"jungler\",\"gameName\":\"打野\",\"assignedPosition\":\"NONE\",\"summonerSpells\":[{\"id\":11,\"name\":\"惩戒\"}]}],\"enemy\":[]}";
    var output: [8192]u8 = undefined;
    const result = try mergeLiveLobbySnapshots(base, dynamic, false, &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    const spells = parsed.value.object.get("ally").?.array.items[0].object.get("summonerSpells").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), spells.len);
    try std.testing.expectEqual(@as(i64, 11), spells[0].object.get("id").?.integer);
}

test "preserves the full cached topology when Live Client only returns one player" {
    const base = "{\"id\":\"123\",\"queueId\":420,\"gameMode\":\"单双排\",\"phase\":\"ChampSelect\",\"ally\":[{\"puuid\":\"self\",\"gameName\":\"自己\",\"championId\":103},{\"puuid\":\"ally-2\",\"gameName\":\"队友2\",\"championId\":64}],\"enemy\":[{\"puuid\":\"enemy-1\",\"gameName\":\"敌人1\",\"championId\":86},{\"puuid\":\"enemy-2\",\"gameName\":\"敌人2\",\"championId\":112}]}";
    const fast = "{\"id\":\"123\",\"queueId\":420,\"gameMode\":\"CLASS\",\"phase\":\"InProgress\",\"ally\":[{\"puuid\":\"self\",\"gameName\":\"自己\",\"championId\":711}],\"enemy\":[]}";
    var output: [16 * 1024]u8 = undefined;
    const result = try mergeLiveLobbySnapshots(base, fast, false, &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.object.get("ally").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.object.get("enemy").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 711), jsonInt(parsed.value.object.get("ally").?.array.items[0], "championId"));
    try std.testing.expectEqualStrings("单双排", jsonField(parsed.value, "gameMode"));
}

test "keeps ChampSelect profiles when gameflow changes the numeric id during handoff" {
    var state = Runtime.init();
    const champ_select =
        "{\"id\":\"111\",\"queueId\":440,\"gameMode\":\"灵活排位\",\"phase\":\"ChampSelect\",\"ally\":[" ++
        "{\"puuid\":\"self\",\"gameName\":\"自己\",\"championId\":103,\"recentMatches\":[{\"gameId\":1,\"win\":true}]}," ++
        "{\"puuid\":\"ally-2\",\"gameName\":\"队友\",\"championId\":64,\"recentMatches\":[{\"gameId\":2,\"win\":false}]}]," ++
        "\"enemy\":[{\"puuid\":\"enemy-1\",\"gameName\":\"敌人\",\"championId\":86,\"recentMatches\":[{\"gameId\":3,\"win\":true}]}]}";
    observeLivePhase(&state, "ChampSelect");
    cacheChampSelectLobby(&state, champ_select);

    observeLivePhase(&state, "GameStart");
    invalidateMismatchedLobbyCaches(&state, 222);
    try std.testing.expect(state.champ_select_handoff_active);
    try std.testing.expectEqual(@as(usize, 3), lobbyRosterCount(state.champ_select_lobby[0..state.champ_select_lobby_len]));

    const in_game = "{\"id\":\"222\",\"queueId\":440,\"gameMode\":\"CLASS\",\"phase\":\"InProgress\",\"ally\":[{\"puuid\":\"self\",\"gameName\":\"自己\",\"championId\":112}],\"enemy\":[]}";
    var output: [32 * 1024]u8 = undefined;
    const merged = try mergeWithBestLiveCache(&state, in_game, false, &output);
    try std.testing.expectEqual(@as(i64, 222), lobbyGameId(merged));
    try std.testing.expectEqual(@as(usize, 3), lobbyRosterCount(merged));
    try std.testing.expect(std.mem.indexOf(u8, merged, "\"recentMatches\":[{\"gameId\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, merged, "\"gameMode\":\"灵活排位\"") != null);
}

test "clears an old ChampSelect snapshot for a new game without handoff evidence" {
    var state = Runtime.init();
    const old_lobby = "{\"id\":\"111\",\"phase\":\"ChampSelect\",\"ally\":[{\"puuid\":\"self\"}],\"enemy\":[]}";
    cacheChampSelectLobby(&state, old_lobby);
    observeLivePhase(&state, "InProgress");
    invalidateMismatchedLobbyCaches(&state, 222);
    try std.testing.expectEqual(@as(usize, 0), state.champ_select_lobby_len);
    try std.testing.expect(!state.champ_select_handoff_active);
}

test "live lobby caches leave headroom above observed production payloads" {
    try std.testing.expect(live_lobby_capacity >= 512 * 1024);
}

test "never merges live player data across numeric game ids" {
    const base = "{\"id\":\"123\",\"ally\":[{\"puuid\":\"old\",\"gameName\":\"旧玩家\",\"recentMatches\":[{}]}],\"enemy\":[]}";
    const next = "{\"id\":\"124\",\"ally\":[{\"puuid\":\"new\",\"gameName\":\"新玩家\",\"recentMatches\":[]}],\"enemy\":[]}";
    var output: [4096]u8 = undefined;
    const result = try mergeLiveLobbySnapshots(base, next, false, &output);
    try std.testing.expect(std.mem.indexOf(u8, result, "新玩家") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "旧玩家") == null);
}

test "live lobby merge accepts a different-game snapshot already in output" {
    const base = "{\"id\":\"1001\",\"ally\":[{\"puuid\":\"old\"}],\"enemy\":[]}";
    const next = "{\"id\":\"1002\",\"ally\":[{\"puuid\":\"new\"}],\"enemy\":[]}";
    var output: [1024]u8 = undefined;
    @memcpy(output[0..next.len], next);
    const result = try mergeLiveLobbySnapshots(base, output[0..next.len], false, &output);
    try std.testing.expectEqualStrings(next, result);
}

test "maps SGP history payload and selects the current participant" {
    const input = "{\"games\":[{\"json\":\"{\\\"gameId\\\":43,\\\"gameDuration\\\":1200,\\\"gameCreation\\\":1625159473123,\\\"queueId\\\":420,\\\"participants\\\":[{\\\"puuid\\\":\\\"other\\\",\\\"teamId\\\":100,\\\"championId\\\":64,\\\"stats\\\":{\\\"kills\\\":9,\\\"deaths\\\":1,\\\"assists\\\":2,\\\"win\\\":true}},{\\\"puuid\\\":\\\"self\\\",\\\"riotIdGameName\\\":\\\"Player\\\",\\\"teamId\\\":200,\\\"teamPosition\\\":\\\"MIDDLE\\\",\\\"championId\\\":103,\\\"item0\\\":3089,\\\"spell1Id\\\":4,\\\"stats\\\":{\\\"kills\\\":3,\\\"deaths\\\":4,\\\"assists\\\":8,\\\"win\\\":false}}]}\"}]}";
    const catalog = "[{\"id\":64,\"name\":\"Lee Sin\"},{\"id\":103,\"name\":\"Ahri\"}]";
    var output: [16 * 1024]u8 = undefined;
    const result = try matchHistoryDtoPage(input, catalog, "self", 0, 10, &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expect(std.mem.indexOf(u8, result, "\"championId\":103") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"kda\":\"3/4/8\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"result\":\"失败\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"position\":\"MIDDLE\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"playedAt\":\"2021-07-01T17:11:13.123Z\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"id\":3089") != null);
}

test "prefers populated SGP history and never replaces populated LCU history with an empty response" {
    const lcu_history = "{\"games\":{\"games\":[{\"gameId\":1}]}}";
    const sgp_history = "{\"games\":[{\"gameId\":2}]}";
    try std.testing.expectEqualStrings(sgp_history, preferredHistory(lcu_history, sgp_history).?);
    try std.testing.expectEqualStrings(lcu_history, preferredHistory(lcu_history, "{\"games\":[]}").?);
    try std.testing.expect(preferredHistory("{}", "{\"games\":[]}") == null);
}

test "maps LCU participant identities when participant rows omit puuid" {
    const input = "{\"games\":{\"games\":[{\"gameId\":44,\"gameDuration\":600,\"queueId\":420,\"gameMode\":\"CLASSIC\",\"participantIdentities\":[{\"participantId\":1,\"player\":{\"puuid\":\"other\",\"summonerName\":\"Other\"}},{\"participantId\":2,\"player\":{\"puuid\":\"self\",\"gameName\":\"Self\"}}],\"participants\":[{\"participantId\":1,\"teamId\":100,\"championId\":64,\"stats\":{\"kills\":9,\"win\":true}},{\"participantId\":2,\"teamId\":200,\"championId\":103,\"stats\":{\"kills\":3,\"deaths\":4,\"assists\":8,\"win\":false}}]}]}}";
    var output: [16 * 1024]u8 = undefined;
    const result = try matchHistoryDtoPage(input, "[]", "self", 0, 10, &output);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"kda\":\"3/4/8\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"puuid\":\"self\"") != null);
}

test "does not label a single-participant history row as MVP or SVP" {
    const input = "{\"games\":[{\"gameId\":45,\"gameDuration\":1200,\"queueId\":420,\"participants\":[{\"puuid\":\"self\",\"teamId\":100,\"championId\":103,\"kills\":12,\"deaths\":0,\"assists\":8,\"totalDamageDealtToChampions\":30000,\"win\":true}]}]}";
    var output: [16 * 1024]u8 = undefined;
    const result = try matchHistoryDtoPage(input, "[]", "self", 0, 10, &output);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"mvp\":null") != null);
}

test "maps Tencent platform ids to SGP hosts" {
    try std.testing.expectEqualStrings("nj100-sgp.lol.qq.com:21019", sgpHost("NJ100").?);
    try std.testing.expectEqualStrings("hn1-k8s-sgp.lol.qq.com:21019", sgpHost("tencent_hn1").?);
    try std.testing.expect(sgpHost("UNKNOWN") == null);
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

test "maps champ select teams into lobby profiles" {
    const input = "{\"queueId\":490,\"myTeam\":[{\"puuid\":\"ally-1\",\"gameName\":\"Ally\",\"tagLine\":\"ONE\",\"championId\":103,\"assignedPosition\":\"MIDDLE\"}],\"theirTeam\":[]}";
    var output: [8192]u8 = undefined;
    const result = try liveSessionEnvelope(input, &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    parsed.deinit();
    try std.testing.expect(std.mem.indexOf(u8, result, "\"queueId\":490") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"puuid\":\"ally-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"ally\":[{") != null);
}

test "maps gameflow teams and preserves the active phase" {
    const input = "{\"gameData\":{\"gameId\":123,\"queue\":{\"id\":420,\"gameMode\":\"CLASSIC\"},\"teamOne\":[{\"puuid\":\"ally\",\"gameName\":\"Ally\",\"championId\":103,\"teamId\":100}],\"teamTwo\":[{\"puuid\":\"enemy\",\"gameName\":\"Enemy\",\"championId\":64,\"teamId\":200}]}}";
    var output: [8192]u8 = undefined;
    const result = try liveSessionEnvelopePhase(input, "InProgress", null, &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("InProgress", parsed.value.object.get("phase").?.string);
    try std.testing.expectEqual(@as(i64, 420), parsed.value.object.get("queueId").?.integer);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"puuid\":\"ally\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"puuid\":\"enemy\"") != null);
}

test "keeps a populated gameflow side while selections fill the missing side" {
    const input = "{\"gameData\":{\"gameId\":123,\"queue\":{\"id\":420,\"gameMode\":\"CLASSIC\"},\"teamOne\":[{\"puuid\":\"real-ally\",\"gameName\":\"真实队友\",\"championId\":103,\"teamId\":100}],\"playerChampionSelections\":[{\"championId\":1},{\"championId\":2},{\"championId\":3},{\"championId\":4},{\"championId\":5},{\"championId\":6},{\"championId\":7},{\"championId\":8},{\"championId\":9},{\"championId\":10}]}}";
    var output: [32 * 1024]u8 = undefined;
    const result = try liveSessionEnvelopePhase(input, "InProgress", null, &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 5), parsed.value.object.get("ally").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 5), parsed.value.object.get("enemy").?.array.items.len);
    try std.testing.expectEqualStrings("真实队友", parsed.value.object.get("ally").?.array.items[0].object.get("gameName").?.string);
}

test "injects a missing current player into the gameflow ally team" {
    const input = "{\"gameData\":{\"gameId\":123,\"queue\":{\"id\":420,\"gameMode\":\"CLASSIC\"},\"teamOne\":[{\"puuid\":\"ally-one\",\"gameName\":\"队友\",\"teamId\":100}],\"teamTwo\":[{\"puuid\":\"enemy-one\",\"gameName\":\"对手\",\"teamId\":200}]}}";
    const current = "{\"puuid\":\"self\",\"gameName\":\"我的账号\",\"tagLine\":\"HN1\"}";
    var output: [16 * 1024]u8 = undefined;
    const result = try liveSessionEnvelopePhase(input, "InProgress", current, &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    const ally = parsed.value.object.get("ally").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), ally.len);
    try std.testing.expectEqualStrings("self", jsonField(ally[0], "puuid"));
    try std.testing.expectEqualStrings("我的账号", jsonField(ally[0], "gameName"));
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.get("enemy").?.array.items.len);
}

test "replaces an unresolved full ally slot with the current player" {
    const input = "{\"gameData\":{\"gameId\":123,\"queue\":{\"id\":420,\"gameMode\":\"CLASSIC\"},\"teamOne\":[{\"puuid\":\"ally-one\",\"gameName\":\"队友一\"},{\"puuid\":\"ally-two\",\"gameName\":\"队友二\"},{\"puuid\":\"ally-three\",\"gameName\":\"队友三\"},{\"puuid\":\"ally-four\",\"gameName\":\"队友四\"},{\"championId\":103}],\"teamTwo\":[]}}";
    const current = "{\"puuid\":\"self\",\"gameName\":\"我的账号\",\"tagLine\":\"HN1\"}";
    var output: [32 * 1024]u8 = undefined;
    const result = try liveSessionEnvelopePhase(input, "InProgress", current, &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    const ally = parsed.value.object.get("ally").?.array.items;
    try std.testing.expectEqual(@as(usize, 5), ally.len);
    try std.testing.expect(containsProfilePuuid(ally, "self"));
}

test "never injects the local account into a spectator roster" {
    const input = "{\"gameId\":321,\"queueId\":420,\"participants\":[{\"puuid\":\"blue\",\"gameName\":\"蓝方\",\"teamId\":1}]}";
    const current = "{\"puuid\":\"spectator\",\"gameName\":\"观战者\"}";
    var output: [16 * 1024]u8 = undefined;
    const result = try liveSessionEnvelopePhase(input, "WatchInProgress", current, &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.get("ally").?.array.items.len);
    try std.testing.expect(!containsProfilePuuid(parsed.value.object.get("ally").?.array.items, "spectator"));
}

test "custom lobby topology overrides fixed ten-slot champ select data" {
    const session = "{\"gameData\":{\"gameId\":440022,\"queue\":{\"id\":3140,\"gameMode\":\"CUSTOM\"},\"playerChampionSelections\":[{\"championId\":1},{\"championId\":2},{\"championId\":3},{\"championId\":4},{\"championId\":5},{\"championId\":6},{\"championId\":7},{\"championId\":8},{\"championId\":9},{\"championId\":10}]},\"myTeam\":[{\"puuid\":\"self\"}],\"theirTeam\":[]}";
    const custom =
        "{\"gameConfig\":{" ++
        "\"customTeam100\":[{\"puuid\":\"self\",\"gameName\":\"我的账号\"},{\"botUuid\":\"blue-bot-1\",\"botChampionId\":1,\"botDifficulty\":\"MEDIUM\"},{\"botUuid\":\"blue-bot-2\",\"botChampionId\":2,\"botSkillLevel\":\"HARD\"},{\"botUuid\":\"blue-bot-3\",\"botChampionId\":3,\"isBot\":true}]," ++
        "\"customTeam200\":[{\"botUuid\":\"red-bot-1\",\"botChampionId\":4,\"botDifficulty\":\"EASY\"},{\"botUuid\":\"red-bot-2\",\"botChampionId\":5,\"type\":\"BOT\"}]" ++
        "}}";
    const current = "{\"puuid\":\"self\",\"gameName\":\"我的账号\",\"tagLine\":\"HN1\"}";
    var output: [64 * 1024]u8 = undefined;
    const result = try liveSessionEnvelopePhaseContext(null, null, session, custom, "ChampSelect", current, "[]", "[]", &output, false);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    const ally = parsed.value.object.get("ally").?.array.items;
    const enemy = parsed.value.object.get("enemy").?.array.items;
    try std.testing.expectEqual(@as(usize, 4), ally.len);
    try std.testing.expectEqual(@as(usize, 2), enemy.len);
    var bots: usize = 0;
    for (ally) |player| if (jsonBool(player, "isBot")) {
        bots += 1;
        try std.testing.expect(std.mem.indexOf(u8, jsonField(player, "puuid"), "-slot-") == null);
    };
    for (enemy) |player| if (jsonBool(player, "isBot")) {
        bots += 1;
        try std.testing.expect(std.mem.indexOf(u8, jsonField(player, "puuid"), "-slot-") == null);
    };
    try std.testing.expectEqual(@as(usize, 5), bots);
}

test "champ select premade overlay keeps the local player in the party" {
    const session =
        "{\"queueId\":420,\"myTeam\":[" ++
        "{\"puuid\":\"self\",\"gameName\":\"我的账号\",\"championId\":103,\"cellId\":0}," ++
        "{\"puuid\":\"friend\",\"gameName\":\"双排队友\",\"championId\":64,\"cellId\":1}," ++
        "{\"puuid\":\"solo\",\"gameName\":\"路人\",\"championId\":86,\"cellId\":2}],\"theirTeam\":[]}";
    const lobby =
        "{\"partyId\":\"party-local\",\"members\":[" ++
        "{\"puuid\":\"self\",\"summonerName\":\"我的账号\"}," ++
        "{\"puuid\":\"friend\",\"summonerName\":\"双排队友\"}]}";
    const current = "{\"puuid\":\"self\",\"gameName\":\"我的账号\",\"tagLine\":\"HN1\"}";
    const catalog = "[{\"id\":103,\"name\":\"九尾妖狐\"},{\"id\":64,\"name\":\"盲僧\"},{\"id\":86,\"name\":\"德玛西亚之力\"}]";
    var lobby_output: [32 * 1024]u8 = undefined;
    const result = try liveSessionEnvelopePhaseContext(null, null, session, lobby, "ChampSelect", current, catalog, "[]", &lobby_output, false);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    const ally = parsed.value.object.get("ally").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), ally.len);
    try std.testing.expectEqualStrings("party-local", jsonField(ally[0], "premadeGroup"));
    try std.testing.expectEqualStrings("party-local", jsonField(ally[1], "premadeGroup"));
    try std.testing.expectEqual(@as(usize, 1), ally[0].object.get("premadeWith").?.array.items.len);
    try std.testing.expectEqualStrings("双排队友", ally[0].object.get("premadeWith").?.array.items[0].string);

    const config = "{\"automation\":{\"shortcuts\":[{\"id\":\"premade\",\"target\":\"premade\",\"template\":\"{name}\",\"enabled\":true}]}}";
    var shortcut_output: [4096]u8 = undefined;
    const lines = try shortcut_service.buildLines(config, "premade", result, "ChampSelect", .{ .premade_side = "ally" }, &shortcut_output);
    try std.testing.expectEqualStrings("[\"我方开黑：[九尾妖狐、盲僧]\"]", lines);
}

test "champ select premade overlay reads the account from localMember" {
    const session =
        "{\"queueId\":420,\"myTeam\":[" ++
        "{\"puuid\":\"self\",\"gameName\":\"我的账号\",\"championId\":103,\"cellId\":0}," ++
        "{\"puuid\":\"friend\",\"gameName\":\"双排队友\",\"championId\":64,\"cellId\":1}],\"theirTeam\":[]}";
    const lobby =
        "{\"partyId\":\"party-local\",\"localMember\":{\"puuid\":\"self\",\"summonerName\":\"我的账号\"}," ++
        "\"members\":[{\"puuid\":\"friend\",\"summonerName\":\"双排队友\"}]}";
    const current = "{\"puuid\":\"self\",\"gameName\":\"我的账号\",\"tagLine\":\"HN1\"}";
    const catalog = "[{\"id\":103,\"name\":\"九尾妖狐\"},{\"id\":64,\"name\":\"盲僧\"}]";
    var lobby_output: [32 * 1024]u8 = undefined;
    const result = try liveSessionEnvelopePhaseContext(null, null, session, lobby, "ChampSelect", current, catalog, "[]", &lobby_output, false);
    var shortcut_output: [4096]u8 = undefined;
    const config = "{\"automation\":{\"shortcuts\":[{\"id\":\"premade\",\"target\":\"premade\",\"template\":\"{name}\",\"enabled\":true}]}}";
    const lines = try shortcut_service.buildLines(config, "premade", result, "ChampSelect", .{ .premade_side = "ally" }, &shortcut_output);
    try std.testing.expectEqualStrings("[\"我方开黑：[九尾妖狐、盲僧]\"]", lines);
}

fn containsProfilePuuid(players: []const std.json.Value, puuid: []const u8) bool {
    for (players) |player| if (std.mem.eql(u8, jsonField(player, "puuid"), puuid)) return true;
    return false;
}

test "recognizes live client rosters and champion aliases" {
    const live = "{\"activePlayer\":{\"riotIdGameName\":\"Self\",\"riotIdTagLine\":\"TAG\"},\"allPlayers\":[{\"riotId\":\"Self#TAG\",\"riotIdGameName\":\"Self\",\"riotIdTagLine\":\"TAG\",\"rawChampionName\":\"game_character_displayname_Vex\",\"team\":\"ORDER\"},{\"riotId\":\"Garen#BOT\",\"riotIdGameName\":\"Garen\",\"riotIdTagLine\":\"BOT\",\"rawChampionName\":\"game_character_displayname_Garen\",\"team\":\"CHAOS\",\"isBot\":true}]}";
    const catalog_json = "[{\"id\":711,\"name\":\"愁云使者\",\"alias\":\"Vex\"},{\"id\":86,\"name\":\"德玛西亚之力\",\"alias\":\"Garen\"}]";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed_live = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), live, .{});
    const catalog = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), catalog_json, .{});
    try std.testing.expect(liveClientRosterHash(live, null) != 0);
    try std.testing.expectEqual(@as(i64, 711), liveChampionId(parsed_live.object.get("allPlayers").?.array.items[0], catalog));
    try std.testing.expectEqual(@as(i64, 86), liveChampionId(parsed_live.object.get("allPlayers").?.array.items[1], catalog));
}

test "maps a realistic ten-player Live Client envelope and orients the current team" {
    const live =
        "{\"activePlayer\":{\"puuid\":\"self\",\"riotId\":\"Current Player#HN1\"},\"gameData\":{\"gameId\":987654321,\"gameMode\":\"CLASSIC\"},\"allPlayers\":[" ++
        "{\"puuid\":\"red-1\",\"riotId\":\"Red One#HN1\",\"team\":\"CHAOS\",\"championName\":\"Ahri\",\"rawChampionName\":\"game_character_displayname_Ahri\",\"position\":\"MIDDLE\"}," ++
        "{\"puuid\":\"self\",\"riotId\":\"Current Player#HN1\",\"team\":\"ORDER\",\"championName\":\"Vex\",\"rawChampionName\":\"game_character_displayname_Vex\",\"position\":\"MIDDLE\"}," ++
        "{\"puuid\":\"blue-2\",\"riotId\":\"Blue Two#HN1\",\"team\":\"ORDER\",\"championName\":\"Garen\",\"position\":\"TOP\"}," ++
        "{\"puuid\":\"blue-3\",\"riotId\":\"Blue Three#HN1\",\"team\":\"ORDER\",\"championName\":\"LeeSin\",\"position\":\"JUNGLE\"}," ++
        "{\"puuid\":\"blue-4\",\"riotId\":\"Blue Four#HN1\",\"team\":\"ORDER\",\"championName\":\"Jinx\",\"position\":\"BOTTOM\"}," ++
        "{\"puuid\":\"blue-5\",\"riotId\":\"Blue Five#HN1\",\"team\":\"ORDER\",\"championName\":\"Thresh\",\"position\":\"UTILITY\"}," ++
        "{\"puuid\":\"red-2\",\"riotId\":\"Red Two#HN1\",\"team\":\"CHAOS\",\"championName\":\"Camille\",\"position\":\"TOP\"}," ++
        "{\"puuid\":\"red-3\",\"riotId\":\"Red Three#HN1\",\"team\":\"CHAOS\",\"championName\":\"Nidalee\",\"position\":\"JUNGLE\"}," ++
        "{\"puuid\":\"red-4\",\"riotId\":\"Red Four#HN1\",\"team\":\"CHAOS\",\"championName\":\"Kaisa\",\"position\":\"BOTTOM\"}," ++
        "{\"puuid\":\"red-5\",\"riotId\":\"Red Five#HN1\",\"team\":\"CHAOS\",\"championName\":\"Nautilus\",\"position\":\"UTILITY\"}]}";
    const current = "{\"puuid\":\"self\",\"gameName\":\"Current Player\",\"tagLine\":\"HN1\"}";
    const session = "{\"gameData\":{\"gameId\":987654321,\"queue\":{\"id\":420,\"gameMode\":\"CLASS\"}}}";
    const catalog = "[{\"id\":711,\"name\":\"愁云使者\",\"alias\":\"Vex\"},{\"id\":103,\"name\":\"九尾妖狐\",\"alias\":\"Ahri\"}]";
    var state = Runtime.init();
    var output: [128 * 1024]u8 = undefined;
    const result = try liveClientEnvelope(&state, undefined, live, session, "InProgress", current, catalog, "[]", &output, false);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 5), parsed.value.object.get("ally").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 5), parsed.value.object.get("enemy").?.array.items.len);
    try std.testing.expectEqualStrings("self", jsonField(parsed.value.object.get("ally").?.array.items[0], "puuid"));
    try std.testing.expectEqualStrings("单双排", jsonField(parsed.value, "gameMode"));
    try std.testing.expectEqualStrings("InProgress", jsonField(parsed.value, "phase"));
    try std.testing.expect(std.mem.indexOf(u8, result, "\"championName\":\"愁云使者\"") != null);
}

test "does not orient a Live Client roster from array order when current account is absent" {
    const live = "{\"activePlayer\":{\"riotId\":\"Observed#HN1\"},\"allPlayers\":[{\"puuid\":\"red\",\"riotId\":\"Observed#HN1\",\"team\":\"CHAOS\"},{\"puuid\":\"blue\",\"riotId\":\"Blue#HN1\",\"team\":\"ORDER\"}]}";
    var state = Runtime.init();
    var output: [16 * 1024]u8 = undefined;
    try std.testing.expectError(error.LcuInvalidResponse, liveClientEnvelope(&state, undefined, live, null, "InProgress", "{\"puuid\":\"local-account\"}", "[]", "[]", &output, false));
}

test "probes active data during idle gameflow transitions" {
    try std.testing.expect(shouldProbeLiveData("None"));
    try std.testing.expect(shouldProbeLiveData("Lobby"));
    try std.testing.expect(shouldProbeLiveData("InProgress"));
    try std.testing.expect(!shouldProbeLiveData("ChampSelect"));
    try std.testing.expect(!shouldProbeLiveData("ReadyCheck"));
}

test "returns only newer release versions from the configured update feed" {
    var output: [256]u8 = undefined;
    try std.testing.expectEqualStrings("{\"version\":\"2.1.0\"}", try updateDto("{\"version\":\"2.1.0\"}", &output));
    try std.testing.expectEqualStrings("null", try updateDto("{\"version\":\"2.0.0\"}", &output));
    try std.testing.expectEqualStrings("null", try updateDto("{\"version\":\"1.9.9\"}", &output));
    try std.testing.expectEqual(@as(i8, 1), compareVersions("v2.0.1-beta.1", "2.0.0"));
}

test "matches modern live client Riot identities and normalized teams" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const player = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"riotId\":\"Player Name#HN1\",\"puuid\":\"same-puuid\",\"team\":\"ORDER\"}", .{});
    const current = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"gameName\":\"Different stale name\",\"tagLine\":\"OLD\",\"puuid\":\"same-puuid\"}", .{});
    const active = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"summonerName\":\"Player Name#HN1\"}", .{});
    try std.testing.expect(livePlayerMatches(player, current));
    try std.testing.expect(livePlayerMatches(player, active));
    try std.testing.expectEqualStrings("Player Name", riotIdentity(player).name);
    try std.testing.expectEqualStrings("HN1", riotIdentity(player).tag);
    try std.testing.expect(sameLiveTeam("ORDER", "BLUE"));
    try std.testing.expect(sameLiveTeam("CHAOS", "RED"));
    try std.testing.expect(!sameLiveTeam("ORDER", "CHAOS"));
}

test "splits spectator participant arrays with numeric team aliases" {
    const input = "{\"gameId\":321,\"queueId\":420,\"gameMode\":\"CLASS\",\"participants\":[{\"puuid\":\"blue\",\"riotId\":\"Blue#ONE\",\"teamId\":1,\"championId\":103},{\"puuid\":\"red\",\"riotId\":\"Red#TWO\",\"teamId\":2,\"championId\":64}]}";
    var output: [16 * 1024]u8 = undefined;
    const result = try liveSessionEnvelopePhase(input, "WatchInProgress", null, &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.get("ally").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.get("enemy").?.array.items.len);
    try std.testing.expectEqualStrings("Blue", parsed.value.object.get("ally").?.array.items[0].object.get("gameName").?.string);
    try std.testing.expectEqualStrings("Red", parsed.value.object.get("enemy").?.array.items[0].object.get("gameName").?.string);
    try std.testing.expectEqualStrings("单双排", parsed.value.object.get("gameMode").?.string);
}

test "accepts nested spectator blue and red team arrays" {
    const input = "{\"gameId\":322,\"queueId\":420,\"gameMode\":\"CLASS\",\"gameData\":{\"playerRoster\":{\"blueTeam\":[{\"puuid\":\"blue\",\"riotId\":\"Blue#ONE\",\"championId\":103}],\"redTeam\":[{\"puuid\":\"red\",\"riotId\":\"Red#TWO\",\"championId\":64}]}}}";
    try std.testing.expectEqual(@as(usize, 2), rawRosterCount(input));
    var output: [16 * 1024]u8 = undefined;
    const result = try liveSessionEnvelopePhase(input, "WatchInProgress", null, &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.get("ally").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.get("enemy").?.array.items.len);
    try std.testing.expect(std.mem.indexOf(u8, result, "蓝方阵容") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "红方阵容") != null);
}

test "maps riotId-only current summoner connection fields" {
    var output: [4096]u8 = undefined;
    const result = try connectionDtoDetailed("{\"puuid\":\"p1\",\"riotId\":\"Current Player#TAG\"}", "\"InProgress\"", "{}", "{}", "{}", "{}", &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Current Player", parsed.value.object.get("gameName").?.string);
    try std.testing.expectEqualStrings("TAG", parsed.value.object.get("tagLine").?.string);
}

test "maps player history into live card recent matches" {
    const input = "{\"games\":[{\"json\":{\"gameId\":51,\"queueId\":420,\"gameDuration\":1200,\"gameCreation\":1625159473123,\"gameMode\":\"CLASSIC\",\"participants\":[{\"puuid\":\"self\",\"championId\":711,\"teamPosition\":\"MIDDLE\",\"kills\":8,\"deaths\":2,\"assists\":7,\"win\":true}]}}]}";
    var catalog_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer catalog_arena.deinit();
    const catalog = try std.json.parseFromSliceLeaky(std.json.Value, catalog_arena.allocator(), "[{\"id\":711,\"name\":\"Vex\"}]", .{});
    var output: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    const count = try writeRecentMatches(&writer, input, catalog, "self", 10);
    try std.testing.expectEqual(@as(usize, 1), count);
    const result = writer.buffered();
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expect(std.mem.indexOf(u8, result, "\"gameId\":51") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"win\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"kills\":8") != null);
}

test "filters hidden history records before applying page offsets" {
    const input = "{\"games\":{\"games\":[{\"gameId\":1,\"queueId\":0,\"gameDuration\":1200,\"participants\":[{\"puuid\":\"self\"}]},{\"gameId\":2,\"queueId\":420,\"gameDuration\":1200,\"participants\":[{\"puuid\":\"self\"}]},{\"gameId\":3,\"queueId\":440,\"gameDuration\":1200,\"participants\":[{\"puuid\":\"self\"}]}]}}";
    var output: [16384]u8 = undefined;
    const result = try matchHistoryDtoPageFiltered(input, "[]", "self", 1, 1, true, &output);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"gameId\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"gameId\":1") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"gameId\":2") == null);
}

test "live card history excludes custom and aborted records" {
    const input = "{\"games\":[{\"gameId\":1,\"queueId\":0,\"gameDuration\":1200,\"participants\":[{\"puuid\":\"self\"}]},{\"gameId\":2,\"queueId\":420,\"gameDuration\":30,\"participants\":[{\"puuid\":\"self\"}]},{\"gameId\":3,\"queueId\":420,\"gameDuration\":1200,\"participants\":[{\"puuid\":\"self\",\"championId\":103,\"win\":true}]}]}";
    var catalog_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer catalog_arena.deinit();
    const catalog = try std.json.parseFromSliceLeaky(std.json.Value, catalog_arena.allocator(), "[{\"id\":103,\"name\":\"阿狸\"}]", .{});
    var output: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    const count = try writeRecentMatches(&writer, input, catalog, "self", 10);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"gameId\":3") != null);
}

test "builds evidence-backed jungle preference from recent match DTOs" {
    const matches = "[{\"championId\":64,\"championName\":\"盲僧\",\"position\":\"JUNGLE\",\"kills\":8,\"deaths\":2,\"assists\":10,\"durationMinutes\":30,\"cs\":180,\"killParticipation\":0.7,\"takedownsFirstXMinutes\":3,\"dragonTakedowns\":2,\"baronTakedowns\":1,\"riftHeraldTakedowns\":1,\"enemyJungleMonsterKills\":4,\"win\":true},{\"championId\":64,\"championName\":\"盲僧\",\"position\":\"JUNGLE\",\"kills\":4,\"deaths\":4,\"assists\":8,\"durationMinutes\":24,\"cs\":144,\"killParticipation\":0.6,\"takedownsFirstXMinutes\":2,\"dragonTakedowns\":1,\"baronTakedowns\":0,\"riftHeraldTakedowns\":1,\"enemyJungleMonsterKills\":2,\"win\":false}]";
    var output: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try writeJunglePreference(&writer, matches, 64);
    const result = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, result, "\"sampleSize\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"style\":\"tempo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"currentChampionGames\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"championName\":\"盲僧\"") != null);
}

test "does not assign an unmatched participant to another player" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const game = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"participants\":[]}", .{});
    const participants = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "[{\"puuid\":\"one\"},{\"puuid\":\"two\"}]", .{});
    const missing = participantForPuuid(game, participants, "missing");
    try std.testing.expect(missing == .null);
    const single = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "[{\"puuid\":\"one\"}]", .{});
    try std.testing.expectEqualStrings("one", jsonField(participantForPuuid(game, single, "missing"), "puuid"));
}

test "derives encounter records from match participants" {
    const input = "{\"games\":{\"games\":[{\"gameId\":9,\"participants\":[{\"puuid\":\"self\",\"teamId\":100},{\"puuid\":\"enemy\",\"summonerName\":\"Opponent\",\"teamId\":200,\"championId\":64,\"championName\":\"Lee Sin\"}]}]}}";
    var output: [4096]u8 = undefined;
    const result = try encountersFromHistory(input, "self", &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    parsed.deinit();
    try std.testing.expect(std.mem.indexOf(u8, result, "\"puuid\":\"enemy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"side\":\"enemy\"") != null);
}

test "merges encounter archive with deduplication and retention cutoff" {
    const existing = "[{\"gameId\":1,\"puuid\":\"old-player\",\"encounteredAt\":\"2024-12-31T23:59:59.000Z\"},{\"gameId\":2,\"puuid\":\"same-player\",\"gameName\":\"stale-name\",\"encounteredAt\":\"2025-06-01T00:00:00.000Z\"},{\"gameId\":3,\"puuid\":\"kept-player\",\"encounteredAt\":\"2025-07-01T00:00:00.000Z\"}]";
    const newest = "[{\"gameId\":2,\"puuid\":\"same-player\",\"gameName\":\"latest-name\",\"encounteredAt\":\"2025-06-01T00:00:00.000Z\"}]";
    var output: [4096]u8 = undefined;
    const result = try mergeEncounterArchive(existing, newest, "2025-01-01T00:00:00.000Z", &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
    try std.testing.expect(std.mem.indexOf(u8, result, "old-player") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "stale-name") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "latest-name") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "kept-player") != null);
}

test "writes encounter evidence before LeagueAkari gank labels" {
    const matches = "[{\"durationMinutes\":20,\"earlyDeathsWithEnemyJungler\":3},{\"durationMinutes\":24,\"earlyDeathsWithEnemyJungler\":2}]";
    var encounter = EncounterSummary{ .count = 2 };
    const latest = "2026-08-28T12:00:00.000Z";
    @memcpy(encounter.latest[0..latest.len], latest);
    encounter.latest_len = latest.len;
    var output: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try writeRecentTags(&writer, matches, "TOP", 0, encounter);
    const result = writer.buffered();
    const met_index = std.mem.indexOf(u8, result, "遇到过") orelse return error.TestUnexpectedResult;
    const gank_index = std.mem.indexOf(u8, result, "非常好抓") orelse return error.TestUnexpectedResult;
    try std.testing.expect(met_index < gank_index);
    try std.testing.expect(std.mem.indexOf(u8, result, "共遇到过 2 次") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, latest) != null);
}

test "matches LeagueAkari easy-gank thresholds" {
    const cases = [_]struct {
        matches: []const u8,
        position: []const u8 = "TOP",
        expected: ?[]const u8,
    }{
        .{ .matches = "[{\"durationMinutes\":20,\"earlyDeathsWithEnemyJungler\":3},{\"durationMinutes\":20,\"earlyDeathsWithEnemyJungler\":2}]", .expected = "非常好抓" },
        .{ .matches = "[{\"durationMinutes\":20,\"earlyDeathsWithEnemyJungler\":2},{\"durationMinutes\":20,\"earlyDeathsWithEnemyJungler\":1}]", .expected = "好抓" },
        .{ .matches = "[{\"durationMinutes\":20,\"earlyDeathsWithEnemyJungler\":1},{\"durationMinutes\":20,\"earlyDeathsWithEnemyJungler\":1}]", .expected = null },
        .{ .matches = "[{\"durationMinutes\":20,\"earlyDeathsWithEnemyJungler\":0},{\"durationMinutes\":20,\"earlyDeathsWithEnemyJungler\":1}]", .expected = "难抓" },
        .{ .matches = "[{\"durationMinutes\":20,\"earlyDeathsWithEnemyJungler\":3}]", .position = "JUNGLE", .expected = null },
    };
    for (cases) |case| {
        var output: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&output);
        try writeRecentTags(&writer, case.matches, case.position, 0, .{});
        if (case.expected) |label| {
            try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), label) != null);
        } else {
            try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "好抓") == null);
            try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "难抓") == null);
        }
    }
}

test "keeps encounter label when recent match history is unavailable" {
    var encounter = EncounterSummary{ .count = 1 };
    const latest = "2026-08-28T12:00:00.000Z";
    @memcpy(encounter.latest[0..latest.len], latest);
    encounter.latest_len = latest.len;
    var output: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try writeRecentTags(&writer, "[]", "TOP", 0, encounter);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, writer.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    try std.testing.expectEqualStrings("met", jsonField(parsed.value.array.items[0], "key"));
    try std.testing.expectEqualStrings("遇到过", jsonField(parsed.value.array.items[0], "label"));
}

test "normalizes friend groups and friend-since dates" {
    var state = Runtime.init();
    const groups = "[{\"id\":7,\"name\":\"双排\",\"priority\":2}]";
    const friends = "[{\"id\":\"friend-id\",\"puuid\":\"friend-puuid\",\"summonerId\":42,\"gameName\":\"好友\",\"gameTag\":\"CN1\",\"icon\":12,\"groupId\":7,\"availability\":\"chat\"}]";
    const giftable = "[{\"summonerId\":42,\"friendsSince\":\"2025-08-29T10:00:00.000Z\"}]";
    var output: [4096]u8 = undefined;
    const result = try friendToolsDto(&state, groups, friends, giftable, &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.get("groups").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.get("friends").?.array.items.len);
    const friend = parsed.value.object.get("friends").?.array.items[0];
    try std.testing.expectEqualStrings("好友", friend.object.get("gameName").?.string);
    try std.testing.expectEqual(@as(i64, 7), friend.object.get("groupId").?.integer);
    try std.testing.expectEqualStrings("2025-08-29T10:00:00.000Z", friend.object.get("friendsSince").?.string);
}

test "extracts the latest friend match timestamp" {
    var output: [1024]u8 = undefined;
    const result = try friendLastGameDto("friend-puuid", "{\"games\":[{\"gameCreation\":1625159473123}]}", &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("friend-puuid", parsed.value.object.get("puuid").?.string);
    try std.testing.expectEqualStrings("2021-07-01T17:11:13.123Z", parsed.value.object.get("lastGameAt").?.string);
}

test "derives encounters from SGP object payloads" {
    const input = "{\"games\":[{\"json\":{\"gameId\":10,\"gameCreation\":1625159473123,\"participants\":[{\"puuid\":\"self\",\"teamId\":100,\"win\":true},{\"puuid\":\"ally\",\"riotIdGameName\":\"Teammate\",\"teamId\":100,\"championId\":103,\"championName\":\"Ahri\"},{\"puuid\":\"enemy\",\"riotIdGameName\":\"Opponent\",\"teamId\":200,\"championId\":64,\"championName\":\"Lee Sin\"}]}}]}";
    var output: [4096]u8 = undefined;
    const result = try encountersFromHistory(input, "self", &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"gameName\":\"Teammate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"side\":\"enemy\"") != null);
}

test "derives encounters from a cached match summary array" {
    const input = "[{\"gameId\":11,\"result\":\"胜利\",\"playedAt\":\"2021-07-01T17:11:13.123Z\",\"participants\":[{\"puuid\":\"self\",\"side\":\"ally\",\"win\":true},{\"puuid\":\"enemy\",\"gameName\":\"Opponent\",\"side\":\"enemy\",\"championId\":64,\"championName\":\"Lee Sin\"}]}]";
    var output: [4096]u8 = undefined;
    const result = try encountersFromHistory(input, "self", &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"puuid\":\"enemy\"") != null);
}

test "writes JavaScript-compatible ISO timestamps with milliseconds" {
    var output: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try writeIsoTimestamp(&writer, 1625159473123);
    try std.testing.expectEqualStrings("\"2021-07-01T17:11:13.123Z\"", writer.buffered());
}

test "decrypts ChampSelect obfuscated PUUIDs before exposing player profiles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const participant = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"obfuscatedPuuid\":\"8161549a-b004-06ec-1d01-c2a8024cf918\",\"gameName\":\"Player\"}", .{});
    var puuid_buffer: [36]u8 = undefined;
    try std.testing.expectEqualStrings("00112233-4455-5677-8899-aabbccddeeff", resolvedIdentityPuuid(participant, &puuid_buffer));

    var output: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try writeProfile(&writer, participant, "ally", std.json.Value{ .null = {} });
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"puuid\":\"00112233-4455-5677-8899-aabbccddeeff\"") != null);
}

test "preserves champ-select summoner spells for smite jungler detection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const participant = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"gameName\":\"打野\",\"assignedPosition\":\"NONE\",\"spell1Id\":11,\"spell2Id\":4}", .{});
    try std.testing.expect(playerIsJungle(participant));
    var output: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try writeProfile(&writer, participant, "ally", std.json.Value{ .null = {} });
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, writer.buffered(), .{});
    defer parsed.deinit();
    const spells = parsed.value.object.get("summonerSpells").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), spells.len);
    try std.testing.expectEqual(@as(i64, 11), spells[0].object.get("id").?.integer);
}

test "normalizes alternate summoner spell fields for smite detection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const participant = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"gameName\":\"备用字段打野\",\"assignedPosition\":\"NONE\",\"summonerSpellOneId\":11,\"summonerSpellTwoId\":4}", .{});
    try std.testing.expect(playerIsJungle(participant));
    var output: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try writeProfile(&writer, participant, "ally", std.json.Value{ .null = {} });
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, writer.buffered(), .{});
    defer parsed.deinit();
    const spells = parsed.value.object.get("summonerSpells").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), spells.len);
    try std.testing.expectEqual(@as(i64, 11), spells[0].object.get("id").?.integer);
}

test "collects nested summoner spell fields for smite detection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const participant = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"gameName\":\"嵌套打野\",\"assignedPosition\":\"NONE\",\"summoner\":{\"spell1Id\":11,\"spell2Id\":4}}", .{});
    try std.testing.expect(playerIsJungle(participant));
    var output: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try writeProfile(&writer, participant, "ally", std.json.Value{ .null = {} });
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, writer.buffered(), .{});
    defer parsed.deinit();
    const spells = parsed.value.object.get("summonerSpells").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), spells.len);
    try std.testing.expectEqual(@as(i64, 11), spells[0].object.get("id").?.integer);
}

test "maps premade group identifiers into player profile evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const members = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "[{\"puuid\":\"one\",\"gameName\":\"玩家一\",\"partyId\":\"party-a\"},{\"puuid\":\"two\",\"gameName\":\"玩家二\",\"premadeGroupId\":\"party-a\"},{\"puuid\":\"three\",\"gameName\":\"玩家三\",\"partyId\":\"party-b\"}]", .{});
    var output: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try writeProfileWithGroup(&writer, members.array.items[0], "ally", std.json.Value{ .null = {} }, members);
    const result = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, result, "\"isPremade\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"premadeGroup\":\"party-a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"premadeWith\":[\"玩家二\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "玩家三") == null);
}

test "maps champ-select party members to stable position evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const members = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "[{\"puuid\":\"one\",\"gameName\":\"玩家一\",\"partyId\":\"party-a\",\"firstPositionPreference\":\"TOP\"},{\"puuid\":\"two\",\"gameName\":\"玩家二\",\"partyId\":\"party-a\",\"firstPositionPreference\":\"JUNGLE\"}]", .{});
    const participant = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"puuid\":\"one\",\"gameName\":\"玩家一\"}", .{});
    var output: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try writeProfileWithGroup(&writer, participant, "ally", std.json.Value{ .null = {} }, members);
    const result = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, result, "\"premadePositions\":[\"打野\"]") != null);
}

test "default runtime config includes native shortcut definitions" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, default_config, .{});
    defer parsed.deinit();
    try std.testing.expect(configAutomation(parsed.value) != null);
    try std.testing.expect(configAutomation(parsed.value).?.object.get("shortcuts") != null);
}

test "runtime persistence paths share one stable data root" {
    var original = Runtime.init();
    try original.setDataPaths("test-data-root");
    var moved = original;
    original.data_dir_path[0] = 'X';

    try std.testing.expectEqualStrings("test-data-root", moved.dataDir());
    try std.testing.expect(std.mem.endsWith(u8, moved.configPath(), "config.json"));
    try std.testing.expect(std.mem.endsWith(u8, moved.databasePath(), "lol-desktop.sqlite3"));
    try std.testing.expect(std.mem.startsWith(u8, moved.configPath(), moved.dataDir()));
    try std.testing.expect(std.mem.startsWith(u8, moved.databasePath(), moved.dataDir()));
}

test "bootstrap JSON escapes Windows persistence paths" {
    var state = Runtime.init();
    try state.setDataPaths("C:\\Users\\tester\\AppData\\Local\\lol-desktop-native\\Data");
    var output: [4096]u8 = undefined;
    const result = try getBootstrap(@ptrCast(&state), undefined, &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(state.dataDir(), parsed.value.object.get("appDataPath").?.string);
}

test "maps detailed LCU connection account rank and platform fields" {
    const summoner = "{\"puuid\":\"p1\",\"gameName\":\"Player\",\"tagLine\":\"TAG\",\"summonerLevel\":42,\"profileIconId\":7}";
    const ranked = "{\"platformId\":\"HN1\",\"queues\":[{\"queueType\":\"RANKED_SOLO_5x5\",\"tier\":\"GOLD\",\"rank\":\"II\",\"leaguePoints\":55,\"wins\":10,\"losses\":8}]}";
    var output: [4096]u8 = undefined;
    const result = try connectionDtoDetailed(summoner, "\"ChampSelect\"", "{\"availability\":\"chat\"}", ranked, "{}", "{}", &output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expect(std.mem.indexOf(u8, result, "\"platformId\":\"HN1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"presence\":\"champSelect\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"tier\":\"GOLD\"") != null);
}

fn writeProfileArray(writer: *std.Io.Writer, value: ?std.json.Value, side: []const u8, catalog: std.json.Value) !void {
    try writer.writeByte('[');
    if (value) |array| if (array == .array) {
        var first = true;
        var index: usize = 0;
        for (array.array.items) |participant| {
            if (participant != .object) continue;
            if (!first) try writer.writeByte(',');
            first = false;
            try writeProfileWithGroupIndexed(writer, participant, side, index, catalog, array);
            index += 1;
        }
    };
    try writer.writeByte(']');
}

fn writeProfile(writer: *std.Io.Writer, participant: std.json.Value, side: []const u8, catalog: std.json.Value) !void {
    return writeProfileWithGroup(writer, participant, side, catalog, null);
}

fn writeProfileWithGroup(writer: *std.Io.Writer, participant: std.json.Value, side: []const u8, catalog: std.json.Value, group_members: ?std.json.Value) !void {
    return writeProfileWithGroupIndexed(writer, participant, side, 0, catalog, group_members);
}

fn writeProfileWithGroupIndexed(writer: *std.Io.Writer, participant: std.json.Value, side: []const u8, index: usize, catalog: std.json.Value, group_members: ?std.json.Value) !void {
    const summoner = nestedObject(participant, "summoner") orelse participant;
    const participant_identity = riotIdentity(participant);
    const summoner_identity = riotIdentity(summoner);
    const game_name = if (participant_identity.name.len > 0) participant_identity.name else if (summoner_identity.name.len > 0) summoner_identity.name else "未知玩家";
    const tag_line = if (participant_identity.tag.len > 0) participant_identity.tag else summoner_identity.tag;
    const champion_id = selectedChampionId(participant);
    const raw_champion_name = jsonField(participant, "championName");
    const champion_name = if (champion_id > 0) catalogChampionName(catalog, champion_id, raw_champion_name) else championDisplayName(raw_champion_name, "等待选择");
    const position = if (playerPosition(participant).len > 0) playerPosition(participant) else "NONE";
    const profile_icon_id = if (jsonInt(participant, "profileIconId") > 0) jsonInt(participant, "profileIconId") else if (jsonInt(participant, "summonerIconId") > 0) jsonInt(participant, "summonerIconId") else jsonInt(summoner, "profileIconId");
    const is_bot = isBotMember(participant) or std.ascii.eqlIgnoreCase(tag_line, "BOT");
    try writer.writeAll("{\"puuid\":");
    var puuid_buffer: [36]u8 = undefined;
    const puuid = resolvedIdentityPuuid(participant, &puuid_buffer);
    if (puuid.len > 0) {
        try jsonString(writer, puuid);
    } else if (identityNumericId(participant) > 0) {
        var numeric_buffer: [32]u8 = undefined;
        try jsonString(writer, try std.fmt.bufPrint(&numeric_buffer, "{d}", .{identityNumericId(participant)}));
    } else {
        var synthetic: [128]u8 = undefined;
        try jsonString(writer, std.fmt.bufPrint(&synthetic, "{s}-{s}-{d}", .{ side, if (is_bot) "bot" else "slot", index }) catch side);
    }
    try writer.writeAll(",\"gameName\":");
    try jsonString(writer, game_name);
    try writer.writeAll(",\"tagLine\":");
    try jsonString(writer, tag_line);
    try writer.print(",\"isBot\":{},\"championId\":{d},\"championName\":", .{ is_bot, champion_id });
    try jsonString(writer, champion_name);
    try writer.writeAll(",\"profileIconId\":");
    try writer.print("{d},\"assignedPosition\":", .{profile_icon_id});
    try jsonString(writer, position);
    try writer.writeAll(",\"summonerSpells\":");
    try writeSummonerSpells(writer, participant);
    try writer.writeAll(",\"rankTier\":\"\",\"rankDivision\":\"\",\"leaguePoints\":0,\"wins\":0,\"losses\":0,\"soloRank\":null,\"flexRank\":null,\"recentMatches\":[],\"topChampions\":[],\"score\":{\"total\":0,\"confidence\":0,\"components\":[]},\"tags\":[],\"junglePreference\":null,\"encounterCount\":0,\"lastEncounteredAt\":null");
    try writePremadeFields(writer, participant, group_members);
    try writer.writeAll(",\"positionGames\":0,\"positionWinRate\":0,\"currentChampionGames\":0,\"currentChampionWinRate\":0,\"championPoolConcentration\":0,\"dataComplete\":false,\"unavailableSources\":[\"lcu\"],\"dataStatus\":{\"source\":\"lcu\",\"fetchedAt\":\"1970-01-01T00:00:00.000Z\",\"expiresAt\":null,\"isStale\":false,\"error\":null},\"side\":");
    try jsonString(writer, side);
    try writer.writeByte('}');
}
