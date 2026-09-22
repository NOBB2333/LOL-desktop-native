/**
 * 对局分析：把十个玩家的数据压成「这局谁占优、该重点防谁」。
 *
 * 为什么单独一个模块：右栏原来只有三条写死的风险规则，而个人数据在左侧卡片上
 * 已经全都能看到，右栏等于什么都没讲。这里把「逐路对位 → 本局胜率 → 重点关注」
 * 这条链路做成**纯函数**，好断言、也能在抽屉/复盘里复用。
 *
 * ⚠️ 这里**没有任何预测模型**，全部是可解释的加权对比。所以对外一律说「估算」，
 * 并把参与计算的项一起列出来——数字不对时用户能自己看出是哪一项偏了。
 */

import type { PlayerProfile } from "../types/domain";
import { HIGH_WIN_RATE_LABEL, HIGH_WIN_RATE_MIN_SAMPLE, HIGH_WIN_RATE_THRESHOLD } from "../tags/definitions/basic";
import { deriveTagFacts } from "../tags/facts";
import type { PlayerTagFacts } from "../tags/facts";
import { rankName } from "../utils/format";

/**
 * 「玩家 → 标签事实」的取数口。
 *
 * 做成参数而不是直接调 `deriveTagFacts`，是为了让这一层不绑死推导实现：
 * - 单测：Akari 综合分是从战绩推导出来的，想验证「通天代」那一档，注入一份结论远比
 *   反推打分公式去凑一堆恰好越过 8 分的对局可靠。
 * - 调用方已经算过 facts 时（例如抽屉里那一份），可以直接传进来复用，不必再推一遍。
 *
 * 不传就用 `defaultFactsResolver`。`deriveTagFacts` 是纯函数、无 memo，一人一次约
 * 20 场循环——右栏连着算几遍也只是几百次算术，不值得为它引入带失效问题的缓存。
 */
export type FactsResolver = (player: PlayerProfile) => PlayerTagFacts;

export const defaultFactsResolver: FactsResolver = (player) => deriveTagFacts(player);

/* ------------------------------------------------------------------ 分路 */

export const LANE_ORDER = ["TOP", "JUNGLE", "MIDDLE", "BOTTOM", "UTILITY"] as const;
export type Lane = (typeof LANE_ORDER)[number];

const LANE_LABELS: Record<Lane, string> = {
  TOP: "上路",
  JUNGLE: "打野",
  MIDDLE: "中路",
  BOTTOM: "下路",
  UTILITY: "辅助",
};

/**
 * `assignedPosition` 在不同数据源里写法不一致（实时对局给 `MIDDLE`/`UTILITY`，
 * 战绩里给 `MID`/`ADC`），所以别只认一种。收口在这里，别在视图里各写一份。
 */
const LANE_ALIASES: Record<string, Lane> = {
  TOP: "TOP",
  JUNGLE: "JUNGLE",
  JUG: "JUNGLE",
  MIDDLE: "MIDDLE",
  MID: "MIDDLE",
  BOTTOM: "BOTTOM",
  BOT: "BOTTOM",
  ADC: "BOTTOM",
  UTILITY: "UTILITY",
  SUPPORT: "UTILITY",
  SUP: "UTILITY",
};

export function laneOf(position: string | null | undefined): Lane | null {
  if (!position) return null;
  return LANE_ALIASES[position.trim().toUpperCase()] ?? null;
}

export function laneLabel(lane: Lane): string {
  return LANE_LABELS[lane];
}

/* -------------------------------------------------------------- 段位刻度 */

const TIER_BASE: Record<string, number> = {
  IRON: 0,
  BRONZE: 4,
  SILVER: 8,
  GOLD: 12,
  PLATINUM: 16,
  EMERALD: 20,
  DIAMOND: 24,
  MASTER: 28,
  GRANDMASTER: 32,
  CHALLENGER: 36,
};
const DIVISION_OFFSET: Record<string, number> = { IV: 0, III: 1, II: 2, I: 3 };
/** 大师以上没有小段，而且 LP 不封顶。 */
const MASTER_BASE = 28;

