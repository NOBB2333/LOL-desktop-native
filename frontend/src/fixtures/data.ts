import type {
  AppBootstrap,
  AppConfig,
  BanSummary,
  ChampionAbilities,
  ChampionAbilityValues,
  ChampionOverview,
  ClaimSnapshot,
  ClientInstallations,
  DeletedFriendsSnapshot,
  EncounterRecord,
  FriendToolsSnapshot,
  FinalBpRecord,
  GameRecording,
  GameRecordingFrame,
  GameRecordingPlayer,
  JungleCampCounts,
  JunglePathMap,
  JunglePathPoint,
  JungleZone,
  LiveLobby,
  ItemSummary,
  MatchParticipant,
  MatchSummary,
  MatchTimeline,
  MatchTimelineEvent,
  MatchTimelineFrame,
  MatchTimelineParticipant,
  PlayerProfile,
  PlayerStatSummary,
  RecentMatch,
  RuneSummary,
  SpellSummary,
  TeamSummary,
} from "../types/domain";
import { defaultPlayerTagSettings } from "../tags/settings";
// 阵营常量只此一份：fixture 与界面必须用同一对值，各写各的迟早对不上。
import { TEAM_BLUE, TEAM_RED } from "../matches/lineup";
import type { JungleCamp } from "../live/gameMap";
import { playerSignals, teamSignals } from "../tags/signals";

const now = Date.now();
const champions = [
  [266, "暗裔剑魔", "Aatrox", "TOP"],
  [64, "盲僧", "LeeSin", "JUNGLE"],
  [103, "九尾妖狐", "Ahri", "MIDDLE"],
  [222, "暴走萝莉", "Jinx", "BOTTOM"],
  [412, "魂锁典狱长", "Thresh", "UTILITY"],
  [164, "青钢影", "Camille", "TOP"],
  [76, "狂野女猎手", "Nidalee", "JUNGLE"],
  [7, "诡术妖姬", "Leblanc", "MIDDLE"],
  [145, "虚空之女", "Kaisa", "BOTTOM"],
  [111, "深海泰坦", "Nautilus", "UTILITY"],
] as const;

const allyNames = [["松间照", "0721"], ["野区巡视员", "JG"], ["第七码头", "MID"], ["今晚不空大", "AD"], ["留灯给你", "SUP"]] as const;
const enemyNames = [["一剑霜寒", "TOP"], ["河道观察者", "233"], ["狐狸收藏家", "MID"], ["四件套启动", "ADC"], ["灯笼点一下", "SUP"]] as const;
const ranks = [["DIAMOND", "II", 67], ["EMERALD", "I", 82], ["DIAMOND", "III", 41], ["MASTER", "", 126], ["EMERALD", "II", 54]] as const;
const fixtureStatus = () => ({ source: "fixture" as const, fetchedAt: new Date(now).toISOString(), expiresAt: null, isStale: false, error: null });

function itemsFor(championName: string): ItemSummary[] {
  // 终局 6 件（含鞋），按英雄定位给真实装备 id——预览里观战面板的装备格
  // 就是从这份来的，给 3 件或通用装会一眼假。
  const names: Record<string, [string, number][]> = {
    "暗裔剑魔": [["星蚀", 6692], ["焚天", 6610], ["死亡之舞", 6333], ["铁板靴", 3047], ["斯特拉克的挑战护手", 3053], ["自然之力", 4401]],
    "盲僧": [["星蚀", 6692], ["黑色切割者", 3071], ["死亡之舞", 6333], ["铁板靴", 3047], ["玛莫提乌斯之噬", 3156], ["守护天使", 3026]],
    "九尾妖狐": [["卢登的伙伴", 6655], ["影焰", 4645], ["中娅沙漏", 3157], ["法师之靴", 3020], ["灭世者的死亡之帽", 3089], ["虚空之杖", 3135]],
    "发条魔灵": [["大天使之杖", 3003], ["影焰", 4645], ["中娅沙漏", 3157], ["法师之靴", 3020], ["灭世者的死亡之帽", 3089], ["虚空之杖", 3135]],
    "诡术妖姬": [["卢登的伙伴", 6655], ["风暴狂涌", 4646], ["影焰", 4645], ["法师之靴", 3020], ["中娅沙漏", 3157], ["灭世者的死亡之帽", 3089]],
    "岩雀": [["卢登的伙伴", 6655], ["影焰", 4645], ["中娅沙漏", 3157], ["法师之靴", 3020], ["灭世者的死亡之帽", 3089], ["虚空之杖", 3135]],
    "辛德拉": [["卢登的伙伴", 6655], ["影焰", 4645], ["中娅沙漏", 3157], ["法师之靴", 3020], ["灭世者的死亡之帽", 3089], ["虚空之杖", 3135]],
    "阿卡丽": [["海克斯科技火箭腰带", 3152], ["影焰", 4645], ["中娅沙漏", 3157], ["法师之靴", 3020], ["灭世者的死亡之帽", 3089], ["虚空之杖", 3135]],
    "暴走萝莉": [["海妖杀手", 6672], ["幻影之舞", 3046], ["无尽之刃", 3031], ["狂战士胫甲", 3006], ["多米尼克领主的致意", 3036], ["饮血剑", 3072]],
    "魂锁典狱长": [["钢铁烈阳之匣", 3190], ["骑士之誓", 3109], ["水银之靴", 3111], ["基克的聚合", 3050], ["荆棘之甲", 3075], ["救赎", 3107]],
    "青钢影": [["三相之力", 3078], ["贪欲九头蛇", 3074], ["死亡之舞", 6333], ["铁板靴", 3047], ["斯特拉克的挑战护手", 3053], ["守护天使", 3026]],
    "狂野女猎手": [["巫妖之祸", 3100], ["影焰", 4645], ["中娅沙漏", 3157], ["法师之靴", 3020], ["灭世者的死亡之帽", 3089], ["虚空之杖", 3135]],
    "虚空之女": [["海妖杀手", 6672], ["鬼索的狂暴之刃", 3124], ["纳什之牙", 3115], ["狂战士胫甲", 3006], ["中娅沙漏", 3157], ["灭世者的死亡之帽", 3089]],
    "深海泰坦": [["钢铁烈阳之匣", 3190], ["骑士之誓", 3109], ["铁板靴", 3047], ["荆棘之甲", 3075], ["基克的聚合", 3050], ["深渊面具", 8020]],
  };
  return (names[championName] ?? [["卢登的伙伴", 6655], ["影焰", 4645], ["中娅沙漏", 3157], ["法师之靴", 3020], ["灭世者的死亡之帽", 3089], ["虚空之杖", 3135]]).map(([name, id]) => ({ id, name, iconUrl: `https://ddragon.leagueoflegends.com/cdn/16.16.1/img/item/${id}.png` }));
}

function spellsFor(index: number): SpellSummary[] {
  return [
    { id: 4, name: "闪现", iconUrl: "https://ddragon.leagueoflegends.com/cdn/16.16.1/img/spell/SummonerFlash.png" },
    index % 2 === 0
      ? { id: 14, name: "点燃", iconUrl: "https://ddragon.leagueoflegends.com/cdn/16.16.1/img/spell/SummonerDot.png" }
      : { id: 12, name: "传送", iconUrl: "https://ddragon.leagueoflegends.com/cdn/16.16.1/img/spell/SummonerTeleport.png" },
  ];
}

function runesFor(index: number): RuneSummary[] {
  return index % 2 === 0
    ? [
      { id: 8112, name: "电刑", style: "主宰", iconUrl: "https://ddragon.leagueoflegends.com/cdn/img/perk-images/Styles/Domination/Electrocute/Electrocute.png" },
      { id: 8226, name: "法力流系带", style: "巫术", iconUrl: "https://ddragon.leagueoflegends.com/cdn/img/perk-images/Styles/Sorcery/ManaflowBand/ManaflowBand.png" },
    ]
    : [
      { id: 8230, name: "相位猛冲", style: "巫术", iconUrl: "https://ddragon.leagueoflegends.com/cdn/img/perk-images/Styles/Sorcery/PhaseRush/PhaseRush.png" },
      { id: 8226, name: "法力流系带", style: "巫术", iconUrl: "https://ddragon.leagueoflegends.com/cdn/img/perk-images/Styles/Sorcery/ManaflowBand/ManaflowBand.png" },
    ];
}

function recentMatches(index: number, ally: boolean, championId: number, championName: string, role: string): RecentMatch[] {
  return Array.from({ length: 10 }, (_, matchIndex) => {
    const hot = (ally && index === 3) || (!ally && index === 2);
    const slump = !ally && index === 4;
    const win = hot ? matchIndex < 8 : slump ? matchIndex === 2 || matchIndex === 7 : (matchIndex + index) % 3 !== 0;
    const kills = win ? 7 + (matchIndex % 4) : 3;
    const deaths = win ? 2 + (matchIndex % 3) : 7;
    const assists = 5 + ((index + matchIndex) % 9);
    const damageShare = 0.16 + index * 0.018;
    const killParticipation = Math.min(0.82, (kills + assists) / (30 + index * 2));
    const performance = damageShare >= 0.23 && (kills + assists) / Math.max(1, deaths) >= 3.5 ? "carry" : win && damageShare < 0.19 ? "carried" : deaths >= 7 ? "struggling" : "solid";
    return {
      gameId: 760000 + index * 100 + matchIndex,
      queueId: matchIndex === 8 ? 450 : 420,
      championId,
      championName,
      queueName: matchIndex === 8 ? "极地大乱斗" : "单双排",
      position: role,
      kills,
      deaths,
      assists,
      durationMinutes: 24 + (matchIndex % 12),
      items: itemsFor(championName),
      summonerSpells: spellsFor(matchIndex),
      runes: runesFor(matchIndex),
      damageDealt: 12000 + index * 1400 + matchIndex * 430,
      damageTaken: 9000 + index * 1100 + matchIndex * 300,
      heal: 1800 + index * 320 + matchIndex * 85,
      goldEarned: 10800 + index * 500 + matchIndex * 180,
      cs: 132 + matchIndex * 9 + index * 4,
      damageShare,
      killParticipation,
      soloKills: kills >= 7 ? 1 : 0,
      takedownsFirstXMinutes: role === "JUNGLE" ? 1 + matchIndex % 4 : null,
      jungleCsBefore10Minutes: role === "JUNGLE" ? 52 + matchIndex % 4 * 3 : null,
      alliedJungleMonsterKills: role === "JUNGLE" ? 68 + matchIndex * 2 : null,
      enemyJungleMonsterKills: role === "JUNGLE" ? 2 + matchIndex % 5 : null,
      dragonTakedowns: role === "JUNGLE" ? matchIndex % 3 : null,
      baronTakedowns: role === "JUNGLE" ? Number(matchIndex % 4 === 0) : null,
      riftHeraldTakedowns: role === "JUNGLE" ? Number(matchIndex % 3 === 0) : null,
      scuttleCrabKills: role === "JUNGLE" ? 1 + matchIndex % 3 : null,
      performance,
      mvp: performance === "carry" ? (win ? "MVP" : "SVP") : null,
      win,
      playedAt: new Date(now - (matchIndex * 9 + index) * 3600000).toISOString(),
    };
  });
}

