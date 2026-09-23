/**
 * 后端门面：只回答「这一调用走原生桥还是走浏览器模拟」。
 *
 * 模拟实现全在 `./browserBackend.ts`，原生传输在 `./native.ts`。本文件不承载任何
 * 领域规则——快捷消息怎么渲染、标签是什么文案、fixture 长什么样，都不在这里。
 * 这样传输层的改动不会牵动业务，业务改动也不会牵动传输层。
 */
import { invokeNative, isNative } from "./native";
import { browserBackend, browserState, usesFixtureData } from "./browserBackend";
import type {
  AppBootstrap,
  AppConfig,
  AssetPayload,
  ChampionOverview,
  ClaimOutcome,
  ClaimSnapshot,
  ClaimSource,
  ClientInstallations,
  ClientLaunchResult,
  DataMode,
  DeletedFriendsSnapshot,
  EncounterRecord,
  FinalBpRecord,
  FriendDeleteOutcome,
  FriendToolsSnapshot,
  GameflowActionKey,
  GameflowActionResult,
  JunglePathMap,
  LiveLobby,
  MatchSummary,
  MatchTimeline,
  RestoreFriendResult,
  ShortcutValidation,
  SpectateResult,
  SummonerSearchResult,
} from "../types/domain";
import { createShortcutSendQueue } from "../shortcuts/sendQueue";

const assetRequests = new Map<string, Promise<AssetPayload>>();

/** 是否运行在原生宿主里（而非浏览器预览）。UI 用它决定要不要起轮询、拉原生资源。 */
export const isTauri = isNative;

const queueShortcutSend = createShortcutSendQueue();
let sendConnection = "";
let sendLobby = "";

function sendContext() {
  return JSON.stringify([browserState.mode, sendConnection, sendLobby]);
}

function rememberLobby(lobby: LiveLobby) {
  const phase = ["ChampSelect", "ReadyCheck"].includes(lobby.phase) ? "选人" : ["GameStart", "InProgress"].includes(lobby.phase) ? "游戏中" : lobby.phase;
  sendLobby = JSON.stringify([lobby.id, phase]);
  return lobby;
}

let lastLobbyVersion = 0;
let lastLobby: LiveLobby | null = null;

async function command<T>(name: string, args?: Record<string, unknown>): Promise<T> {
  if (!isNative()) throw new Error("浏览器预览不支持此操作");
  if (name === "send_shortcut") {
    const context = sendContext();
    return queueShortcutSend(JSON.stringify([context, args]), () => {
      if (context !== sendContext()) throw new Error("会话已变化，已取消排队消息");
      return invokeNative<T>(`lol.${name}`, args);
    });
  }
  return invokeNative<T>(`lol.${name}`, args);
}

