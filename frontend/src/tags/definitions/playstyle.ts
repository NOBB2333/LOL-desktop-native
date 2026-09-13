import { chip, textPopover } from "../chip";
import { EASY_GANK_TONES } from "../tones";
import type { PlayerTagDefinition } from "../types";

/** 场均样本下限：低于此值不做「场均」类判定，避免 1~2 场的噪声。 */
export const AVERAGE_MIN_SAMPLE = 5;

/** 单杀判定：需要至少 3 场提供精确数据的对局。 */
export const SOLO_KILL_MIN_SAMPLE = 3;

export const HIGH_DEATH_THRESHOLD = 6;
export const LOW_DEATH_THRESHOLD = 3;

export const HIGH_PARTICIPATION_THRESHOLD = 0.62;
export const LOW_PARTICIPATION_THRESHOLD = 0.4;

export const DAMAGE_CORE_THRESHOLD = 0.27;
export const STRONG_FARM_THRESHOLD = 7.2;

export const HIGH_VISION_THRESHOLD = 25;
export const LOW_VISION_THRESHOLD = 10;

export const POOL_CONCENTRATION_THRESHOLD = 0.7;

/**
 * 以下文案常量同时被卡片标签、`frontend/src/tags/signals.ts`（浏览器预览下的
 * 队伍小结与快捷消息变量）和后端 `src/backend/player_signals.zig` 使用。
 * 改动文案或阈值时必须三处同步，否则又会出现「同一概念两套说法」。
 */
export const EASY_GANK_LABELS = {
  "hard-gank": "难抓",
  "easy-gank": "好抓",
  "very-easy-gank": "非常好抓",
} as const;

export const DEATHS_HIGH_LABEL = "阵亡偏多";
export const DEATHS_LOW_LABEL = "生存稳健";
export const PARTICIPATION_HIGH_LABEL = "参团积极";
export const PARTICIPATION_LOW_LABEL = "参团偏低";
export const POOL_CONCENTRATION_LABEL = "英雄池集中";

/** 单杀 chip 文案：`{n} 单杀`。 */
export function soloKillsLabel(average: number): string {
  return `${average.toFixed(1)} 单杀`;
}

/** 伤害占比 chip 文案：`伤害 {n}%`。 */
export function damageShareLabel(share: number): string {
  return `伤害 ${(share * 100).toFixed(0)}%`;
}

/** 分均补刀 chip 文案：`分均补刀 {n}`。 */
export function csPerMinuteLabel(cs: number): string {
  return `分均补刀 ${cs.toFixed(1)}`;
}

/**
 * 好抓 / 难抓 / 非常好抓。
 *
 * 阈值与 LeagueAkari 的 `getEasyGankTag` 完全一致：
 * `> 2` 非常好抓、`>= 1.5` 好抓、`[1, 1.5)` 不标注、`< 1` 难抓。
 * 打野自己不会被标「好抓」。
 */
export const EASY_GANK_TAG: PlayerTagDefinition = {
  id: "easy-gank",
  render: (ctx) => {
    const { facts } = ctx;
    if (!ctx.settings.showEasyGankTag || facts.isJungler) return null;
    const times = facts.averageEarlyDeathsWithJungler;
    if (times === null) return null;
    if (times >= 1 && times <= 1.5) return null;

    if (times > 2) {
      return {
        label: chip(EASY_GANK_LABELS["very-easy-gank"], { tone: EASY_GANK_TONES["very-easy-gank"] }),
        popover: textPopover(() => easyGankPopover(times, facts.earlyDeathsSample)),
      };
    }
    if (times >= 1.5) {
      return {
        label: chip(EASY_GANK_LABELS["easy-gank"], { tone: EASY_GANK_TONES["easy-gank"] }),
        popover: textPopover(() => easyGankPopover(times, facts.earlyDeathsSample)),
      };
    }
    return {
      label: chip(EASY_GANK_LABELS["hard-gank"], { tone: EASY_GANK_TONES["hard-gank"] }),
      popover: textPopover(() => easyGankPopover(times, facts.earlyDeathsSample)),
    };
  },
};

const easyGankPopover = (times: number, count: number) =>
  `在最近已分析的 ${count} 场召唤师峡谷对局中，该玩家 15 分钟前被敌方打野参与击杀的场均次数为 ${times.toFixed(2)} 次`;

/**
 * 场均单杀。
 *
 * 对齐 LeagueAkari 的 `SOLO_KILLS_TAG`：chip 直接给出次数（`{{times}} 单杀`，
 * 如「1.2 单杀」），不用「威胁 / 有能力」这类主观分档；语境放弹层。
 */
export const SOLO_KILLS_TAG: PlayerTagDefinition = {
  id: "solo-kills",
  render: (ctx) => {
    const { facts } = ctx;
    if (!ctx.settings.showSoloKillsTag) return null;
    const average = facts.averageSoloKills;
    if (average === null || average <= 0) return null;
    if (facts.soloKillsSample < SOLO_KILL_MIN_SAMPLE) return null;

    return {
      label: chip(() => soloKillsLabel(average), { tone: "solo" }),
      popover: textPopover(
        () => `在近期 ${facts.soloKillsSample} 场游戏中，该玩家场均单杀 ${average.toFixed(2)} 次`,
      ),
    };
  },
};