function makePlayer(index: number, ally: boolean, rankedOnly = false): PlayerProfile {
  const champion = champions[index + (ally ? 0 : 5)];
  const [id, championName, , role] = champion;
  const [gameName, tagLine] = (ally ? allyNames : enemyNames)[index];
  const [rankTier, rankDivision, leaguePoints] = ranks[ally ? index : (index + 2) % 5];
  const matches = recentMatches(index, ally, id, championName, role).filter((match) => !rankedOnly || match.queueId === 420 || match.queueId === 440);
  const wins = matches.filter((match) => match.win).length;
  const kda = matches.reduce((sum, match) => sum + (match.kills + match.assists) / Math.max(1, match.deaths), 0) / matches.length;
  const score = Math.round((58 + wins * 2.8 + Math.min(kda, 5) * 2.2 + (rankTier === "MASTER" ? 10 : 0)) * 10) / 10;
  const topChampions = [
    { championId: id, championName, games: 63 - index * 5, wins: 39 - index * 2, winRate: 0.62 - index * 0.01 },
    { championId: champions[(index + 1) % 5][0], championName: champions[(index + 1) % 5][1], games: 31, wins: 18, winRate: 0.58 },
    { championId: champions[(index + 2) % 5][0], championName: champions[(index + 2) % 5][1], games: 19, wins: 10, winRate: 0.53 },
  ];
  // fixture 里每一局都有真参团率（不是后端那种「整队数据缺失」），`?? 0` 只是满足类型。
  const averageParticipation = matches.reduce((sum, match) => sum + (match.killParticipation ?? 0), 0) / matches.length;
  const averageCsPerMinute = matches.reduce((sum, match) => sum + match.cs / Math.max(1, match.durationMinutes), 0) / matches.length;
  const averageEarlyTakedowns = role === "JUNGLE" ? matches.reduce((sum, match) => sum + (match.takedownsFirstXMinutes ?? 0), 0) / matches.length : null;
  const averageObjectiveTakedowns = role === "JUNGLE" ? matches.reduce((sum, match) => sum + (match.dragonTakedowns ?? 0) + (match.baronTakedowns ?? 0) + (match.riftHeraldTakedowns ?? 0), 0) / matches.length : null;
  const junglePreference: PlayerProfile["junglePreference"] = role === "JUNGLE" ? {
    sampleSize: matches.length,
    wins,
    winRate: wins / matches.length,
    style: averageEarlyTakedowns !== null && averageEarlyTakedowns >= 2 ? "tempo" : averageCsPerMinute >= 6.5 && averageParticipation < 0.55 ? "farm" : "balanced",
    label: averageEarlyTakedowns !== null && averageEarlyTakedowns >= 2 ? "节奏带动型" : averageCsPerMinute >= 6.5 && averageParticipation < 0.55 ? "发育控图型" : "均衡型",
    evidence: `近${matches.length}场打野，参团 ${Math.round(averageParticipation * 100)}%，分均补刀 ${averageCsPerMinute.toFixed(1)}，前期场均参与击杀 ${averageEarlyTakedowns?.toFixed(1)}`,
    averageKda: Number(kda.toFixed(1)),
    averageKillParticipation: averageParticipation,
    averageCsPerMinute: Number(averageCsPerMinute.toFixed(1)),
    averageEarlyTakedowns: averageEarlyTakedowns === null ? null : Number(averageEarlyTakedowns.toFixed(1)),
    averageObjectiveTakedowns: averageObjectiveTakedowns === null ? null : Number(averageObjectiveTakedowns.toFixed(1)),
    averageEnemyJungleMonsters: Number((matches.reduce((sum, match) => sum + (match.enemyJungleMonsterKills ?? 0), 0) / matches.length).toFixed(1)),
    mainChampions: topChampions,
    currentChampionGames: matches.filter((match) => match.championId === id).length,
  } : null;
  return {
    puuid: `fixture-${ally ? "ally" : "enemy"}-${index}`,
    gameName,
    tagLine,
    isBot: false,
    championId: id,
    championName,
    profileIconId: 29 + index,
    summonerLevel: 285 + index * 63 + (ally ? 0 : 29),
    assignedPosition: role,
    rankTier,
    rankDivision,
    leaguePoints,
    wins: 62 + index * 7,
    losses: 49 + index * 5,
    soloRank: { queueType: "RANKED_SOLO_5x5", tier: rankTier, division: rankDivision, leaguePoints, wins: 62 + index * 7, losses: 49 + index * 5 },
    flexRank: { queueType: "RANKED_FLEX_SR", tier: index % 2 === 0 ? "GOLD" : "PLATINUM", division: index % 2 === 0 ? "II" : "IV", leaguePoints: 31 + index * 6, wins: 38 + index * 4, losses: 34 + index * 3 },
    recentMatches: matches,
    topChampions,
    score: {
      total: score,
      confidence: 78,
      components: [
        { key: "rank", label: "段位", score: rankTier === "MASTER" ? 29 : 24, maxScore: 30, evidence: `${rankTier} ${rankDivision}` },
        { key: "recent", label: "近期状态", score: wins * 2.5, maxScore: 25, evidence: `近10场 ${wins} 胜` },
        { key: "kda", label: "KDA", score: Math.min(15, kda * 3), maxScore: 15, evidence: `平均 KDA ${kda.toFixed(2)}` },
        { key: "position", label: "位置熟练", score: index === 1 ? 5 : 9, maxScore: 10, evidence: index === 1 ? "同位置 4/10 场" : "同位置 9/10 场" },
        { key: "current", label: "当前英雄", score: 12, maxScore: 15, evidence: "当前英雄 5 场" },
        { key: "pool", label: "英雄池", score: 4, maxScore: 5, evidence: "主要使用 3 个英雄" },
      ],
    },
    junglePreference,
    encounterCount: index === 2 ? 3 : index % 2,
    lastEncounteredAt: index === 2 ? new Date(now - 12 * 86400000).toISOString() : null,
    isPremade: ally ? index >= 3 : index === 1 || index === 2,
    premadeWith: ally && index >= 3 ? [allyNames[index === 3 ? 4 : 3][0]] : !ally && (index === 1 || index === 2) ? [enemyNames[index === 1 ? 2 : 1][0]] : [],
    positionGames: index === 1 ? 4 : 9,
    positionWinRate: index === 1 ? 0.5 : 0.6 + index * 0.01,
    currentChampionGames: 63 - index * 5,
    currentChampionWinRate: 0.62 - index * 0.01,
    championPoolConcentration: 0.48 + index * 0.07,
    dataComplete: true,
    unavailableSources: [],
    dataStatus: fixtureStatus(),
  };
}

function summary(side: "ally" | "enemy", players: PlayerProfile[]): TeamSummary {
  const score = players.reduce((sum, player) => sum + player.score.total, 0) / players.length;
  // 与后端 `writeLiveTeamSummary` 同口径：优势 / 风险取自 `player_signals` 那份信号表。
  const { strengths, risks } = teamSignals(players, { emptyStrengths: "整体状态稳定", emptyRisks: "暂无明显风险" });
  return {
    side,
    score: Math.round(score * 10) / 10,
    title: score >= 78 ? "状态占优" : "整体均衡",
    focusPlayerPuuid: players.reduce((lowest, player) => player.score.total < lowest.score.total ? player : lowest).puuid,
    strengths: strengths.slice(0, 2).map((label) => {
      const owner = players.find((player) => playerSignals(player).some((signal) => signal.label === label));
      return owner ? `${owner.championName}：${label}` : label;
    }),
    risks: risks.slice(0, 2).map((label) => {
      const owner = players.find((player) => playerSignals(player).some((signal) => signal.label === label));
      return owner ? `${owner.championName}：${label}` : label;
    }),
    composition: { early: side === "ally" ? 76 : 72, mid: side === "ally" ? 84 : 78, late: side === "ally" ? 71 : 82, teamfight: side === "ally" ? 86 : 79 },
  };
}

const ally = Array.from({ length: 5 }, (_, index) => makePlayer(index, true));
const enemy = Array.from({ length: 5 }, (_, index) => makePlayer(index, false));

export const fixtureLobby: LiveLobby = {
  id: "fixture-ranked-20260816",
  queueId: 420,
  gameMode: "单双排 · 征召模式",
  phase: "ChampSelect",
  ally,
  enemy,
  allySummary: summary("ally", ally),
  enemySummary: summary("enemy", enemy),
  layoutKind: "classic",
  teams: [
    { id: "ally", label: "我方阵容", side: "ally", players: ally, summary: summary("ally", ally) },
    { id: "enemy", label: "敌方阵容", side: "enemy", players: enemy, summary: summary("enemy", enemy) },
  ],
  generatedAt: new Date(now).toISOString(),
  recentMatch: null,
  isFixture: true,
};

export function createFixtureLobby(rankedOnly: boolean): LiveLobby {
  const value = structuredClone(fixtureLobby);
  if (!rankedOnly) return value;
  value.ally = Array.from({ length: 5 }, (_, index) => makePlayer(index, true, true));
  value.enemy = Array.from({ length: 5 }, (_, index) => makePlayer(index, false, true));
  value.allySummary = summary("ally", value.ally);
  value.enemySummary = summary("enemy", value.enemy);
  value.teams = value.teams?.map((team) => ({ ...team, players: team.side === "ally" ? value.ally : value.enemy, summary: team.side === "ally" ? value.allySummary : value.enemySummary }));
  return value;
}

/**
 * 房间/匹配中（还没进选人）的预览快照。
 *
 * 和 champ select 的差别必须照着后端 `liveSessionEnvelopePhaseContext` 的房间分支来：
 * `id` 退回 `lcu-session`（房间没有局号）、只有本机所在小队（这里取 3 人队）、
 * `enemy` 为空、`teams` 只有一组「房间成员」。
 */
