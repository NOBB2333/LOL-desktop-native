import { chip, textPopover } from "../chip";
import { EASY_GANK_TONES, premadeGroupColor } from "../tones";
import type { PlayerTagDefinition } from "../types";

/**
 * LeagueAkari `basic.tsx` 的移植。
 *
 * 一条原则必须守住：**场均类标签只报数值，不做「偏高 / 偏低」判断。**
 * AK 只对少数几项做分档（好抓难抓、击杀伤害转化、极高胜率、连胜连败、优异表现），
 * 其余场均指标都是「打开开关就显示那个数」。本项目此前给存活、参团、视野、
 * 伤害占比都加了主观高低阈值，是噪声的主要来源，这里全部去掉。
 */

const TAG_LABELS = {
  self: "自己",
  premade: "开黑",
  highWinRate: "极高胜率",
  private: "战绩隐藏",
  easyGank: { "hard-gank": "难抓", "easy-gank": "好抓", "very-easy-gank": "非常好抓" },
  killDamageHigh: "击杀伤害转化高",
  killDamageLow: "击杀伤害转化低",
} as const;

/** 好抓 / 难抓文案；卡片标签与 `signals.ts` 的快捷消息变量共用，避免两套说法。 */
export const EASY_GANK_LABELS = TAG_LABELS.easyGank;
/** 极高胜率文案，同上共用。 */
export const HIGH_WIN_RATE_LABEL = TAG_LABELS.highWinRate;

/** `{streak}` 变量与连胜/连败标签共用的文案。 */
export function streakLabel(facts: { winningStreak: number; losingStreak: number }): string {
  if (facts.winningStreak >= STREAK_THRESHOLD) return `${facts.winningStreak} 连胜`;
  if (facts.losingStreak >= STREAK_THRESHOLD) return `${facts.losingStreak} 连败`;
  return "状态稳定";
}

/** 场均单杀文案：`{n} 单杀`。 */
export function soloKillsLabel(average: number): string {
  return `${average.toFixed(1)} 单杀`;
}

/** 极高胜率：样本 ≥ 16 场且胜率 ≥ 85%（AK 的 `analysis.winLoss.all`）。 */
export const HIGH_WIN_RATE_MIN_SAMPLE = 16;
export const HIGH_WIN_RATE_THRESHOLD = 0.85;

/** 连胜 / 连败阈值，AK 同为 3。 */
export const STREAK_THRESHOLD = 3;

/** 击杀伤害转化的分档阈值（AK `basic.tsx`）。 */
export const KILL_DAMAGE_EFFICIENCY_LOW_THRESHOLD = 0.65;
export const KILL_DAMAGE_EFFICIENCY_HIGH_THRESHOLD = 1.35;

/** 好抓 / 难抓：15 分钟前被敌方打野参与击杀的场均值分档（AK `getEasyGankTag`）。 */
export type EasyGankTag = {
  kind: "hard-gank" | "easy-gank" | "very-easy-gank";
  times: number;
  count: number;
};

export function resolveEasyGankTag(
  averageTimes: number | null,
  sample: number,
  isCurrentJungler: boolean,
): EasyGankTag | null {
  // 打野自己不会被标「好抓」。
  if (isCurrentJungler || averageTimes === null) return null;
  const times = averageTimes;
  // `[1, 1.5)` 不标注：既不算好抓也不算难抓。
  if (times >= 1 && times < 1.5) return null;
  if (times > 2) return { kind: "very-easy-gank", times, count: sample };
  if (times >= 1.5) return { kind: "easy-gank", times, count: sample };
  return { kind: "hard-gank", times, count: sample };
}

/** 击杀伤害转化分档（AK `getKillDamageEfficiencyTag`）。 */
export function resolveKillDamageEfficiency(value: number): "high" | "low" | "normal" {
  if (value > KILL_DAMAGE_EFFICIENCY_HIGH_THRESHOLD) return "high";
  if (value < KILL_DAMAGE_EFFICIENCY_LOW_THRESHOLD) return "low";
  return "normal";
}

const truncateTailingZeros = (value: number, precision = 1) =>
  value.toFixed(precision).replace(/\.?0+$/, "");