/**
 * 段位折算成一个可比较的连续刻度（越小越弱）。
 *
 * 取的是卡片上显示的那组字段（`rankTier` / `rankDivision` / `leaguePoints`），
 * **不用** `soloRank`/`flexRank`——这样右栏的结论和玩家卡片上的段位永远是同一个数，
 * 不会出现「卡片写铂金、右栏按另一个队列算成钻石」。
 */
export function rankScore(player: PlayerProfile): number | null {
  const base = TIER_BASE[player.rankTier?.trim().toUpperCase() ?? ""];
  if (base === undefined) return null;
  const lp = Math.max(0, player.leaguePoints || 0);
  if (base >= MASTER_BASE) return base + lp / 100;
  return base + (DIVISION_OFFSET[player.rankDivision?.trim().toUpperCase() ?? ""] ?? 0) + lp / 400;
}

const SCORE_BANDS: [number, string][] = [
  [36, "王者"],
  [32, "宗师"],
  [28, "大师"],
  [24, "钻石"],
  [20, "翡翠"],
  [16, "铂金"],
  [12, "黄金"],
  [8, "白银"],
  [4, "青铜"],
  [0, "黑铁"],
];
const DIVISION_NAMES = ["IV", "III", "II", "I"];

/** `rankScore` 的反函数，用于把「平均段位」显示成人看得懂的样子。 */
export function describeRankScore(score: number | null): string {
  if (score === null) return "未定级";
  for (const [floor, name] of SCORE_BANDS) {
    if (score < floor) continue;
    if (floor >= MASTER_BASE) return name;
    const step = Math.min(DIVISION_NAMES.length - 1, Math.max(0, Math.floor(score - floor)));
    return `${name} ${DIVISION_NAMES[step]}`;
  }
  return "未定级";
}

function clamp01(value: number): number {
  if (!Number.isFinite(value)) return 0.5;
  return Math.min(1, Math.max(0, value));
}

/**
 * 把「n 场赢 k 场」往 50% 收：样本越小越靠近 50%。
 * 否则「1 场 100% 胜率」会和一个 20 场 85% 的人等价，对位结论直接失去意义。
 */
export function shrinkRate(rate: number, sample: number, priorWeight = 6): number {
  if (sample <= 0) return 0.5;
  const wins = rate * sample;
  return (wins + 0.5 * priorWeight) / (sample + priorWeight);
}

/* -------------------------------------------------------------- 单人评分 */

export interface MatchupMetric {
  key: string;
  label: string;
  /** 归一化到 0..1 的强度，用来算两边的差。 */
  value: number;
  /** 给人看的原文，例如「黄金 II · 62 LP」。 */
  display: string;
  weight: number;
}

export interface PlayerRating {
  total: number;
  metrics: MatchupMetric[];
}

/**
 * 权重取整到 1.00，方便解释。段位最重——它是唯一一个跨局稳定、又能横向比较的量。
 * 熟练度/状态给得低，因为它们在单局里波动大。
 */
const METRIC_WEIGHTS = { rank: 0.34, recent: 0.22, position: 0.16, champion: 0.12, form: 0.06, akari: 0.1 } as const;

/** 归一化用的刻度上界：约等于「王者 200 LP」。再高也不会顶满，因为那已经不是判断依据了。 */
const RANK_SCALE_MAX = 38;

