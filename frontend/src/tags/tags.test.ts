import { mount } from "@vue/test-utils";
import { computed } from "vue";
import { describe, expect, it } from "vitest";
import { fixtureLobby } from "../fixtures/data";
import type { EncounterRecord, PlayerProfile, RecentMatch } from "../types/domain";
import {
  AGGREGATE_AKARI_EXTRAORDINARY_MIN_COUNT,
  AGGREGATE_AKARI_EXTRAORDINARY_THRESHOLD,
  AGGREGATE_AKARI_OUTSTANDING_MIN_COUNT,
  AGGREGATE_AKARI_OUTSTANDING_THRESHOLD,
  AKARI_MAX_SCORE,
  computeAggregateAkariScore,
  scoreKda,
} from "./akari";
import type { PlayerTagFacts } from "./facts";
import { defaultPlayerTagSettings } from "./settings";
import { PLAYER_CARD_TAGS } from "./registry";
import type { PlayerTagContext, PlayerTagDefinition } from "./types";
import { usePlayerTags } from "./usePlayerTags";

const SELF = fixtureLobby.ally[0];
const TARGET = fixtureLobby.ally[2];
const BASE_MATCH = fixtureLobby.ally[0].recentMatches[0];

const EMPTY_AKARI = {
  total: 0,
  maxScore: AKARI_MAX_SCORE,
  outstanding: false,
  extraordinary: false,
  components: [],
};

function facts(overrides: Partial<PlayerTagFacts> = {}): PlayerTagFacts {
  return {
    sample: 10,
    wins: 5,
    winRate: 0.5,
    averageKda: 3,
    avgChampionDamagePercentageOfTeam: 0.2,
    avgDamageTakenPercentageOfTeam: 0.2,
    avgGoldPercentageOfTeam: 0.2,
    avgCsPercentageOfTeam: 0.2,
    avgCsPerMinute: 6,
    avgDamageGoldEfficiency: 1,
    avgKillDamageEfficiency: 1,
    avgVisionScore: 0,
    avgEnemyMissingPings: null,
    averageSoloKills: null,
    soloKillsSample: 0,
    averageEarlyDeathsWithJungler: null,
    earlyDeathsSample: 0,
    winningStreak: 0,
    losingStreak: 0,
    currentChampionGames: 0,
    isJungler: false,
    flashOnD: 0,
    flashOnF: 0,
    akariScore: { ...EMPTY_AKARI },
    ...overrides,
  };
}

/** 干净玩家：清掉 fixture 里会顺手触发其它标签的字段，便于逐标签断言。 */
function player(overrides: Partial<PlayerProfile> = {}): PlayerProfile {
  return {
    ...structuredClone(TARGET),
    isPremade: false,
    premadeWith: [],
    encounterCount: 0,
    lastEncounteredAt: null,
    recentMatches: [],
    ...overrides,
  };
}

function context(overrides: Partial<PlayerTagContext> = {}): PlayerTagContext {
  return {
    player: player(),
    selfPuuid: null,
    selfPlayer: null,
    settings: { ...defaultPlayerTagSettings },
    facts: facts(),
    encounterRecords: [],
    encounterLoading: false,
    encounterError: false,
    currentGameId: 0,
    premadeTone: undefined,
    playerNotes: [],
    canEditNotes: false,
    onEditNotes: () => {},
    openEncounterGame: () => {},
    retryEncounters: () => {},
    ...overrides,
  };
}

/** 打开默认关闭的场均指标开关（AK 里这些默认是关的）。 */
function withAverageTags(): typeof defaultPlayerTagSettings {
  return {
    ...defaultPlayerTagSettings,
    showAverageTeamDamageTag: true,
    showAverageTeamDamageTakenTag: true,
    showAverageTeamGoldTag: true,
    showAverageCsPerMinuteTag: true,
    showAverageDamageGoldEfficiencyTag: true,
    showAverageEnemyMissingPingsTag: true,
    showAverageVisionScoreTag: true,
    showAkariScoreTag: true,
  };
}

function findDefinition(id: string): PlayerTagDefinition {
  const definition = PLAYER_CARD_TAGS.find((tag) => tag.id === id);
  if (!definition) throw new Error(`未注册的标签：${id}`);
  return definition;
}

/** 渲染标签的 label 组件并取文本，`null` 表示该标签在当前上下文不成立。 */
function renderText(id: string, ctx: PlayerTagContext): string | null {
  const result = findDefinition(id).render(ctx);
  if (!result) return null;
  return mount(result.label).text();
}