export function createFixtureRoomLobby(rankedOnly: boolean): LiveLobby {
  const value = createFixtureLobby(rankedOnly);
  const room = value.ally.slice(0, 3);
  value.id = "lcu-session";
  value.phase = "Lobby";
  value.ally = room;
  value.enemy = [];
  value.allySummary = summary("ally", room);
  // 敌方为空时不能重算摘要：`summary` 空数组会 reduce 到 NaN 并抛错。房间阶段本来
  // 也不渲染敌方，沿用原值即可。
  value.teams = [{ id: "room", label: "房间成员", side: "ally", players: room, summary: value.allySummary }];
  // 房间里「上一局对局信息」那块是露出来的（`LiveView` 的条件是 `!hasLobbyPlayers || isRoomPhase`），
  // 真机上它读后端 `matches/current` 缓存里的最新一局。fixture 不补这一条，预览就永远停在
  // 一句「暂无可回看的历史对局」上，看着像功能没做。
  // 必须取 `fixtureMatches[0]`——得和 `browserBackend.matches()` 返回的是同一局，
  // 否则展开详情会 join 不上（历史页踩过这个坑）。房间 fixture 本来就是「刚打完一局回到房间」，
  // 所以这一条也确实就是「上一局」。
  value.recentMatch = fixtureMatches[0] ?? null;
  return value;
}

/**
 * 「我」在每局用的英雄。三处必须用同一份：对局列表的本行、十人详情里的座位 0、
 * 相遇记录的 selfChampion —— 各写各的就会出现「列表说我玩了狐狸、详情里座位 0
 * 却是剑魔」这种自相矛盾的预览（用户看到只会以为功能坏了）。
 */
const SELF_CHAMPION_BY_MATCH = ["九尾妖狐", "发条魔灵", "诡术妖姬", "岩雀", "九尾妖狐", "辛德拉", "九尾妖狐", "阿卡丽", "九尾妖狐", "发条魔灵"] as const;
const CHAMPION_IDS: Record<string, number> = { "九尾妖狐": 103, "发条魔灵": 61, "诡术妖姬": 7, "岩雀": 163, "辛德拉": 134, "阿卡丽": 84 };

/**
 * 每个位置的十人数据基线（按 26 分钟的对局估）。
 *
 * 原来这五项都是 `125 + slot * 12` / `10500 + slot * 1100` 这种**等差数列**：五个人整齐地
 * 排成一档一档，战绩详情里切到伤害就是一列完美的斜线，补刀更是辅助和中单差不多——位置
 * 完全没体现，一眼就假。改成按位置取基线：辅助补刀/输出最低、视野最高；adc 补刀与输出
 * 最高；上单承伤最高。数值量级也与逐帧金币对得上（一队 26 分钟约 10 万输出 / 5.4 万经济）。
 */
const ROLE_BASELINE: Record<string, { cs: number; damage: number; taken: number; heal: number; vision: number; gold: number }> = {
  TOP: { cs: 207, damage: 21300, taken: 26900, heal: 1500, vision: 26, gold: 11400 },
  JUNGLE: { cs: 168, damage: 18600, taken: 24800, heal: 1200, vision: 32, gold: 11000 },
  MIDDLE: { cs: 239, damage: 28200, taken: 18100, heal: 900, vision: 22, gold: 12800 },
  BOTTOM: { cs: 252, damage: 30200, taken: 16200, heal: 1000, vision: 19, gold: 13400 },
  UTILITY: { cs: 39, damage: 8700, taken: 17400, heal: 4400, vision: 55, gold: 8700 },
};

/**
 * 确定性扰动（**不要**用 `Math.random`）：同样的 (局号, 座位) 永远得到同一个值，
 * 预览才可复现、截图对比才有意义。叠上它之后五个人不再排成一条直线。
 */
function wobble(index: number, slot: number, seed: number, span: number) {
  return ((index * 7 + slot * 13 + seed * 5) % (span * 2 + 1)) - span;
}

function matchParticipants(index: number, win: boolean, selfTeam: number = TEAM_BLUE): MatchParticipant[] {
  const selfChampionName = SELF_CHAMPION_BY_MATCH[index] ?? "九尾妖狐";
  // 每个位置的数据基线（按 26 分钟的对局估）。见上面 `ROLE_BASELINE` 的说明。
  // 先把十个人的原始数值算出来，再算两队总量——「团队占比」必须拿**实际生成的**总量做分母，
  // 写死常数在叠加扰动之后就对不上了（战绩详情里那一列五个人加起来不是 100%，一眼假）。
  const dealt = (slot: number, role: string) => (ROLE_BASELINE[role] ?? ROLE_BASELINE.MIDDLE).damage + wobble(index, slot, 1, 2600);
  const taken = (slot: number, role: string) => (ROLE_BASELINE[role] ?? ROLE_BASELINE.MIDDLE).taken + wobble(index, slot, 2, 2100);
  const teamSum = (of: (slot: number, role: string) => number, ally: boolean) => champions.reduce((sum, [, , , role], slot) => sum + ((slot < 5) === ally ? of(slot, role) : 0), 0);
  const damageTotal = { ally: teamSum(dealt, true), enemy: teamSum(dealt, false) };
  const takenTotal = { ally: teamSum(taken, true), enemy: teamSum(taken, false) };

  const participants: MatchParticipant[] = champions.map(([championId, championName, , role], slot) => {
    const base = ROLE_BASELINE[role] ?? ROLE_BASELINE.MIDDLE;
    const ally = slot < 5;
    const damageDealt = dealt(slot, role);
    const damageTaken = taken(slot, role);
    return {
      // ⚠️ puuid / 名字必须与大厅（`allyNames` / `enemyNames`）用同一套——相遇档案和
      // 「关系记录」都按这些 puuid 关联。各写各的会让预览里「这一局遇到谁」「遇到过 N 次」
      // 永远 join 不上，看起来就像功能没做（前面已经因为同样的问题返工过一次）。
      // 座位 0 正好是「我」（`allyNames[0]`），所以相遇档案（`ally.slice(1)`）天然不含自己。
      puuid: slot < 5 ? `fixture-ally-${slot}` : `fixture-enemy-${slot - 5}`,
      gameName: (slot < 5 ? allyNames : enemyNames)[slot % 5][0],
      isBot: false,
      // 座位 0 = 我，英雄用这一局真实的那只（见上面的 `SELF_CHAMPION_BY_MATCH`）。
      championId: slot === 0 ? CHAMPION_IDS[selfChampionName] ?? championId : championId,
      championName: slot === 0 ? selfChampionName : championName,
      side: ally ? "ally" : "enemy",
      // 绝对阵营：与后端 DTO 同构（100 蓝 / 200 红）。`side` 与 `team` 是**两套坐标**
      // ——我打红方时自己的 `side` 还是 "ally" 却属于 200，配对必须走 `team`。
      // 默认把我放在蓝方，两个字段恰好同向；`?selfSide=red` 会把我放到 200，
      // 复现真机上「两个字段不同向」的形状（预览里能一眼看出配对有没有写错）。
      team: ally ? selfTeam : selfTeam === TEAM_BLUE ? TEAM_RED : TEAM_BLUE,
      position: role,
      kills: slot === 2 ? 9 : 3 + ((slot + index) % 5),
      deaths: slot === 2 ? 2 : 4 + ((slot + index) % 4),
      assists: 5 + ((slot * 2 + index) % 9),
      damageDealt,
      damageTaken,
      goldEarned: base.gold + wobble(index, slot, 3, 700),
      cs: base.cs + wobble(index, slot, 4, 17),
      win: ally ? win : !win,
      items: itemsFor(championName),
      summonerSpells: spellsFor(slot + index),
      runes: runesFor(slot + index),
      heal: base.heal + wobble(index, slot, 5, 380),
      damageShare: Number((damageDealt / damageTotal[ally ? "ally" : "enemy"]).toFixed(3)),
      damageTakenShare: Number((damageTaken / takenTotal[ally ? "ally" : "enemy"]).toFixed(3)),
      killParticipation: 0.28 + ((slot + index) % 5) * 0.08,
      towerDamage: 700 + slot * 180 + index * 40,
      turretKills: slot % 3,
      wardsPlaced: (role === "UTILITY" ? 26 : 8) + slot * 2 + index,
      wardsKilled: (role === "UTILITY" ? 6 : 2) + (slot % 4),
      visionScore: base.vision + wobble(index, slot, 6, 5),
      visionWardsBought: role === "UTILITY" ? 5 : slot % 3,
      sightWardsBought: slot % 2,
    };
  });

  // 座位 0 被换成「我」的英雄后，可能与本队中路撞成**同队重复英雄**（当前 fixture 里
  // 我玩九尾妖狐时就会撞上原阵容的中路）。同队重复在真实对局里不存在，一眼就假；
  // 跨队重复在匹配/极地里是允许的，所以直接把双方中路对调就消掉了。
  const allyMid = participants[2];
  const enemyMid = participants[7];
  if (allyMid && enemyMid && allyMid.championId === participants[0].championId) {
    [allyMid.championId, enemyMid.championId] = [enemyMid.championId, allyMid.championId];
    [allyMid.championName, enemyMid.championName] = [enemyMid.championName, allyMid.championName];
  }
  // 队内一路一人，中路对调后也不该出现两个打同一个英雄的队友。
  return participants;
}

const fixtureBanDetails: BanSummary[] = [
  { id: 164, name: "青钢影", iconUrl: "./fixtures/champions/Camille.png", side: "ally" },
  { id: 64, name: "盲僧", iconUrl: "./fixtures/champions/LeeSin.png", side: "ally" },
  { id: 157, name: "疾风剑豪", iconUrl: "./fixtures/champions/Yasuo.png", side: "ally" },
  { id: 84, name: "离群之刺", iconUrl: "./fixtures/champions/Akali.png", side: "enemy" },
  { id: 412, name: "魂锁典狱长", iconUrl: "./fixtures/champions/Thresh.png", side: "enemy" },
];

/**
 * 造一局的十人详情。
 *
 * `selfTeam` 是**主视角所在的绝对阵营**（100 蓝 / 200 红），默认蓝方。它只影响
 * `side` / `team` 这对坐标，不影响胜负与数值——真机上换个边不会让 KDA 变样，
 * 变的只是「谁在我的队里」。
 */