/** 自己：只在本地玩家身上出现。 */
export const SELF_TAG: PlayerTagDefinition = {
  id: "self",
  render: (ctx) => {
    if (!ctx.settings.showSelfTag || !ctx.selfPuuid || ctx.player.puuid !== ctx.selfPuuid) return null;
    return { label: chip(TAG_LABELS.self, { tone: "self" }) };
  },
};

/** 预组队：按分组编号取色，同组同色。 */
export const PREMADE_TEAM_TAG: PlayerTagDefinition = {
  id: "premade-team",
  render: (ctx) => {
    if (!ctx.settings.showPremadeTeamTag) return null;
    const tone = ctx.premadeTone;
    if (tone === undefined && !ctx.player.isPremade) return null;

    const color = premadeGroupColor(tone);
    const members = ctx.player.premadeWith.filter(Boolean);
    const labelText = tone === undefined ? TAG_LABELS.premade : `${TAG_LABELS.premade} ${tone + 1}`;
    const detail = members.length
      ? `与 ${members.join("、")} 开黑`
      : "检测到已知组队（选人阶段可能尚未公开队友名称）";

    return {
      label: chip(labelText, { tone: "premade", bg: color?.bg, fg: color?.fg }),
      popover: textPopover(detail),
    };
  },
};

/** 极高胜率：胜率高到不像真的。 */
export const HIGH_WIN_RATE_TAG: PlayerTagDefinition = {
  id: "high-win-rate",
  render: (ctx) => {
    const { facts } = ctx;
    if (!ctx.settings.showWinRateTeamTag) return null;
    if (facts.sample < HIGH_WIN_RATE_MIN_SAMPLE || facts.winRate < HIGH_WIN_RATE_THRESHOLD) return null;

    return {
      label: chip(TAG_LABELS.highWinRate, { tone: "win-rate" }),
      popover: textPopover(
        () => `该玩家的胜率高到不可置信。在近期 ${facts.sample} 场的对局中，赢了 ${facts.wins} 场`,
      ),
    };
  },
};

/** 战绩隐藏：玩家把生涯设为私密。 */
export const PRIVACY_TAG: PlayerTagDefinition = {
  id: "privacy",
  render: (ctx) => {
    if (!ctx.settings.showPrivacyTag) return null;
    if (ctx.player.privacy !== "PRIVATE") return null;
    return {
      label: chip(TAG_LABELS.private, { tone: "privacy" }),
      popover: textPopover("该玩家把战绩设为私密，客户端不会返回他的对局列表"),
    };
  },
};

/** 连胜。 */
export const WINNING_STREAK_TAG: PlayerTagDefinition = {
  id: "winning-streak",
  render: (ctx) => {
    const { facts } = ctx;
    if (!ctx.settings.showWinningStreakTag || facts.winningStreak < STREAK_THRESHOLD) return null;
    return {
      label: chip(() => `${facts.winningStreak} 连胜`, { tone: "streak-win" }),
      popover: textPopover(() => `截止到现在，该玩家 ${facts.winningStreak} 连胜，很棒`),
    };
  },
};

/** 连败。 */
export const LOSING_STREAK_TAG: PlayerTagDefinition = {
  id: "losing-streak",
  render: (ctx) => {
    const { facts } = ctx;
    if (!ctx.settings.showLosingStreakTag || facts.losingStreak < STREAK_THRESHOLD) return null;
    return {
      label: chip(() => `${facts.losingStreak} 连败`, { tone: "streak-loss" }),
      popover: textPopover(() => `截止到现在，该玩家 ${facts.losingStreak} 连败`),
    };
  },
};

/** 好抓 / 难抓 / 非常好抓。 */
export const EASY_GANK_TAG: PlayerTagDefinition = {
  id: "easy-gank",
  render: (ctx) => {
    const { facts } = ctx;
    if (!ctx.settings.showEasyGankTag) return null;
    const tag = resolveEasyGankTag(
      facts.averageEarlyDeathsWithJungler,
      facts.earlyDeathsSample,
      facts.isJungler,
    );
    if (!tag) return null;
    return {
      label: chip(TAG_LABELS.easyGank[tag.kind], { tone: EASY_GANK_TONES[tag.kind] }),
      popover: textPopover(
        () =>
          `在最近已分析的 ${tag.count} 场召唤师峡谷对局中，该玩家 15 分钟前被敌方打野参与击杀的场均次数为 ${tag.times.toFixed(2)} 次`,
      ),
    };
  },
};

