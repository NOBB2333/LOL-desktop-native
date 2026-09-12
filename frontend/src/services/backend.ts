import { invokeNative, isNative } from "./native";
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
  PlayerProfile,
  ShortcutValidation,
} from "../types/domain";
import {
  fixtureBootstrap,
  fixtureBpHistory,
  fixtureChampions,
  fixtureConfig,
  fixtureEncounters,
  fixtureFriends,
  fixtureLobby,
  createFixtureLobby,
  fixtureMatches,
} from "../fixtures/data";
import { visibleMatches } from "../utils/matchFilters";
import { roleName } from "../utils/format";
import { createShortcutSendQueue } from "../utils/shortcutSendQueue";

let browserMode: DataMode = "fixture";
let browserConfig = structuredClone(fixtureConfig);
let browserFriends = structuredClone(fixtureFriends);
const assetRequests = new Map<string, Promise<AssetPayload>>();
const storedBrowserConfig = typeof localStorage === "undefined" ? null : localStorage.getItem("lol-desktop-config");
if (storedBrowserConfig) {
  try { browserConfig = JSON.parse(storedBrowserConfig) as AppConfig; } catch { localStorage.removeItem("lol-desktop-config"); }
}

/** 兼容原有调用点，底层已经使用原生桥接。 */
export const isTauri = isNative;
const queueShortcutSend = createShortcutSendQueue();
let sendConnection = "";
let sendLobby = "";