function buildFixtureMatch(index: number, selfTeam: number = TEAM_BLUE): MatchSummary {
  const championName = SELF_CHAMPION_BY_MATCH[index] ?? "九尾妖狐";
  const win = ![2, 5, 6, 9].includes(index);
  const championId = CHAMPION_IDS[championName] ?? 103;
  const kills = index === 0 ? 9 : index === 1 ? 4 : index === 2 ? 7 : 6;
  const deaths = index === 0 ? 2 : index === 1 ? 3 : index === 2 ? 8 : 4;
  const assists = index === 0 ? 11 : index === 1 ? 16 : index === 2 ? 5 : 9;
  return {
    gameId: 880210 + index,
    championId,
    championName,
    position: index % 3 === 0 ? "MIDDLE" : "UTILITY",
    queueId: index === 5 ? 450 : 420,
    queueName: index === 5 ? "极地大乱斗" : "单双排",
    result: win ? "胜利" : "失败",
    kda: `${kills} / ${deaths} / ${assists}`,
    kills,
    deaths,
    assists,
    durationMinutes: 27 + index * 3,
    items: itemsFor(championName),
    summonerSpells: spellsFor(index),
    runes: runesFor(index),
    damageDealt: 18400 + index * 1700,
    damageTaken: 10800 + index * 700,
    damageTakenShare: 0.18 + (index % 3) * 0.035,
    heal: 1900 + index * 260,
    goldEarned: 13200 + index * 260,
    cs: 182 + index * 11,
    towerDamage: 1200 + index * 430,
    turretKills: index % 3,
    towerLeader: index === 0 || index === 4,
    damageShare: 0.22 + (index % 4) * 0.025,
    killParticipation: Math.min(0.88, (kills + assists) / (38 + (index % 4))),
    performance: index === 0 || index === 4 ? "carry" : win && index === 1 ? "carried" : !win && deaths >= 7 ? "struggling" : "solid",
    mvp: index === 0 || index === 4 ? "MVP" : index === 2 ? "SVP" : null,
    teamKills: 38 + (index % 4),
    participants: matchParticipants(index, win, selfTeam),
    bans: ["青钢影", "盲僧", "亚索", "阿卡丽", "锤石"],
    banDetails: fixtureBanDetails,
    playedAt: new Date(now - (index * 11 + 2) * 3600000).toISOString(),
    dataStatus: fixtureStatus(),
  };
}

export const fixtureMatches: MatchSummary[] = SELF_CHAMPION_BY_MATCH.map((_, index) => buildFixtureMatch(index));

/**
 * 同一局、但主视角落在**指定阵营**的十人详情，`?selfSide=red` 走这条。
 *
 * 存在的理由和 `?frameDamage=0` 一样：fixture 默认把我放在蓝方，`side`（我方/敌方）
 * 与 `team`（100/200）恰好同向，于是「拿 `side` 去配时间线座位」这条错误规则在预览里
 * **永远是对的**——真机红方局会全线错位（每个人 KDA 000、装备空白），预览却一片正常。
 * 有了这一条，配对写错时预览自己就能露馅。
 */
export function createFixtureMatchDetail(gameId: number, options: { selfTeam?: number } = {}): MatchSummary | undefined {
  const index = fixtureMatches.findIndex((item) => item.gameId === gameId);
  if (index < 0) return undefined;
  return buildFixtureMatch(index, options.selfTeam ?? TEAM_BLUE);
}

export const fixtureChampions: ChampionOverview[] = champions.map(([id, name, alias, role], index) => ({
  id, name, alias, abilities: ["被动技能", "技能 Q", "技能 W", "技能 E", "技能 R"], roles: [role], tier: index < 3 ? "S" : index < 7 ? "A" : "B",
  winRate: 0.485 + (index % 6) * 0.009, pickRate: 0.032 + (10 - index) * 0.004, banRate: 0.018 + index * 0.006, kda: 2.1 + index * 0.17,
  iconUrl: `./fixtures/champions/${alias}.png`, baseSource: "fixture", statsSource: "fixture",
  statsRegion: "global", statsTier: "emerald_plus",
  dataStatus: fixtureStatus(),
}));

/**
 * fixture 的技能详情：**形状必须照真机来**。
 *
 * 真机是 LCU 的 `/lol-game-data/assets/v1/champions/{id}.json`：`spells[]` 带
 * `spellKey`（q/w/e/r）、名字已本地化、每级数组长度 5~6。这里刻意让四个槽位都齐、
 * 名字用中文、冷却/耗蓝/射程是**真数组**（不是空数组）——空数组会让预览里
 * 「看不到数组渲染长什么样」，等真机出现 5 个数字时才发现布局挤爆。
 *
 * ⚠️ 这里**不能**填每级伤害：真机上 LCU 的 `coefficients` 全是 0，真实系数只在
 * CommunityDragon 里。fixture 里编一个，就会掩盖「这一项本来就没做」。
 */
export function createFixtureChampionAbilities(championId: number): ChampionAbilities {
  const row = champions.find(([id]) => id === championId) ?? champions[0];
  const [id, name, alias] = row;
  const slotNames: Record<string, string> = { q: "一技能", w: "二技能", e: "三技能", r: "终极技" };
  /**
   * 描述必须**照真机的形状**写：带官方标记（`<speed>` / `<magicDamage>` …）和
   * `@Name@` 变量。写成纯文本的话，预览就测不出渲染层到底有没有正确处理——
   * 而这一层正是最容易出错的地方（2026-09-30 就是标签被原样印出来了）。
   */
  const descriptions: Record<string, string> = {
    q: "获得<speed>@MinimumMoveSpeed@移动速度</speed>，并在@RollDuration@秒里持续加速至<speed>@MaximumMoveSpeed@移动速度</speed>。碰撞后造成<magicDamage>@PowerBallDamage@魔法伤害</magicDamage>与<status>击退</status>。<br><br><recast>再次施放</recast>：提前结束这个技能。@SpellModifierDescriptionAppend@",
    w: "进入持续@BuffDuration@秒的防御姿态，获得<scaleArmor>@BonusArmorTooltip@护甲</scaleArmor>和<scaleMR>@BonusMRTooltip@魔法抗性</scaleMR>。",
    e: "<status>嘲讽</status>一个敌方英雄，强制目标攻击自己@Duration@秒。",
    r: "造成<magicDamage>@InitialDamage@魔法伤害</magicDamage>和持续@SlowDuration@秒的@SlowPercent@%<status>减速</status>。",
  };
  return {
    championId: id,
    alias,
    name,
    title: name,
    passive: {
      name: "被动技能",
      description: `${name} 的被动效果：普攻附带<b>额外伤害</b>（fixture 文案）。`,
      iconPath: `/lol-game-data/assets/ASSETS/Characters/${alias}/HUD/Icons2D/${alias}_Passive.png`,
      videoPath: `champion-abilities/${id}/ability_${id}_P1.webm`,
      videoImagePath: `champion-abilities/${id}/ability_${id}_P1.jpg`,
    },
    spells: (["q", "w", "e", "r"] as const).map((slot, index) => ({
      slot,
      name: slotNames[slot],
      description: `${name} 的${slotNames[slot]}（fixture 文案）`,
      dynamicDescription: descriptions[slot],
      // 真机的长度是 5 或 6（技能最多点 5 级，有的技能多一格）。这里用 5。
      cooldown: Array.from({ length: 5 }, () => 6 + index * 2),
      cost: Array.from({ length: 5 }, () => 40 + index * 10),
      range: Array.from({ length: 5 }, () => 400 + index * 150),
      iconPath: `/lol-game-data/assets/ASSETS/Characters/${alias}/HUD/Icons2D/${alias}_${slot.toUpperCase()}.png`,
      videoPath: `champion-abilities/${id}/ability_${id}_${slot.toUpperCase()}1.webm`,
      videoImagePath: `champion-abilities/${id}/ability_${id}_${slot.toUpperCase()}1.jpg`,
    })),
  };
}

/**
 * fixture 的技能变量取值：**必须和上面的描述对得上**。
 *
 * 覆盖三种情形，缺一就测不出渲染层的行为：
 *  - 能取到值的（`@PowerBallDamage@` → 逐级数组 + AP 系数）；
 *  - **取不到**值的（`@MinimumMoveSpeed@` 随英雄等级插值、`@BonusArmorTooltip@` 要实时护甲）
 *    ——这两类故意不进表，用来验证「填不上时保留原文并说明原因」；
 *  - 没有数值的纯位置标记（`@SpellModifierDescriptionAppend@`）。
 *
 * ⚠️ 真实取值来自 CommunityDragon，而**预览是离线**的：真机上这一步会走公网，
 * 连不上时整条命令报错、前端退回「全部占位符原样保留」。fixture 给的是
 * 「公网能连上」的分支，别把这里当成「这一项一定拿得到」。
 */
export function createFixtureChampionAbilityValues(alias: string): ChampionAbilityValues {
  return {
    alias,
    spells: [
      { slot: "p", values: { PBonusDamage: { values: [10, 20, 30, 40, 50] } } },
      {
        slot: "q",
        values: {
          PowerBallDamage: { values: [40, 80, 120, 160, 200, 240, 280], ratio: 1, ratioStat: "AP" },
          RollDuration: { values: [6, 6, 6, 6, 6, 6, 6] },
          SlowPercent: { values: [30, 40, 50, 60, 70, 80, 90] },
          // 客户端文案写 `@AOEModifier*100@%`：原始值 0.5，`percent` 为真。
          // 预览里能同时验到「*100 表达式」与「百分号只出现一次」。
          AOEModifier: { values: [0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5], percent: true },
        },
      },
      {
        slot: "w",
        values: {
          BuffDuration: { values: [6, 6, 6, 6, 6] },
          // 加成抗性随装备/符文变，真实数据里**就是没有**基础值——这里也不给。
        },
      },
      { slot: "e", values: { Duration: { values: [1.25, 1.5, 1.75, 2, 2.25] } } },
      {
        slot: "r",
        values: {
          InitialDamage: { values: [100, 175, 250], ratio: 0.6, ratioStat: "AP" },
          SlowDuration: { values: [3, 3, 3] },
          // `@SlowAmount*100@%`——同样是分数口径。
          SlowPercent: { values: [0.4, 0.5, 0.6], percent: true },
        },
      },
    ],
  };
}


