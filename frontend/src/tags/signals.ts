/**
 * 前端侧的「玩家信号」。
 *
 * 真机路径上这些信号由后端产出（`src/backend/player_signals.zig`），因为队伍小结与
 * 快捷消息模板都在后端渲染。只有**浏览器预览**（没有原生后端）需要在前端自己算，
 * 于是有了这个模块：
 *
 * - 队伍小结的 strengths / risks（`fixtures/data.ts`）
 * - 快捷消息模板里的 `{tag}` / `{streak}` / `{risk}`（`services/backend.ts`）
 *
 * 为了不出现「同一概念两套说法」：
 * - **阈值**全部 import 自 `definitions/`，不存在第二份数字；
 * - **文案**全部来自 `definitions/` 导出的常量与函数；
 * - 分档顺序与 `backend/player_signals.zig` 的 `emitAll` 保持一致。
 */
import type { PlayerProfile } from "../types/domain";
import { deriveTagFacts, type PlayerTagFacts } from "./facts";
import {
  HIGH_WIN_RATE_LABEL,
  HIGH_WIN_RATE_MIN_SAMPLE,
  HIGH_WIN_RATE_THRESHOLD,
  STREAK_THRESHOLD,
  streakLabel,
} from "./definitions/performance";
import {
  AVERAGE_MIN_SAMPLE,
  DAMAGE_CORE_THRESHOLD,
  DEATHS_HIGH_LABEL,
  DEATHS_LOW_LABEL,
  EASY_GANK_LABELS,
  HIGH_DEATH_THRESHOLD,
  HIGH_PARTICIPATION_THRESHOLD,
  LOW_DEATH_THRESHOLD,
  LOW_PARTICIPATION_THRESHOLD,
  PARTICIPATION_HIGH_LABEL,
  PARTICIPATION_LOW_LABEL,
  POOL_CONCENTRATION_LABEL,
  POOL_CONCENTRATION_THRESHOLD,
  SOLO_KILL_MIN_SAMPLE,
  STRONG_FARM_THRESHOLD,
  csPerMinuteLabel,
  damageShareLabel,
  soloKillsLabel,
} from "./definitions/playstyle";

/**
 * 信号倾向。`neutral` 与 `positive` 同进 strengths（只是陈述，不是优点）。
 * 与后端 `player_signals.zig` 的 `Tone` 一一对应。
 */
export type SignalPolarity = "positive" | "negative" | "neutral";

export interface PlayerSignal {
  label: string;
  polarity: SignalPolarity;
}

/** 好抓判定阈值，与 `EASY_GANK_TAG` 注释里的四档一致。 */
const GANK_VERY_EASY_THRESHOLD = 2;
const GANK_EASY_THRESHOLD = 1.5;

/** 按与后端 `emitAll` 相同的顺序产出全部信号。 */
export function playerSignals(profile: PlayerProfile, facts = deriveTagFacts(profile)): PlayerSignal[] {
  const signals: PlayerSignal[] = [];
  if (facts.sample === 0) return signals;

  const push = (label: string, polarity: SignalPolarity) => {
    if (label) signals.push({ label, polarity });
  };

  if (facts.sample >= HIGH_WIN_RATE_MIN_SAMPLE && facts.winRate >= HIGH_WIN_RATE_THRESHOLD) {
    push(HIGH_WIN_RATE_LABEL, "positive");
  }
  if (facts.winningStreak >= STREAK_THRESHOLD) push(`${facts.winningStreak} 连胜`, "positive");
  if (facts.losingStreak >= STREAK_THRESHOLD) push(`${facts.losingStreak} 连败`, "negative");

  if (!facts.isJungler && facts.averageEarlyDeathsWithJungler !== null) {
    const times = facts.averageEarlyDeathsWithJungler;
    if (times > GANK_VERY_EASY_THRESHOLD) push(EASY_GANK_LABELS["very-easy-gank"], "negative");
    else if (times >= GANK_EASY_THRESHOLD) push(EASY_GANK_LABELS["easy-gank"], "negative");
    else if (times < 1) push(EASY_GANK_LABELS["hard-gank"], "positive");
  }

  if (facts.soloKillsSample >= SOLO_KILL_MIN_SAMPLE && facts.averageSoloKills !== null && facts.averageSoloKills > 0) {
    push(soloKillsLabel(facts.averageSoloKills), "neutral");
  }

  if (facts.sample >= AVERAGE_MIN_SAMPLE) {
    if (facts.averageDamageShare >= DAMAGE_CORE_THRESHOLD) {
      push(damageShareLabel(facts.averageDamageShare), "positive");
    }
    if (facts.averageCsPerMinute >= STRONG_FARM_THRESHOLD) {
      push(csPerMinuteLabel(facts.averageCsPerMinute), "neutral");
    }
    if (facts.averageDeaths >= HIGH_DEATH_THRESHOLD) push(DEATHS_HIGH_LABEL, "negative");
    else if (facts.averageDeaths <= LOW_DEATH_THRESHOLD) push(DEATHS_LOW_LABEL, "positive");

    if (facts.averageParticipation >= HIGH_PARTICIPATION_THRESHOLD) {
      push(PARTICIPATION_HIGH_LABEL, "positive");
    } else if (facts.averageParticipation > 0 && facts.averageParticipation <= LOW_PARTICIPATION_THRESHOLD) {
      push(PARTICIPATION_LOW_LABEL, "negative");
    }
  }

  if (profile.championPoolConcentration >= POOL_CONCENTRATION_THRESHOLD) {
    push(POOL_CONCENTRATION_LABEL, "negative");
  }

  return signals;
}

export interface TeamSignalOptions {
  /** 为空时用兜底文案。 */
  emptyStrengths: string;
  emptyRisks: string;
}

/** 一队玩家的 strengths / risks（去重，保持首次出现顺序与后端一致）。 */
export function teamSignals(
  profiles: PlayerProfile[],
  options: TeamSignalOptions,
): { strengths: string[]; risks: string[] } {
  const strengths: string[] = [];
  const risks: string[] = [];
  for (const profile of profiles) {
    for (const signal of playerSignals(profile)) {
      const bucket = signal.polarity === "negative" ? risks : strengths;
      if (!bucket.includes(signal.label)) bucket.push(signal.label);
    }
  }
  if (!strengths.length) strengths.push(profiles.length ? options.emptyStrengths : "暂无队伍数据");
  if (!risks.length) risks.push(profiles.length ? options.emptyRisks : "等待玩家信息");
  return { strengths, risks };
}

/** `{streak}` 变量。 */
export function shortcutStreakLabel(profile: PlayerProfile, facts?: PlayerTagFacts): string {
  return streakLabel(facts ?? deriveTagFacts(profile));
}

/** `{tag}` 变量：第一条命中信号；无信号时为空串（与后端一致）。 */
export function shortcutPrimaryTag(profile: PlayerProfile): string {
  return playerSignals(profile)[0]?.label ?? "";
}

/** `{risk}` 变量：只取负向信号。 */
export function shortcutRiskLabels(profile: PlayerProfile): string {
  return playerSignals(profile)
    .filter((signal) => signal.polarity === "negative")
    .map((signal) => signal.label)
    .join("、");
}