export function ratePlayer(player: PlayerProfile, resolveFacts: FactsResolver = defaultFactsResolver): PlayerRating {
  const facts = resolveFacts(player);
  const metrics: MatchupMetric[] = [];

  const score = rankScore(player);
  if (score !== null) {
    metrics.push({
      key: "rank",
      label: "段位",
      weight: METRIC_WEIGHTS.rank,
      value: clamp01(score / RANK_SCALE_MAX),
      display: `${describeRankScore(score)}${player.leaguePoints ? ` · ${player.leaguePoints} LP` : ""}`,
    });
  }

  if (facts.sample > 0) {
    metrics.push({
      key: "recent",
      label: "近期胜率",
      weight: METRIC_WEIGHTS.recent,
      value: shrinkRate(facts.winRate, facts.sample),
      display: `近 ${facts.sample} 场 ${Math.round(facts.winRate * 100)}%`,
    });
  }

  if (player.positionGames > 0) {
    metrics.push({
      key: "position",
      label: "本位置",
      weight: METRIC_WEIGHTS.position,
      value: shrinkRate(player.positionWinRate, player.positionGames),
      display: `${player.positionGames} 场 ${Math.round(player.positionWinRate * 100)}%`,
    });
  }

  if (player.currentChampionGames > 0) {
    metrics.push({
      key: "champion",
      label: "英雄熟练",
      weight: METRIC_WEIGHTS.champion,
      value: shrinkRate(player.currentChampionWinRate, player.currentChampionGames),
      display: `${player.championName || "本命"} ${player.currentChampionGames} 场 ${Math.round(player.currentChampionWinRate * 100)}%`,
    });
  }

  if (facts.sample > 0) {
    const streak = facts.winningStreak - facts.losingStreak;
    metrics.push({
      key: "form",
      label: "近期状态",
      weight: METRIC_WEIGHTS.form,
      value: clamp01(0.5 + streak * 0.06),
      // 「1 连胜」不是连胜——只有真连起来（≥2）才那么说，否则一律「平稳」。
      display:
        facts.winningStreak >= 2
          ? `${facts.winningStreak} 连胜`
          : facts.losingStreak >= 2
            ? `${facts.losingStreak} 连败`
            : "平稳",
    });
  }

  if (facts.akariScore.maxScore > 0) {
    metrics.push({
      key: "akari",
      label: "Akari 评分",
      weight: METRIC_WEIGHTS.akari,
      value: clamp01(facts.akariScore.total / facts.akariScore.maxScore),
      display: `${facts.akariScore.total.toFixed(2)} / ${facts.akariScore.maxScore}`,
    });
  }

  // 缺项就按剩下的权重重归一化：宁可少算一项，也不要把「没数据」当成「水平 0」。
  const weightSum = metrics.reduce((sum, metric) => sum + metric.weight, 0);
  const total = weightSum > 0 ? metrics.reduce((sum, metric) => sum + metric.value * metric.weight, 0) / weightSum : 0.5;
  return { total, metrics };
}

/* -------------------------------------------------------------- 逐路对位 */

export interface MetricDelta {
  label: string;
  ally: string;
  enemy: string;
  delta: number;
}

export type LaneVerdict = "ally" | "enemy" | "even" | "unknown";

export interface LaneMatchup {
  lane: Lane;
  label: string;
  ally: PlayerProfile | null;
  enemy: PlayerProfile | null;
  allyRating: number;
  enemyRating: number;
  /** 正数 = 我方占优。 */
  edge: number;
  verdict: LaneVerdict;
  /** 差距最大的两项，用来解释「凭什么」。 */
  reasons: MetricDelta[];
}

/** 小于这个差值就当均势——不然 0.001 的差别也会被说成「占优」。 */
const EVEN_BAND = 0.03;

function indexByLane(players: PlayerProfile[]): Map<Lane, PlayerProfile> {
  const map = new Map<Lane, PlayerProfile>();
  for (const player of players) {
    const lane = laneOf(player.assignedPosition);
    if (lane && !map.has(lane)) map.set(lane, player);
  }
  return map;
}

export function laneMatchups(
  allies: PlayerProfile[],
  enemies: PlayerProfile[],
  resolveFacts: FactsResolver = defaultFactsResolver,
): LaneMatchup[] {
  const allyByLane = indexByLane(allies);
  const enemyByLane = indexByLane(enemies);

  return LANE_ORDER.flatMap((lane) => {
    const ally = allyByLane.get(lane) ?? null;
    const enemy = enemyByLane.get(lane) ?? null;
    // 两边都没有人就别占位置（ARAM、或者位置字段缺失时会走到这里）。
    if (!ally && !enemy) return [];

    const allyRating = ally ? ratePlayer(ally, resolveFacts) : null;
    const enemyRating = enemy ? ratePlayer(enemy, resolveFacts) : null;
    const allyTotal = allyRating?.total ?? 0.5;
    const enemyTotal = enemyRating?.total ?? 0.5;
    const edge = allyRating && enemyRating ? allyTotal - enemyTotal : 0;

    const verdict: LaneVerdict = !allyRating || !enemyRating ? "unknown" : Math.abs(edge) < EVEN_BAND ? "even" : edge > 0 ? "ally" : "enemy";

    const reasons: MetricDelta[] = [];
    if (allyRating && enemyRating) {
      const enemyMetrics = new Map(enemyRating.metrics.map((metric) => [metric.key, metric]));
      for (const metric of allyRating.metrics) {
        const counterpart = enemyMetrics.get(metric.key);
        if (!counterpart) continue;
        reasons.push({
          label: metric.label,
          ally: metric.display,
          enemy: counterpart.display,
          delta: metric.value - counterpart.value,
        });
      }
      reasons.sort((a, b) => Math.abs(b.delta) - Math.abs(a.delta));
    }

    return [{ lane, label: LANE_LABELS[lane], ally, enemy, allyRating: allyTotal, enemyRating: enemyTotal, edge, verdict, reasons: reasons.slice(0, 2) }];
  });
}