function sendContext() {
  return JSON.stringify([browserMode, sendConnection, sendLobby]);
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

function usesFixtureData() {
  return !isTauri() || browserMode !== "live";
}

function lobbyFixture(): LiveLobby {
  const lobby = createFixtureLobby(browserConfig.providers.rankedOnly);
  lobby.isFixture = true;
  return lobby;
}

export const backend = {
  async bootstrap(): Promise<AppBootstrap> {
    if (!isTauri()) return { ...structuredClone(fixtureBootstrap), dataMode: browserMode };
    const value = await command<AppBootstrap>("get_bootstrap");
    browserMode = value.dataMode;
    if (browserMode === "live") return value;
    return { ...value, dashboard: structuredClone(fixtureBootstrap.dashboard) };
  },
  async config(): Promise<AppConfig> {
    if (!isTauri()) return structuredClone(browserConfig);
    browserConfig = await command<AppConfig>("get_config");
    return structuredClone(browserConfig);
  },
  async saveConfig(value: AppConfig): Promise<AppConfig> {
    browserConfig = structuredClone(value);
    if (!isTauri()) {
      localStorage.setItem("lol-desktop-config", JSON.stringify(browserConfig));
      return structuredClone(value);
    }
    browserConfig = await command<AppConfig>("save_config", { value });
    return structuredClone(browserConfig);
  },
  async setMode(mode: DataMode): Promise<DataMode> {
    if (mode === "replay") throw new Error("回看功能尚未开放");
    const selected = isTauri() ? await command<DataMode>("set_data_mode", { mode }) : mode;
    browserMode = selected;
    return selected;
  },
  async refreshConnection() {
    if (usesFixtureData()) return structuredClone(fixtureBootstrap.dashboard.connection);
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
    if (usesFixtureData()) return lobbyFixture();
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
    if (usesFixtureData()) return lobbyFixture();
    return rememberLobby(await command<LiveLobby>("get_live_roster"));
  },
  async matches(summonerName?: string, page = 0, pageSize = 10): Promise<MatchSummary[]> {
    if (usesFixtureData()) {
      const source = visibleMatches(fixtureMatches, browserConfig.providers.hideUnfinishedMatches, browserConfig.providers.rankedOnly);
      const start = page * pageSize;
      return structuredClone(source.slice(start, start + pageSize));
    }
    return command("get_match_history", { summonerName: summonerName?.trim() || null, page, pageSize });
  },
  async champions(): Promise<ChampionOverview[]> {
    if (usesFixtureData()) return structuredClone(fixtureChampions);
    return command("get_champions");
  },
  async matchDetail(gameId: number, platformId: string, selfPuuid: string, targetPuuid: string): Promise<MatchSummary> {
    if (usesFixtureData()) {
      const match = fixtureMatches.find((item) => item.gameId === gameId);
      if (!match) throw new Error("该对局的完整详情不可用");
      return structuredClone(match);
    }
    return command("get_match_detail", { gameId, platformId, selfPuuid, targetPuuid });
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
    if (usesFixtureData()) {
      const targetGames = [...new Map(
        fixtureEncounters
          .filter((record) => record.gameId !== excludeGameId && (!target || record.puuid === target))
          .sort((left, right) => right.encounteredAt.localeCompare(left.encounteredAt))
          .map((record) => [record.gameId, record.encounteredAt] as const),
      ).keys()].slice(0, boundedLimit);
      const selected = new Set(targetGames);
      return structuredClone(fixtureEncounters.filter((record) => selected.has(record.gameId)));
    }
    return command("get_encounters", { puuid: target || null, limitGames: boundedLimit, excludeGameId });
  },
  async friends(): Promise<FriendToolsSnapshot> {
    if (usesFixtureData()) return structuredClone(browserFriends);
    return command("get_friends");
  },
  async friendLastGame(puuid: string, force = false): Promise<{ puuid: string; lastGameAt: string | null }> {
    if (usesFixtureData()) {
      const friend = browserFriends.friends.find((item) => item.puuid === puuid);
      return { puuid, lastGameAt: friend?.lastGameAt ?? null };
    }
    return command("get_friend_last_game", { puuid, force });
  },
  async deleteFriend(id: string): Promise<void> {
    if (usesFixtureData()) {
      browserFriends.friends = browserFriends.friends.filter((friend) => friend.id !== id);
      return;
    }
    await command("delete_friend", { id });
  },
  async bpHistory(): Promise<FinalBpRecord[]> {
    if (usesFixtureData()) return structuredClone(fixtureBpHistory);
    return command("get_bp_history");
  },
  async saveMatchExport(gameId: number, format: "csv" | "json", content: string): Promise<string> {
    if (!isTauri()) return "";
    return command("save_match_export", { gameId, format, content });
  },
  async sendShortcut(shortcutId: string): Promise<string[]> {
    if (usesFixtureData()) {
      const fixtureLobby = lobbyFixture();
      const shortcut = browserConfig.automation.shortcuts.find((item) => item.id === shortcutId);
      if (!shortcut) throw new Error("快捷消息不存在");
      const allPlayers = [...fixtureLobby.ally, ...fixtureLobby.enemy];
      if (shortcut.target === "premade") {
        return [
          `敌方开黑：${browserPremadeGroups(fixtureLobby.enemy)}`,
          `我方开黑：${browserPremadeGroups(fixtureLobby.ally)}`,
        ];
      }
      if (shortcut.target === "encounter") {
        const records = fixtureEncounters.slice(0, 3);
        return records.map((record) => {
          const date = new Date(record.encounteredAt);
          const stamp = `${String(date.getMonth() + 1).padStart(2, "0")}月${String(date.getDate()).padStart(2, "0")}日 ${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
          const selfId = `${record.selfGameName || "未知玩家"}${record.selfTagLine ? `#${record.selfTagLine}` : ""}`;
          const targetId = `${record.gameName || "未知玩家"}${record.tagLine ? `#${record.tagLine}` : ""}`;
          const selfKda = record.selfKills === undefined ? "战绩待结算" : `${record.selfKills}/${record.selfDeaths ?? 0}/${record.selfAssists ?? 0}${record.selfWin === undefined ? "" : record.selfWin ? " 胜" : " 负"}`;
          const targetKda = record.kills === undefined ? "战绩待结算" : `${record.kills}/${record.deaths ?? 0}/${record.assists ?? 0}${record.win === undefined ? "" : record.win ? " 胜" : " 负"}`;
          return `遇到过：${stamp}，我（${selfId}）使用 ${record.selfChampionName || "未知英雄"} ${selfKda}；${record.side === "ally" ? "队友" : "对方"}（${targetId}）使用 ${record.championName || "未知英雄"} ${targetKda}`;
        });
      }
      const jungleShortcut = shortcut.target === "jungle" || (shortcut.target === "custom" && shortcut.template.includes("{jungle_preference}"));
      const players = shortcut.target === "ally" ? fixtureLobby.ally : shortcut.target === "enemy" ? fixtureLobby.enemy : jungleShortcut ? allPlayers.filter((player) => player.assignedPosition.toUpperCase() === "JUNGLE" || player.summonerSpells?.some((spell) => spell.id === 11)) : shortcut.target === "lobby" ? allPlayers : [fixtureLobby.ally[0]];
      return players.map((player) => renderBrowserTemplate(shortcut.template, player, fixtureLobby.ally.some((item) => item.puuid === player.puuid) ? "我方" : "敌方"));
    }
    return command("send_shortcut", { shortcutId });
  },
  async sendPremadeSide(side: "ally" | "enemy"): Promise<string[]> {
    if (usesFixtureData()) {
      const group = side === "ally" ? fixtureLobby.ally : fixtureLobby.enemy;
      return [`${side === "ally" ? "我方" : "敌方"}开黑：${browserPremadeGroups(group)}`];
    }
    return command("send_shortcut", { shortcutId: "premade", premadeSide: side });
  },
  async setShortcutCapture(active: boolean): Promise<void> {
    if (!isTauri()) return;
    return command("set_shortcut_capture", { active });
  },
  async sendAssessments(kind: "ally" | "enemy" | "premade"): Promise<string[]> {
    const shortcut = browserConfig.automation.shortcuts.find((item) => item.target === kind);
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
    const shortcut = browserConfig.automation.shortcuts.find((item) => item.target === kind);
    return this.previewShortcut(shortcut?.id ?? kind);
  },
  async runAutomation(): Promise<{ actionType: string; actionId: number; championId: number; executed: boolean; reason: string }[]> {
    if (usesFixtureData()) return [];
    return command("run_automation");
  },
  async validateShortcutTemplate(template: string): Promise<ShortcutValidation> {
    if (usesFixtureData()) return validateBrowserTemplate(template);
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

const templateFields = ["name", "tag", "position", "rank", "lp", "score", "recent_wins", "recent_losses", "recent_win_rate", "recent_games", "streak", "kda", "current_champion", "champion_games", "champion_win_rate", "top_champions", "premade", "risk", "jungle_preference", "team", "horse", "encounter"] as const;

function validateBrowserTemplate(template: string): ShortcutValidation {
  const errors: string[] = [];
  if (!template.trim()) errors.push("模板不能为空");
  const opened = (template.match(/\{/g) ?? []).length;
  const closed = (template.match(/\}/g) ?? []).length;
  if (opened !== closed) errors.push("占位符括号没有闭合");
  for (const field of template.matchAll(/\{([^{}]+)\}/g)) {
    if (!templateFields.includes(field[1] as typeof templateFields[number])) errors.push(`未知占位符：{${field[1]}}`);
  }
  return { valid: errors.length === 0, errors, preview: errors.length ? "" : renderBrowserTemplate(template, fixtureLobby.ally[0], "我方") };
}

function renderBrowserTemplate(template: string, player: typeof fixtureLobby.ally[number], team: string): string {
  const completed = player.recentMatches.filter((match) => match.durationMinutes > 0).slice(0, 10);
  const wins = completed.filter((match) => match.win).length;
  const losses = completed.length - wins;
  const averageKda = completed.length ? completed.reduce((sum, match) => sum + (match.kills + match.assists) / Math.max(1, match.deaths), 0) / completed.length : 0;
  const currentChampion = player.championId > 0 && player.championName !== "等待选择" ? player.championName : "未选择";
  const recentGameCount = Math.min(10, Math.max(1, browserConfig.automation.shortcutRecentGameCount ?? 5));
  const recentGames = completed.slice(0, recentGameCount).map((match) => `${match.win ? "胜" : "负"} ${match.championName} ${match.kills}/${match.deaths}/${match.assists}`).join("；");
  const values: Record<string, string> = {
    name: player.gameName, tag: player.tagLine, position: roleName(player.assignedPosition),
    rank: `${player.rankTier} ${player.rankDivision}`.trim(), lp: String(player.leaguePoints), score: player.score.total.toFixed(0),
    recent_wins: String(wins), recent_losses: String(losses), recent_win_rate: `${Math.round(wins / Math.max(1, wins + losses) * 100)}%`,
    recent_games: recentGames ? `近${recentGameCount}场：${recentGames}` : "暂无近期对局",
    streak: player.tags.find((item) => item.key === "hot" || item.key === "slump")?.label ?? "状态稳定", kda: averageKda.toFixed(2),
    current_champion: currentChampion, champion_games: String(player.currentChampionGames), champion_win_rate: `${Math.round(player.currentChampionWinRate * 100)}%`,
    top_champions: player.topChampions.map((item) => `${item.championName} ${Math.round(item.winRate * 100)}%`).join("、"),
    premade: (player.premadePositions?.length ? player.premadePositions : player.premadeWith).join("、") || "无", risk: player.tags.map((item) => item.label).join("、"),
    jungle_preference: formatBrowserJunglePreference(player), team,
    horse: browserHorseLabel(player.score.total, completed.length, wins, averageKda),
    encounter: "暂无本地遇到记录",
  };
  return template.replace(/\{([^{}]+)\}/g, (_, key: string) => values[key] ?? `{${key}}`);
}

function browserHorseLabel(score: number, games: number, wins: number, averageKda: number) {
  if (games < 3) return "中等马";
  const winRate = wins / games;
  if (score >= 75 || (winRate >= 0.65 && averageKda >= 3)) return "上等马";
  if ((score > 0 && score < 55) || (winRate <= 0.35 && averageKda < 2)) return "下等马";
  return "中等马";
}

function formatBrowserJunglePreference(player: PlayerProfile) {
  const preference = player.junglePreference;
  if (!preference) return player.championId > 0 ? "近期没有本英雄打野记录" : "尚未选择英雄";
  const parts = [
    `本英雄打野样本${preference.currentChampionGames || preference.sampleSize}场`,
    preference.evidence,
    `KDA ${preference.averageKda.toFixed(1)}`,
  ];
  if (preference.averageObjectiveTakedowns !== null) parts.push(`场均资源参与 ${preference.averageObjectiveTakedowns.toFixed(1)}`);
  if (preference.averageEnemyJungleMonsters !== null) parts.push(`场均反野 ${preference.averageEnemyJungleMonsters.toFixed(1)}`);
  return parts.join(" ");
}

function browserPremadeGroups(players: PlayerProfile[]): string {
  const groups = new Map<string, string[]>();
  for (const player of players.filter((item) => item.isPremade)) {
    const names = [...player.premadeWith, player.gameName].sort((left, right) => left.localeCompare(right, "zh-CN"));
    if (names.length > 1) groups.set(names.join("\u001f"), names);
  }
  return groups.size ? [...groups.values()].map((names) => `[${names.join("、")}]`).join("；") : "[]";
}
