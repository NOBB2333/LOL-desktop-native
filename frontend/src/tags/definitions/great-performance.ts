import { h } from "vue";
import { chip } from "../chip";
import PlayerTagAkariScorePopover from "../components/PlayerTagAkariScorePopover.vue";
import type { PlayerTagDefinition } from "../types";

/**
 * 优异表现：Akari 评分达到「优异 / 通天代」。
 *
 * AK 的 `GREAT_PERFORMANCE_TAG` 读的是 `analysis.akariScore.outstanding / extraordinary`
 * ——这两个布尔只在聚合层产出，且带最小样本门槛
 * （优异 ≥ 6.5 分且 ≥ 5 场；通天代 ≥ 8 分且 ≥ 8 场），见 `akari.ts`。
 */
export const GREAT_PERFORMANCE_TAG: PlayerTagDefinition = {
  id: "great-performance",
  render: (ctx) => {
    if (!ctx.settings.showGreatPerformanceTag) return null;
    const score = ctx.facts.akariScore;
    if (!score.outstanding && !score.extraordinary) return null;

    const detail = score.extraordinary
      ? "该玩家的水平远远超过当前段位"
      : "该玩家在近期对局中表现优异";

    return {
      label: chip(score.extraordinary ? "通天代" : "优异", { tone: "score" }),
      popover: {
        content: () =>
          h(PlayerTagAkariScorePopover, { score, precision: 1, description: detail }),
        delay: 50,
      },
    };
  },
};