function match(gameId: number, overrides: Partial<RecentMatch> = {}): RecentMatch {
  return { ...structuredClone(BASE_MATCH), gameId, durationMinutes: 30, ...overrides };
}

function encounter(gameId: number, overrides: Partial<EncounterRecord> = {}): EncounterRecord {
  return {
    gameId,
    selfPuuid: SELF.puuid,
    selfGameName: SELF.gameName,
    selfTagLine: SELF.tagLine,
    selfChampionId: 10,
    selfChampionName: "自己英雄",
    selfPosition: "MIDDLE",
    selfKills: 8,
    selfDeaths: 2,
    selfAssists: 7,
    selfWin: true,
    puuid: TARGET.puuid,
    gameName: TARGET.gameName,
    tagLine: TARGET.tagLine,
    championId: 20,
    championName: "对手英雄",
    side: "ally",
    result: "胜利",
    encounteredAt: "2026-09-02T10:00:00.000Z",
    kills: 3,
    deaths: 4,
    assists: 5,
    win: true,
    position: "MIDDLE",
    ...overrides,
  };
}

describe("标签注册表", () => {
  it("顺序与 LeagueAkari 的 PLAYER_CARD_TAGS 逐项一致（21 条）", () => {
    expect(PLAYER_CARD_TAGS.map((tag) => tag.id)).toEqual([
      "self",
      "tagged",
      "premade-team",
      "high-win-rate",
      "met",
      "privacy",
      "winning-streak",
      "losing-streak",
      "great-performance",
      "suspicious-flash-position",
      "easy-gank",
      "solo-kills",
      "average-team-damage",
      "average-team-damage-taken",
      "average-team-gold",
      "average-cs-per-minute",
      "average-damage-gold-efficiency",
      "average-enemy-missing-pings",
      "average-vision-score",
      "average-kill-damage-efficiency",
      "akari-score",
    ]);
  });

  it("不再保留本项目自创的三条标签", () => {
    const ids = PLAYER_CARD_TAGS.map((tag) => tag.id);
    expect(ids).not.toContain("deaths");
    expect(ids).not.toContain("participation");
    expect(ids).not.toContain("pool-concentration");
    expect(ids).not.toContain("score");
  });

  it("usePlayerTags 只产出成立的标签且保持注册顺序", () => {
    const ctx = context({
      selfPuuid: TARGET.puuid,
      facts: facts({
        winningStreak: 3,
        akariScore: { ...EMPTY_AKARI, total: 9, outstanding: true },
      }),
    });
    const ids = usePlayerTags(computed(() => ctx)).value.map((tag) => tag.id);
    expect(ids).toEqual(["self", "winning-streak", "great-performance"]);
  });
});

describe("身份类标签", () => {
  it("self 只在本地玩家身上出现", () => {
    expect(renderText("self", context({ player: player({ puuid: SELF.puuid }), selfPuuid: SELF.puuid }))).toBe("自己");
    expect(renderText("self", context({ player: player({ puuid: TARGET.puuid }), selfPuuid: SELF.puuid }))).toBeNull();
    expect(renderText("self", context({ player: player({ puuid: SELF.puuid }), selfPuuid: null }))).toBeNull();
  });

  it("premade-team 在已知分组时带组号，未知分组时退化为「开黑」", () => {
    expect(renderText("premade-team", context({ premadeTone: 1 }))).toBe("开黑 2");
    expect(renderText("premade-team", context({ player: player({ isPremade: true }) }))).toBe("开黑");
    expect(renderText("premade-team", context())).toBeNull();
  });

  it("tagged 只有存在备注且允许编辑时才渲染", () => {
    expect(renderText("tagged", context({ playerNotes: ["   "], canEditNotes: true }))).toBeNull();
    expect(renderText("tagged", context({ playerNotes: ["爱打野"], canEditNotes: false }))).toBeNull();
    expect(renderText("tagged", context({ playerNotes: ["爱打野"], canEditNotes: true }))).toBe("已标记");
  });

  it("privacy 只在客户端把战绩设为私密时出现", () => {
    expect(renderText("privacy", context({ player: player({ privacy: "PRIVATE" }) }))).toBe("战绩隐藏");
    expect(renderText("privacy", context({ player: player({ privacy: "PUBLIC" }) }))).toBeNull();
    expect(renderText("privacy", context({ player: player({ privacy: null }) }))).toBeNull();
  });

  it("关掉开关后对应标签不再渲染", () => {
    const off = {
      ...defaultPlayerTagSettings,
      showSelfTag: false,
      showMetTag: false,
      showTaggedTag: false,
      showPrivacyTag: false,
    };
    expect(renderText("self", context({ player: player({ puuid: SELF.puuid }), selfPuuid: SELF.puuid, settings: off }))).toBeNull();
    expect(renderText("tagged", context({ playerNotes: ["备注"], canEditNotes: true, settings: off }))).toBeNull();
    expect(renderText("privacy", context({ player: player({ privacy: "PRIVATE" }), settings: off }))).toBeNull();
    expect(
      renderText("met", context({ player: player({ encounterCount: 3 }), encounterRecords: [encounter(910000)], settings: off })),
    ).toBeNull();
  });
});