/** 五路能不能真的配上对。配不上时右栏要降级成「只看队伍汇总」，而不是编一个结论出来。 */
export function hasLaneCoverage(matchups: LaneMatchup[]): boolean {
  return matchups.filter((matchup) => matchup.verdict !== "unknown").length >= 3;
}

/* ------------------------------------------------------------ 本局胜率 */

export interface WinEstimate {
  /** 0..1，我方估算胜率。 */
  ally: number;
  enemy: number;
  /** 五路差值之和，正数=我方占优。 */
  edge: number;
  /** 真正参与计算的路径数。 */
  lanes: number;
}

/** 手感系数：五路差值之和 1.0 大概对应「一边倒」，但也不到 90%。 */
const EDGE_SCALE = 2.2;
/** 不宣称确定性：再好/再差的对位也留一线。 */
const MIN_PROBABILITY = 0.12;

export function estimateWinRate(matchups: LaneMatchup[]): WinEstimate {
  const usable = matchups.filter((matchup) => matchup.verdict !== "unknown");
  if (!usable.length) return { ally: 0.5, enemy: 0.5, edge: 0, lanes: 0 };
  const edge = usable.reduce((sum, matchup) => sum + matchup.edge, 0);
  const raw = 1 / (1 + Math.exp(-EDGE_SCALE * edge));
  const ally = Math.min(1 - MIN_PROBABILITY, Math.max(MIN_PROBABILITY, raw));
  return { ally, enemy: 1 - ally, edge, lanes: usable.length };
}

/* ---------------------------------------------------------- 队伍汇总 */

export interface TeamAggregate {
  count: number;
  /** 平均段位分，用来横向比两队的整体段位。 */
  averageRankScore: number | null;
  averageRankLabel: string;
  /** 按场次加权，避免「1 场 100%」把整队拉高。 */
  averageWinRate: number | null;
  winRateSample: number;
  averageAkari: number | null;
  /** 段位已知的人数，用来判断上面几个数稳不稳。 */
  rankedCount: number;
  premadeCount: number;
}

export function aggregateTeam(players: PlayerProfile[], resolveFacts: FactsResolver = defaultFactsResolver): TeamAggregate {
  const scores: number[] = [];
  let wins = 0;
  let sample = 0;
  let akariSum = 0;
  let akariCount = 0;
  let premadeCount = 0;

  for (const player of players) {
    const score = rankScore(player);
    if (score !== null) scores.push(score);
    const facts = resolveFacts(player);
    if (facts.sample > 0) {
      wins += facts.wins;
      sample += facts.sample;
    }
    if (facts.akariScore.maxScore > 0) {
      akariSum += facts.akariScore.total;
      akariCount += 1;
    }
    if (player.isPremade) premadeCount += 1;
  }

  const averageRankScore = scores.length ? scores.reduce((sum, value) => sum + value, 0) / scores.length : null;
  return {
    count: players.length,
    averageRankScore,
    averageRankLabel: describeRankScore(averageRankScore),
    averageWinRate: sample > 0 ? wins / sample : null,
    winRateSample: sample,
    averageAkari: akariCount > 0 ? akariSum / akariCount : null,
    rankedCount: scores.length,
    premadeCount,
  };
}

/* ---------------------------------------------------------- 重点关注 */

export type FocusTone = "danger" | "warning" | "good" | "info";

export interface FocusPoint {
  key: string;
  tone: FocusTone;
  title: string;
  /** 必须是**带数字的**证据。「高风险」这种不给数字的结论等于没说。 */
  detail: string;
  /** 排序用：分越高越该先看。 */
  severity: number;
}

const PERCENT = (value: number) => `${Math.round(value * 100)}%`;