/** 场均单杀：chip 直接给次数，不做「威胁 / 有能力」这类主观分档。 */
export const SOLO_KILLS_TAG: PlayerTagDefinition = {
  id: "solo-kills",
  render: (ctx) => {
    const { facts } = ctx;
    if (!ctx.settings.showSoloKillsTag) return null;
    const average = facts.averageSoloKills;
    if (average === null || average <= 0) return null;
    if (facts.soloKillsSample < 3) return null;
    return {
      label: chip(() => `${average.toFixed(1)} 单杀`, { tone: "solo" }),
      popover: textPopover(
        () => `在近期 ${facts.soloKillsSample} 场游戏中，该玩家场均单杀 ${average.toFixed(2)} 次`,
      ),
    };
  },
};

/**
 * 以下为 AK 的 `AVERAGE_*` 系列：**只报数值，不做高低判断**，
 * 且多数默认关闭（见 `settings.ts`）。数值缺失时不渲染，而不是显示 0。
 */

/** 场均队伍伤害占比。 */
export const AVERAGE_TEAM_DAMAGE_TAG: PlayerTagDefinition = {
  id: "average-team-damage",
  render: (ctx) => {
    const { facts } = ctx;
    if (!ctx.settings.showAverageTeamDamageTag || facts.sample === 0) return null;
    return {
      label: chip(() => `伤害 ${(facts.avgChampionDamagePercentageOfTeam * 100).toFixed(0)}%`, { tone: "damage" }),
      popover: textPopover(
        () =>
          `在近期 ${facts.sample} 场对局中，该玩家的平均团队伤害占比为 ${(facts.avgChampionDamagePercentageOfTeam * 100).toFixed(2)}%`,
      ),
    };
  },
};

/** 场均队伍承伤占比。 */
export const AVERAGE_TEAM_DAMAGE_TAKEN_TAG: PlayerTagDefinition = {
  id: "average-team-damage-taken",
  render: (ctx) => {
    const { facts } = ctx;
    const share = facts.avgDamageTakenPercentageOfTeam;
    if (!ctx.settings.showAverageTeamDamageTakenTag || share === null) return null;
    return {
      label: chip(() => `承伤 ${(share * 100).toFixed(0)}%`, { tone: "damage-taken" }),
      popover: textPopover(
        () => `在近期 ${facts.sample} 场对局中，该玩家的平均团队承伤占比为 ${(share * 100).toFixed(2)}%`,
      ),
    };
  },
};

/** 场均队伍经济占比。 */
export const AVERAGE_TEAM_GOLD_TAG: PlayerTagDefinition = {
  id: "average-team-gold",
  render: (ctx) => {
    const { facts } = ctx;
    const share = facts.avgGoldPercentageOfTeam;
    if (!ctx.settings.showAverageTeamGoldTag || share === null) return null;
    return {
      label: chip(() => `经济 ${(share * 100).toFixed(0)}%`, { tone: "gold" }),
      popover: textPopover(
        () => `在近期 ${facts.sample} 场对局中，该玩家的平均团队经济占比为 ${(share * 100).toFixed(2)}%`,
      ),
    };
  },
};

/** 场均分均补兵；弹层额外给出补刀占队伍的比例。 */
export const AVERAGE_CS_PER_MINUTE_TAG: PlayerTagDefinition = {
  id: "average-cs-per-minute",
  render: (ctx) => {
    const { facts } = ctx;
    if (!ctx.settings.showAverageCsPerMinuteTag || facts.sample === 0) return null;
    return {
      label: chip(() => `分均补刀 ${facts.avgCsPerMinute.toFixed(1)}`, { tone: "cs" }),
      popover: textPopover(() => {
        const lines = [
          `在近期 ${facts.sample} 场对局中，该玩家平均每分钟补兵 ${facts.avgCsPerMinute.toFixed(2)} 个`,
        ];
        if (facts.avgCsPercentageOfTeam !== null) {
          lines.push(`补刀占队伍总量 ${(facts.avgCsPercentageOfTeam * 100).toFixed(2)}%`);
        }
        return lines.join("\n");
      }),
    };
  },
};

