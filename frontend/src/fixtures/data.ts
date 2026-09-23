import type {
  AppBootstrap,
  AppConfig,
  BanSummary,
  ChampionOverview,
  ClaimSnapshot,
  ClientInstallations,
  DeletedFriendsSnapshot,
  EncounterRecord,
  FriendToolsSnapshot,
  FinalBpRecord,
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
  RecentMatch,
  RuneSummary,
  SpellSummary,
  TeamSummary,
} from "../types/domain";
import { defaultPlayerTagSettings } from "../tags/settings";
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
  const names: Record<string, [string, number][]> = {
    "九尾妖狐": [["卢登的伙伴", 6655], ["影焰", 4645], ["法师之靴", 3020]],
    "发条魔灵": [["大天使之杖", 3003], ["灭世者的死亡之帽", 3089], ["法师之靴", 3020]],
    "诡术妖姬": [["火箭腰带", 3152], ["暗影烈焰", 4645], ["法师之靴", 3020]],
  };
  return (names[championName] ?? [["中娅沙漏", 3157], ["明朗之靴", 3158], ["灭世者的死亡之帽", 3089]]).map(([name, id]) => ({ id, name, iconUrl: `https://ddragon.leagueoflegends.com/cdn/16.16.1/img/item/${id}.png` }));
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
  const averageParticipation = matches.reduce((sum, match) => sum + match.killParticipation, 0) / matches.length;
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
  return value;
}

function matchParticipants(index: number, win: boolean): MatchParticipant[] {
  return champions.map(([championId, championName, , role], slot) => ({
    puuid: `match-${index}-player-${slot}`,
    gameName: slot < 5 ? `我方玩家${slot + 1}` : `敌方玩家${slot - 4}`,
    isBot: false,
    championId,
    championName,
    side: slot < 5 ? "ally" : "enemy",
    position: role,
    kills: slot === 2 ? 9 : 3 + ((slot + index) % 5),
    deaths: slot === 2 ? 2 : 4 + ((slot + index) % 4),
    assists: 5 + ((slot * 2 + index) % 9),
    damageDealt: 10500 + slot * 1100 + index * 200,
    damageTaken: 8500 + slot * 900 + index * 150,
    goldEarned: 10800 + slot * 420 + index * 190,
    cs: 125 + slot * 12 + index * 3,
    win: slot < 5 ? win : !win,
    items: itemsFor(championName),
    summonerSpells: spellsFor(slot + index),
    runes: runesFor(slot + index),
    heal: 1200 + slot * 90 + index * 20,
    damageShare: 0.12 + (slot % 5) * 0.035,
    damageTakenShare: 0.12 + ((slot + 2) % 5) * 0.03,
    killParticipation: 0.28 + ((slot + index) % 5) * 0.08,
    towerDamage: 700 + slot * 180 + index * 40,
    turretKills: slot % 3,
    wardsPlaced: 8 + slot * 2 + index,
    wardsKilled: 2 + (slot % 4),
    visionScore: 18 + slot * 4 + index,
    visionWardsBought: slot % 3,
    sightWardsBought: slot % 2,
  }));
}

const fixtureBanDetails: BanSummary[] = [
  { id: 164, name: "青钢影", iconUrl: "./fixtures/champions/Camille.png", side: "ally" },
  { id: 64, name: "盲僧", iconUrl: "./fixtures/champions/LeeSin.png", side: "ally" },
  { id: 157, name: "疾风剑豪", iconUrl: "./fixtures/champions/Yasuo.png", side: "ally" },
  { id: 84, name: "离群之刺", iconUrl: "./fixtures/champions/Akali.png", side: "enemy" },
  { id: 412, name: "魂锁典狱长", iconUrl: "./fixtures/champions/Thresh.png", side: "enemy" },
];

export const fixtureMatches: MatchSummary[] = ["九尾妖狐", "发条魔灵", "诡术妖姬", "岩雀", "九尾妖狐", "辛德拉", "九尾妖狐", "阿卡丽", "九尾妖狐", "发条魔灵"].map((championName, index) => {
  const win = ![2, 5, 6, 9].includes(index);
  const championId = { "九尾妖狐": 103, "发条魔灵": 61, "诡术妖姬": 7, "岩雀": 163, "辛德拉": 134, "阿卡丽": 84 }[championName] ?? 103;
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
    participants: matchParticipants(index, win),
    bans: ["青钢影", "盲僧", "亚索", "阿卡丽", "锤石"],
    banDetails: fixtureBanDetails,
    playedAt: new Date(now - (index * 11 + 2) * 3600000).toISOString(),
    dataStatus: fixtureStatus(),
  };
});

