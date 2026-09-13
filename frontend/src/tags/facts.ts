import type { PlayerProfile, RecentMatch } from "../types/domain";

/** Smite（惩戒）的法术 id，用于在未分配位置时识别打野。 */
const SMITE_SPELL_ID = 11;

/**
 * 标签推导用的事实集合。
 *
 * 对齐 LeagueAkari 的 `AggregatedAnalysis`：标签定义只读这份已算好的数字，
 * 不自己遍历原始对局，避免同一份样本被反复计算。
 */
export interface PlayerTagFacts {
  /** 有效样本数（已完成的对局）。 */
  sample: number;
  wins: number;
  winRate: number;
  averageDeaths: number;
  averageParticipation: number;
  averageDamageShare: number;
  averageCsPerMinute: number;
  /** 仅统计提供了精确单杀数据的对局。 */
  averageSoloKills: number | null;
  soloKillsSample: number;
  /** 仅统计提供了视野得分的对局。 */
  averageVisionScore: number | null;
  visionSample: number;
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
}

const finished = (match: RecentMatch) => match.durationMinutes > 0;

function optionalAverage(sum: number, count: number): number | null {
  return count > 0 ? sum / count : null;
}

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
  return Boolean(
    player.summonerSpells?.some((spell) => spell.id === SMITE_SPELL_ID),
  );
}

/**
 * 从玩家画像推导标签事实。
 *
 * `recentMatches` 由后端按「最近一局在前」输出（见 `writeRecentMatchesFiltered`），
 * 因此连胜/连败可以直接从数组头部扫描。
 */
export function deriveTagFacts(player: PlayerProfile): PlayerTagFacts {
  const matches = player.recentMatches.filter(finished);
  const sample = matches.length;
  if (sample === 0) {
    return {
      sample: 0,
      wins: 0,
      winRate: 0,
      averageDeaths: 0,
      averageParticipation: 0,
      averageDamageShare: 0,
      averageCsPerMinute: 0,
      averageSoloKills: null,
      soloKillsSample: 0,
      averageVisionScore: null,
      visionSample: 0,
      averageEarlyDeathsWithJungler: null,
      earlyDeathsSample: 0,
      winningStreak: 0,
      losingStreak: 0,
      currentChampionGames: 0,
      isJungler: isJungler(player),
    };
  }

  let wins = 0;
  let deaths = 0;
  let participation = 0;
  let damageShare = 0;
  let csPerMinute = 0;
  let soloSum = 0;
  let soloSample = 0;
  let visionSum = 0;
  let visionSample = 0;
  let earlyDeathsSum = 0;
  let earlyDeathsSample = 0;
  let currentChampionGames = 0;

  for (const match of matches) {
    if (match.win) wins += 1;
    deaths += match.deaths;
    participation += match.killParticipation;
    damageShare += match.damageShare;
    csPerMinute += match.cs / Math.max(1, match.durationMinutes);
    if (typeof match.soloKills === "number" && Number.isFinite(match.soloKills) && match.soloKills >= 0) {
      soloSum += match.soloKills;
      soloSample += 1;
    }
    if (typeof match.visionScore === "number" && Number.isFinite(match.visionScore) && match.visionScore >= 0) {
      visionSum += match.visionScore;
      visionSample += 1;
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
  }

  return {
    sample,
    wins,
    winRate: wins / sample,
    averageDeaths: deaths / sample,
    averageParticipation: participation / sample,
    averageDamageShare: damageShare / sample,
    averageCsPerMinute: csPerMinute / sample,
    averageSoloKills: optionalAverage(soloSum, soloSample),
    soloKillsSample: soloSample,
    averageVisionScore: optionalAverage(visionSum, visionSample),
    visionSample,
    averageEarlyDeathsWithJungler: optionalAverage(earlyDeathsSum, earlyDeathsSample),
    earlyDeathsSample,
    winningStreak: streakOf(matches, true),
    losingStreak: streakOf(matches, false),
    currentChampionGames,
    isJungler: isJungler(player),
  };
}
