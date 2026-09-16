import { h } from "vue";
import { chip } from "../chip";
import PlayerTagAkariScorePopover from "../components/PlayerTagAkariScorePopover.vue";
import type { PlayerTagDefinition } from "../types";

/**
 * Akari 评分：直接展示数值（满分 17）。
 *
 * 对应 AK 的 `AKARI_SCORE_TAG`：默认关闭，因为它是「想深究的人才会看」的指标。
 *
 * 三处必须一致，否则数值看起来会「不一样」：
 * - 标签上保留 **2 位小数**（AK `total.toFixed(2)`），此前本项目只保留 1 位；
 * - 弹层用 **3 位小数**（AK `totalPrecision={3}`）；
 * - 附一句 AK 的说明文案（`akariScorePopoverDescription`）。
 *
 * 条件也对齐 AK：只有 `settings` 与「有没有样本」，不再额外要求总分 > 0
 * —— AK 在有样本时会照实显示 `Akari 0.00`。
 */
export const AKARI_SCORE_TAG: PlayerTagDefinition = {
  id: "akari-score",
  render: (ctx) => {
    if (!ctx.settings.showAkariScoreTag) return null;
    const score = ctx.facts.akariScore;
    if (ctx.facts.sample === 0) return null;

    return {
      label: chip(() => `Akari ${score.total.toFixed(2)}`, { tone: "score" }),
      popover: {
        content: () =>
          h(PlayerTagAkariScorePopover, {
            score,
            precision: 3,
            description: "Akari Score 摘要了该玩家近期的部分数据指标，仅供参考。",
          }),
      },
    };
  },
};