export const fixtureChampions: ChampionOverview[] = champions.map(([id, name, alias, role], index) => ({
  id, name, alias, abilities: ["被动技能", "技能 Q", "技能 W", "技能 E", "技能 R"], roles: [role], tier: index < 3 ? "S" : index < 7 ? "A" : "B",
  winRate: 0.485 + (index % 6) * 0.009, pickRate: 0.032 + (10 - index) * 0.004, banRate: 0.018 + index * 0.006, kda: 2.1 + index * 0.17,
  iconUrl: `./fixtures/champions/${alias}.png`, baseSource: "fixture", statsSource: "fixture",
  statsRegion: "global", statsTier: "emerald_plus",
  dataStatus: fixtureStatus(),
}));

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
  version: 23,
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
  providers: { statsProvider: "auto", requestTimeoutSeconds: 6, cacheTtlMinutes: 120, hideUnfinishedMatches: false, rankedOnly: false, clearLobbyAfterGame: true, lobbyRoster: true },
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
  appVersion: "2.5.0",
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
export function createFixtureMatchTimeline(gameId: number): MatchTimeline {
  const seed = Math.abs(Math.trunc(gameId)) % 997;
  const minutes = 24 + (seed % 14);
  const durationSeconds = minutes * 60;
  // 谁笑到最后由 gameId 决定，这样不同对局的曲线不会长得一模一样。
  const blueEdge = seed % 2 === 0 ? 1 : -1;
  const champions = [64, 103, 12, 222, 99, 24, 105, 40, 1, 111];
  const participants: MatchTimelineParticipant[] = champions.map((championId, index) => ({
    participantId: index + 1,
    team: index < 5 ? 100 : 200,
    championId,
  }));

  // 队内经济分配：越靠前的座位越像 C 位，辅助拿最少。
  const goldShares = [0.24, 0.22, 0.21, 0.19, 0.14];
  const frames: MatchTimelineFrame[] = [];
  for (let minute = 1; minute <= minutes; minute += 1) {
    const ramp = minute / minutes;
    // 开局 40% 处两条线交叉：前半段红方领先，后半段蓝方反超（或反过来）。
    const swing = blueEdge * (ramp - 0.4) * 9200;
    const blueGold = 2500 + minute * 1350 + Math.round(swing);
    const redGold = 2500 + minute * 1330 - Math.round(swing);
    const gold = goldShares.map((share, index) => Math.round((index < 5 ? blueGold : redGold) * share));
    frames.push({
      minute,
      blueGold,
      redGold,
      goldDiff: blueGold - redGold,
      blueCs: Math.round(minute * 28.5),
      redCs: Math.round(minute * 27.2),
      gold,
    });
  }

  const timelineEvent = (
    base: Pick<MatchTimelineEvent, "type" | "seconds" | "team"> & Partial<MatchTimelineEvent>,
  ): MatchTimelineEvent => ({
    killerId: 0,
    victimId: 0,
    assistCount: 0,
    killerChampionId: 0,
    victimChampionId: 0,
    monsterType: "",
    monsterSubType: "",
    buildingType: "",
    towerType: "",
    laneType: "",
    ...base,
  });

  // 脚本时间点固定，靠 `filter` 按这局的实际时长裁掉没打到的部分。
  const events: MatchTimelineEvent[] = [
    timelineEvent({ type: "CHAMPION_KILL", seconds: 232, team: 200, killerId: 6, victimId: 1, killerChampionId: 24, victimChampionId: 64 }),
    timelineEvent({ type: "TURRET_PLATE_DESTROYED", seconds: 341, team: 200, killerId: 7, killerChampionId: 40, laneType: "TOP_LANE" }),
    timelineEvent({ type: "ELITE_MONSTER_KILL", seconds: 352, team: 100, killerId: 2, killerChampionId: 103, monsterType: "DRAGON", monsterSubType: "FIRE_DRAGON" }),
    timelineEvent({ type: "BUILDING_KILL", seconds: 528, team: 200, killerId: 7, killerChampionId: 40, buildingType: "TOWER_BUILDING", towerType: "OUTER_TURRET", laneType: "TOP_LANE" }),
    timelineEvent({ type: "CHAMPION_KILL", seconds: 604, team: 100, killerId: 1, victimId: 8, assistCount: 2, killerChampionId: 64, victimChampionId: 1 }),
    timelineEvent({ type: "ELITE_MONSTER_KILL", seconds: 611, team: 100, killerId: 2, killerChampionId: 103, monsterType: "RIFTHERALD" }),
    timelineEvent({ type: "BUILDING_KILL", seconds: 902, team: 100, killerId: 1, killerChampionId: 64, buildingType: "TOWER_BUILDING", towerType: "OUTER_TURRET", laneType: "MID_LANE" }),
    timelineEvent({ type: "ELITE_MONSTER_KILL", seconds: 968, team: 200, killerId: 6, killerChampionId: 24, monsterType: "DRAGON", monsterSubType: "OCEAN_DRAGON" }),
    timelineEvent({ type: "CHAMPION_KILL", seconds: 1188, team: 100, killerId: 3, victimId: 9, assistCount: 1, killerChampionId: 12, victimChampionId: 105 }),
    timelineEvent({ type: "BUILDING_KILL", seconds: 1264, team: 100, killerId: 3, killerChampionId: 12, buildingType: "TOWER_BUILDING", towerType: "INNER_TURRET", laneType: "MID_LANE" }),
    timelineEvent({ type: "ELITE_MONSTER_KILL", seconds: 1288, team: 100, killerId: 2, killerChampionId: 103, monsterType: "BARON_NASHOR" }),
    timelineEvent({ type: "BUILDING_KILL", seconds: 1502, team: 100, killerId: 4, killerChampionId: 222, buildingType: "INHIBITOR_BUILDING", laneType: "MID_LANE" }),
    timelineEvent({ type: "ELITE_MONSTER_KILL", seconds: 1596, team: 100, killerId: 2, killerChampionId: 103, monsterType: "DRAGON", monsterSubType: "ELDER_DRAGON" }),
    timelineEvent({ type: "CHAMPION_KILL", seconds: 1704, team: 100, killerId: 1, victimId: 6, assistCount: 3, killerChampionId: 64, victimChampionId: 24 }),
    timelineEvent({ type: "BUILDING_KILL", seconds: 1810, team: 100, killerId: 5, killerChampionId: 99, buildingType: "TOWER_BUILDING", towerType: "BASE_TURRET", laneType: "MID_LANE" }),
  ].filter((item) => item.seconds <= durationSeconds);

  return { gameId, durationSeconds, participants, frames, events };
}
