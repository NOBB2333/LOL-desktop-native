/**
 * 浏览器预览（没有原生后端）下的「后端模拟实现」。
 *
 * 为什么要单独成模块：`services/backend.ts` 是对外门面，只负责回答「这一调用走原生
 * 还是走模拟」。模拟逻辑留在门面里，会让**传输层反向依赖领域规则**
 * （`tags/signals` 的标签文案、`shortcuts/template` 的占位符）——改一条标签文案
 * 要动传输层，且这条链路没法单独测。
 *
 * 本模块的职责**就是**复刻后端行为，所以它依赖领域规则是合理的：门面不再依赖，
 * 依赖收敛到这一个文件里。
 */
import { isNative } from "./native";
import {
  createFixtureLobby,
  fixtureBootstrap,
  fixtureBpHistory,
  fixtureChampions,
  fixtureConfig,
  fixtureEncounters,
  fixtureFriends,
  fixtureLobby,
  fixtureMatches,
} from "../fixtures/data";
import { visibleMatches } from "../matches/filters";
import { roleName } from "../utils/format";
import { shortcutPrimaryTag, shortcutRiskLabels, shortcutStreakLabel } from "../tags/signals";
import { shortcutTemplateKeys } from "../shortcuts/template";
import type {
  AppBootstrap,
  AppConfig,
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

/**
 * 浏览器预览的可变状态。
 *
 * `mode` 在原生路径下也会被写（`bootstrap` / `setMode` 拿到后端结果后同步），
 * 因为「要不要走模拟」是门面和模拟实现共同关心的唯一事实。
 */
export const browserState = {
  mode: "fixture" as DataMode,
  /** 配置缓存：两条路径共用；native 下每次读写后端后同步到这里。 */
  config: structuredClone(fixtureConfig),
  friends: structuredClone(fixtureFriends),
  /** 浏览器预览下的玩家标记，写在内存里方便演示。 */
  playerTags: {} as Record<string, string[]>,
};

const storedConfig = typeof localStorage === "undefined" ? null : localStorage.getItem("lol-desktop-config");
if (storedConfig) {
  try { browserState.config = JSON.parse(storedConfig) as AppConfig; } catch { localStorage.removeItem("lol-desktop-config"); }
}

/** 当前是否必须走模拟实现：没有原生桥，或数据模式不是 live。 */
export function usesFixtureData(): boolean {
  return !isNative() || browserState.mode !== "live";
}

function lobbyFixture(): LiveLobby {
  const lobby = createFixtureLobby(browserState.config.providers.rankedOnly);
  lobby.isFixture = true;
  return lobby;
}

/** 浏览器预览下的模板渲染：占位符 → 该玩家的实际值。 */
function renderBrowserTemplate(template: string, player: PlayerProfile, team: string): string {
  const completed = player.recentMatches.filter((match) => match.durationMinutes > 0).slice(0, 10);
  const wins = completed.filter((match) => match.win).length;
  const losses = completed.length - wins;
  const averageKda = completed.length ? completed.reduce((sum, match) => sum + (match.kills + match.assists) / Math.max(1, match.deaths), 0) / completed.length : 0;
  const currentChampion = player.championId > 0 && player.championName !== "等待选择" ? player.championName : "未选择";
  const recentGameCount = Math.min(10, Math.max(1, browserState.config.automation.shortcutRecentGameCount ?? 5));
  const recentGames = completed.slice(0, recentGameCount).map((match) => `${match.win ? "胜" : "负"} ${match.championName} ${match.kills}/${match.deaths}/${match.assists}`).join("；");
  const values: Record<string, string> = {
    name: player.gameName, tag: shortcutPrimaryTag(player), position: roleName(player.assignedPosition),
    rank: `${player.rankTier} ${player.rankDivision}`.trim(), lp: String(player.leaguePoints), score: player.score.total.toFixed(0),
    recent_wins: String(wins), recent_losses: String(losses), recent_win_rate: `${Math.round(wins / Math.max(1, wins + losses) * 100)}%`,
    recent_games: recentGames ? `近${recentGameCount}场：${recentGames}` : "暂无近期对局",
    streak: shortcutStreakLabel(player), kda: averageKda.toFixed(2),
    current_champion: currentChampion, champion_games: String(player.currentChampionGames), champion_win_rate: `${Math.round(player.currentChampionWinRate * 100)}%`,
    top_champions: player.topChampions.map((item) => `${item.championName} ${Math.round(item.winRate * 100)}%`).join("、"),
    premade: (player.premadePositions?.length ? player.premadePositions : player.premadeWith).join("、") || "无", risk: shortcutRiskLabels(player),
    jungle_preference: formatBrowserJunglePreference(player), team,
    horse: browserHorseLabel(player.score.total, completed.length, wins, averageKda),
    encounter: "暂无本地遇到记录",
  };
  return template.replace(/\{([^{}]+)\}/g, (_, key: string) => values[key] ?? `{${key}}`);
}

function validateBrowserTemplate(template: string): ShortcutValidation {
  const errors: string[] = [];
  if (!template.trim()) errors.push("模板不能为空");
  const opened = (template.match(/\{/g) ?? []).length;
  const closed = (template.match(/\}/g) ?? []).length;
  if (opened !== closed) errors.push("占位符括号没有闭合");
  for (const field of template.matchAll(/\{([^{}]+)\}/g)) {
    // key 表来自 `shortcuts/template.ts`，与设置页的占位符面板同一份。
    if (!shortcutTemplateKeys.has(field[1])) errors.push(`未知占位符：{${field[1]}}`);
  }
  return { valid: errors.length === 0, errors, preview: errors.length ? "" : renderBrowserTemplate(template, fixtureLobby.ally[0], "我方") };
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

/**
 * 与原生实现同一套方法签名的模拟实现。
 *
 * 参数都是门面已经做过清洗/边界处理的值（如 `targets` 已去重、`boundedLimit` 已 clamp），
 * 本模块只负责「造出后端会返回的数据」。
 */
export const browserBackend = {
  bootstrap(): AppBootstrap {
    return { ...structuredClone(fixtureBootstrap), dataMode: browserState.mode };
  },
  /** 原生后端已应答但数据模式不是 live：保留会话信息，仪表盘换成 fixture。 */
  withFixtureDashboard(value: AppBootstrap): AppBootstrap {
    return { ...value, dashboard: structuredClone(fixtureBootstrap.dashboard) };
  },
  config(): AppConfig {
    return structuredClone(browserState.config);
  },
  saveConfig(value: AppConfig): AppConfig {
    browserState.config = structuredClone(value);
    localStorage.setItem("lol-desktop-config", JSON.stringify(browserState.config));
    return structuredClone(value);
  },
  connection() {
    return structuredClone(fixtureBootstrap.dashboard.connection);
  },
  lobby: lobbyFixture,
  matches(page: number, pageSize: number): MatchSummary[] {
    const source = visibleMatches(fixtureMatches, browserState.config.providers.hideUnfinishedMatches, browserState.config.providers.rankedOnly);
    const start = page * pageSize;
    return structuredClone(source.slice(start, start + pageSize));
  },
  champions(): ChampionOverview[] {
    return structuredClone(fixtureChampions);
  },
  matchDetail(gameId: number): MatchSummary {
    const match = fixtureMatches.find((item) => item.gameId === gameId);
    if (!match) throw new Error("该对局的完整详情不可用");
    return structuredClone(match);
  },
  encounters(target: string, boundedLimit: number, excludeGameId: number): EncounterRecord[] {
    const targetGames = [...new Map(
      fixtureEncounters
        .filter((record) => record.gameId !== excludeGameId && (!target || record.puuid === target))
        .sort((left, right) => right.encounteredAt.localeCompare(left.encounteredAt))
        .map((record) => [record.gameId, record.encounteredAt] as const),
    ).keys()].slice(0, boundedLimit);
    const selected = new Set(targetGames);
    return structuredClone(fixtureEncounters.filter((record) => selected.has(record.gameId)));
  },
  playerTags(targets: string[]): Record<string, string[]> {
    const result: Record<string, string[]> = {};
    for (const puuid of targets) result[puuid] = [...(browserState.playerTags[puuid] ?? [])];
    return result;
  },
  updatePlayerTag(target: string, cleaned: string[]): { puuid: string; notes: string[]; updatedAt: number } {
    if (cleaned.length) browserState.playerTags[target] = cleaned;
    else delete browserState.playerTags[target];
    return { puuid: target, notes: [...cleaned], updatedAt: Date.now() };
  },
  friends(): FriendToolsSnapshot {
    return structuredClone(browserState.friends);
  },
  friendLastGame(puuid: string): { puuid: string; lastGameAt: string | null } {
    const friend = browserState.friends.friends.find((item) => item.puuid === puuid);
    return { puuid, lastGameAt: friend?.lastGameAt ?? null };
  },
  deleteFriend(id: string): void {
    browserState.friends.friends = browserState.friends.friends.filter((friend) => friend.id !== id);
  },
  bpHistory(): FinalBpRecord[] {
    return structuredClone(fixtureBpHistory);
  },
  validateShortcutTemplate(template: string): ShortcutValidation {
    return validateBrowserTemplate(template);
  },
  sendShortcut(shortcutId: string): string[] {
    const lobby = lobbyFixture();
    const shortcut = browserState.config.automation.shortcuts.find((item) => item.id === shortcutId);
    if (!shortcut) throw new Error("快捷消息不存在");
    const allPlayers = [...lobby.ally, ...lobby.enemy];
    if (shortcut.target === "premade") {
      return [
        `敌方开黑：${browserPremadeGroups(lobby.enemy)}`,
        `我方开黑：${browserPremadeGroups(lobby.ally)}`,
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
    const players = shortcut.target === "ally" ? lobby.ally : shortcut.target === "enemy" ? lobby.enemy : jungleShortcut ? allPlayers.filter((player) => player.assignedPosition.toUpperCase() === "JUNGLE" || player.summonerSpells?.some((spell) => spell.id === 11)) : shortcut.target === "lobby" ? allPlayers : [lobby.ally[0]];
    return players.map((player) => renderBrowserTemplate(shortcut.template, player, lobby.ally.some((item) => item.puuid === player.puuid) ? "我方" : "敌方"));
  },
  premadeSide(side: "ally" | "enemy"): string[] {
    const group = side === "ally" ? fixtureLobby.ally : fixtureLobby.enemy;
    return [`${side === "ally" ? "我方" : "敌方"}开黑：${browserPremadeGroups(group)}`];
  },
};