const fixtureEncounterPlayers = [...fixtureLobby.ally.slice(1), ...fixtureLobby.enemy];
export const fixtureEncounters: EncounterRecord[] = Array.from({ length: 3 }, (_, gameIndex) => {
  // 必须和 `fixtureMatches` 对齐同一局：同 id、同时间、同胜负。
  // 否则历史页「最近对局」里那句「这局是跟谁打的」永远 join 不上，
  // 预览里清一色显示「未记录」——看起来像功能没做，其实是 fixture 各说各话。
  const game = fixtureMatches[gameIndex];
  const selfWin = game.result === "胜利";
  return fixtureEncounterPlayers.map((player, playerIndex) => {
    const side = fixtureLobby.ally.some((member) => member.puuid === player.puuid) ? "ally" : "enemy";
    return {
      gameId: game.gameId,
      queueId: 420,
      queueName: "单双排",
      selfPuuid: fixtureLobby.ally[0].puuid,
      selfGameName: fixtureLobby.ally[0].gameName,
      selfTagLine: fixtureLobby.ally[0].tagLine,
      selfChampionId: fixtureLobby.ally[0].championId,
      selfChampionName: fixtureLobby.ally[0].championName,
      selfPosition: fixtureLobby.ally[0].assignedPosition,
      selfKills: 8 - gameIndex,
      selfDeaths: 2 + gameIndex,
      selfAssists: 7 + gameIndex,
      selfWin,
      puuid: player.puuid,
      gameName: player.gameName,
      tagLine: player.tagLine,
      championId: player.championId,
      championName: player.championName,
      side,
      position: player.assignedPosition,
      result: selfWin ? "胜利" : "失败",
      kills: 3 + ((playerIndex + gameIndex) % 7),
      deaths: 2 + ((playerIndex + gameIndex) % 5),
      assists: 5 + ((playerIndex * 2 + gameIndex) % 9),
      win: side === "ally" ? selfWin : !selfWin,
      encounteredAt: game.playedAt,
    };
  });
}).flat();

export const fixtureBpHistory: FinalBpRecord[] = Array.from({ length: 4 }, (_, index) => ({
  id: `fixture-bp-${index}`, queueId: 420, gameMode: "单双排",
  allyChampionIds: champions.slice(0, 5).map((item) => item[0]),
  allyChampions: champions.slice(0, 5).map((item) => item[1]), enemyChampions: champions.slice(5).map((item) => item[1]),
  enemyChampionIds: champions.slice(5).map((item) => item[0]),
  allyScore: 78.4 - index, enemyScore: 73.2 + index, aiSummary: null,
  createdAt: new Date(now - index * 2 * 86400000).toISOString(),
}));

export const fixtureFriends: FriendToolsSnapshot = {
  groups: [
    { id: 1, name: "**Default", priority: 10 },
    { id: 2, name: "双排", priority: 20 },
  ],
  friends: [
    { id: "friend-1", puuid: "friend-puuid-1", summonerId: 101, gameName: "河道观察者", gameTag: "233", icon: 3494, groupId: 2, availability: "chat", gameStatus: "", canSpectate: false, friendsSince: new Date(now - 420 * 86400000).toISOString(), lastGameAt: new Date(now - 5 * 3600000).toISOString() },
    { id: "friend-2", puuid: "friend-puuid-2", summonerId: 102, gameName: "狐狸收藏家", gameTag: "MID", icon: 29, groupId: 1, availability: "dnd", gameStatus: "ingame", canSpectate: true, friendsSince: new Date(now - 730 * 86400000).toISOString(), lastGameAt: new Date(now - 2 * 86400000).toISOString() },
    { id: "friend-3", puuid: "friend-puuid-3", summonerId: 103, gameName: "灯笼点一下", gameTag: "SUP", icon: 7, groupId: 1, availability: "offline", gameStatus: "", canSpectate: false, friendsSince: null, lastGameAt: null },
  ],
};

/**
 * 「好友回收站」的浏览器预览样本。
 *
 * 形状与后端 `lol.get_deleted_friends` 一致（本地 SQLite 里的存档，按删除时间新的在前）。
 * 给两条：一条是「删错了想加回来」的典型（有完整名字#标签），一条是名字里带空格/符号的，
 * 用来看长名字会不会把布局撑坏。**必须留样本**——否则这块界面在预览里永远是空的。
 */
export const fixtureDeletedFriends: DeletedFriendsSnapshot = {
  friends: [
    { id: "deleted-1", puuid: "deleted-puuid-1", summonerId: 201, gameName: "手滑删掉的队友", gameTag: "HN1", icon: 3494, groupId: 1, deletedAt: new Date(now - 36 * 3600000).toISOString() },
    { id: "deleted-2", puuid: "deleted-puuid-2", summonerId: 202, gameName: "Long Name 空格", gameTag: "233", icon: 29, groupId: 2, deletedAt: new Date(now - 9 * 86400000).toISOString() },
  ],
};

/**
 * 「一键启动客户端」的浏览器预览样本。
 *
 * 真机上入口是扫盘 / 读 Riot 安装清单扫出来的，行数和盘符有关。这里给三个典型入口
 * （腾讯系两个 + 官方一个），就是为了让「下拉切换」这条分支在预览里也看得见。
 */
export const fixtureClientInstallations: ClientInstallations = {
  entries: [
    { id: "tcls", label: "英雄联盟（腾讯登录器）", detail: "WeGameApps 扫盘", path: "D:\\WeGameApps\\英雄联盟\\Launcher\\Client.exe" },
    { id: "wegame-launcher", label: "英雄联盟（WeGame 启动）", detail: "WeGameApps 扫盘", path: "D:\\WeGameApps\\英雄联盟\\WeGameLauncher\\launcher.exe" },
    { id: "riot-client", label: "Riot 客户端", detail: "Riot 安装清单", path: "C:\\Riot Games\\Riot Client\\RiotClientServices.exe" },
  ],
};

/**
 * 「一键领取」（现挂在自动化页）的浏览器预览样本。
 *
 * 形状与后端 `lol.get_claims` 一致（三个来源各来一两条），**不参与任何真实统计**；
 * 预览里领一条就少一条，方便看「领空之后」的样子。
 */
/**
 * 预览用的奖励图标。
 *
 * 用内联 SVG 而不是去 CommunityDragon 拉真图：预览环境经常没有外网，真图拉不到就
 * 只剩兜底字形，反而看不出「有图标」这个分支。真实运行时这里来自 LCU 的 iconUrl。
 */
const fixtureRewardIcon = `data:image/svg+xml,${encodeURIComponent(
  '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" fill="#2c2f4a"/><path d="M32 7 45 27 32 57 19 27Z" fill="#b98bff"/><path d="M32 7 45 27H19Z" fill="#e8dcff"/></svg>',
)}`;

export const fixtureClaims: ClaimSnapshot = {
  items: [
    // 三条分支各来一份：真图标 / LCU 路径（拉不到就回退 CDragon）/ 完全没有图标。
    { key: "mission:fixture-1", source: "mission", sourceLabel: "任务", id: "fixture-1", title: "峡谷日常", detail: "蓝色精粹 500", iconUrl: null, count: 1 },
    { key: "mission:fixture-2", source: "mission", sourceLabel: "任务", id: "fixture-2", title: "今日首胜", detail: "钥匙 1", iconUrl: null, count: 1 },
    { key: "reward:fixture-3", source: "reward", sourceLabel: "奖励", id: "fixture-3", title: "自选皮肤碎片", detail: "皮肤碎片 A · 皮肤碎片 B", iconUrl: fixtureRewardIcon, count: 1 },
    { key: "event:fixture-4", source: "event", sourceLabel: "事件中心", id: "fixture-4", title: "灵魂莲华", detail: "奖励轨道待领 3 项", iconUrl: "/lol-game-data/assets/v1/champion-icons/64.png", count: 3 },
  ],
  sources: [
    { source: "mission", label: "任务", count: 2 },
    { source: "reward", label: "奖励", count: 1 },
    { source: "event", label: "事件中心", count: 1 },
  ],
  total: 4,
};

export const fixtureConfig: AppConfig = {
  version: 25,
  appearance: { theme: "mint", colorMode: "light", compact: false },
  playerTags: { ...defaultPlayerTagSettings },
  connection: { kind: "local", sshTarget: "", identityFile: "", forwardedPort: 0 },
  automation: {
    enabled: true,
    advisoryMode: false,
    autoAccept: true,
    autoAcceptDelaySeconds: 3,
    autoPick: false,
    autoPickDelaySeconds: 1,
    autoPickStrategy: "show-and-lock-in",
    autoBan: false,
    pickChampionIds: [103, 222, 64],
    banChampionIds: [164, 7, 145],
    aramGrab: true,
    aramChampionIds: [64, 222, 103],
    aramSwapDelaySeconds: 3,
    shortcutSendIntervalMs: 65,
    shortcutRecentGameCount: 5,
    shortcuts: [
      { id: "encounter", label: "发送遇到记录", key: "Ctrl+F5", target: "encounter", template: "{encounter}", enabled: true },
      { id: "premade", label: "发送已知组队", key: "Ctrl+F9", target: "premade", template: "{position} {name}：组队 {premade}，近10场 {recent_wins}胜{recent_losses}负", enabled: true },
      { id: "jungle-preference", label: "发送打野偏好", key: "Ctrl+F7", target: "jungle", template: "{name}：{jungle_preference}", enabled: true },
      { id: "enemy", label: "发送敌方评估", key: "Ctrl+F11", target: "enemy", template: "{team}{position} {current_champion}：{rank} 主玩{main_position} {recent_wins}胜{recent_losses}负，{recent_games}", enabled: true },
      { id: "ally", label: "发送我方评估", key: "Ctrl+F12", target: "ally", template: "{team}{position} {current_champion}：{rank} 主玩{main_position} {recent_wins}胜{recent_losses}负，{recent_games}", enabled: true },
      { id: "open-game", label: "打开对局速看", key: "Ctrl+F1", target: "lobby", template: "对局速看：{team} {name}，近10场 {recent_wins}胜{recent_losses}负，KDA {kda}", enabled: true },
    ],
  },
  providers: { statsProvider: "auto", requestTimeoutSeconds: 6, cacheTtlMinutes: 120, hideUnfinishedMatches: false, rankedOnly: false, clearLobbyAfterGame: true, lobbyRoster: true, recording: { enabled: false, intervalSeconds: 5, retentionDays: 30 } },
  ai: { enabled: false, provider: "deepseek", protocol: "openai", baseUrl: "https://api.deepseek.com", model: "deepseek-v4-flash", apiKey: "", automaticPregameAnalysis: false },
};