/**
 * 重点关注：从两队里挑出「这局真正会影响胜负判断」的几件事，按严重度排序。
 *
 * 覆盖的是卡片上已有的那批判定（极高胜率、通天代/优异、连胜连败、组队、可疑闪现、
 * 好抓难抓），再加上对位算出来的错位——**但每条都带具体数字**，这是和原来那版
 * 「高风险」最大的区别。
 */
export function focusPoints(
  allies: PlayerProfile[],
  enemies: PlayerProfile[],
  matchups: LaneMatchup[],
  resolveFacts: FactsResolver = defaultFactsResolver,
): FocusPoint[] {
  const points: FocusPoint[] = [];

  for (const player of enemies) {
    const facts = resolveFacts(player);
    const who = player.gameName || "敌方玩家";

    if (facts.akariScore.extraordinary) {
      points.push({
        key: `extraordinary-${player.puuid}`,
        tone: "danger",
        title: `敌方 ${who} 是通天代`,
        detail: `Akari 综合分 ${facts.akariScore.total.toFixed(2)} / ${facts.akariScore.maxScore}（≥8 且样本 ≥8 场）${facts.sample > 0 ? `，近 ${facts.sample} 场 ${PERCENT(facts.winRate)} 胜率` : ""}。`,
        severity: 100,
      });
    } else if (facts.akariScore.outstanding) {
      points.push({
        key: `outstanding-${player.puuid}`,
        tone: "warning",
        title: `敌方 ${who} 表现优异`,
        detail: `Akari 综合分 ${facts.akariScore.total.toFixed(2)} / ${facts.akariScore.maxScore}（≥6.5 且样本 ≥5 场）。`,
        severity: 70,
      });
    }

    if (facts.sample >= HIGH_WIN_RATE_MIN_SAMPLE && facts.winRate >= HIGH_WIN_RATE_THRESHOLD) {
      points.push({
        key: `winrate-${player.puuid}`,
        tone: "danger",
        title: `敌方 ${who} ${HIGH_WIN_RATE_LABEL}`,
        detail: `近 ${facts.sample} 场 ${facts.wins} 胜（${PERCENT(facts.winRate)}）；本局英雄已打 ${player.currentChampionGames} 场。`,
        severity: 90,
      });
    }

    if (facts.winningStreak >= 3) {
      points.push({
        key: `win-streak-${player.puuid}`,
        tone: "warning",
        title: `敌方 ${who} 正处于连胜`,
        detail: `已经 ${facts.winningStreak} 连胜，手感在线。`,
        severity: 55,
      });
    }

    if (facts.losingStreak >= 3) {
      points.push({
        key: `loss-streak-${player.puuid}`,
        tone: "good",
        title: `敌方 ${who} 处于连败`,
        detail: `已经 ${facts.losingStreak} 连败，可以对这个点加压。`,
        severity: 40,
      });
    }

    if (facts.flashOnD > 0 && facts.flashOnF > 0) {
      points.push({
        key: `flash-${player.puuid}`,
        tone: "warning",
        title: `敌方 ${who} 闪现位置可疑`,
        detail: `闪现既放在 D 位（${facts.flashOnD} 次）也放在 F 位（${facts.flashOnF} 次），可能换人上号。`,
        severity: 60,
      });
    }

    if (facts.averageEarlyDeathsWithJungler !== null && facts.averageEarlyDeathsWithJungler > 2) {
      points.push({
        key: `gank-${player.puuid}`,
        tone: "good",
        title: `敌方 ${who} 非常易抓`,
        detail: `场均 ${facts.averageEarlyDeathsWithJungler.toFixed(1)} 次在 15 分钟前被敌方打野参与击杀，前期可以多去。`,
        severity: 50,
      });
    }

    if (player.privacy === "PRIVATE") {
      points.push({
        key: `privacy-${player.puuid}`,
        tone: "info",
        title: `敌方 ${who} 隐藏了战绩`,
        detail: "拿不到近期对局，对位评估里这个人只按段位算。",
        severity: 25,
      });
    }
  }

  // 组队只报一次，别一个人一条——那正是原来那版列表显得空洞的原因。
  const groups = new Map<string, PlayerProfile[]>();
  for (const player of enemies) {
    if (!player.premadeGroup) continue;
    groups.set(player.premadeGroup, [...(groups.get(player.premadeGroup) ?? []), player]);
  }
  for (const [groupId, members] of groups) {
    if (members.length < 2) continue;
    points.push({
      key: `premade-${groupId}`,
      tone: "warning",
      title: `敌方有一组 ${members.length} 人组队`,
      detail: `${members.map((member) => member.gameName).join(" + ")} 有共同组队证据，注意联动节奏。`,
      severity: 65,
    });
  }

  // 对位错位：把「哪一路最该管」直接点出来。
  const decided = matchups.filter((matchup) => matchup.verdict === "ally" || matchup.verdict === "enemy");
  if (decided.length) {
    const worst = decided.reduce((a, b) => (b.edge < a.edge ? b : a));
    const best = decided.reduce((a, b) => (b.edge > a.edge ? b : a));
    if (worst.edge < -EVEN_BAND) {
      points.push({
        key: `lane-worst-${worst.lane}`,
        tone: "danger",
        title: `我方 ${worst.label} 处于劣势`,
        detail: describeLaneGap(worst, "enemy"),
        severity: 80,
      });
    }
    if (best.edge > EVEN_BAND) {
      points.push({
        key: `lane-best-${best.lane}`,
        tone: "good",
        title: `我方 ${best.label} 占优`,
        detail: describeLaneGap(best, "ally"),
        severity: 45,
      });
    }
  }

  const allyAggregate = aggregateTeam(allies, resolveFacts);
  const enemyAggregate = aggregateTeam(enemies, resolveFacts);
  if (allyAggregate.averageRankScore !== null && enemyAggregate.averageRankScore !== null) {
    const gap = allyAggregate.averageRankScore - enemyAggregate.averageRankScore;
    if (Math.abs(gap) >= 2) {
      points.push({
        key: "rank-gap",
        tone: gap > 0 ? "good" : "danger",
        title: gap > 0 ? "我方整体段位更高" : "敌方整体段位更高",
        detail: `我方平均 ${allyAggregate.averageRankLabel}，敌方平均 ${enemyAggregate.averageRankLabel}。`,
        severity: 35,
      });
    }
  }

  if (!points.length) {
    points.push({
      key: "even",
      tone: "info",
      title: "双方数据接近",
      detail: `没有触发${HIGH_WIN_RATE_LABEL}、通代表现、连胜连败、组队或可疑闪现；五路对位也没有明显错位，按临场发挥打。`,
      severity: 10,
    });
  }

  return points.sort((a, b) => b.severity - a.severity).slice(0, 6);
}