describe("遇到过标签", () => {
  it("自己、无记录且无计数时不渲染", () => {
    expect(renderText("met", context({ selfPuuid: TARGET.puuid }))).toBeNull();
    expect(renderText("met", context({ encounterRecords: [] }))).toBeNull();
  });

  it("chip 只写「遇到过」，次数收进弹层（对齐 LeagueAkari）", () => {
    const ctx = context({ player: player({ encounterCount: 3 }), encounterRecords: [encounter(910000)] });
    expect(renderText("met", ctx)).toBe("遇到过");
  });

  it("双方最新一局就是共同对局时区分上局队友 / 上局对手", () => {
    const gameId = 555;
    const latest = match(gameId, { playedAt: "2026-09-05T10:00:00.000Z" });
    const shared = {
      player: player({ recentMatches: [latest] }),
      selfPlayer: player({ puuid: SELF.puuid, recentMatches: [latest] }),
      selfPuuid: SELF.puuid,
    };
    expect(renderText("met", context({ ...shared, encounterRecords: [encounter(gameId, { side: "ally" })] }))).toBe("上局队友");
    expect(renderText("met", context({ ...shared, encounterRecords: [encounter(gameId, { side: "enemy" })] }))).toBe("上局对手");
  });

  it("共同对局不是双方最新一局时只写「遇到过」", () => {
    const latest = match(555, { playedAt: "2026-09-05T10:00:00.000Z" });
    const ctx = context({
      player: player({ recentMatches: [latest] }),
      selfPlayer: player({ puuid: SELF.puuid, recentMatches: [latest] }),
      selfPuuid: SELF.puuid,
      encounterRecords: [encounter(444)],
    });
    expect(renderText("met", ctx)).toBe("遇到过");
  });
});

describe("状态类标签", () => {
  it("high-win-rate 需要足够样本与极高胜率", () => {
    expect(renderText("high-win-rate", context({ facts: facts({ sample: 20, winRate: 0.9 }) }))).toBe("极高胜率");
    expect(renderText("high-win-rate", context({ facts: facts({ sample: 20, winRate: 0.8 }) }))).toBeNull();
    expect(renderText("high-win-rate", context({ facts: facts({ sample: 12, winRate: 0.9 }) }))).toBeNull();
  });

  it("连胜 / 连败是相互独立的两个开关，阈值都是 3", () => {
    expect(renderText("winning-streak", context({ facts: facts({ winningStreak: 3 }) }))).toBe("3 连胜");
    expect(renderText("winning-streak", context({ facts: facts({ winningStreak: 2 }) }))).toBeNull();
    expect(renderText("losing-streak", context({ facts: facts({ losingStreak: 4 }) }))).toBe("4 连败");

    // AK 的两个开关必须能各管各的，不能像以前那样共用一个 showStreakTag。
    const onlyWinning = { ...defaultPlayerTagSettings, showLosingStreakTag: false };
    expect(renderText("losing-streak", context({ facts: facts({ losingStreak: 4 }), settings: onlyWinning }))).toBeNull();
    expect(renderText("winning-streak", context({ facts: facts({ winningStreak: 4 }), settings: onlyWinning }))).toBe("4 连胜");
  });

  it("great-performance 与 akari-score 都读 Akari 评分", () => {
    const outstanding = context({
      facts: facts({ akariScore: { ...EMPTY_AKARI, total: 6.8, outstanding: true } }),
    });
    const extraordinary = context({
      facts: facts({ akariScore: { ...EMPTY_AKARI, total: 9.1, extraordinary: true } }),
    });
    expect(renderText("great-performance", outstanding)).toBe("优异");
    expect(renderText("great-performance", extraordinary)).toBe("通天代");
    expect(renderText("great-performance", context())).toBeNull();

    // akari-score 默认关闭，打开后直接给数值。
    expect(renderText("akari-score", { ...outstanding, settings: withAverageTags() })).toBe("Akari 6.8");
    expect(renderText("akari-score", outstanding)).toBeNull();
    expect(
      renderText("akari-score", { ...outstanding, settings: withAverageTags(), facts: facts({ sample: 0 }) }),
    ).toBeNull();
  });
});

