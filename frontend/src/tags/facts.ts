import type { PlayerProfile, RecentMatch } from "../types/domain";
import { computeAggregateAkariScore, type AkariScore, type SingleAkariInput } from "./akari";

/** Smite（惩戒）的法术 id，用于在未分配位置时识别打野。 */
const SMITE_SPELL_ID = 11;
/** Flash（闪现）的法术 id。 */
const FLASH_SPELL_ID = 4;

/** 单杀判定：需要至少 3 场提供精确数据的对局。 */
export const SOLO_KILL_MIN_SAMPLE = 3;

/**
 * 标签推导用的事实集合。
 *
 * 对齐 LeagueAkari 的 `AggregatedAnalysis`：标签定义只读这份已算好的数字，
 * 不自己遍历原始对局，避免同一份样本被反复计算。
 *
 * 命名刻意保留 AK 的 `avgChampionDamagePercentageOfTeam` 一类长名：这样从标签
 * 定义回查 AK 原实现时一一对得上，不必再猜「这个 averageDamageShare 是不是
 * 那个 avgChampionDamagePercentageOfTeam」。
 */
export interface PlayerTagFacts {
  /** 有效样本数（已完成的对局）。 */
  sample: number;
  wins: number;
  winRate: number;
  /** `analysis.summary.avgKda`：逐局 KDA 的均值；Akari 的 KDA 项吃这个数。 */
  averageKda: number;

  /** `analysis.summary.avgChampionDamagePercentageOfTeam` */
  avgChampionDamagePercentageOfTeam: number;
  /** `analysis.summary.avgDamageTakenPercentageOfTeam`；无十人数据时为 null。 */
  avgDamageTakenPercentageOfTeam: number | null;
  /** `analysis.summary.avgGoldPercentageOfTeam`；无十人数据时为 null。 */
  avgGoldPercentageOfTeam: number | null;
  /** `analysis.summary.avgCsPercentageOfTeam`；无十人数据时为 null。 */
  avgCsPercentageOfTeam: number | null;
  /** `analysis.summary.avgCsPerMinute` */
  avgCsPerMinute: number;
  /** `analysis.summary.avgDamageGoldEfficiency`（比值，UI 再 ×100）。 */
  avgDamageGoldEfficiency: number;
  /** `analysis.summary.avgKillDamageEfficiency`；空样本为 1（对齐 AK 的 avgOrOne）。 */
  avgKillDamageEfficiency: number;
  /** `analysis.summary.avgVisionScore`；AK 对缺失值按 0 处理，因此不为 null。 */
  avgVisionScore: number;
  /** `analysis.summary.avgEnemyMissingPings`；任意一局缺 ping 就整体为 null。 */
  avgEnemyMissingPings: number | null;

  /** 仅统计提供了精确单杀数据的对局。 */
  averageSoloKills: number | null;
  soloKillsSample: number;
  /** 15 分钟前被敌方打野参与击杀的场均值。 */
  averageEarlyDeathsWithJungler: number | null;
  earlyDeathsSample: number;

  /** 从最近一局往前连续胜利的场数。 */
  winningStreak: number;
  /** 从最近一局往前连续失败的场数。 */
  losingStreak: number;
  /** 当前英雄的使用场数。 */
  currentChampionGames: number;
  isJungler: boolean;

  /** 闪现放在 D / F 位的对局数（`analysis.spells`）。 */
  flashOnD: number;
  flashOnF: number;

  /** Akari 综合评分（满分 17）。 */
  akariScore: AkariScore;
}

const finished = (match: RecentMatch) => match.durationMinutes > 0;

function optionalAverage(sum: number, count: number): number | null {
  return count > 0 ? sum / count : null;
}

