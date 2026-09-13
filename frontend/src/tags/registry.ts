import type { PlayerTagDefinition } from "./types";
import { PREMADE_TAG, SELF_TAG, TAGGED_TAG } from "./definitions/identity";
import { MET_TAG } from "./definitions/met";
import {
  GREAT_PERFORMANCE_TAG,
  HIGH_WIN_RATE_TAG,
  LOSING_STREAK_TAG,
  SCORE_TAG,
  WINNING_STREAK_TAG,
} from "./definitions/performance";
import {
  CS_PER_MINUTE_TAG,
  DAMAGE_SHARE_TAG,
  DEATHS_TAG,
  EASY_GANK_TAG,
  PARTICIPATION_TAG,
  POOL_CONCENTRATION_TAG,
  SOLO_KILLS_TAG,
  VISION_SCORE_TAG,
} from "./definitions/playstyle";

/**
 * 标签注册表。
 *
 * 顺序严格对齐 LeagueAkari 的 `PLAYER_CARD_TAGS`：
 * 「身份 / 关系」→「胜率与状态」→「亮眼表现」→「打野与被抓」→「各项场均指标」→「综合评分」。
 * 数组顺序即展示顺序；`SCORE_TAG` 与 LeagueAkari 的 `AKARI_SCORE_TAG` 一样放在最后。
 *
 * 新增标签只需在这里追加一条定义，渲染层（`PlayerTagArea`）无需改动。
 */
export const PLAYER_CARD_TAGS: PlayerTagDefinition[] = [
  SELF_TAG,
  TAGGED_TAG,
  PREMADE_TAG,
  HIGH_WIN_RATE_TAG,
  MET_TAG,
  WINNING_STREAK_TAG,
  LOSING_STREAK_TAG,
  GREAT_PERFORMANCE_TAG,
  EASY_GANK_TAG,
  SOLO_KILLS_TAG,
  DAMAGE_SHARE_TAG,
  CS_PER_MINUTE_TAG,
  VISION_SCORE_TAG,
  // 以下三项为本项目在 LeagueAkari 之外补充、但同样按 chip + 弹层规范呈现的指标。
  DEATHS_TAG,
  PARTICIPATION_TAG,
  POOL_CONCENTRATION_TAG,
  SCORE_TAG,
];
