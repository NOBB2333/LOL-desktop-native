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
  /** 团队承伤占比 */
  | "damage-taken"
  /** 团队经济占比 */
  | "gold"
  /** 伤害经济转化 */
  | "damage-gold"
  /** 击杀伤害转化 */
  | "kill-damage"
  /** 敌方消失信号 */
  | "pings"
  /** 可疑闪现位置 */
  | "flash"
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

/**
 * 开黑分组配色（浅色模式）：LeagueAkari `PREMADE_TEAM_COLORS_LIGHT` 的 A~L 十二组，
 * 一组不漏（此前只抄了 8 组，第 9 组起会绕回 A 的颜色）。
 */
export const PREMADE_GROUP_COLORS: { bg: string; fg: string }[] = [
  { bg: "#0f6f68", fg: "#ffffff" }, // A
  { bg: "#1f3fa6", fg: "#ffffff" }, // B
  { bg: "#5c6000", fg: "#ffffff" }, // C
  { bg: "#1a7a2a", fg: "#ffffff" }, // D
  { bg: "#8a4400", fg: "#ffffff" }, // E
  { bg: "#8a2a00", fg: "#ffffff" }, // F
  { bg: "#6a0d6a", fg: "#ffffff" }, // G
  { bg: "#a2133f", fg: "#ffffff" }, // H
  { bg: "#0b3d91", fg: "#ffffff" }, // I
  { bg: "#7f0000", fg: "#ffffff" }, // J
  { bg: "#5a2a0b", fg: "#ffffff" }, // K
  { bg: "#333333", fg: "#ffffff" }, // L
];

/** 深色模式：LeagueAkari `PREMADE_TEAM_COLORS`，同序同长度。 */
export const PREMADE_GROUP_COLORS_DARK: { bg: string; fg: string }[] = [
  { bg: "#48e5db", fg: "#000000" }, // A
  { bg: "#628aff", fg: "#000000" }, // B
  { bg: "#d4de17", fg: "#000000" }, // C
  { bg: "#2eda3e", fg: "#000000" }, // D
  { bg: "#ff9f1c", fg: "#000000" }, // E
  { bg: "#da4e2e", fg: "#ffffff" }, // F
  { bg: "#bc2ebc", fg: "#ffffff" }, // G
  { bg: "#fa4e80", fg: "#000000" }, // H
  { bg: "#0b3d91", fg: "#ffffff" }, // I
  { bg: "#7f0000", fg: "#ffffff" }, // J
  { bg: "#8b4513", fg: "#ffffff" }, // K
  { bg: "#555555", fg: "#ffffff" }, // L
];

export function premadeGroupColor(
  tone: number | undefined,
  dark = false,
): { bg: string; fg: string } | null {
  if (tone === undefined || tone < 0) return null;
  const palette = dark ? PREMADE_GROUP_COLORS_DARK : PREMADE_GROUP_COLORS;
  return palette[tone % palette.length];
}

/**
 * 分组序号 → 分组字母。
 *
 * AK 的预组队标签与弹层都用字母（`小队 {{team}}`，team 取 `A`~`L`），
 * 因此内部用序号的分组在展示前必须先换算成字母，否则会出现「小队 1」这种文案。
 */
export function premadeGroupLabel(tone: number | undefined): string | null {
  if (tone === undefined || tone < 0) return null;
  return String.fromCharCode("A".charCodeAt(0) + (tone % PREMADE_GROUP_COLORS.length));
}

/** `easy-gank` 三档色值，与 LeagueAkari 的 `EASY_GANK_TAG_CLASSES` 一一对应。 */
export const EASY_GANK_TONES = {
  "hard-gank": "gank-hard",
  "easy-gank": "gank-easy",
  "very-easy-gank": "gank-very-easy",
} as const satisfies Record<string, TagTone>;