/** 空样本按 0（对应 AK 的 `avgOrZero`）。 */
function avgOrZero(values: number[]): number {
  if (!values.length) return 0;
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

/** 空样本按 1（对应 AK 的 `avgOrOne`，只用于击杀伤害转化）。 */
function avgOrOne(values: number[]): number {
  if (!values.length) return 1;
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

/** 任意一项为 null 就整体 null（对应 AK 的 `avgIfAllNonNull`）。 */
function avgIfAllNonNull(values: Array<number | null>): number | null {
  if (!values.length) return null;
  const present = values.filter((value): value is number => value !== null);
  if (present.length !== values.length) return null;
  return avgOrZero(present);
}

function numberOrNull(value: number | null | undefined): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

/** 缺失的视野得分按 0 计入（AK 的 `getVisionScore` 就是 `?? 0`）。 */
function visionScoreValue(match: RecentMatch): number {
  return typeof match.visionScore === "number" && Number.isFinite(match.visionScore) && match.visionScore >= 0
    ? match.visionScore
    : 0;
}

const kdaOf = (match: RecentMatch) => (match.kills + match.assists) / Math.max(1, match.deaths);

function streakOf(matches: RecentMatch[], win: boolean): number {
  let count = 0;
  for (const match of matches) {
    if (match.win !== win) break;
    count += 1;
  }
  return count;
}

export function isJungler(player: Pick<PlayerProfile, "assignedPosition" | "summonerSpells">): boolean {
  if (player.assignedPosition?.toUpperCase() === "JUNGLE") return true;
  return Boolean(player.summonerSpells?.some((spell) => spell.id === SMITE_SPELL_ID));
}

/**
 * 单局的 Akari 评分输入。
 *
 * AK 的这些比例来自 `computeSingleSummary`（十人明细）。此项目只有在明细字段
 * 存在时才凑得出同一套数字，所以返回 null 表示「这一局队伍数据不足」——
 * 该局会被排除在这 7 项之外，而不是按 0 混进均值把结果拉低。
 */
function singleAkariInput(match: RecentMatch): SingleAkariInput | null {
  const teamSize = numberOrNull(match.teamSize);
  const teamDamageTaken = numberOrNull(match.teamDamageTaken);
  const damageTakenShare = numberOrNull(match.damageTakenShare);
  const goldShare = numberOrNull(match.goldShare);
  const visionScoreShare = numberOrNull(match.visionScoreShare);
  if (
    teamSize === null ||
    teamSize <= 1 ||
    teamDamageTaken === null ||
    damageTakenShare === null ||
    goldShare === null ||
    visionScoreShare === null
  ) {
    return null;
  }
  // AK 的「理应贡献比」= 队伍占比 / (1 / 队伍人数) = 占比 × 队伍人数。
  const scale = (share: number) => share * teamSize;
  return {
    kda: kdaOf(match),
    win: match.win,
    teamParticipantCount: teamSize,
    championDamageRatioToExpectedContribution: scale(match.damageShare),
    damageTakenRatioToExpectedContribution: scale(damageTakenShare),
    healingRatioToTeamAverageDamageTaken: match.heal / Math.max(1, teamDamageTaken / teamSize),
    csPerMinute: match.cs / Math.max(1, match.durationMinutes),
    goldRatioToExpectedContribution: scale(goldShare),
    killParticipation: match.killParticipation,
    visionScoreRatioToExpectedContribution: scale(visionScoreShare),
  };
}

const emptyFacts = (player: PlayerProfile): PlayerTagFacts => ({
  sample: 0,
  wins: 0,
  winRate: 0,
  averageKda: 0,
  avgChampionDamagePercentageOfTeam: 0,
  avgDamageTakenPercentageOfTeam: null,
  avgGoldPercentageOfTeam: null,
  avgCsPercentageOfTeam: null,
  avgCsPerMinute: 0,
  avgDamageGoldEfficiency: 0,
  avgKillDamageEfficiency: 1,
  avgVisionScore: 0,
  avgEnemyMissingPings: null,
  averageSoloKills: null,
  soloKillsSample: 0,
  averageEarlyDeathsWithJungler: null,
  earlyDeathsSample: 0,
  winningStreak: 0,
  losingStreak: 0,
  currentChampionGames: 0,
  isJungler: isJungler(player),
  flashOnD: 0,
  flashOnF: 0,
  akariScore: { total: 0, maxScore: 0, outstanding: false, extraordinary: false, components: [] },
});

/**
 * 从玩家画像推导标签事实。
 *
 * `recentMatches` 由后端按「最近一局在前」输出（见 `writeRecentMatchesFiltered`），
 * 因此连胜/连败可以直接从数组头部扫描。
 */
export function deriveTagFacts(player: PlayerProfile): PlayerTagFacts {
  const matches = player.recentMatches.filter(finished);
  const sample = matches.length;
  if (sample === 0) return emptyFacts(player);

  let wins = 0;
  let soloSum = 0;
  let soloSample = 0;
  let earlyDeathsSum = 0;
  let earlyDeathsSample = 0;
  let currentChampionGames = 0;
  let flashOnD = 0;
  let flashOnF = 0;
  const aggregation: SingleAkariInput[] = [];

  for (const match of matches) {
    if (match.win) wins += 1;
    if (typeof match.soloKills === "number" && Number.isFinite(match.soloKills) && match.soloKills >= 0) {
      soloSum += match.soloKills;
      soloSample += 1;
    }
    if (
      typeof match.earlyDeathsWithEnemyJungler === "number" &&
      Number.isFinite(match.earlyDeathsWithEnemyJungler) &&
      match.earlyDeathsWithEnemyJungler >= 0
    ) {
      earlyDeathsSum += match.earlyDeathsWithEnemyJungler;
      earlyDeathsSample += 1;
    }
    if (player.championId > 0 && match.championId === player.championId) currentChampionGames += 1;
    // `summonerSpells` 按 [spell1Id, spell2Id] 输出，即索引 0 = D、索引 1 = F。
    if (match.summonerSpells?.[0]?.id === FLASH_SPELL_ID) flashOnD += 1;
    if (match.summonerSpells?.[1]?.id === FLASH_SPELL_ID) flashOnF += 1;

    const single = singleAkariInput(match);
    if (single) aggregation.push(single);
  }

  const damageTakenShares = matches
    .map((match) => numberOrNull(match.damageTakenShare))
    .filter((value): value is number => value !== null);
  const goldShares = matches
    .map((match) => numberOrNull(match.goldShare))
    .filter((value): value is number => value !== null);
  const csShares = matches
    .map((match) => numberOrNull(match.csShare))
    .filter((value): value is number => value !== null);

  const averageKda = avgOrZero(matches.map(kdaOf));
  const winRate = wins / sample;

  return {
    sample,
    wins,
    winRate,
    averageKda,
    avgChampionDamagePercentageOfTeam: avgOrZero(matches.map((match) => match.damageShare)),
    avgDamageTakenPercentageOfTeam: damageTakenShares.length ? avgOrZero(damageTakenShares) : null,
    avgGoldPercentageOfTeam: goldShares.length ? avgOrZero(goldShares) : null,
    avgCsPercentageOfTeam: csShares.length ? avgOrZero(csShares) : null,
    avgCsPerMinute: avgOrZero(matches.map((match) => match.cs / Math.max(1, match.durationMinutes))),
    avgDamageGoldEfficiency: avgOrZero(
      matches.map((match) => match.damageDealt / Math.max(1, match.goldEarned)),
    ),
    // AK: `kills / teamTotalKills / (damage / teamTotalDamage)`，队伍 0 击杀或 0 伤害时该局记 1。
    avgKillDamageEfficiency: avgOrOne(
      matches.map((match) => {
        const teamKills = numberOrNull(match.teamKills) ?? 0;
        if (teamKills === 0 || match.damageShare === 0) return 1;
        return match.kills / teamKills / match.damageShare;
      }),
    ),
    avgVisionScore: avgOrZero(matches.map(visionScoreValue)),
    avgEnemyMissingPings: avgIfAllNonNull(matches.map((match) => numberOrNull(match.enemyMissingPings))),
    averageSoloKills: optionalAverage(soloSum, soloSample),
    soloKillsSample: soloSample,
    averageEarlyDeathsWithJungler: optionalAverage(earlyDeathsSum, earlyDeathsSample),
    earlyDeathsSample,
    winningStreak: streakOf(matches, true),
    losingStreak: streakOf(matches, false),
    currentChampionGames,
    isJungler: isJungler(player),
    flashOnD,
    flashOnF,
    akariScore: computeAggregateAkariScore(aggregation, averageKda, winRate),
  };
}
