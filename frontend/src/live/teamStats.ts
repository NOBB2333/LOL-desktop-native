import { deriveTagFacts } from "../tags/facts";
import type { PlayerProfile } from "../types/domain";

/**
 * 队伍级标签（面板头部那一条），移植自 LeagueAkari 的
 * `analysis/team/index.ts::analyzePlayers` 与 `widgets/TeamTagsArea.vue`。
 *
 * AK 把它算在 data-adapter 里、随 `analysis.teams` 下发；本项目的事实层在
 * 前端（`tags/facts.ts`），所以这里同样在前端从十个玩家的画像聚合，
 * 口径与 AK 逐项对齐。
 */

/** AK `constants.ts` 的队伍标签阈值。 */
export const WIN_RATE_TEAM_MIN_MATCHES = 13;
export const WIN_RATE_TEAM_OTHER_MEMBER_WIN_STREAK = 4;
export const WIN_RATE_TEAM_MIN_SIZE = 3;
export const LOSS_RATE_TEAM_MIN_SIZE = 2;
export const WIN_RATE_TEAM_MIN_WIN_RATE = 0.9;
export const LOSS_RATE_TEAM_MAX_WIN_RATE = 0.25;

/** 对应 AK `AggregatedTeamAnalysis` 中本面板用到的那几项。 */
export interface TeamStats {
  avgWinRate: number;
  wins: number;
  losses: number;
  games: number;
  kills: number;
  deaths: number;
  assists: number;
  avgKda: number;
}

/** 对应 AK 的 `noZero`：0 变 1，避免除零得到 Infinity/NaN。 */
function noZero(value: number) {
  return value || 1;
}

/**
 * 聚合一支队伍的战绩。
 *
 * AK 的做法是把每位玩家已分析的场次**相加**，再做整体除法：
 * `avgKda = (Σ击杀 + Σ助攻) / Σ死亡`，不是「每人 KDA 求平均」。
 * 队伍平均胜率同理 = `Σ胜 / Σ场次`。
 */
export function analyzeTeamStats(players: readonly PlayerProfile[]): TeamStats | null {
  if (!players.length) return null;

  let kills = 0;
  let deaths = 0;
  let assists = 0;
  let wins = 0;
  let games = 0;
  for (const player of players) {
    // `deriveTagFacts` 已按「已完成的对局」过滤，与卡片标签用的是同一份样本；
    // 胜场与场次直接复用，避免两处各算一遍导致口径漂移。
    const facts = deriveTagFacts(player);
    wins += facts.wins;
    games += facts.sample;
    for (const match of player.recentMatches) {
      if (match.durationMinutes <= 0) continue;
      kills += match.kills;
      deaths += match.deaths;
      assists += match.assists;
    }
  }

  return {
    avgWinRate: wins / noZero(games),
    wins,
    losses: games - wins,
    games,
    kills,
    deaths,
    assists,
    avgKda: (kills + assists) / noZero(deaths),
  };
}

/** 一个预组队的引用：字母 + 内部配色序号 + 成员 puuid。 */
export interface PremadeGroupRef {
  id: string;
  tone: number;
  puuids: string[];
}

export interface PremadeTeamTag {
  premadeId: string;
  puuids: string[];
  type: "win-rate-team" | "loss-rate-team";
}

/**
 * 胜率队 / 败率队判定，逐行对齐 AK `TeamTagsArea.vue` 的 `winRateTeams`。
 *
 * - **胜率队**：≥3 人；其中存在一名「胜率 ≥ 90% 且样本 ≥ 13 场」的玩家；
 *   其余成员的连胜均值 ≥ 4。（`hasOneHighWinRateMember` 一旦置位，
 *   后续玩家全部计入 `otherMembersWinTotalStreak`。）
 * - **败率队**：≥2 人；且**每一名**成员都满足「样本 ≥ 2 场且胜率 ≤ 25%」。
 *
 * 两组条件互相独立，同一支队伍可能同时命中，AK 用 reduce 覆盖 → 败率队优先。
 * 这里保持同样的覆盖顺序。
 */
export function resolvePremadeTeamTags(
  groups: readonly PremadeGroupRef[],
  players: readonly PlayerProfile[],
): Map<string, PremadeTeamTag> {
  const result = new Map<string, PremadeTeamTag>();
  if (!groups.length) return result;

  const factsByPuuid = new Map<string, ReturnType<typeof deriveTagFacts>>();
  for (const player of players) {
    if (!player.puuid) continue;
    factsByPuuid.set(player.puuid, deriveTagFacts(player));
  }

  for (const group of groups) {
    const size = group.puuids.length;
    if (size < WIN_RATE_TEAM_MIN_SIZE && size < LOSS_RATE_TEAM_MIN_SIZE) continue;

    let hasOneHighWinRateMember = false;
    let otherMembersWinTotalStreak = 0;
    for (const puuid of group.puuids) {
      const facts = puuid ? factsByPuuid.get(puuid) : undefined;
      // AK 在这里是 `break`（缺数据就停，已累加的部分仍会参与下面的除法），保持一致。
      if (!facts) break;
      if (
        !hasOneHighWinRateMember &&
        facts.winRate >= WIN_RATE_TEAM_MIN_WIN_RATE &&
        facts.sample >= WIN_RATE_TEAM_MIN_MATCHES
      ) {
        hasOneHighWinRateMember = true;
      } else {
        otherMembersWinTotalStreak += facts.winningStreak;
      }
    }

    if (
      hasOneHighWinRateMember &&
      otherMembersWinTotalStreak / (size - 1) >= WIN_RATE_TEAM_OTHER_MEMBER_WIN_STREAK
    ) {
      result.set(group.id, { premadeId: group.id, puuids: [...group.puuids], type: "win-rate-team" });
    }

    let lossRateTeamQualified = true;
    for (const puuid of group.puuids) {
      const facts = puuid ? factsByPuuid.get(puuid) : undefined;
      if (
        !facts ||
        facts.sample < LOSS_RATE_TEAM_MIN_SIZE ||
        facts.winRate > LOSS_RATE_TEAM_MAX_WIN_RATE
      ) {
        lossRateTeamQualified = false;
        break;
      }
    }
    if (lossRateTeamQualified) {
      // 与 AK 的 reduce 覆盖顺序一致：同一组命中两队时，败率队生效。
      result.set(group.id, { premadeId: group.id, puuids: [...group.puuids], type: "loss-rate-team" });
    }
  }

  return result;
}