/** 阵亡倾向。 */
export const DEATHS_TAG: PlayerTagDefinition = {
  id: "deaths",
  render: (ctx) => {
    const { facts } = ctx;
    if (!ctx.settings.showDeathsTag || facts.sample < AVERAGE_MIN_SAMPLE) return null;

    if (facts.averageDeaths >= HIGH_DEATH_THRESHOLD) {
      return {
        label: chip(DEATHS_HIGH_LABEL, { tone: "warn" }),
        popover: textPopover(
          () => `最近 ${facts.sample} 场场均阵亡 ${facts.averageDeaths.toFixed(1)} 次`,
        ),
      };
    }
    if (facts.averageDeaths <= LOW_DEATH_THRESHOLD) {
      return {
        label: chip(DEATHS_LOW_LABEL, { tone: "good" }),
        popover: textPopover(
          () => `最近 ${facts.sample} 场场均阵亡 ${facts.averageDeaths.toFixed(1)} 次`,
        ),
      };
    }
    return null;
  },
};

/** 参团率。 */
export const PARTICIPATION_TAG: PlayerTagDefinition = {
  id: "participation",
  render: (ctx) => {
    const { facts } = ctx;
    if (!ctx.settings.showParticipationTag || facts.sample < AVERAGE_MIN_SAMPLE) return null;

    if (facts.averageParticipation >= HIGH_PARTICIPATION_THRESHOLD) {
      return {
        label: chip(PARTICIPATION_HIGH_LABEL, { tone: "good" }),
        popover: textPopover(
          () => `最近 ${facts.sample} 场平均参团率 ${(facts.averageParticipation * 100).toFixed(0)}%`,
        ),
      };
    }
    if (facts.averageParticipation > 0 && facts.averageParticipation <= LOW_PARTICIPATION_THRESHOLD) {
      return {
        label: chip(PARTICIPATION_LOW_LABEL, { tone: "warn" }),
        popover: textPopover(
          () => `最近 ${facts.sample} 场平均参团率 ${(facts.averageParticipation * 100).toFixed(0)}%`,
        ),
      };
    }
    return null;
  },
};

/** 团队伤害占比。 */
export const DAMAGE_SHARE_TAG: PlayerTagDefinition = {
  id: "damage-share",
  render: (ctx) => {
    const { facts } = ctx;
    if (
      !ctx.settings.showDamageShareTag ||
      facts.sample < AVERAGE_MIN_SAMPLE ||
      facts.averageDamageShare < DAMAGE_CORE_THRESHOLD
    ) {
      return null;
    }
    return {
      label: chip(() => damageShareLabel(facts.averageDamageShare), { tone: "damage" }),
      popover: textPopover(
        () => `在最近的 ${facts.sample} 场对局中，该玩家的平均团队伤害占比为 ${(facts.averageDamageShare * 100).toFixed(2)}%`,
      ),
    };
  },
};

/** 分均补刀。 */
export const CS_PER_MINUTE_TAG: PlayerTagDefinition = {
  id: "cs-per-minute",
  render: (ctx) => {
    const { facts } = ctx;
    if (
      !ctx.settings.showCsPerMinuteTag ||
      facts.sample < AVERAGE_MIN_SAMPLE ||
      facts.averageCsPerMinute < STRONG_FARM_THRESHOLD
    ) {
      return null;
    }
    return {
      label: chip(() => csPerMinuteLabel(facts.averageCsPerMinute), { tone: "cs" }),
      popover: textPopover(
        () => `在最近的 ${facts.sample} 场对局中，该玩家平均每分钟补兵 ${facts.averageCsPerMinute.toFixed(2)} 个`,
      ),
    };
  },
};

/** 视野得分。 */
export const VISION_SCORE_TAG: PlayerTagDefinition = {
  id: "vision-score",
  render: (ctx) => {
    const { facts } = ctx;
    if (!ctx.settings.showVisionScoreTag) return null;
    const score = facts.averageVisionScore;
    if (score === null || facts.visionSample < AVERAGE_MIN_SAMPLE) return null;

    if (score >= HIGH_VISION_THRESHOLD) {
      return {
        label: chip(() => `视野分 ${score.toFixed(0)}`, { tone: "vision" }),
        popover: textPopover(() => `该玩家平均每局视野得分 ${score.toFixed(2)} 分`),
      };
    }
    if (score <= LOW_VISION_THRESHOLD) {
      return {
        label: chip(() => `视野偏少 ${score.toFixed(0)}`, { tone: "warn" }),
        popover: textPopover(() => `该玩家平均每局视野得分 ${score.toFixed(2)} 分`),
      };
    }
    return null;
  },
};

/** 英雄池集中。 */
export const POOL_CONCENTRATION_TAG: PlayerTagDefinition = {
  id: "pool-concentration",
  render: (ctx) => {
    if (!ctx.settings.showPoolConcentrationTag) return null;
    const concentration = ctx.player.championPoolConcentration;
    if (!Number.isFinite(concentration) || concentration < POOL_CONCENTRATION_THRESHOLD) return null;
    return {
      label: chip(POOL_CONCENTRATION_LABEL, { tone: "warn" }),
      popover: textPopover(
        () =>
          `单一英雄占近期样本 ${(concentration * 100).toFixed(0)}%，可结合 BP 针对`,
      ),
    };
  },
};
