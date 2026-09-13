import { h } from "vue";
import { chip, textPopover } from "../chip";
import PlayerTagScorePopover from "../components/PlayerTagScorePopover.vue";
import type { PlayerTagDefinition } from "../types";
import type { PlayerTagFacts } from "../facts";

/**
 * 「极高胜率」判定阈值：与 LeagueAkari 的 `HIGH_WIN_RATE_TAG` 一致——
 * 样本 ≥ 16 场且胜率 ≥ 85%（其判定用的是 `winLoss.all.count/winRate`）。
 */
export const HIGH_WIN_RATE_MIN_SAMPLE = 16;
export const HIGH_WIN_RATE_THRESHOLD = 0.85;

/** 连胜/连败阈值，LeagueAkari 同为 3。 */
export const STREAK_THRESHOLD = 3;

/** 综合评分分档：`outstanding` 与页面其它「状态占优」判定保持一致。 */
export const OUTSTANDING_SCORE = 78;
export const EXTRAORDINARY_SCORE = 88;

export type ScoreGrade = "extraordinary" | "outstanding" | "normal";

export function scoreGrade(total: number): ScoreGrade {
  if (total >= EXTRAORDINARY_SCORE) return "extraordinary";
  if (total >= OUTSTANDING_SCORE) return "outstanding";
  return "normal";
}

/**
 * 「连胜 / 连败」文案，shortcut 模板与卡片标签共用，也是
 * `frontend/src/tags/signals.ts` 与后端 `player_signals.zig` 的 `{streak}` 文案来源。
 */
export function streakLabel(facts: PlayerTagFacts): string {
  if (facts.winningStreak >= STREAK_THRESHOLD) return `${facts.winningStreak} 连胜`;
  if (facts.losingStreak >= STREAK_THRESHOLD) return `${facts.losingStreak} 连败`;
  return "状态稳定";
}

/** 极高胜率的文案。信号模块与卡片标签共用，避免两套说法。 */
export const HIGH_WIN_RATE_LABEL = "极高胜率";

const winRatePopover = (facts: PlayerTagFacts) =>
  `该玩家的胜率高到不可置信。在近期 ${facts.sample} 场的对局中，赢了 ${facts.wins} 场`;

/** 极高胜率。 */
export const HIGH_WIN_RATE_TAG: PlayerTagDefinition = {
  id: "high-win-rate",
  render: (ctx) => {
    const { facts } = ctx;
    if (!ctx.settings.showHighWinRateTag) return null;
    if (facts.sample < HIGH_WIN_RATE_MIN_SAMPLE || facts.winRate < HIGH_WIN_RATE_THRESHOLD) return null;
    return {
      label: chip(HIGH_WIN_RATE_LABEL, { tone: "win-rate" }),
      popover: textPopover(() => winRatePopover(facts)),
    };
  },
};

/** 连胜。 */
export const WINNING_STREAK_TAG: PlayerTagDefinition = {
  id: "winning-streak",
  render: (ctx) => {
    const { facts } = ctx;
    if (!ctx.settings.showStreakTag || facts.winningStreak < STREAK_THRESHOLD) return null;
    return {
      label: chip(() => streakLabel(facts), { tone: "streak-win" }),
      popover: textPopover(() => `截止到现在，该玩家 ${facts.winningStreak} 连胜，很棒`),
    };
  },
};

/** 连败。 */
export const LOSING_STREAK_TAG: PlayerTagDefinition = {
  id: "losing-streak",
  render: (ctx) => {
    const { facts } = ctx;
    if (!ctx.settings.showStreakTag || facts.losingStreak < STREAK_THRESHOLD) return null;
    return {
      label: chip(() => streakLabel(facts), { tone: "streak-loss" }),
      popover: textPopover(() => `截止到现在，该玩家 ${facts.losingStreak} 连败`),
    };
  },
};

/** 亮眼表现：综合评分达到优异 / 通天代。 */
export const GREAT_PERFORMANCE_TAG: PlayerTagDefinition = {
  id: "great-performance",
  render: (ctx) => {
    if (!ctx.settings.showGreatPerformanceTag) return null;
    // 没有样本时评分没有意义，对齐 LeagueAkari「analysis 为空则不渲染」。
    if (ctx.facts.sample === 0) return null;
    const grade = scoreGrade(ctx.player.score.total);
    if (grade === "normal") return null;

    const label = grade === "extraordinary" ? "通天代" : "优异";
    const detail =
      grade === "extraordinary"
        ? "该玩家在近期对局中表现极其突出，属于可以主导比赛的水平"
        : "该玩家在近期对局中表现优异";

    return {
      label: chip(label, { tone: "score" }),
      popover: {
        content: () =>
          h(PlayerTagScorePopover, { score: ctx.player.score, precision: 1, description: detail }),
        delay: 50,
      },
    };
  },
};

/** 综合评分：直接展示数值。 */
export const SCORE_TAG: PlayerTagDefinition = {
  id: "score",
  render: (ctx) => {
    if (!ctx.settings.showScoreTag) return null;
    // 无样本时评分恒为 0，不渲染，避免空战绩卡片仍挂着「评分」。
    if (ctx.facts.sample === 0) return null;
    const score = ctx.player.score;
    if (!Number.isFinite(score.total) || score.total <= 0) return null;

    return {
      label: chip(() => `评分 ${score.total.toFixed(1)}`, { tone: "score" }),
      popover: {
        content: () => h(PlayerTagScorePopover, { score, precision: 2 }),
      },
    };
  },
};
