/**
 * Akari 评分模型。
 *
 * 逐行移植 LeagueAkari 的 `src/shared/data-adapter/analysis/player`：
 * - `scoring.ts` 的 6 个打分函数与 `clamp` / `scoreLinearRange`
 * - `constants.ts` 的全部评分常量
 * - `single/akari.ts` 的单局 9 项加权
 * - `aggregate/akari.ts` 的聚合规则
 *
 * 聚合规则有一个容易踩的细节：**它不是「逐局总分求平均」**，而是一半一半——
 * KDA 与胜率两项先用**聚合均值**（`avgKda` / `winRate`）再打分，
 * 其余 7 项是**逐局打分的均值**，最后把 9 项相加。
 *
 * `outstanding` / `extraordinary` 只在聚合层产出（单局恒为 false）。
 * 满分 `AKARI_MAX_SCORE = 17`。
 */

/** KDA 起评分：低于它 KDA 项得 0 分。 */
export const AKARI_KDA_BASELINE = 2;
export const AKARI_KDA_WEIGHT = 3 / 7;
export const AKARI_KDA_MAX_SCORE = 1;

export const AKARI_WIN_RATE_BASELINE = 0.5;
export const AKARI_WIN_RATE_WEIGHT = 1;

export const AKARI_DAMAGE_WEIGHT = 3;
export const AKARI_DAMAGE_TAKEN_WEIGHT = 2;

export const AKARI_HEALING_MIN_TEAM_AVERAGE_DAMAGE_TAKEN_RATIO = 0.2;
export const AKARI_HEALING_FULL_SCORE_TEAM_AVERAGE_DAMAGE_TAKEN_RATIO = 1.4;
export const AKARI_HEALING_SOLO_FULL_SCORE_TEAM_AVERAGE_DAMAGE_TAKEN_RATIO = 1;
export const AKARI_HEALING_MAX_SCORE = 2;

export const AKARI_CS_MIN_SCORE_PER_MINUTE = 5;
export const AKARI_CS_FULL_SCORE_PER_MINUTE = 10;
export const AKARI_CS_MAX_SCORE = 2;

export const AKARI_GOLD_WEIGHT = 2;

export const AKARI_PARTICIPATION_MIN_SHARE = 0.3;
export const AKARI_PARTICIPATION_WEIGHT = 2;

/** 伤害 / 承伤 / 视野「理应贡献」满分比（1.0 = 与队友平均持平）。 */
export const AKARI_STANDARD_EXPECTED_CONTRIBUTION_FULL_SCORE_RATIO = 2.0;
export const AKARI_EXPECTED_CONTRIBUTION_BASELINE_RATIO = 1.0;
/** 经济满分所需的理应贡献比。 */
export const AKARI_GOLD_EXPECTED_CONTRIBUTION_FULL_SCORE_RATIO = 1.5;

export const AKARI_VISION_MAX_SCORE = 2;

/** 满分 = 1 + 1 + 3 + 2 + 2 + 2 + 2 + 2 + 2。 */
export const AKARI_MAX_SCORE =
  AKARI_KDA_MAX_SCORE +
  AKARI_WIN_RATE_WEIGHT +
  AKARI_DAMAGE_WEIGHT +
  AKARI_DAMAGE_TAKEN_WEIGHT +
  AKARI_HEALING_MAX_SCORE +
  AKARI_CS_MAX_SCORE +
  AKARI_GOLD_WEIGHT +
  AKARI_PARTICIPATION_WEIGHT +
  AKARI_VISION_MAX_SCORE;

export const AGGREGATE_AKARI_OUTSTANDING_THRESHOLD = 6.5;
export const AGGREGATE_AKARI_OUTSTANDING_MIN_COUNT = 5;
export const AGGREGATE_AKARI_EXTRAORDINARY_THRESHOLD = 8;
export const AGGREGATE_AKARI_EXTRAORDINARY_MIN_COUNT = 8;

function clamp(value: number, min: number, max: number) {
  return Math.max(Math.min(value, max), min);
}

function scoreLinearRange(value: number, min: number, max: number, maxScore: number) {
  return ((clamp(value, min, max) - min) / (max - min)) * maxScore;
}

/** 0 会变成 1，避免除零得到 Infinity。对应 AK 的 `noZero`。 */
function noZero(value: number) {
  return value || 1;
}

/** 按「理应贡献比」线性给分：1.0 得 0 分，`fullScoreRatio` 得满分。 */
export function scoreExpectedContribution(ratio: number, fullScoreRatio: number, maxScore: number) {
  return scoreLinearRange(
    ratio,
    AKARI_EXPECTED_CONTRIBUTION_BASELINE_RATIO,
    fullScoreRatio,
    maxScore,
  );
}

