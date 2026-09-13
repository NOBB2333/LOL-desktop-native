/**
 * 标签配色令牌。
 *
 * 每个标签一个色，色值直接取自 LeagueAkari 的 `tagClass(...)`：
 * - `SELF` #37246c、`MET` #5cacea(黑字)、`TAGGED` #49914d、
 *   `HIGH_WIN_RATE` #7e2c85、`WINNING_STREAK` #18571c、`LOSING_STREAK` #893b3b、
 *   `PRIVACY` #870808、`AKARI_SCORE`/`GREAT_PERFORMANCE` #b81b86、
 *   `EASY_GANK` #24606d / #8f541e / #a81919、`SOLO_KILLS` #9019a8、
 *   各项场均指标 #692723 / #135225 / #a73d2a / #5a4a1f / #8f411e / #e7da30 / #2451a6 / #04614b。
 *
 * 这里用 CSS 变量落地（定义在 `styles/main.css` 的 `.tag-chip--*`），
 * 以便跟随应用的四套主题自动切换。
 */
export type TagTone =
  /** 自己 */
  | "self"
  /** 开黑组队 */
  | "premade"
  /** 遇到过 */
  | "met"
  /** 玩家标记（tagged） */
  | "note"
  /** 极高胜率 */
  | "win-rate"
  /** 生涯隐藏 */
  | "privacy"
  /** 连胜 */
  | "streak-win"
  /** 连败 */
  | "streak-loss"
  /** 综合评分 / 亮眼表现 */
  | "score"
  /** 难抓 */
  | "gank-hard"
  /** 好抓 */
  | "gank-easy"
  /** 非常好抓 */
  | "gank-very-easy"
  /** 单杀 */
  | "solo"
  /** 团队伤害占比 */
  | "damage"
  /** 分均补刀 */
  | "cs"
  /** 视野得分 */
  | "vision"
  /** 通用「正向」 */
  | "good"
  /** 通用「警示」 */
  | "warn"
  /** 通用「危险」 */
  | "danger"
  /** 通用「中性信息」 */
  | "info"
  | "neutral";

/** 开黑分组配色（对齐 LeagueAkari 的 A~L 分组色板，此处收敛为 8 组循环）。 */
export const PREMADE_GROUP_COLORS: { bg: string; fg: string }[] = [
  { bg: "#0f6f68", fg: "#ffffff" }, // A
  { bg: "#1f3fa6", fg: "#ffffff" }, // B
  { bg: "#5c6000", fg: "#ffffff" }, // C
  { bg: "#1a7a2a", fg: "#ffffff" }, // D
  { bg: "#8a4400", fg: "#ffffff" }, // E
  { bg: "#8a2a00", fg: "#ffffff" }, // F
  { bg: "#6a0d6a", fg: "#ffffff" }, // G
  { bg: "#a2133f", fg: "#ffffff" }, // H
];

export function premadeGroupColor(tone: number | undefined): { bg: string; fg: string } | null {
  if (tone === undefined || tone < 0) return null;
  return PREMADE_GROUP_COLORS[tone % PREMADE_GROUP_COLORS.length];
}

/** `easy-gank` 三档色值，与 LeagueAkari 的 `EASY_GANK_TAG_CLASSES` 一一对应。 */
export const EASY_GANK_TONES = {
  "hard-gank": "gank-hard",
  "easy-gank": "gank-easy",
  "very-easy-gank": "gank-very-easy",
} as const satisfies Record<string, TagTone>;
