import type {
  AppBootstrap,
  AppConfig,
  BanSummary,
  ChampionOverview,
  EncounterRecord,
  FriendToolsSnapshot,
  FinalBpRecord,
  LiveLobby,
  ItemSummary,
  MatchParticipant,
  MatchSummary,
  PlayerProfile,
  RecentMatch,
  RuneSummary,
  SpellSummary,
  TeamSummary,
} from "../types/domain";

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
  const tags: PlayerProfile["tags"] = [];
  const averageSoloKills = matches.reduce((sum, match) => sum + (match.soloKills ?? 0), 0) / matches.length;
  const averageDeaths = matches.reduce((sum, match) => sum + match.deaths, 0) / matches.length;
  const averageParticipation = matches.reduce((sum, match) => sum + match.killParticipation, 0) / matches.length;
  if (averageSoloKills >= 0.4) tags.push({ key: "soloThreat", label: "单杀威胁", tone: "danger", evidence: `10场精确数据，场均单杀 ${averageSoloKills.toFixed(1)} 次` });
  if (averageDeaths >= 6) tags.push({ key: "highDeaths", label: "阵亡偏多", tone: "warning", evidence: `近10场场均阵亡 ${averageDeaths.toFixed(1)} 次` });
  else if (averageDeaths <= 3) tags.push({ key: "survivor", label: "生存稳健", tone: "success", evidence: `近10场场均阵亡 ${averageDeaths.toFixed(1)} 次` });
  if (averageParticipation >= 0.62) tags.push({ key: "highParticipation", label: "参团积极", tone: "success", evidence: `近10场平均参团率 ${Math.round(averageParticipation * 100)}%` });
  if (wins >= 7) tags.push({ key: "hot", label: "状态火热", tone: "success", evidence: `近10场 ${wins} 胜` });
  if (wins <= 3) tags.push({ key: "slump", label: "近期低迷", tone: "danger", evidence: `近10场仅 ${wins} 胜` });
  if (index === 1) tags.push({ key: "autofill", label: "位置样本少", tone: "warning", evidence: "近10场同位置 4 场" });
  if (index === 2) tags.push({ key: "signature", label: "当前英雄熟练", tone: "success", evidence: "当前英雄 5 场" });
  if (index === 2) tags.unshift({ key: "met", label: "遇到过", tone: "info", evidence: "近期战绩中遇到过 3 次" });
  if (!tags.length) tags.push({ key: "stable", label: "状态稳定", tone: "info", evidence: "近期表现无明显波动" });
  const topChampions = [
    { championId: id, championName, games: 63 - index * 5, wins: 39 - index * 2, winRate: 0.62 - index * 0.01 },
    { championId: champions[(index + 1) % 5][0], championName: champions[(index + 1) % 5][1], games: 31, wins: 18, winRate: 0.58 },
    { championId: champions[(index + 2) % 5][0], championName: champions[(index + 2) % 5][1], games: 19, wins: 10, winRate: 0.53 },
  ];
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
    tags,
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
  return {
    side,
    score: Math.round(score * 10) / 10,
    title: score >= 78 ? "状态占优" : "整体均衡",
    focusPlayerPuuid: players.reduce((lowest, player) => player.score.total < lowest.score.total ? player : lowest).puuid,
    strengths: players.filter((player) => player.tags.some((tag) => tag.tone === "success")).slice(0, 2).map((player) => `${player.championName}：${player.tags[0].label}`),
    risks: players.filter((player) => player.tags.some((tag) => ["warning", "danger"].includes(tag.tone))).slice(0, 2).map((player) => `${player.championName}：${player.tags[0].label}`),
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
  dataStatus: fixtureStatus(),
}));

const fixtureEncounterPlayers = [...fixtureLobby.ally.slice(1), ...fixtureLobby.enemy];
export const fixtureEncounters: EncounterRecord[] = Array.from({ length: 3 }, (_, gameIndex) => {
  const selfWin = gameIndex !== 1;
  return fixtureEncounterPlayers.map((player, playerIndex) => {
    const side = fixtureLobby.ally.some((member) => member.puuid === player.puuid) ? "ally" : "enemy";
    return {
      gameId: 910000 + gameIndex,
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
      encounteredAt: new Date(now - (gameIndex * 4 + 1) * 86400000).toISOString(),
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
    { id: "friend-1", puuid: "friend-puuid-1", summonerId: 101, gameName: "河道观察者", gameTag: "233", icon: 3494, groupId: 2, availability: "chat", friendsSince: new Date(now - 420 * 86400000).toISOString(), lastGameAt: new Date(now - 5 * 3600000).toISOString() },
    { id: "friend-2", puuid: "friend-puuid-2", summonerId: 102, gameName: "狐狸收藏家", gameTag: "MID", icon: 29, groupId: 1, availability: "dnd", friendsSince: new Date(now - 730 * 86400000).toISOString(), lastGameAt: new Date(now - 2 * 86400000).toISOString() },
    { id: "friend-3", puuid: "friend-puuid-3", summonerId: 103, gameName: "灯笼点一下", gameTag: "SUP", icon: 7, groupId: 1, availability: "offline", friendsSince: null, lastGameAt: null },
  ],
};

export const fixtureConfig: AppConfig = {
  version: 18,
  appearance: { theme: "mint", colorMode: "light", compact: false },
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
    shortcutSendIntervalMs: 250,
    protectChatInput: true,
    shortcutRecentGameCount: 5,
    shortcuts: [
      { id: "encounter", label: "发送遇到记录", key: "Ctrl+F8", target: "encounter", template: "{encounter}", enabled: true },
      { id: "premade", label: "发送已知组队", key: "Ctrl+F9", target: "premade", template: "{position} {name}：组队 {premade}，近10场 {recent_wins}胜{recent_losses}负", enabled: true },
      { id: "jungle-preference", label: "发送打野偏好", key: "Ctrl+F10", target: "jungle", template: "{name}：{jungle_preference}", enabled: true },
      { id: "enemy", label: "发送敌方评估", key: "Ctrl+F11", target: "enemy", template: "{team}{position} {current_champion}：{rank} {recent_wins}胜{recent_losses}负，{recent_games}", enabled: true },
      { id: "ally", label: "发送我方评估", key: "Ctrl+F12", target: "ally", template: "{team}{position} {current_champion}：{rank} {recent_wins}胜{recent_losses}负，{recent_games}", enabled: true },
      { id: "open-game", label: "打开对局速看", key: "Ctrl+F1", target: "lobby", template: "对局速看：{team} {name}，近10场 {recent_wins}胜{recent_losses}负，KDA {kda}", enabled: true },
    ],
  },
  providers: { statsProvider: "auto", requestTimeoutSeconds: 6, cacheTtlMinutes: 120, hideUnfinishedMatches: false, rankedOnly: false, clearLobbyAfterGame: true },
  ai: { enabled: false, provider: "deepseek", protocol: "openai", baseUrl: "https://api.deepseek.com", model: "deepseek-v4-flash", apiKey: "", automaticPregameAnalysis: false },
};

export const fixtureBootstrap: AppBootstrap = {
  dataMode: "fixture",
  dashboard: {
    connection: {
      status: "disconnected", phase: "Fixture", summonerName: "测试召唤师", gameName: "测试召唤师", tagLine: "HN1",
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
  appVersion: "2.0.0",
};