/** KDA 项：`sqrt(max(kda - 2, 0)) * 3/7`，上限 1 分。 */
export function scoreKda(kda: number) {
  const effectiveKda = Math.max(kda - AKARI_KDA_BASELINE, 0);
  return clamp(Math.sqrt(effectiveKda) * AKARI_KDA_WEIGHT, 0, AKARI_KDA_MAX_SCORE);
}

export function scoreWinRate(winRate: number) {
  return scoreLinearRange(winRate, AKARI_WIN_RATE_BASELINE, 1, AKARI_WIN_RATE_WEIGHT);
}

export function scoreHealing(
  healingRatioToTeamAverageDamageTaken: number,
  teamParticipantCount: number,
) {
  const fullScoreRatio =
    teamParticipantCount === 1
      ? AKARI_HEALING_SOLO_FULL_SCORE_TEAM_AVERAGE_DAMAGE_TAKEN_RATIO
      : AKARI_HEALING_FULL_SCORE_TEAM_AVERAGE_DAMAGE_TAKEN_RATIO;

  return scoreLinearRange(
    healingRatioToTeamAverageDamageTaken,
    AKARI_HEALING_MIN_TEAM_AVERAGE_DAMAGE_TAKEN_RATIO,
    fullScoreRatio,
    AKARI_HEALING_MAX_SCORE,
  );
}

export function scoreCsPerMinute(csPerMinute: number) {
  return scoreLinearRange(
    csPerMinute,
    AKARI_CS_MIN_SCORE_PER_MINUTE,
    AKARI_CS_FULL_SCORE_PER_MINUTE,
    AKARI_CS_MAX_SCORE,
  );
}

export function scoreParticipation(killParticipation: number) {
  return scoreLinearRange(
    killParticipation,
    AKARI_PARTICIPATION_MIN_SHARE,
    1,
    AKARI_PARTICIPATION_WEIGHT,
  );
}

/**
 * 单局评分输入。
 *
 * 全部字段都是「本该在 `computeSingleSummary` 里算完的比例」，由 `facts.ts`
 * 从 `RecentMatch` 的份额字段 + 队伍总量反推；`null` 表示这一局的队伍数据不足，
 * 该局整体不参与评分（与 AK「`analysis` 为空则不渲染」的取向一致）。
 */
export interface SingleAkariInput {
  kda: number;
  win: boolean;
  teamParticipantCount: number;
  championDamageRatioToExpectedContribution: number;
  damageTakenRatioToExpectedContribution: number;
  healingRatioToTeamAverageDamageTaken: number;
  csPerMinute: number;
  goldRatioToExpectedContribution: number;
  killParticipation: number;
  visionScoreRatioToExpectedContribution: number;
}

/** 单局 9 项得分之和；`outstanding` / `extraordinary` 在单局恒为 false。 */
export function computeSingleAkariTotal(input: SingleAkariInput): number {
  return (
    scoreKda(input.kda) +
    scoreWinRate(input.win ? 1 : 0) +
    scoreExpectedContribution(
      input.championDamageRatioToExpectedContribution,
      AKARI_STANDARD_EXPECTED_CONTRIBUTION_FULL_SCORE_RATIO,
      AKARI_DAMAGE_WEIGHT,
    ) +
    scoreExpectedContribution(
      input.damageTakenRatioToExpectedContribution,
      AKARI_STANDARD_EXPECTED_CONTRIBUTION_FULL_SCORE_RATIO,
      AKARI_DAMAGE_TAKEN_WEIGHT,
    ) +
    scoreHealing(
      input.healingRatioToTeamAverageDamageTaken,
      input.teamParticipantCount,
    ) +
    scoreCsPerMinute(input.csPerMinute) +
    scoreExpectedContribution(
      input.goldRatioToExpectedContribution,
      AKARI_GOLD_EXPECTED_CONTRIBUTION_FULL_SCORE_RATIO,
      AKARI_GOLD_WEIGHT,
    ) +
    scoreParticipation(input.killParticipation) +
    scoreExpectedContribution(
      input.visionScoreRatioToExpectedContribution,
      AKARI_STANDARD_EXPECTED_CONTRIBUTION_FULL_SCORE_RATIO,
      AKARI_VISION_MAX_SCORE,
    )
  );
}

export interface AkariScoreComponent {
  key: string;
  label: string;
  score: number;
  maxScore: number;
}