describe("打野与场均指标标签", () => {
  const easyGank = (times: number | null) =>
    renderText("easy-gank", context({ facts: facts({ averageEarlyDeathsWithJungler: times }) }));

  it("easy-gank 三档阈值与 LeagueAkari 一致", () => {
    expect(easyGank(2.5)).toBe("非常好抓");
    expect(easyGank(2)).toBe("好抓");
    expect(easyGank(1.2)).toBeNull();
    expect(easyGank(0.5)).toBe("难抓");
    expect(easyGank(null)).toBeNull();
  });

  it("打野自己不会被标「好抓」", () => {
    expect(renderText("easy-gank", context({ facts: facts({ averageEarlyDeathsWithJungler: 2.5, isJungler: true }) }))).toBeNull();
  });

  it("solo-kills 需要精确样本，chip 直接给出场均次数", () => {
    const ctx = (average: number, sample: number) => context({ facts: facts({ averageSoloKills: average, soloKillsSample: sample }) });
    expect(renderText("solo-kills", ctx(0.9, 5))).toBe("0.9 单杀");
    expect(renderText("solo-kills", ctx(0, 5))).toBeNull();
    expect(renderText("solo-kills", ctx(0.9, 2))).toBeNull();
  });

  it("场均指标只报数值，不做「偏高 / 偏低」判断", () => {
    const settings = withAverageTags();
    const damage = (share: number) =>
      renderText("average-team-damage", context({ settings, facts: facts({ avgChampionDamagePercentageOfTeam: share }) }));
    const vision = (value: number) =>
      renderText("average-vision-score", context({ settings, facts: facts({ avgVisionScore: value }) }));

    expect(damage(0.3)).toBe("伤害 30%");
    expect(damage(0.12)).toBe("伤害 12%");
    // 低视野分只是把数字报出来，不再打「视野偏少」这种主观标签。
    expect(vision(8)).toBe("视野分 8");
    expect(vision(30)).toBe("视野分 30");

    expect(renderText("average-team-damage-taken", context({ settings, facts: facts({ avgDamageTakenPercentageOfTeam: 0.31 }) }))).toBe("承伤 31%");
    expect(renderText("average-team-gold", context({ settings, facts: facts({ avgGoldPercentageOfTeam: 0.26 }) }))).toBe("经济 26%");
    expect(renderText("average-cs-per-minute", context({ settings, facts: facts({ avgCsPerMinute: 8 }) }))).toBe("分均补刀 8.0");
    expect(renderText("average-damage-gold-efficiency", context({ settings, facts: facts({ avgDamageGoldEfficiency: 1.25 }) }))).toBe("伤害经济 125%");
  });

  it("缺少十人数据时队伍占比类标签不渲染（而不是显示 0）", () => {
    const settings = withAverageTags();
    expect(renderText("average-team-damage-taken", context({ settings, facts: facts({ avgDamageTakenPercentageOfTeam: null }) }))).toBeNull();
    expect(renderText("average-team-gold", context({ settings, facts: facts({ avgGoldPercentageOfTeam: null }) }))).toBeNull();
    expect(renderText("average-enemy-missing-pings", context({ settings, facts: facts({ avgEnemyMissingPings: null }) }))).toBeNull();
  });

  it("敌方消失信号有数据时才显示", () => {
    const settings = withAverageTags();
    expect(renderText("average-enemy-missing-pings", context({ settings, facts: facts({ avgEnemyMissingPings: 1.25 }) }))).toBe("消失信号 1.3");
  });

  it("击杀伤害转化按 0.65 / 1.35 分档", () => {
    const kde = (value: number) =>
      renderText("average-kill-damage-efficiency", context({ facts: facts({ avgKillDamageEfficiency: value }) }));
    expect(kde(1.6)).toBe("击杀伤害转化高");
    expect(kde(0.4)).toBe("击杀伤害转化低");
    expect(kde(1)).toBeNull();
    // 等于阈值时算 normal，与 AK 的 `>` / `<` 严格比较一致。
    expect(kde(1.35)).toBeNull();
    expect(kde(0.65)).toBeNull();
  });

  it("可疑闪现位置要求 D / F 两边都放过闪现", () => {
    const flash = (onD: number, onF: number) =>
      renderText("suspicious-flash-position", context({ facts: facts({ flashOnD: onD, flashOnF: onF }) }));
    expect(flash(3, 2)).toBe("闪现位置可疑");
    expect(flash(5, 0)).toBeNull();
    expect(flash(0, 5)).toBeNull();
  });
});