export const fixtureBootstrap: AppBootstrap = {
  dataMode: "fixture",
  dashboard: {
    connection: {
      status: "disconnected", phase: "Fixture", summonerName: "测试召唤师", gameName: "测试召唤师", tagLine: "HN1", puuid: "fixture-ally-0",
      summonerLevel: 416, profileIconId: 3494, platformId: "HN1", region: "峡谷之巅 / HN1", presence: "online",
      soloRank: { queueType: "RANKED_SOLO_5x5", tier: "SILVER", division: "IV", leaguePoints: 26, wins: 10, losses: 16 },
      flexRank: { queueType: "RANKED_FLEX_SR", tier: "GOLD", division: "II", leaguePoints: 43, wins: 193, losses: 169 },
      queueLabel: "单双排", message: "正在使用内置测试数据", checkedAt: new Date(now).toISOString()
    },
    recentMatches: fixtureMatches.slice(0, 5), recentEncounters: fixtureEncounters.slice(0, 3), patch: "26.16", cachedChampions: fixtureChampions.length,
  },
  configPath: "~/.lol_desktop/config.jsonc",
  databasePath: "~/.lol_desktop/lol-desktop.sqlite3",
  appDataPath: "~/.lol_desktop",
  appVersion: "3.0.0",
};

/**
 * 打野路线图 fixture（只服务浏览器预览）。
 *
 * 原生侧这份数据来自逐帧解析 SGP DETAILS，没有原生桥就取不到；这里造一份
 * 「形状对、随玩家变化、同一个人每次刷新都一样」的样本，让浏览器预览也能看到
 * 路线图。**不参与任何统计口径**，结论都不应该引用这里的数字。
 *
 * 构造规则：
 * - 场次一半算蓝方（`blueGames`）、一半算红方；
 * - 起始营地按 puuid 哈希在蓝 Buff / 红 Buff 之间二选一，占多数场次，其余算入侵开
 *   ——入侵那一组要落到**对面半区**的营地，理由见 `live/gameMap.ts` 的 `clearCountsAt`；
 * - 每分钟一个落点，沿「自家野区 → 河道 → 边路」推进，再叠一点确定性抖动；
 * - 3 级抓 / 4 级抓各取一部分场次，落点在自家野区到河道之间。
 */
export function createFixtureJunglePath(puuid: string, gameIds: number[]): JunglePathMap {
  const games = Math.max(1, gameIds.length);
  const seed = [...puuid].reduce((sum, char) => sum + char.charCodeAt(0), 0) + games;
  const blueGames = Math.ceil(games / 2);
  const redGames = games - blueGames;
  const startBlue = seed % 3 !== 0;
  const ownCamp: JungleCamp = startBlue ? "blue" : "red";
  // 入侵只留一场、且只给一侧：跑对面半区的四鬼（蓝开时）/ 三狼（红开时）。
  // 只给一侧是为了让「入侵描边」在图上只出现一处，肉眼一看就知道落在哪个半区。
  const invadeCamp: JungleCamp = startBlue ? "raptors" : "wolves";
  const zero = (): JungleCampCounts => ({ blue: 0, red: 0, wolves: 0, raptors: 0 });
  const split = (total: number, invade: boolean) => {
    const invadeGames = invade && total > 3 ? 1 : 0;
    return { own: total - invadeGames, invade: invadeGames };
  };
  const blue = split(blueGames, seed % 2 === 0);
  const red = split(redGames, seed % 4 === 0);
  const camps = { blueOwn: zero(), blueInvade: zero(), redOwn: zero(), redInvade: zero() };
  camps.blueOwn[ownCamp] = blue.own;
  camps.blueInvade[invadeCamp] = blue.invade;
  camps.redOwn[ownCamp] = red.own;
  camps.redInvade[invadeCamp] = red.invade;

  // 起始半区决定走向：蓝方半区靠下路，红方半区靠上路。游戏坐标，y 轴与地图相反。
  const route: [number, number, JungleZone][] = startBlue
    ? [[3830, 7880, "bot"], [3800, 6440, "bot"], [6970, 5460, "mid"], [7760, 4010, "mid"], [11200, 2600, "bot"]]
    : [[10990, 7000, "top"], [11020, 8440, "top"], [7850, 9420, "mid"], [7060, 10870, "mid"], [3200, 12000, "top"]];
  const minutePoints: JunglePathPoint[] = [];
  const gankPoints: JunglePathPoint[] = [];
  const level3Points: JunglePathPoint[] = [];
  const level4Points: JunglePathPoint[] = [];
  for (let game = 0; game < games; game += 1) {
    for (let minute = 0; minute < 14; minute += 1) {
      const [x, y, zone] = route[Math.min(route.length - 1, Math.floor(minute / 3))];
      const jitter = ((seed + game * 7 + minute * 13) % 25) - 12;
      minutePoints.push({ x: x + jitter * 45, y: y + jitter * 45, zone });
    }
    const lane = route[4];
    gankPoints.push({ x: lane[0] - game * 90, y: lane[1] + game * 110, zone: lane[2] });
    if (game % 2 === 0) level3Points.push({ x: route[1][0], y: route[1][1], zone: route[1][2] });
    level4Points.push({ x: route[2][0], y: route[2][1], zone: route[2][2] });
  }

  const tally: Record<JungleZone, number> = { top: 0, mid: 0, bot: 0 };
  for (const point of minutePoints) tally[point.zone] += 1;
  const zone = { top: 0, mid: 0, bot: 0 } as Record<JungleZone, number>;
  for (const key of Object.keys(tally) as JungleZone[]) zone[key] = tally[key] / minutePoints.length;

  return {
    games,
    championId: 0,
    zone,
    camps,
    level3: level3Points.length,
    level4: level4Points.length,
    blueGames,
    redGames,
    minutePoints,
    gankPoints,
    level3Points,
    level4Points,
  };
}

/**
 * 预览用的对局时间线。
 *
 * 真机上这份数据来自 LCU 的 `game-timelines`，预览里没有客户端，所以按 gameId 造一份
 * **确定但会随对局变化**的数据：经济曲线带一次翻盘拐点，事件列表覆盖四类关键事件。
 * 不补这个 fixture，「对局时间线」页签在预览里永远是空的。
 */
/** 十项全 0：`frameDamage: false` 时冒充「客户端帧里没有伤害字段」。每次给一份新的，
 *  免得所有帧共享同一个数组（下游哪怕只是排序/切片也容易被连带影响）。 */
const zeroFrameValues = () => Array.from({ length: 10 }, () => 0);