/** 把一路的差距写成一句话，用差距最大的那一项当证据。 */
function describeLaneGap(matchup: LaneMatchup, side: "ally" | "enemy"): string {
  const reason = matchup.reasons[0];
  if (!reason) return "双方可用数据都不多，只能按段位粗看。";
  const leader = side === "ally" ? reason.ally : reason.enemy;
  const trailer = side === "ally" ? reason.enemy : reason.ally;
  return `${reason.label} ${leader}，对面 ${trailer}。`;
}

/* -------------------------------------------------------------- 评价 */

export function matchVerdict(matchups: LaneMatchup[], estimate: WinEstimate): string {
  if (!estimate.lanes) return "位置信息不全，先把左侧卡片上的个人数据作为主要参考。";
  const allyLanes = matchups.filter((matchup) => matchup.verdict === "ally").length;
  const enemyLanes = matchups.filter((matchup) => matchup.verdict === "enemy").length;
  const percent = PERCENT(estimate.ally);
  if (allyLanes === 0 && enemyLanes === 0) return `五路基本均势，估算我方胜率 ${percent}——这局看临场和配合。`;
  if (allyLanes > enemyLanes) return `五路里我方 ${allyLanes} 路占优、${enemyLanes} 路落后，估算我方胜率 ${percent}。`;
  if (enemyLanes > allyLanes) return `五路里敌方 ${enemyLanes} 路占优、我方 ${allyLanes} 路领先，估算我方胜率 ${percent}，前期要稳住。`;
  return `五路各占 ${allyLanes} 路，估算我方胜率 ${percent}，节奏和团战是胜负手。`;
}

/* ------------------------------------------------------- 段位名（供 UI） */

export { rankName };
