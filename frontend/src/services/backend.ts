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
  DataMode,
  EncounterRecord,
  FinalBpRecord,
  FriendToolsSnapshot,
  LiveLobby,
  MatchSummary,
  ShortcutValidation,
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
    if (usesFixtureData()) return { query: trimmed, hasTag, requiresTag: !hasTag, candidates: [] };
    return command("search_summoner", { query: trimmed });
  },
  async champions(): Promise<ChampionOverview[]> {
    if (usesFixtureData()) return browserBackend.champions();
    return command("get_champions");
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
  async asset(kind: "champion" | "item" | "spell" | "perk" | "profile", id: number): Promise<AssetPayload> {
    if (usesFixtureData()) throw new Error("Fixture 使用静态资源");
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
    if (usesFixtureData()) return this.sendShortcut(shortcutId);
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