describe("Akari 评分模型", () => {
  it("KDA 项低于基准线得 0 分，满分 1 分", () => {
    expect(scoreKda(2)).toBe(0);
    expect(scoreKda(1)).toBe(0);
    expect(scoreKda(2 + 49 / 9)).toBeCloseTo(1, 6);
  });

  it("空样本 outstanding / extraordinary 都为 false", () => {
    const score = computeAggregateAkariScore([], 0, 0);
    expect(score.total).toBe(0);
    expect(score.maxScore).toBe(AKARI_MAX_SCORE);
    expect(score.outstanding).toBe(false);
    expect(score.extraordinary).toBe(false);
    expect(score.components).toHaveLength(9);
  });

  it("优异 / 通天代需要同时达到分数与样本门槛", () => {
    // 一局「全项拉满」的样本：队伍占比 1/5 起步，这里给到远超满分的值。
    const perfect = {
      kda: 100,
      win: true,
      teamParticipantCount: 5,
      championDamageRatioToExpectedContribution: 5,
      damageTakenRatioToExpectedContribution: 5,
      healingRatioToTeamAverageDamageTaken: 5,
      csPerMinute: 20,
      goldRatioToExpectedContribution: 5,
      killParticipation: 1,
      visionScoreRatioToExpectedContribution: 5,
    };
    const many = computeAggregateAkariScore(Array.from({ length: AGGREGATE_AKARI_EXTRAORDINARY_MIN_COUNT }, () => perfect), 100, 1);
    expect(many.total).toBeCloseTo(AKARI_MAX_SCORE, 6);
    expect(many.extraordinary).toBe(true);
    expect(many.outstanding).toBe(true);

    // 分数够但样本不够：两个布尔都必须为 false。
    const few = computeAggregateAkariScore(
      Array.from({ length: AGGREGATE_AKARI_OUTSTANDING_MIN_COUNT - 1 }, () => perfect),
      100,
      1,
    );
    expect(few.total).toBeGreaterThanOrEqual(AGGREGATE_AKARI_EXTRAORDINARY_THRESHOLD);
    expect(few.outstanding).toBe(false);
    expect(few.extraordinary).toBe(false);

    // 样本够但分数不够。
    const weak = {
      ...perfect,
      kda: 2,
      win: false,
      championDamageRatioToExpectedContribution: 1,
      damageTakenRatioToExpectedContribution: 1,
      healingRatioToTeamAverageDamageTaken: 0.2,
      csPerMinute: 5,
      goldRatioToExpectedContribution: 1,
      killParticipation: 0.3,
      visionScoreRatioToExpectedContribution: 1,
    };
    const low = computeAggregateAkariScore(Array.from({ length: 10 }, () => weak), 2, 0);
    expect(low.total).toBeLessThan(AGGREGATE_AKARI_OUTSTANDING_THRESHOLD);
    expect(low.outstanding).toBe(false);
  });
});

describe("标签弹层", () => {
  it("met 标签使用可滚动的表格弹层并限制高度", () => {
    const met = findDefinition("met").render(
      context({ player: player({ encounterCount: 3 }), encounterRecords: [encounter(910000)] }),
    );
    expect(met?.popover?.scrollable).toBe(true);
    expect(met?.popover?.maxHeight).toBe(320);
  });

  it("纯文本标签也带弹层用于展示依据", () => {
    const streak = findDefinition("winning-streak").render(context({ facts: facts({ winningStreak: 3 }) }));
    expect(streak?.popover?.content).toBeTruthy();
  });

  it("可疑闪现位置与 Akari 评分使用图形化弹层", () => {
    const flash = findDefinition("suspicious-flash-position").render(
      context({ facts: facts({ flashOnD: 3, flashOnF: 2 }) }),
    );
    expect(flash?.popover?.content).toBeTruthy();

    const score = findDefinition("akari-score").render(
      context({ settings: withAverageTags(), facts: facts({ akariScore: { ...EMPTY_AKARI, total: 9 } }) }),
    );
    expect(score?.popover?.content).toBeTruthy();
  });
});