export function createFixtureMatchTimeline(gameId: number, options: { frameDamage?: boolean; selfTeam?: number } = {}): MatchTimeline {
  const seed = Math.abs(Math.trunc(gameId)) % 997;
  const minutes = 24 + (seed % 14);
  const durationSeconds = minutes * 60;
  // 谁笑到最后由 gameId 决定，这样不同对局的曲线不会长得一模一样。
  const blueEdge = seed % 2 === 0 ? 1 : -1;
  /**
   * 主视角所在的绝对阵营。座位 1..5 是**主视角那一队**（roster 前五个按 ally 取），
   * 所以它们的 `team` 就是这个值，不是写死的 100——真机红方局里正是这个不一致
   * 让「拿 side 配座位」全线配空。帧里的 `blueGold` / `blueCs` 是**绝对颜色**，
   * 主视角在红方时必须取后五个座位，不能再默认前五个是蓝。
   */
  const selfTeam = options.selfTeam ?? TEAM_BLUE;
  const otherTeam = selfTeam === TEAM_BLUE ? TEAM_RED : TEAM_BLUE;
  const alliesAreBlue = selfTeam === TEAM_BLUE;
  // 英雄目录必须与「十人详情」（`fixtureMatches`）同一份：观战面板按「英雄 + 阵营」
  // 配对入座，各写各的就会出现「剑魔没有名字、没有装备」这种配对失败的空行（真踩过）。
  const match = createFixtureMatchDetail(gameId, { selfTeam });
  const roster = match
    ? [...match.participants.filter((player) => player.side === "ally"), ...match.participants.filter((player) => player.side === "enemy")].map((player) => player.championId)
    : champions.map(([id]) => id);
  const participants: MatchTimelineParticipant[] = roster.map((championId, index) => ({
    participantId: index + 1,
    team: index < 5 ? selfTeam : otherTeam,
    championId,
  }));
  /** 座位号 → 英雄 id。事件的英雄**一律由座位号推**，不手写。 */
  const championOf = (participantId: number) => roster[participantId - 1] ?? 0;

  // 座位（每队 0..4）固定对应 上/野/中/下/辅：经济速率、分均伤害、升级快慢都按它来，
  // 预览才不会出现「辅助比 C 位有钱」「打野等级全场最高」这种一眼假。
  const LANE_RATES = [
    { gold: 385, damage: 780, taken: 640, level: 0.66 }, // 上（前排，承伤最高）
    { gold: 360, damage: 620, taken: 560, level: 0.6 }, // 野
    { gold: 400, damage: 950, taken: 520, level: 0.66 }, // 中
    { gold: 405, damage: 1000, taken: 480, level: 0.64 }, // 下
    { gold: 235, damage: 380, taken: 440, level: 0.5 }, // 辅
  ] as const;

  /**
   * 每个座位的「个人状态」系数（输出 / 承伤各一组，±8%），按 (局号, 座位) 确定性生成。
   *
   * 少了它，两队同位置的分均速率完全一样（都是 `LANE_RATES[index % 5]`），对线期一擦游标
   * 就会看到**双方出现一模一样的伤害数字**（6746 / 6408 / 4182…），实时伤害榜两列长得像
   * 复制粘贴，一眼假数据。幅度刻意收在 ±8%：再大就会盖过相邻位置之间本来就只差 5%
   * （中 950 / 下 1000）的差距，把「下路 > 中路 > 上单 > 打野 > 辅助」的顺序翻掉。
   */
  const formOut = Array.from({ length: 10 }, (_, index) => 0.92 + ((seed + index * 37) % 17) / 100);
  const formIn = Array.from({ length: 10 }, (_, index) => 0.93 + ((seed + index * 53) % 15) / 100);

  /**
   * 几个点位的近似坐标（mapId 11 的 `0..14820 × 0..14881` 域，取自 `live/gameMap.ts`
   * 的营地坐标与真实点位）。有了它们，预览里「这波团打在哪」才会落在图上说得通的位置
   * ——蓝方基地在**左下**、红方在**右上**，y 轴越大地图越靠上。
   */
  const spot = {
    mid: { x: 7400, y: 7400 },
    dragon: { x: 9866, y: 4410 },
    baron: { x: 5000, y: 9900 },
    blueTop: { x: 1600, y: 11300 },
    redBot: { x: 13200, y: 3400 },
  };

  const timelineEvent = (
    base: Pick<MatchTimelineEvent, "type" | "seconds" | "team"> & Partial<MatchTimelineEvent>,
  ): MatchTimelineEvent => {
    const event: MatchTimelineEvent = {
      killerId: 0,
      victimId: 0,
      assistCount: 0,
      // 助攻名单与位置是「每波团」的地基（`matches/teamfights.ts`）。fixture 必须一起给，
      // 否则预览里团战永远聚不出来——看不到的效果等于没做。
      assistIds: [],
      killerChampionId: 0,
      victimChampionId: 0,
      posX: 0,
      posY: 0,
      monsterType: "",
      monsterSubType: "",
      buildingType: "",
      towerType: "",
      laneType: "",
      ...base,
    };
    // 英雄 id 由座位号推出来，**不手写**：手写迟早会和 participants 对不上，
    // 而那种错在界面上只表现为「英雄 #24」，很难一眼看出是 fixture 的问题。
    if (!event.killerChampionId && event.killerId > 0) event.killerChampionId = championOf(event.killerId);
    if (!event.victimChampionId && event.victimId > 0) event.victimChampionId = championOf(event.victimId);
    return event;
  };

  // 脚本时间点固定，靠 `filter` 按这局的实际时长裁掉没打到的部分。
  //
  // 三波团是**刻意设计**的（604 / 1188 / 1450 秒，都在最短一局 24 分钟之内，
  // 所以每局预览都至少能看到一波）：
  //   ① 中路   蓝 3 : 1 红，1 号拿下三杀
  //   ② 红方下路 蓝 1 : 2 红（这波红方赢，避免团战全都是蓝方赢）
  //   ③ 大龙坑 蓝 3 : 0 红
  // 232 秒那次单杀**不算团战**（1 换 1、参与者 2 人），正好当反例。
  const events: MatchTimelineEvent[] = [
    timelineEvent({ type: "CHAMPION_KILL", seconds: 232, team: 200, killerId: 6, victimId: 1, ...spot.blueTop }),
    timelineEvent({ type: "TURRET_PLATE_DESTROYED", seconds: 341, team: 200, killerId: 7, laneType: "TOP_LANE", ...spot.blueTop }),
    timelineEvent({ type: "ELITE_MONSTER_KILL", seconds: 352, team: 100, killerId: 2, monsterType: "DRAGON", monsterSubType: "FIRE_DRAGON", ...spot.dragon }),
    timelineEvent({ type: "BUILDING_KILL", seconds: 528, team: 200, killerId: 7, buildingType: "TOWER_BUILDING", towerType: "OUTER_TURRET", laneType: "TOP_LANE", ...spot.blueTop }),
    // ① 中路团：1 号三杀
    timelineEvent({ type: "CHAMPION_KILL", seconds: 604, team: 100, killerId: 1, victimId: 8, assistCount: 2, assistIds: [2, 3], posX: 7250, posY: 7350 }),
    timelineEvent({ type: "CHAMPION_KILL", seconds: 609, team: 100, killerId: 1, victimId: 6, assistCount: 1, assistIds: [3], posX: 7400, posY: 7400 }),
    timelineEvent({ type: "CHAMPION_KILL", seconds: 614, team: 100, killerId: 1, victimId: 7, assistCount: 2, assistIds: [2, 4], posX: 7520, posY: 7460 }),
    timelineEvent({ type: "CHAMPION_KILL", seconds: 619, team: 200, killerId: 8, victimId: 3, assistCount: 1, assistIds: [6], posX: 7480, posY: 7290 }),
    timelineEvent({ type: "ELITE_MONSTER_KILL", seconds: 660, team: 100, killerId: 2, monsterType: "RIFTHERALD", ...spot.baron }),
    timelineEvent({ type: "BUILDING_KILL", seconds: 902, team: 100, killerId: 1, buildingType: "TOWER_BUILDING", towerType: "OUTER_TURRET", laneType: "MID_LANE", ...spot.mid }),
    timelineEvent({ type: "ELITE_MONSTER_KILL", seconds: 968, team: 200, killerId: 6, monsterType: "DRAGON", monsterSubType: "OCEAN_DRAGON", ...spot.dragon }),
    // ② 红方下路团（这波红方赢）
    timelineEvent({ type: "CHAMPION_KILL", seconds: 1188, team: 200, killerId: 8, victimId: 4, assistCount: 2, assistIds: [9, 10], posX: 13100, posY: 3450 }),
    timelineEvent({ type: "CHAMPION_KILL", seconds: 1196, team: 200, killerId: 9, victimId: 2, assistCount: 1, assistIds: [8], posX: 13250, posY: 3380 }),
    timelineEvent({ type: "CHAMPION_KILL", seconds: 1204, team: 100, killerId: 3, victimId: 9, assistCount: 2, assistIds: [1, 4], posX: 13340, posY: 3520 }),
    timelineEvent({ type: "BUILDING_KILL", seconds: 1264, team: 100, killerId: 3, buildingType: "TOWER_BUILDING", towerType: "INNER_TURRET", laneType: "MID_LANE", ...spot.mid }),
    timelineEvent({ type: "ELITE_MONSTER_KILL", seconds: 1288, team: 100, killerId: 2, monsterType: "BARON_NASHOR", ...spot.baron }),
    // ③ 大龙坑团（蓝方 3 : 0，2 号双杀）
    timelineEvent({ type: "CHAMPION_KILL", seconds: 1450, team: 100, killerId: 1, victimId: 6, assistCount: 2, assistIds: [2, 3], posX: 5050, posY: 9850 }),
    timelineEvent({ type: "CHAMPION_KILL", seconds: 1454, team: 100, killerId: 2, victimId: 7, assistCount: 1, assistIds: [1], posX: 4920, posY: 9960 }),
    timelineEvent({ type: "CHAMPION_KILL", seconds: 1458, team: 100, killerId: 2, victimId: 8, assistCount: 2, assistIds: [1, 3], posX: 5180, posY: 10080 }),
    timelineEvent({ type: "BUILDING_KILL", seconds: 1502, team: 100, killerId: 4, buildingType: "INHIBITOR_BUILDING", laneType: "MID_LANE", ...spot.mid }),
    timelineEvent({ type: "ELITE_MONSTER_KILL", seconds: 1596, team: 100, killerId: 2, monsterType: "DRAGON", monsterSubType: "ELDER_DRAGON", ...spot.dragon }),
    timelineEvent({ type: "BUILDING_KILL", seconds: 1810, team: 100, killerId: 5, buildingType: "TOWER_BUILDING", towerType: "BASE_TURRET", laneType: "MID_LANE", ...spot.mid }),
  ]
    .filter((item) => item.seconds <= durationSeconds)
    // 事件里的 `team` 是「做事的一方」的**绝对阵营**。上面那串时间点全是按
    // 「座位 1..5 = 蓝方」写的（看 killerId 就知道），主视角在红方时整体翻转；
    // 不翻的话击杀记录会整片挂到对手那边。
    .map((item) => ({ ...item, team: item.team === TEAM_BLUE ? selfTeam : otherTeam }));

  // 击杀（含三波团）的伤害爆点：累计进「事发分钟」的帧里，这样「团后帧 − 团前帧」
  // 就是这波团每人实际打了多少伤害——「每波团」伤害柱状图的原料。
  const damageBursts = Array.from({ length: 10 }, () => 0);
  const takenBursts = Array.from({ length: 10 }, () => 0);
  const burstAt = (participantId: number, minute: number, kind: "damage" | "taken") => {
    let burst = 0;
    for (const event of events) {
      if (event.type !== "CHAMPION_KILL" || Math.ceil(event.seconds / 60) !== minute) continue;
      // 打出伤害的是击杀方与助攻方，挨打的是被击杀的那个——两个指标刚好互补。
      if (event.killerId === participantId) burst += kind === "damage" ? 1500 : 700;
      if (event.victimId === participantId) burst += kind === "damage" ? 800 : 1400;
      if (event.assistIds.includes(participantId)) burst += kind === "damage" ? 600 : 500;
    }
    return burst;
  };

  /**
   * 走位锚点（mapId 11 的 `0..14820 × 0..14881` 域，蓝方基地在**左下**、红方在右上）。
   * 每条分路一条「对线期守自己路、中期开始向中路/资源区靠」的确定性轨迹，加一点
   * 正弦抖动——上一版十个人全绕中路随机晃，预览里一眼假。
   */
  const laneAnchor = (slot: number, ramp: number, blue: boolean) => {
    const roam = Math.max(0, (ramp - 0.5) / 0.5); // 0 = 对线期 → 1 = 终局抱团
    const anchors = [
      { x: 2600, y: 12400 }, // 上
      { x: 4200, y: 9600 }, // 野（基准点，下面再叠加绕圈）
      { x: 6900, y: 7900 }, // 中
      { x: 12300, y: 2700 }, // 下
      { x: 11800, y: 3200 }, // 辅
    ];
    const anchor = anchors[slot] ?? anchors[2];
    const mid = { x: 7400, y: 7400 };
    const x = anchor.x + (mid.x - anchor.x) * roam * 0.6;
    const y = anchor.y + (mid.y - anchor.y) * roam * 0.6;
    return blue ? { x, y } : { x: 14820 - x, y: 14881 - y };
  };

  const frames: MatchTimelineFrame[] = [];
  for (let minute = 1; minute <= minutes; minute += 1) {
    const ramp = minute / minutes;
    // 开局 35% 后领先方开始滚雪球：一侧速率加成、一侧衰减，曲线平滑交叉一次。
    const swing = Math.max(0, (ramp - 0.35) / 0.65);
    // ⚠️ 必须是 **10 项**（participantId 1..10 各一项）——`MatchTimelineFrame.gold`
    // 的契约就是十项。曾经写成 5 项，红方五人的金币全是 0，预览像坏了。
    const gold = Array.from({ length: 10 }, (_, index) => {
      const lane = LANE_RATES[index % 5];
      const side = index < 5 ? 1 : -1;
      return Math.round((500 + lane.gold * minute) * (1 + blueEdge * side * swing * 0.1));
    });
    // `blueGold` / `redGold` 是**绝对颜色**的队总经济：座位 1..5 是主视角那一队，
    // 主视角在红方时它们才是红队的钱。
    const blueGold = (alliesAreBlue ? gold.slice(0, 5) : gold.slice(5)).reduce((sum, value) => sum + value, 0);
    const redGold = (alliesAreBlue ? gold.slice(5) : gold.slice(0, 5)).reduce((sum, value) => sum + value, 0);
    for (let id = 1; id <= 10; id += 1) {
      damageBursts[id - 1] += burstAt(id, minute, "damage");
      takenBursts[id - 1] += burstAt(id, minute, "taken");
    }
    const level = Array.from({ length: 10 }, (_, index) => Math.min(18, 1 + Math.floor(minute * LANE_RATES[index % 5].level)));
    // `frameDamage: false` = **真机形状**：客户端（TENCENT 客户端实测）的分钟帧里只有
    // 金币 / 等级 / 补刀 / 位置，逐分钟伤害字段压根不存在。默认 true 保留「有伤害」那
    // 一路，是为了让「到此刻累计」这条路径在预览与单测里仍然可走；真机形状用
    // `?frameDamage=0` 打开（见 `services/browserBackend.ts`）。
    const damage = options.frameDamage === false
      ? zeroFrameValues()
      : Array.from({ length: 10 }, (_, index) => Math.round(LANE_RATES[index % 5].damage * minute * (1 + 0.15 * ramp) * formOut[index]) + damageBursts[index]);
    const taken = options.frameDamage === false
      ? zeroFrameValues()
      : Array.from({ length: 10 }, (_, index) => Math.round(LANE_RATES[index % 5].taken * minute * (1 + 0.12 * ramp) * formIn[index]) + takenBursts[index]);
    const positions = Array.from({ length: 10 }, (_, index) => {
      // 第三个参数是「蓝方基地在左下」的那套坐标；座位 1..5 是主视角那一队，
      // 所以 `blue` 得看主视角在不在蓝方，不能恒等于 `index < 5`。
      const anchor = laneAnchor(index % 5, ramp, (index < 5) === alliesAreBlue);
      const jitter = Math.sin(minute * 2.1 + index * 3.7) * 380;
      // 打野在对线期也按半区绕圈，不能钉在一个点上。
      const jungleWander = index % 5 === 1 && ramp < 0.55 ? Math.sin(minute * 0.9) * 2400 : 0;
      return { x: Math.round(anchor.x + jitter + jungleWander), y: Math.round(anchor.y - jitter * 0.7 + jungleWander * 0.5) };
    });
    frames.push({
      minute,
      blueGold,
      redGold,
      goldDiff: blueGold - redGold,
      // 基数 1 不能动，翻转的只是「领先方雪球」那一项的方向。
      blueCs: Math.round(minute * 31.5 * (1 + (alliesAreBlue ? 1 : -1) * blueEdge * swing * 0.06)),
      redCs: Math.round(minute * 31.5 * (1 - (alliesAreBlue ? 1 : -1) * blueEdge * swing * 0.06)),
      gold,
      level,
      damage,
      taken,
      positions,
    });
  }

  return { gameId, durationSeconds, participants, frames, events };
}