/** 场均伤害 / 经济转化：每点经济打出多少伤害。 */
export const AVERAGE_DAMAGE_GOLD_EFFICIENCY_TAG: PlayerTagDefinition = {
  id: "average-damage-gold-efficiency",
  render: (ctx) => {
    const { facts } = ctx;
    if (!ctx.settings.showAverageDamageGoldEfficiencyTag || facts.sample === 0) return null;
    const rate = facts.avgDamageGoldEfficiency;
    if (!Number.isFinite(rate) || rate <= 0) return null;
    return {
      label: chip(() => `伤害经济 ${(rate * 100).toFixed(0)}%`, { tone: "damage-gold" }),
      popover: textPopover(
        () =>
          [
            `在近期 ${facts.sample} 场对局中，该玩家的平均伤害经济转化为 ${(rate * 100).toFixed(2)}%`,
            "定义：对英雄伤害 ÷ 获得经济。数值越高，说明同样多的经济打出的伤害越多。",
          ].join("\n"),
      ),
    };
  },
};

/** 场均「敌人消失」信号次数。LCU 数据源没有 ping 计数，因此可能整体不渲染。 */
export const AVERAGE_ENEMY_MISSING_PINGS_TAG: PlayerTagDefinition = {
  id: "average-enemy-missing-pings",
  render: (ctx) => {
    const { facts } = ctx;
    const pings = facts.avgEnemyMissingPings;
    if (!ctx.settings.showAverageEnemyMissingPingsTag || pings === null) return null;
    return {
      label: chip(() => `消失信号 ${truncateTailingZeros(pings)}`, { tone: "pings" }),
      popover: textPopover(
        () => `该玩家平均每局发出 ${pings.toFixed(3)} 次「敌人消失」信号`,
      ),
    };
  },
};

/** 场均视野得分。 */
export const AVERAGE_VISION_SCORE_TAG: PlayerTagDefinition = {
  id: "average-vision-score",
  render: (ctx) => {
    const { facts } = ctx;
    if (!ctx.settings.showAverageVisionScoreTag || facts.sample === 0) return null;
    return {
      label: chip(() => `视野分 ${truncateTailingZeros(facts.avgVisionScore)}`, { tone: "vision" }),
      popover: textPopover(
        () => `该玩家平均每局视野得分 ${facts.avgVisionScore.toFixed(3)} 分`,
      ),
    };
  },
};

/** 击杀伤害转化：击杀份额 ÷ 伤害份额。 */
export const AVERAGE_KILL_DAMAGE_EFFICIENCY_TAG: PlayerTagDefinition = {
  id: "average-kill-damage-efficiency",
  render: (ctx) => {
    const { facts } = ctx;
    if (!ctx.settings.showAverageKillDamageEfficiencyTag || facts.sample === 0) return null;
    const value = facts.avgKillDamageEfficiency;
    const kind = resolveKillDamageEfficiency(value);
    if (kind === "normal") return null;
    const label = kind === "high" ? TAG_LABELS.killDamageHigh : TAG_LABELS.killDamageLow;
    return {
      label: chip(label, { tone: "kill-damage" }),
      popover: textPopover(
        () =>
          `${kind === "high" ? "击杀份额高于伤害份额" : "伤害份额高于击杀份额"}：${(value * 100).toFixed(2)}%（近期 ${facts.sample} 场均值）`,
      ),
    };
  },
};

/** AK `basic.tsx` 的标签列表（顺序与 AK 的 `PLAYER_CARD_TAGS` 中这一段一致）。 */
export const BASIC_PLAYER_CARD_TAGS: PlayerTagDefinition[] = [
  SELF_TAG,
  PREMADE_TEAM_TAG,
  HIGH_WIN_RATE_TAG,
  PRIVACY_TAG,
  WINNING_STREAK_TAG,
  LOSING_STREAK_TAG,
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
];
