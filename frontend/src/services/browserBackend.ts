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
  createFixtureGameRecording,
  createFixtureJunglePath,
  createFixtureLobby,
  createFixtureMatchDetail,
  createFixtureMatchTimeline,
  createFixturePlayerStats,
  createFixtureRoomLobby,
  fixtureBootstrap,
  fixtureBpHistory,
  fixtureChampions,
  fixtureClaims,
  fixtureClientInstallations,
  fixtureConfig,
  fixtureDeletedFriends,
  fixtureEncounters,
  fixtureFriends,
  fixtureLobby,
  fixtureMatches,
} from "../fixtures/data";
import { visibleMatches } from "../matches/filters";
import { TEAM_BLUE, TEAM_RED } from "../matches/lineup";
import { roleName } from "../utils/format";
import { shortcutPrimaryTag, shortcutRiskLabels, shortcutStreakLabel } from "../tags/signals";
import { shortcutTemplateKeys } from "../shortcuts/template";
import type {
  AppBootstrap,
  AppConfig,
  ChampionOverview,
  ClaimItem,
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
  FriendDeleteResultEntry,
  FriendToolsSnapshot,
  GameflowActionResult,
  GameRecording,
  JunglePathMap,
  LiveLobby,
  MatchSummary,
  MatchTimeline,
  PlayerProfile,
  PlayerStatSummary,
  ReleaseUpdate,
  RestoreFriendResult,
  ShortcutValidation,
  SpectateResult,
  SummonerSearchResult,
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
  /**
   * 浏览器预览下的好友回收站。
   *
   * 必须真的**可写**：预览里删一个好友，回收站里就要多一条，否则这块功能在预览下
   * 永远是空的，看不出它对不对（真机上是 SQLite，预览里就放内存）。
   */
  deletedFriends: structuredClone(fixtureDeletedFriends).friends,
  /** 浏览器预览下的可领清单，领取后就地从这里减掉，方便演示「领完变空」。 */
  claims: structuredClone(fixtureClaims),
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

/**
 * 预览开关：`?selfSide=red` 把主视角放到**红方**。
 *
 * fixture 默认把「我」放在蓝方，于是 `side`（我方 / 敌方）与 `team`（100 / 200）恰好
 * 同向，而真机上这是两套坐标——我打红方时自己那行的 `side` 仍是 `ally`、`team` 却是 200。
 * 曾经因此把「拿 side 去配时间线座位」写错而预览里完全看不出来，真机红方局却是
 * 「每个人 KDA 000、装备整片空白」。开了这个开关，那条路径在预览里就看得见了。
 */
function previewSelfTeam(): number {
  if (typeof location === "undefined") return TEAM_BLUE;
  return new URLSearchParams(location.search).get("selfSide") === "red" ? TEAM_RED : TEAM_BLUE;
}

/**
 * 把即将从预览里删掉的好友抄进回收站。
 *
 * 与后端 `friends_ipc.archiveDeletedFriend` 同一口径：**删之前**取记录，
 * 且只留身份 + 删除时间（`availability` 之类实时状态不留，过期就是错的）。
 * 原生侧只有删除成功才落档，这里没有失败路径，所以照着删。
 */
function archiveBrowserFriends(ids: string[]): void {
  const now = new Date().toISOString();
  for (const id of ids) {
    const friend = browserState.friends.friends.find((item) => item.id === id);
    if (!friend) continue;
    browserState.deletedFriends = [
      {
        id: friend.id,
        puuid: friend.puuid,
        summonerId: friend.summonerId,
        gameName: friend.gameName,
        gameTag: friend.gameTag,
        icon: friend.icon,
        groupId: friend.groupId,
        deletedAt: now,
      },
      ...browserState.deletedFriends.filter((item) => item.id !== id),
    ];
  }
}

function lobbyFixture(): LiveLobby {
  // 房间/匹配中的界面在预览里默认看不到（fixture 快照固定在选人阶段），
  // 加 `?phase=room` 就能把它调出来看。只影响 fixture 分支，真机走原生桥。
  const lobby = typeof location !== "undefined" && new URLSearchParams(location.search).get("phase") === "room"
    ? createFixtureRoomLobby(browserState.config.providers.rankedOnly)
    : createFixtureLobby(browserState.config.providers.rankedOnly);
  lobby.isFixture = true;
  return lobby;
}

/** 浏览器预览下的模板渲染：占位符 → 该玩家的实际值。 */
function renderBrowserTemplate(template: string, player: PlayerProfile, team: string, chatExpanded = false): string {
  const completed = player.recentMatches.filter((match) => match.durationMinutes > 0).slice(0, 10);
  const wins = completed.filter((match) => match.win).length;
  const losses = completed.length - wins;
  const averageKda = completed.length ? completed.reduce((sum, match) => sum + (match.kills + match.assists) / Math.max(1, match.deaths), 0) / completed.length : 0;
  const currentChampion = player.championId > 0 && player.championName !== "等待选择" ? player.championName : "未选择";
  const recentGameCount = Math.min(10, Math.max(1, browserState.config.automation.shortcutRecentGameCount ?? 5));
  const recentGames = completed.slice(0, recentGameCount).map((match) => `${match.win ? "胜" : "负"} ${match.championName} ${match.kills}/${match.deaths}/${match.assists}`).join(chatExpanded ? "\n" : "；");
  // 聊天版本里「近N场：」自己占一行，每场再各占一行；压缩版仍是「；」连成一行。
  const recentGamesBlock = recentGames ? (chatExpanded ? `近${recentGameCount}场：\n${recentGames}` : `近${recentGameCount}场：${recentGames}`) : "暂无近期对局";
  const values: Record<string, string> = {
    name: player.gameName, tag: shortcutPrimaryTag(player), position: roleName(player.assignedPosition),
    main_position: browserMainPosition(player),
    rank: `${player.rankTier} ${player.rankDivision}`.trim(), lp: String(player.leaguePoints), score: player.score.total.toFixed(0),
    recent_wins: String(wins), recent_losses: String(losses), recent_win_rate: `${Math.round(wins / Math.max(1, wins + losses) * 100)}%`,
    recent_games: recentGamesBlock,
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

/** 主玩位置：近期对局里出现最多的**两个**分路，与本局被分配到的分路无关。 */
function browserMainPosition(player: PlayerProfile) {
  // 顺序即 AK 的 POSITION_ORDER，同票时按它定序，保证结果稳定。
  const order = ["上路", "打野", "中路", "下路", "辅助"];
  const counts = new Map<string, number>();
  for (const match of player.recentMatches.slice(0, 20)) {
    const label = roleName(match.position);
    if (!label || label === "待定" || !order.includes(label)) continue;
    counts.set(label, (counts.get(label) ?? 0) + 1);
  }
  const picked = [...counts.entries()]
    .sort((a, b) => b[1] - a[1] || order.indexOf(a[0]) - order.indexOf(b[0]))
    .slice(0, 2)
    .map(([label]) => label);
  return picked.length ? picked.join("，") : "待定";
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
 * 预览里的观战结果。
 *
 * 真机上后端会**先试好友路线、拿不到密钥再落到观察者模式**，而观察者模式是否
 * 生效只有客户端才知道。预览里没有真实观战服务，所以只按「这位好友现在有没有
 * 密钥」给出可读的成败与路线，让界面两条分支都能看到。
 */
function spectateFixture(puuid: string): SpectateResult {
  const friend = browserState.friends.friends.find((item) => item.puuid === puuid);
  if (!friend) {
    return { ok: false, reason: "观察者模式未生效：对方可能不在对局中，或未允许被观战", route: "observe" };
  }
  if (!friend.canSpectate) {
    return { ok: false, reason: "观察者模式未生效：这位好友现在不在对局中", route: "observe" };
  }
  return { ok: true, reason: "", route: "buddy" };
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
  junglePath(puuid: string, gameIds: number[]): JunglePathMap {
    // 参数已由门面清洗（去重、截断到 10 场），这里只负责造数据。
    return createFixtureJunglePath(puuid, gameIds);
  },
  /**
   * 预览用的逐帧明细。
   *
   * `?frameDamage=0` 走**真机形状**：客户端（TENCENT 实机实测）的分钟帧里没有伤害字段，
   * 「本波输出 / 本波承伤 / 十人第二行的输出两项」在真机上就是算不出来、要降级成全场总账。
   * 不开这个开关就看不到那条降级路径，很容易把「预览里好好的」当成「真机也没问题」。
   */
  matchTimeline(gameId: number): MatchTimeline {
    const noDamage = typeof location !== "undefined" && new URLSearchParams(location.search).get("frameDamage") === "0";
    return createFixtureMatchTimeline(gameId, { frameDamage: !noDamage, selfTeam: previewSelfTeam() });
  },
  /**
   * 预览用的本地录制。
   *
   * **默认回空帧**——真机上没开开关、不是本机在打、或者这一局已经超出保留局数被回收，
   * 拿到的都是这份空结果，界面据此隐藏时间轴。要看到有数据的样子，得显式带
   * `?recording=1`；不这么做的话预览里每局都凭空冒出一条录制，真机的空路径就没地方验了。
   */
  gameRecording(gameId: number): GameRecording {
    const wanted = typeof location !== "undefined" && new URLSearchParams(location.search).get("recording") === "1";
    if (!wanted) return { gameId, intervalSeconds: 15, frames: [] };
    return createFixtureGameRecording(gameId, { selfTeam: previewSelfTeam() });
  },
  matches(page: number, pageSize: number): MatchSummary[] {
    const source = visibleMatches(fixtureMatches, browserState.config.providers.hideUnfinishedMatches, browserState.config.providers.rankedOnly);
    const start = page * pageSize;
    return structuredClone(source.slice(start, start + pageSize));
  },
  /**
   * 预览模式下的玩家解析。
   *
   * 真机上这步是「Riot Client 精确解析 → 本地 LCU 补等级与段位」。预览里没有客户端，
   * 所以改成在 fixture 的十人名单里找同名的人：命中就带着等级、单双与灵活段位回来，
   * 让战绩页顶部的账号信息条在预览里也能看到真实排版（否则那一块永远是「—」）。
   */
  searchSummoner(query: string): SummonerSearchResult {
    const trimmed = query.trim();
    const hasTag = trimmed.includes("#");
    if (!trimmed) return { query: "", hasTag, requiresTag: false, candidates: [] };
    const [rawName, rawTag = ""] = trimmed.split("#");
    const gameName = rawName.trim();
    const tagLine = rawTag.trim();
    const hit = [...fixtureLobby.ally, ...fixtureLobby.enemy].find((player) => player.gameName === gameName && (!tagLine || player.tagLine === tagLine));
    if (!hit) return { query: trimmed, hasTag, requiresTag: !hasTag, candidates: [] };
    return {
      query: trimmed,
      hasTag,
      requiresTag: false,
      candidates: [{
        gameName: hit.gameName,
        tagLine: hit.tagLine,
        puuid: hit.puuid,
        summonerLevel: hit.summonerLevel ?? null,
        soloRank: hit.soloRank ?? null,
        flexRank: hit.flexRank ?? null,
      }],
    };
  },
  champions(): ChampionOverview[] {
    return structuredClone(fixtureChampions);
  },
  playerStats(puuids: string[]): PlayerStatSummary[] {
    return createFixturePlayerStats(puuids);
  },
  matchDetail(gameId: number): MatchSummary {
    const match = createFixtureMatchDetail(gameId, { selfTeam: previewSelfTeam() });
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
    archiveBrowserFriends([id]);
    browserState.friends.friends = browserState.friends.friends.filter((friend) => friend.id !== id);
  },
  /**
   * 批量删除。原生侧逐条回报，这里也保持同一形状（含失败原因字段），
   * 免得界面在预览和真机下走两条分支。
   */
  deleteFriends(ids: string[]): FriendDeleteOutcome {
    const removing = new Set(ids);
    const results: FriendDeleteResultEntry[] = ids.map((id) => ({ id, ok: true, reason: "" }));
    archiveBrowserFriends(ids);
    browserState.friends.friends = browserState.friends.friends.filter((friend) => !removing.has(friend.id));
    return { results, deleted: results.length, failed: 0 };
  },
  deletedFriends(): DeletedFriendsSnapshot {
    return { friends: structuredClone(browserState.deletedFriends) };
  },
  /**
   * 预览里的「撤销」。原生侧 `addBack` 会真的向对方发一条好友申请，
   * 这里没有客户端可发，只能把记录划掉——**不能**假装加回了好友列表，
   * 那会让人以为这个按钮能把人变回来。
   */
  restoreFriend(id: string, addBack: boolean): RestoreFriendResult {
    const record = browserState.deletedFriends.find((friend) => friend.id === id);
    if (!record) return { ok: false, reason: "回收站里没有这条记录", added: false, gameName: "", gameTag: "" };
    browserState.deletedFriends = browserState.deletedFriends.filter((friend) => friend.id !== id);
    return {
      ok: true,
      reason: addBack ? "浏览器预览不发送好友申请，只清掉了本地记录" : "",
      added: false,
      gameName: record.gameName,
      gameTag: record.gameTag,
    };
  },
  claims(): ClaimSnapshot {
    return structuredClone(browserState.claims);
  },
  clientInstallations(): ClientInstallations {
    return structuredClone(fixtureClientInstallations);
  },
  /**
   * 预览里的「发现新版本」：fixture 版本永远比 appVersion 新一档，这样浏览器预览
   * 就能稳定看到「有更新」的完整 UI；「已是最新」与「检查失败」的状态由测试覆盖。
   */
  checkUpdate(): ReleaseUpdate | null {
    return {
      version: "2.7.0",
      title: "桌上英雄联盟 Native v2.7.0",
      publishedAt: "2026-09-20T12:00:00Z",
      url: "https://github.com/NOBB2333/LOL-desktop-native/releases",
      notes: "预览数据：这里显示的是 Release 说明的前一段内容。\n支持多行。",
    };
  },
  /**
   * 预览里不真的拉进程，只回报「会启动哪一个」。
   *
   * 与原生一致：`id` 为空就按探测顺序取第一个（后端也这么做），所以预览里点一下
   * 主按钮看到的提示，和真机是一样的。
   */
  launchClient(id: string): ClientLaunchResult {
    const entry = fixtureClientInstallations.entries.find((item) => item.id === id) ?? fixtureClientInstallations.entries[0];
    if (!entry) return { ok: false, reason: "没找到已安装的英雄联盟 / WeGame / Riot 客户端", id: "", label: "" };
    return { ok: true, reason: "", id: entry.id, label: entry.label };
  },
  claim(source: ClaimSource | "all", keys: string[]): ClaimOutcome {
    const matches = (item: ClaimItem) =>
      (source === "all" || item.source === source) && (!keys.length || keys.includes(item.key));
    const claimed = browserState.claims.items.filter(matches);
    // 与原生一致：领过的条目就不该再出现在「可领」清单里。
    browserState.claims.items = browserState.claims.items.filter((item) => !matches(item));
    for (const summary of browserState.claims.sources) summary.count = browserState.claims.items.filter((item) => item.source === summary.source).length;
    browserState.claims.total = browserState.claims.items.length;
    return {
      claimed: claimed.map((item) => ({ source: item.source, id: item.id, title: item.title, detail: item.detail })),
      claimedCount: claimed.length,
      failedCount: 0,
    };
  },
  /**
   * 浏览器预览里没有 LCU，急救动作没有对象可施。
   *
   * 这里**不抛错**而是回报 `ok: false`：页面本来就是靠 `reason` 这一行告诉用户
   * 「为什么没生效」，预览下正好把这套展示跑通。
   */
  gameflowAction(action: string): GameflowActionResult {
    return { action, ok: false, phase: "", reason: "浏览器预览不支持客户端操作" };
  },
  spectate(puuid: string): SpectateResult {
    return spectateFixture(puuid);
  },
  /**
   * 按「名字#标签」观战。
   *
   * 预览里没有 summoner 解析服务，只能在 fixture 好友名单里按 Riot ID 找同名的人，
   * 找得到就复用好友那条判断；找不到就回报「没找到」——真机上这一步由后端
   * 走 LCU 的 `summoners?name=` 完成。
   */
  spectateById(query: string): SpectateResult {
    const [rawName, rawTag] = query.split("#");
    const name = (rawName ?? "").trim().toLowerCase();
    const tag = (rawTag ?? "").trim().toLowerCase();
    const friend = browserState.friends.friends.find(
      (item) => item.gameName.trim().toLowerCase() === name && (!tag || item.gameTag.trim().toLowerCase() === tag),
    );
    if (!friend) return { ok: false, reason: "没找到这位召唤师：需要完整的「名字#标签」，且只能解析当前大区的玩家", route: "" };
    return spectateFixture(friend.puuid);
  },
  bpHistory(): FinalBpRecord[] {
    return structuredClone(fixtureBpHistory);
  },
  validateShortcutTemplate(template: string): ShortcutValidation {
    return validateBrowserTemplate(template);
  },
  sendShortcut(shortcutId: string): string[] {
    // 真正发进聊天框的是展开版（每场一行、玩家之间一个空格行），但命令回传给
    // 页面「最近发送」面板的是压缩版（每人一行）——与 Zig 侧 `send_shortcut`
    // 的返回口径一致，否则展开版会把页面面板撑成几十行。展开版见 browserChatText。
    return renderShortcutLines(shortcutId, false);
  },
  previewShortcut(shortcutId: string): string[] {
    // 页面上的「最终发送内容」预览：保持每人一行，省画幅。
    return renderShortcutLines(shortcutId, false);
  },
  premadeSide(side: "ally" | "enemy"): string[] {
    const group = side === "ally" ? fixtureLobby.ally : fixtureLobby.enemy;
    return [`${side === "ally" ? "我方" : "敌方"}开黑：${browserPremadeGroups(group)}`];
  },
};

/** 与 Zig 侧 `chat_player_divider` 保持一致；改一处必须改另一处。 */
const CHAT_PLAYER_DIVIDER = "----------";

/**
 * 浏览器预览下的快捷消息渲染。`chatExpanded` 对应 Zig 侧的 `chat_expanded`：
 * 聊天版本把「近N场：」和每一场各拆到单独一行，玩家之间插一条**可见**分隔线
 * （实机验证：连续两个换行、以及只含空格的「空格行」都会被客户端吃掉，
 * 空行留不住）；页面预览保持单行。两个分支必须渲染同一份模板，只有分隔符不同。
 */
function renderShortcutLines(shortcutId: string, chatExpanded: boolean): string[] {
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
  return players.flatMap((player, index) => {
    const team = lobby.ally.some((item) => item.puuid === player.puuid) ? "我方" : "敌方";
    const rendered = renderBrowserTemplate(shortcut.template, player, team, chatExpanded);
    const lines = rendered.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
    return chatExpanded && index > 0 ? [CHAT_PLAYER_DIVIDER, ...lines] : lines;
  });
}

/** 真实后端发进聊天框的文本（含可见分隔线）。浏览器预览下仅用于校验渲染口径。 */
export function browserChatText(shortcutId: string): string[] {
  return renderShortcutLines(shortcutId, true);
}