export const backend = {
  async bootstrap(): Promise<AppBootstrap> {
    if (!isTauri()) return browserBackend.bootstrap();
    const value = await command<AppBootstrap>("get_bootstrap");
    browserState.mode = value.dataMode;
    if (browserState.mode === "live") return value;
    return browserBackend.withFixtureDashboard(value);
  },
  async config(): Promise<AppConfig> {
    if (!isTauri()) return browserBackend.config();
    browserState.config = await command<AppConfig>("get_config");
    return browserBackend.config();
  },
  async saveConfig(value: AppConfig): Promise<AppConfig> {
    if (!isTauri()) return browserBackend.saveConfig(value);
    browserState.config = await command<AppConfig>("save_config", { value });
    return browserBackend.config();
  },
  async setMode(mode: DataMode): Promise<DataMode> {
    if (mode === "replay") throw new Error("回看功能尚未开放");
    const selected = isTauri() ? await command<DataMode>("set_data_mode", { mode }) : mode;
    browserState.mode = selected;
    return selected;
  },
  async refreshConnection() {
    if (usesFixtureData()) return browserBackend.connection();
    const connection = await command<AppBootstrap["dashboard"]["connection"]>("refresh_connection");
    sendConnection = JSON.stringify([connection.status, connection.platformId, connection.gameName, connection.tagLine, connection.phase]);
    return connection;
  },
  async lcuEvents(): Promise<{ uri: string; phase?: string }[]> {
    if (!isTauri()) return [];
    return command("get_lcu_events");
  },
  async shortcutEvents(): Promise<string[]> {
    if (!isTauri()) return [];
    return command("get_shortcut_events");
  },
  async lobby(force = false): Promise<LiveLobby> {
    if (usesFixtureData()) return browserBackend.lobby();
    // 加载期间界面每 750ms 问一次进度，但十个人里往往只有一两个刚完成。
    // 带上一次收到的版本号，快照内容没变时后端只回进度，省掉整份阵容的
    // 传输与前端重建。
    const response = await command<LiveLobby & { version?: number; unchanged?: boolean }>("get_live_lobby", { force, sinceVersion: lastLobbyVersion });
    if (typeof response.version === "number") lastLobbyVersion = response.version;
    const merged = response.unchanged && lastLobby ? { ...lastLobby, loading: response.loading } : response;
    lastLobby = merged;
    return rememberLobby(merged);
  },
  async lobbyRoster(): Promise<LiveLobby> {
    if (usesFixtureData()) return browserBackend.lobby();
    return rememberLobby(await command<LiveLobby>("get_live_roster"));
  },
  async matches(summonerName?: string, page = 0, pageSize = 10): Promise<MatchSummary[]> {
    if (usesFixtureData()) return browserBackend.matches(page, pageSize);
    return command("get_match_history", { summonerName: summonerName?.trim() || null, page, pageSize });
  },
  /**
   * 把一个「可能不完整」的查询解析成候选「名字#TAG」。
   *
   * 本地接口都是精确匹配，且没有任何 name→tags 的反向索引：带 `#TAG` 时能走
   * Riot Client 跨区命中；只给名字时最多在当前大区解析一个结果，解析不到就返回空
   * 候选并把 `requiresTag` 置真，由界面提示需要完整 Riot ID。
   */
  async searchSummoner(query: string): Promise<SummonerSearchResult> {
    const trimmed = query.trim();
    const hasTag = trimmed.includes("#");
    if (!trimmed) return { query: "", hasTag, requiresTag: false, candidates: [] };
    if (usesFixtureData()) return browserBackend.searchSummoner(trimmed);
    return command("search_summoner", { query: trimmed });
  },
  /**
   * 英雄目录 + OP.GG 统计。
   *
   * `region` / `tier` 是 OP.GG 的区服与分段口径（`kr` / `euw` / `global` … 与
   * `emerald_plus` / `master_plus` …）。不传就是默认的 `global` + `emerald_plus`——
   * 自动化页和实时页只关心英雄名和 id，走默认即可，也就还能共用同一份缓存。
   * 后端对这两个值有白名单，表外的值落回默认而不是报错。
   */
  async champions(region?: string, tier?: string): Promise<ChampionOverview[]> {
    if (usesFixtureData()) return browserBackend.champions();
    return command("get_champions", { region: region?.trim() ?? "", tier: tier?.trim() ?? "" });
  },
  /**
   * 一局的完整十人详情。
   *
   * `selfPuuid` 只用于账号归属校验（必须等于当前登录账号）；
   * `subjectPuuid` 决定行内 KDA / 阵营取谁的视角，缺省等于 `selfPuuid`。
   * 看别人的历史时要显式传 `subjectPuuid`——那一局通常没有「我」。
   */
  async matchDetail(gameId: number, platformId: string, selfPuuid: string, targetPuuid: string, subjectPuuid = ""): Promise<MatchSummary> {
    if (usesFixtureData()) return browserBackend.matchDetail(gameId);
    return command("get_match_detail", { gameId, platformId, selfPuuid, targetPuuid, subjectPuuid });
  },
  /**
   * 打野路线图：把该玩家这些局的前 15 分钟逐帧落点取回来。
   *
   * 只传 gameId，不传 MatchSummary——后端自己按 gameId 走 SGP DETAILS（带本地
   * 缓存），拿到的帧数据和快捷消息里的「打野偏好」是同一份，两处口径不会漂。
   * `selfPuuid` 与 `matchDetail` 同义，只做账号归属校验。没有逐帧数据时返回 null。
   */
  async junglePath(puuid: string, selfPuuid: string, gameIds: number[], championId = 0): Promise<JunglePathMap | null> {
    const target = puuid?.trim() ?? "";
    // 上限与后端 `jungle_path_sample_limit` 一致，对齐 AK 的 gameDetailsLoadCount（20）。
    const ids = [...new Set(gameIds.filter((id) => Number.isFinite(id) && id > 0))].slice(0, 20);
    if (!target || !ids.length) return null;
    // 浏览器预览下没有逐帧数据可解，用 fixture 顶上，保证路线图这块看得见。
    if (usesFixtureData()) return browserBackend.junglePath(target, ids);
    return command<JunglePathMap | null>("get_jungle_path", {
      puuid: target,
      selfPuuid: selfPuuid?.trim() ?? "",
      championId,
      gameIds: ids,
    });
  },
  /**
   * 一局的分钟帧 + 关键事件（经济曲线、野怪、掉塔）。
   *
   * 和 `junglePath` 同源（都读 LCU 的 `game-timelines`），但返回的是整场的宏观走势。
   * 逐帧数据打完就不变，后端有 `matchTimeline` 落盘缓存，重复进入同一局不会重复联网。
   */
  async matchTimeline(gameId: number, selfPuuid = ""): Promise<MatchTimeline | null> {
    if (!Number.isFinite(gameId) || gameId <= 0) return null;
    if (usesFixtureData()) return browserBackend.matchTimeline(gameId);
    return command<MatchTimeline | null>("get_match_timeline", { gameId, selfPuuid: selfPuuid?.trim() ?? "" });
  },
  async asset(kind: "champion" | "item" | "spell" | "perk" | "profile", id: number): Promise<AssetPayload> {    if (usesFixtureData()) throw new Error("Fixture 使用静态资源");
    const key = `${kind}:${id}`;
    const cached = assetRequests.get(key);
    if (cached) return cached;
    const request = command<AssetPayload>("get_asset", { kind, id }).catch((cause) => {
      assetRequests.delete(key);
      throw cause;
    });
    assetRequests.set(key, request);
    return request;
  },
  /**
   * 按 LCU 资源路径取图标。
   *
   * 领取奖励那类资源只有路径（`/lol-game-data/assets/...`），没有 `(kind, id)` 编号，
   * 所以单开一条。同一路径的请求会复用同一个 promise。
   */
  async assetPath(path: string): Promise<AssetPayload> {
    const target = path?.trim() ?? "";
    if (!target) throw new Error("空的资源路径");
    if (usesFixtureData()) throw new Error("Fixture 使用静态资源");
    const key = `path:${target}`;
    const cached = assetRequests.get(key);
    if (cached) return cached;
    const request = command<AssetPayload>("get_asset", { path: target }).catch((cause) => {
      assetRequests.delete(key);
      throw cause;
    });
    assetRequests.set(key, request);
    return request;
  },
  async encounters(puuid?: string, limitGames = 40, excludeGameId = 0): Promise<EncounterRecord[]> {
    const target = puuid?.trim() || "";
    const boundedLimit = Math.max(1, Math.min(40, Math.trunc(limitGames) || 40));
    if (usesFixtureData()) return browserBackend.encounters(target, boundedLimit, excludeGameId);
    return command("get_encounters", { puuid: target || null, limitGames: boundedLimit, excludeGameId });
  },
  /** 批量读取本局玩家的备注（玩家标记），键为 puuid。 */
  async playerTags(puuids: string[], selfPuuid?: string | null): Promise<Record<string, string[]>> {
    const targets = [...new Set(puuids.map((puuid) => puuid?.trim() ?? "").filter(Boolean))];
    if (!targets.length) return {};
    if (usesFixtureData()) return browserBackend.playerTags(targets);
    const response = await command<{ tags?: Record<string, string[]> }>("get_player_tags", {
      puuids: targets,
      selfPuuid: selfPuuid?.trim() || null,
    });
    return response.tags ?? {};
  },
  /** 覆盖写入某位玩家的备注，返回清洗后的结果。 */
  async updatePlayerTag(puuid: string, notes: string[], selfPuuid?: string | null): Promise<{ puuid: string; notes: string[]; updatedAt: number }> {
    const target = puuid?.trim() ?? "";
    if (!target) throw new Error("缺少玩家标识，无法保存标记");
    const cleaned = notes.map((note) => note.trim()).filter(Boolean);
    if (usesFixtureData()) return browserBackend.updatePlayerTag(target, cleaned);
    return command("update_player_tag", {
      puuid: target,
      notes: cleaned,
      selfPuuid: selfPuuid?.trim() || null,
    });
  },
  async friends(): Promise<FriendToolsSnapshot> {
    if (usesFixtureData()) return browserBackend.friends();
    return command("get_friends");
  },
  async friendLastGame(puuid: string, force = false): Promise<{ puuid: string; lastGameAt: string | null }> {
    if (usesFixtureData()) return browserBackend.friendLastGame(puuid);
    return command("get_friend_last_game", { puuid, force });
  },
  async deleteFriend(id: string): Promise<void> {
    if (usesFixtureData()) {
      browserBackend.deleteFriend(id);
      return;
    }
    await command("delete_friend", { id });
  },
  /**
   * 批量删除好友。
   *
   * 后端逐条删、逐条回报，所以**不会因为其中一个失败就整批抛错**：返回值里
   * `failed > 0` 时去 `results` 里挑 `ok === false` 的那些看原因。
   */
  async deleteFriends(ids: string[]): Promise<FriendDeleteOutcome> {
    const targets = [...new Set(ids.map((id) => id?.trim()).filter(Boolean))];
    if (!targets.length) return { results: [], deleted: 0, failed: 0 };
    if (usesFixtureData()) return browserBackend.deleteFriends(targets);
    return command("delete_friends", { ids: targets });
  },
  /**
   * 回收站：被删好友的本地存档。
   *
   * 完全来自本地库，所以**客户端没开也能看**——这正是它作为「后悔药」的意义。
   */
  async deletedFriends(): Promise<DeletedFriendsSnapshot> {
    if (!isTauri()) return browserBackend.deletedFriends();
    return command("get_deleted_friends");
  },
  /**
   * 回收站里的动作。
   *
   * `addBack = false` 只划掉存档；`addBack = true` 会**向对方发一条好友申请**
   * （客户端只有这一个入口，加回来需要对方同意），成功后才划掉存档。
   */
  async restoreFriend(id: string, addBack = false): Promise<RestoreFriendResult> {
    const target = id?.trim() ?? "";
    if (!target) throw new Error("缺少好友 id");
    if (usesFixtureData()) return browserBackend.restoreFriend(target, addBack);
    return command("restore_friend", { id: target, add_back: addBack });
  },
  /**
   * 观战（按 puuid）。
   *
   * 后端会先试**好友路线**（用客户端下发的 `spectatorKey`）；拿不到密钥
   * （非好友、或对方不在局内）就自动落到**观察者模式**——那条路不带密钥，
   * 所以不要求对方是好友。失败时返回 `ok: false` 与一句能直接展示的原因，
   * 调用方**不要**把它当成异常来处理。
   */
  async spectate(puuid: string): Promise<SpectateResult> {
    const target = puuid?.trim() ?? "";
    if (!target) throw new Error("缺少玩家标识，无法观战");
    if (usesFixtureData()) return browserBackend.spectate(target);
    return command("spectate", { puuid: target, query: "" });
  },
  /**
   * 观战（按「名字#标签」）。
   *
   * 后端先在**当前大区**把 Riot ID 解析成 puuid，再走上面同一条观战链路。
   * 本地没有跨区索引，所以只解析得到当前大区的玩家。
   */
  async spectateById(query: string): Promise<SpectateResult> {
    const target = query?.trim() ?? "";
    if (!target) throw new Error("缺少玩家标识，无法观战");
    if (usesFixtureData()) return browserBackend.spectateById(target);
    return command("spectate", { puuid: "", query: target });
  },
  /**
   * 本机能一键启动的客户端入口。
   *
   * 探测完全在原生侧做（读 Riot 安装清单 + 扫盘），前端只拿结果。返回空数组表示
   * 这台机器上没找到任何入口。
   */
  async clientInstallations(): Promise<ClientInstallations> {
    if (usesFixtureData()) return browserBackend.clientInstallations();
    return command("get_client_installations");
  },
  /**
   * 启动客户端。
   *
   * `id` 为空表示「按探测顺序挑第一个」。**路径一律由后端现场重新探测**，前端不传
   * 路径——否则这个命令就成了拉任意 exe 的口子。
   */
  async launchClient(id = ""): Promise<ClientLaunchResult> {
    if (usesFixtureData()) return browserBackend.launchClient(id);
    return command("launch_client", { id: id.trim() });
  },
  /** 当前能领的东西（只读）。`total === 0` 表示没有可领的。 */
  async claims(): Promise<ClaimSnapshot> {
    if (usesFixtureData()) return browserBackend.claims();
    return command("get_claims");
  },
  /**
   * 领取。
   *
   * `source` 传 `"all"` 表示三个来源全领；`keys` 为空表示该来源下所有可领的都领，
   * 也可以只传想领的那几个 `ClaimItem.key`。逐项提交，成功失败混在
   * `claimed` 里（有 `reason` 就是没领成）。
   */
  async claim(source: ClaimSource | "all", keys: string[] = []): Promise<ClaimOutcome> {
    if (usesFixtureData()) return browserBackend.claim(source, keys);
    return command("claim", { source, keys });
  },
  /** 客户端急救动作。永远返回结构化结果，失败时 `reason` 是给人看的一句话。 */
  async gameflowAction(action: GameflowActionKey): Promise<GameflowActionResult> {
    if (usesFixtureData()) return browserBackend.gameflowAction(action);
    return command("gameflow_action", { action });
  },
  async bpHistory(): Promise<FinalBpRecord[]> {
    if (usesFixtureData()) return browserBackend.bpHistory();
    return command("get_bp_history");
  },
  async saveMatchExport(gameId: number, format: "csv" | "json", content: string): Promise<string> {
    if (!isTauri()) return "";
    return command("save_match_export", { gameId, format, content });
  },
  async sendShortcut(shortcutId: string): Promise<string[]> {
    if (usesFixtureData()) return browserBackend.sendShortcut(shortcutId);
    return command("send_shortcut", { shortcutId });
  },
  async sendPremadeSide(side: "ally" | "enemy"): Promise<string[]> {
    if (usesFixtureData()) return browserBackend.premadeSide(side);
    return command("send_shortcut", { shortcutId: "premade", premadeSide: side });
  },
  async setShortcutCapture(active: boolean): Promise<void> {
    if (!isTauri()) return;
    return command("set_shortcut_capture", { active });
  },
  async sendAssessments(kind: "ally" | "enemy" | "premade"): Promise<string[]> {
    const shortcut = browserState.config.automation.shortcuts.find((item) => item.target === kind);
    const lines = await this.sendShortcut(shortcut?.id ?? kind);
    if (kind === "ally") {
      let phase = "";
      try { phase = (await this.lobbyRoster()).phase; } catch { /* the ally message was already sent */ }
      if (phase === "ChampSelect" || phase === "ReadyCheck") lines.push(...await this.sendPremadeSide("ally"));
    }
    return lines;
  },
  async previewShortcut(shortcutId: string): Promise<string[]> {
    if (usesFixtureData()) return browserBackend.previewShortcut(shortcutId);
    return command("preview_shortcut", { shortcutId });
  },
  async previewAssessments(kind: "ally" | "enemy" | "premade" = "ally"): Promise<string[]> {
    const shortcut = browserState.config.automation.shortcuts.find((item) => item.target === kind);
    return this.previewShortcut(shortcut?.id ?? kind);
  },
  async runAutomation(): Promise<{ actionType: string; actionId: number; championId: number; executed: boolean; reason: string }[]> {
    if (usesFixtureData()) return [];
    return command("run_automation");
  },
  async validateShortcutTemplate(template: string): Promise<ShortcutValidation> {
    if (usesFixtureData()) return browserBackend.validateShortcutTemplate(template);
    return command("validate_shortcut_template", { template });
  },
  async checkUpdate(): Promise<string> {
    if (!isTauri()) return "浏览器预览不检查更新";
    try {
      const result = await command<{ version?: string } | null>("check_update");
      return result?.version ? `发现新版本 ${result.version}` : "当前已是最新版本";
    } catch {
      return "更新服务暂不可用";
    }
  },
};
