import type { PlayerTagDefinition } from "./types";
import {
  AVERAGE_CS_PER_MINUTE_TAG,
  AVERAGE_DAMAGE_GOLD_EFFICIENCY_TAG,
  AVERAGE_ENEMY_MISSING_PINGS_TAG,
  AVERAGE_KILL_DAMAGE_EFFICIENCY_TAG,
  AVERAGE_TEAM_DAMAGE_TAG,
  AVERAGE_TEAM_DAMAGE_TAKEN_TAG,
  AVERAGE_TEAM_GOLD_TAG,
  AVERAGE_VISION_SCORE_TAG,
  EASY_GANK_TAG,
  HIGH_WIN_RATE_TAG,
  LOSING_STREAK_TAG,
  PREMADE_TEAM_TAG,
  PRIVACY_TAG,
  SELF_TAG,
  SOLO_KILLS_TAG,
  WINNING_STREAK_TAG,
} from "./definitions/basic";
import { AKARI_SCORE_TAG } from "./definitions/akari-score";
import { GREAT_PERFORMANCE_TAG } from "./definitions/great-performance";
import { MET_TAG } from "./definitions/met";
import { SUSPICIOUS_FLASH_POSITION_TAG } from "./definitions/suspicious-flash-position";
import { TAGGED_TAG } from "./definitions/tagged";

/**
 * 标签注册表。
 *
 * 顺序与 LeagueAkari 的 `PLAYER_CARD_TAGS`
 * （`renderer-shared/components/ongoing-game-panel/widgets/player-info-card/player-card-tags/tags/index.ts`）
 * **逐项一致**，共 21 条：
 *
 *   身份/关系 → 胜率与状态 → 亮眼表现 → 可疑闪现 → 打野与被抓 → 场均指标 → Akari 评分
 *
 * 数组顺序即展示顺序，`AKARI_SCORE_TAG` 与 AK 一样放在最后。
 *
 * 本项目此前在 AK 之外自创了「阵亡倾向 / 参团率 / 英雄池集中」三条，并给存活、
 * 参团、视野、伤害占比加了「偏高 / 偏低」分档——这些已全部删除：
 * AK 的方案里场均指标只报数值，不做主观评判。
 */
export const PLAYER_CARD_TAGS: PlayerTagDefinition[] = [
  SELF_TAG,
  TAGGED_TAG,
  PREMADE_TEAM_TAG,
  HIGH_WIN_RATE_TAG,
  MET_TAG,
  PRIVACY_TAG,
  WINNING_STREAK_TAG,
  LOSING_STREAK_TAG,
  GREAT_PERFORMANCE_TAG,
  SUSPICIOUS_FLASH_POSITION_TAG,
  EASY_GANK_TAG,
  SOLO_KILLS_TAG,
  AVERAGE_TEAM_DAMAGE_TAG,
  AVERAGE_TEAM_DAMAGE_TAKEN_TAG,
  AVERAGE_TEAM_GOLD_TAG,
  AVERAGE_CS_PER_MINUTE_TAG,
  AVERAGE_DAMAGE_GOLD_EFFICIENCY_TAG,
  AVERAGE_ENEMY_MISSING_PINGS_TAG,
  AVERAGE_VISION_SCORE_TAG,
  AVERAGE_KILL_DAMAGE_EFFICIENCY_TAG,
  AKARI_SCORE_TAG,
];
