import { h } from "vue";
import { chip } from "../chip";
import PlayerTagAkariScorePopover from "../components/PlayerTagAkariScorePopover.vue";
import type { PlayerTagDefinition } from "../types";

/**
 * Akari 评分：直接展示数值（满分 17）。
 *
 * 对应 AK 的 `AKARI_SCORE_TAG`：默认关闭，因为它是「想深究的人才会看」的指标。
 * 没有有效样本时评分恒为 0，不渲染，避免空战绩卡片仍挂着一个 0 分。
 */
export const AKARI_SCORE_TAG: PlayerTagDefinition = {
  id: "akari-score",
  render: (ctx) => {
    if (!ctx.settings.showAkariScoreTag) return null;
    const score = ctx.facts.akariScore;
    if (ctx.facts.sample === 0) return null;
    if (!Number.isFinite(score.total) || score.total <= 0) return null;

    return {
      label: chip(() => `Akari ${score.total.toFixed(1)}`, { tone: "score" }),
      popover: {
        content: () => h(PlayerTagAkariScorePopover, { score, precision: 2 }),
      },
    };
  },
};