/**
 * 预览用的「本地录制」帧序列。
 *
 * 真机上这是**游戏进行中**每 N 秒（默认 5 秒，设置页可改）把本机 Live Client Data 采一帧
 * 存进 SQLite 的结果（见后端 `backend/game_recording.zig`）。预览里没有客户端，所以按同一
 * 份十人名单合成一份**确定性**的帧（不用随机数，否则每次刷新曲线都在跳，看着像坏了）。
 *
 * 默认回空帧——真机上新装的人、没开开关的人、或者不是本机在打的人，看到的正是
 * 「这一局没有录制」这条空状态，预览里必须能复现它，不能默认造一份假录制出来。
 */
export function createFixtureGameRecording(gameId: number, options: { selfTeam?: number; intervalSeconds?: number } = {}): GameRecording {
  const intervalSeconds = options.intervalSeconds ?? 5;
  const selfTeam = options.selfTeam ?? TEAM_BLUE;
  const otherTeam = selfTeam === TEAM_BLUE ? TEAM_RED : TEAM_BLUE;
  const match = createFixtureMatchDetail(gameId, { selfTeam });
  if (!match) return { gameId, intervalSeconds, recordedGames: 0, frames: [] };
  const roster = [
    ...match.participants.filter((player) => player.side === "ally"),
    ...match.participants.filter((player) => player.side === "enemy"),
  ].slice(0, 10);
  if (!roster.length) return { gameId, intervalSeconds, recordedGames: 0, frames: [] };

  const seed = Math.abs(Math.trunc(gameId)) % 997;
  const durationSeconds = Math.max(intervalSeconds, (match.durationMinutes || 28) * 60);
  /**
   * 每个座位一条「个人曲线」。
   *
   * 全程线性走到这一局的最终数据（补刀率、视野分率、阵亡时刻都由它推），再加一点按
   * (局号, 座位) 定的固定扰动——不加扰动十个人的曲线会整齐得像同一个模板。
   */
  const curves = roster.map((player, index) => {
    const lane = index % 5;
    const wobble = ((seed + index * 41) % 13) / 100;
    // 阵亡时刻：把人头均匀铺在整局里（第 n 个人头落在 (n + 0.6)/总数 处），
    // 这样游标扫过去能真的看到「有人躺了、倒计时在跳」。
    const deathTimes = Array.from({ length: Math.max(0, player.deaths) }, (_, nth) => (durationSeconds * (nth + 0.6 + wobble)) / Math.max(1, player.deaths));
    return {
      player,
      index,
      lane,
      wobble,
      csRate: [7.4, 6.1, 8.3, 8.7, 1.5][lane]! * (0.94 + wobble),
      wardRate: [0.35, 0.42, 0.28, 0.26, 0.85][lane]! * (0.9 + wobble),
      deathTimes,
      build: itemsFor(player.championName),
    };
  });

  const frames: GameRecordingFrame[] = [];
  for (let t = 0; t <= durationSeconds; t += intervalSeconds) {
    const progress = durationSeconds ? t / durationSeconds : 0;
    const players: GameRecordingPlayer[] = curves.map((curve) => {
      const { player, index, csRate, wardRate, deathTimes, build } = curve;
      const lvl = Math.min(18, 1 + Math.floor(t / (durationSeconds / 18.5)));
      const respawnSeconds = 6 + lvl * 1.3;
      const downAt = deathTimes.find((at) => t >= at && t < at + respawnSeconds);
      // 开局 12% 之前先不买东西：一级团就六神装看着太假。
      const itemCount = progress < 0.12 ? 0 : Math.min(build.length, 1 + Math.floor(progress * 6));
      return {
        puuid: player.puuid,
        rid: player.gameName,
        // Live Client 给的是 ORDER / CHAOS，不是 100 / 200。
        team: (player.team ?? (index < 5 ? selfTeam : otherTeam)) === TEAM_BLUE ? "ORDER" : "CHAOS",
        champ: player.championName,
        cid: player.championId,
        pos: player.position,
        lvl,
        k: Math.floor(player.kills * progress),
        d: deathTimes.filter((at) => at <= t).length,
        a: Math.floor(player.assists * progress),
        cs: Math.round(csRate * (t / 60)),
        ward: Math.round(wardRate * (t / 60)),
        dead: downAt !== undefined,
        respawn: downAt === undefined ? 0 : Math.round(downAt + respawnSeconds - t),
        bot: player.isBot,
        items: build.slice(0, itemCount).map((item) => item.id),
        spells: (player.summonerSpells ?? []).map((spell) => spell.name),
      };
    });
    const selfCurve = curves[0]!;
    const selfFrame = players[0]!;
    const maxHp = Math.round(620 + progress * 1560 + selfCurve.wobble * 300);
    frames.push({
      t,
      gameId,
      sampledAt: new Date(now + t * 1000).toISOString(),
      players,
      me: {
        rid: selfCurve.player.gameName,
        gold: Math.round(selfCurve.player.goldEarned * progress),
        lvl: selfFrame.lvl,
        ad: Math.round(58 + selfCurve.wobble * 40 + progress * 210),
        ap: Math.round(progress * 480 * (0.6 + selfCurve.wobble)),
        armor: Math.round(34 + progress * 96),
        mr: Math.round(32 + progress * 55),
        ms: 345 + (selfCurve.lane === 4 ? 0 : 10),
        hp: selfFrame.dead ? 0 : Math.round(maxHp * 0.72),
        maxHp,
      },
    });
  }
  // 造出了帧就说明「本机录过」，所以 `recordedGames` 至少是 1（这个数字是给
  // 「区分两种空」用的，不含在这一局里）。
  return { gameId, intervalSeconds, recordedGames: 1, frames };
}

/**
 * 预览用的「召唤师等级 / 段位」。
 *
 * 大厅那十个人本来就是同一批对局里的人，所以优先复用他们的等级与段位（值也和
 * 实时页一致）；不在大厅里的 puuid 按字符和造一份**稳定**的值——不能用随机数，
 * 否则每次刷新界面上的段位都在跳，看着像坏了。
 */
export function createFixturePlayerStats(puuids: string[]): PlayerStatSummary[] {
  const roster = [...fixtureLobby.ally, ...fixtureLobby.enemy];
  return puuids.map((puuid) => {
    const known = roster.find((player) => player.puuid === puuid);
    if (known) {
      return {
        puuid,
        summonerLevel: known.summonerLevel ?? null,
        soloRank: known.soloRank ?? null,
        flexRank: known.flexRank ?? null,
      };
    }
    const seed = [...puuid].reduce((sum, char) => sum + char.charCodeAt(0), 0);
    const tier = ["GOLD", "PLATINUM", "EMERALD", "DIAMOND"][seed % 4] ?? "GOLD";
    const division = ["I", "II", "III", "IV"][seed % 4] ?? "IV";
    return {
      puuid,
      summonerLevel: 120 + (seed % 400),
      soloRank: { queueType: "RANKED_SOLO_5x5", tier, division, leaguePoints: 10 + (seed % 90), wins: 40 + (seed % 60), losses: 35 + (seed % 50) },
      flexRank: null,
    };
  });
}