export interface AkariScore {
  total: number;
  maxScore: number;
  outstanding: boolean;
  extraordinary: boolean;
  /** 9 项明细，供弹层展示「分是怎么来的」。 */
  components: AkariScoreComponent[];
}

/** 逐项取均值；空样本按 0（对应 AK 的 `avgOrZero`）。 */
function avgOrZero(values: number[]): number {
  if (!values.length) return 0;
  return values.reduce((sum, value) => sum + value, 0) / noZero(values.length);
}

/**
 * 聚合评分。
 *
 * 与 AK 的 `computeAggregatedAkariScore` 完全一致：KDA / 胜率吃的是聚合均值，
 * 其余 7 项吃的是「逐局得分的均值」。
 */
export function computeAggregateAkariScore(
  games: SingleAkariInput[],
  averageKda: number,
  winRate: number,
): AkariScore {
  const count = games.length;
  const components: AkariScoreComponent[] = [
    {
      key: "kda",
      label: "KDA",
      score: scoreKda(averageKda),
      maxScore: AKARI_KDA_MAX_SCORE,
    },
    {
      key: "win-rate",
      label: "胜率",
      score: scoreWinRate(winRate),
      maxScore: AKARI_WIN_RATE_WEIGHT,
    },
    {
      key: "damage",
      label: "伤害",
      score: avgOrZero(
        games.map((game) =>
          scoreExpectedContribution(
            game.championDamageRatioToExpectedContribution,
            AKARI_STANDARD_EXPECTED_CONTRIBUTION_FULL_SCORE_RATIO,
            AKARI_DAMAGE_WEIGHT,
          ),
        ),
      ),
      maxScore: AKARI_DAMAGE_WEIGHT,
    },
    {
      key: "damage-taken",
      label: "承伤",
      score: avgOrZero(
        games.map((game) =>
          scoreExpectedContribution(
            game.damageTakenRatioToExpectedContribution,
            AKARI_STANDARD_EXPECTED_CONTRIBUTION_FULL_SCORE_RATIO,
            AKARI_DAMAGE_TAKEN_WEIGHT,
          ),
        ),
      ),
      maxScore: AKARI_DAMAGE_TAKEN_WEIGHT,
    },
    {
      key: "healing",
      label: "治疗",
      score: avgOrZero(
        games.map((game) =>
          scoreHealing(game.healingRatioToTeamAverageDamageTaken, game.teamParticipantCount),
        ),
      ),
      maxScore: AKARI_HEALING_MAX_SCORE,
    },
    {
      key: "cs",
      label: "补兵",
      score: avgOrZero(games.map((game) => scoreCsPerMinute(game.csPerMinute))),
      maxScore: AKARI_CS_MAX_SCORE,
    },
    {
      key: "gold",
      label: "经济",
      score: avgOrZero(
        games.map((game) =>
          scoreExpectedContribution(
            game.goldRatioToExpectedContribution,
            AKARI_GOLD_EXPECTED_CONTRIBUTION_FULL_SCORE_RATIO,
            AKARI_GOLD_WEIGHT,
          ),
        ),
      ),
      maxScore: AKARI_GOLD_WEIGHT,
    },
    {
      key: "participation",
      label: "参团",
      score: avgOrZero(games.map((game) => scoreParticipation(game.killParticipation))),
      maxScore: AKARI_PARTICIPATION_WEIGHT,
    },
    {
      key: "vision",
      label: "视野",
      score: avgOrZero(
        games.map((game) =>
          scoreExpectedContribution(
            game.visionScoreRatioToExpectedContribution,
            AKARI_STANDARD_EXPECTED_CONTRIBUTION_FULL_SCORE_RATIO,
            AKARI_VISION_MAX_SCORE,
          ),
        ),
      ),
      maxScore: AKARI_VISION_MAX_SCORE,
    },
  ];

  // 求和而不是复用 components 的 reduce：保留 AK「逐项相加」的语义，
  // 避免以后有人给某一项加 clamp 时悄悄改变总分口径。
  const total =
    scoreKda(averageKda) +
    scoreWinRate(winRate) +
    components[2].score +
    components[3].score +
    components[4].score +
    components[5].score +
    components[6].score +
    components[7].score +
    components[8].score;

  return {
    total,
    maxScore: AKARI_MAX_SCORE,
    outstanding:
      total >= AGGREGATE_AKARI_OUTSTANDING_THRESHOLD && count >= AGGREGATE_AKARI_OUTSTANDING_MIN_COUNT,
    extraordinary:
      total >= AGGREGATE_AKARI_EXTRAORDINARY_THRESHOLD &&
      count >= AGGREGATE_AKARI_EXTRAORDINARY_MIN_COUNT,
    components,
  };
}
