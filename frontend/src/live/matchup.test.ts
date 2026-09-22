import { describe, expect, it } from "vitest";
import { fixtureLobby } from "../fixtures/data";
import { deriveTagFacts } from "../tags/facts";
import type { PlayerTagFacts } from "../tags/facts";
import type { PlayerProfile, RecentMatch } from "../types/domain";
import {
  aggregateTeam,
  describeRankScore,
  estimateWinRate,
  focusPoints,
  hasLaneCoverage,
  laneMatchups,
  matchVerdict,
  rankScore,
  ratePlayer,
  shrinkRate,
} from "./matchup";
import type { FactsResolver, LaneMatchup } from "./matchup";

const TEMPLATE = fixtureLobby.ally[0];

/** 用 fixture 玩家当模板，避免手写 `PlayerProfile` 那一长串字段。 */
function player(overrides: Partial<PlayerProfile> = {}): PlayerProfile {
  return { ...structuredClone(TEMPLATE), isPremade: false, premadeWith: [], premadeGroup: null, ...overrides };
}

/**
 * 注入一份「标签事实」。
 *
 * Akari 综合分是**从战绩推出来的**（`deriveTagFacts` → `computeAggregateAkariScore`），
 * 不是 `PlayerProfile` 上的字段。要在单测里造一个「通天代」，与其反推打分公式去凑
 * 一堆恰好越过 8 分的对局，不如直接把结论注进去——真实推导那部分另有 `tags` 的用例守着。
 */
function factsWith(overrides: Partial<PlayerTagFacts>): FactsResolver {
  return (subject) => ({ ...deriveTagFacts(subject), ...overrides });
}

/** 明确「查不出 Akari 分」：避免默认推导顺手把某些用例带进优异档。 */
const NO_AKARI = factsWith({ akariScore: { total: 0, maxScore: 0, outstanding: false, extraordinary: false, components: [] } });

/**
 * 造「最近一局在前」的战绩，胜负**交替**排。
 *
 * 交替是为了压住连胜/连败：不然造个 17 胜 3 负就会顺带触发「处于连胜」，
 * 让不相干的断言被第二个关注点带偏。
 */
function winLoss(wins: number, losses: number, championId = 0): RecentMatch[] {
  const template = structuredClone(TEMPLATE.recentMatches[0]);
  const out: RecentMatch[] = [];
  const build = (win: boolean) => ({
    ...structuredClone(template),
    gameId: 900000 + out.length,
    win,
    durationMinutes: 30,
    championId: championId || template.championId,
    // 清掉闪现，免得顺手触发「闪现位置可疑」。
    summonerSpells: [],
    earlyDeathsWithEnemyJungler: undefined,
  });
  for (let index = 0; index < Math.max(wins, losses); index += 1) {
    if (index < wins) out.push(build(true));
    if (index < losses) out.push(build(false));
  }
  return out;
}

/** 一个「各方面都齐全」的玩家：有段位、有战绩。 */
function ranked(overrides: Partial<PlayerProfile> = {}): PlayerProfile {
  return player({
    rankTier: "GOLD",
    rankDivision: "II",
    leaguePoints: 40,
    recentMatches: winLoss(10, 10),
    ...overrides,
  });
}

describe("rankScore / describeRankScore", () => {
  it("把段位、小段与 LP 折成一个连续刻度", () => {
    expect(rankScore(player({ rankTier: "GOLD", rankDivision: "I", leaguePoints: 100 }))).toBeCloseTo(15.25, 5);
    expect(rankScore(player({ rankTier: "SILVER", rankDivision: "IV", leaguePoints: 0 }))).toBe(8);
  });

  it("大师以上没有小段，LP 直接线性累加", () => {
    expect(rankScore(player({ rankTier: "MASTER", rankDivision: "", leaguePoints: 200 }))).toBe(30);
    expect(rankScore(player({ rankTier: "GRANDMASTER", rankDivision: "", leaguePoints: 0 }))).toBe(32);
  });

  it("未定级返回 null，而不是当成 0（当成 0 会把人误判成黑铁）", () => {
    expect(rankScore(player({ rankTier: "UNRANKED", rankDivision: "", leaguePoints: 0 }))).toBeNull();
    expect(rankScore(player({ rankTier: "", rankDivision: "", leaguePoints: 0 }))).toBeNull();
  });

  it("反函数能把刻度读回成人看得懂的段位", () => {
    expect(describeRankScore(15.25)).toBe("黄金 I");
    expect(describeRankScore(8)).toBe("白银 IV");
    expect(describeRankScore(30)).toBe("大师");
    expect(describeRankScore(37)).toBe("王者");
    expect(describeRankScore(null)).toBe("未定级");
  });

  it("刻度与显示是自洽的：来回换算不会跳段", () => {
    for (const tier of ["BRONZE", "SILVER", "GOLD", "PLATINUM", "EMERALD", "DIAMOND"]) {
      for (const division of ["IV", "III", "II", "I"]) {
        const score = rankScore(player({ rankTier: tier, rankDivision: division, leaguePoints: 0 }))!;
        expect(describeRankScore(score).endsWith(division)).toBe(true);
      }
    }
  });
});

describe("shrinkRate", () => {
  it("样本越小越靠近 50%，避免「1 场 100%」被当成强者", () => {
    expect(shrinkRate(1, 1)).toBeCloseTo(4 / 7, 5);
    expect(shrinkRate(1, 0)).toBe(0.5);
    // 样本越大越接近原始胜率。
    expect(shrinkRate(0.85, 40)).toBeGreaterThan(shrinkRate(0.85, 5));
  });
});

describe("ratePlayer", () => {
  it("同战绩下段位高的一方评分更高", () => {
    const strong = ratePlayer(ranked({ rankTier: "DIAMOND", rankDivision: "I", leaguePoints: 80 }));
    const weak = ratePlayer(ranked({ rankTier: "SILVER", rankDivision: "IV", leaguePoints: 0 }));
    expect(strong.total).toBeGreaterThan(weak.total);
  });

  it("缺项按剩余权重重归一化，而不是当成 0 分", () => {
    // 只有段位、没有战绩/位置场次/Akari 分：总分应该由段位单独决定，
    // 而不是被「缺的那几项」压到 0。
    const solo = ratePlayer(
      player({
        rankTier: "CHALLENGER",
        rankDivision: "",
        leaguePoints: 500,
        recentMatches: [],
        positionGames: 0,
        currentChampionGames: 0,
      }),
    );
    expect(solo.metrics.map((metric) => metric.key)).toEqual(["rank"]);
    expect(solo.total).toBe(1);
  });

  it("Akari 分有值时也算一项，并且能把总分往上抬", () => {
    const base = ratePlayer(ranked(), NO_AKARI);
    const withAkari = ratePlayer(ranked(), factsWith({ akariScore: { total: 14, maxScore: 17, outstanding: true, extraordinary: true, components: [] } }));
    expect(base.metrics.map((metric) => metric.key)).not.toContain("akari");
    expect(withAkari.metrics.map((metric) => metric.key)).toContain("akari");
    expect(withAkari.total).toBeGreaterThan(base.total);
  });

  it("每条指标都带可读原文，方便在界面上解释结论", () => {
    const rating = ratePlayer(ranked());
    for (const metric of rating.metrics) {
      expect(metric.display.length).toBeGreaterThan(0);
      expect(metric.label.length).toBeGreaterThan(0);
    }
  });

  it("只有一局连着胜负时说「平稳」，不说「1 连胜」", () => {
    const formOf = (matches: RecentMatch[]) =>
      ratePlayer(ranked({ recentMatches: matches }), NO_AKARI).metrics.find((metric) => metric.key === "form")?.display;
    // [胜, 负]：winningStreak 只有 1，按连胜讲会读成很怪的一句话。
    expect(formOf(winLoss(1, 1))).toBe("平稳");
    expect(formOf(winLoss(0, 0))).toBeUndefined();
    expect(formOf(winLoss(3, 0))).toBe("3 连胜");
    expect(formOf(winLoss(0, 3))).toBe("3 连败");
  });
});

describe("laneMatchups", () => {
  const allies = [
    ranked({ assignedPosition: "TOP", gameName: "我方上单" }),
    ranked({ assignedPosition: "JUNGLE", gameName: "我方打野" }),
    ranked({ assignedPosition: "MIDDLE", gameName: "我方中单" }),
    ranked({ assignedPosition: "BOTTOM", gameName: "我方射手" }),
    ranked({ assignedPosition: "UTILITY", gameName: "我方辅助" }),
  ];
  const enemies = [
    ranked({ rankTier: "BRONZE", rankDivision: "IV", leaguePoints: 0, assignedPosition: "MID", gameName: "敌方中单" }),
    ranked({ rankTier: "DIAMOND", rankDivision: "II", leaguePoints: 60, assignedPosition: "TOP", gameName: "敌方上单" }),
  ];

  it("按位置配对，并认下不同写法（MID / UTILITY 等）", () => {
    const matchups = laneMatchups(allies, enemies);
    expect(matchups.find((item) => item.lane === "MIDDLE")?.enemy?.gameName).toBe("敌方中单");
    expect(matchups.find((item) => item.lane === "TOP")?.enemy?.gameName).toBe("敌方上单");
  });

  it("只有一边有空缺时仍保留该路，但结论标成 unknown 而不是编一个", () => {
    const matchups = laneMatchups(allies, enemies);
    const jungle = matchups.find((item) => item.lane === "JUNGLE")!;
    expect(jungle.ally).not.toBeNull();
    expect(jungle.enemy).toBeNull();
    expect(jungle.verdict).toBe("unknown");
  });

  it("两边都没人的位置不占位置", () => {
    const matchups = laneMatchups([], []);
    expect(matchups).toHaveLength(0);
    expect(hasLaneCoverage(matchups)).toBe(false);
  });

  it("段位差得远时给出明确占优方与理由", () => {
    const matchups = laneMatchups(allies, enemies);
    const top = matchups.find((item) => item.lane === "TOP")!;
    expect(top.verdict).toBe("enemy");
    expect(top.edge).toBeLessThan(0);
    expect(top.reasons[0]?.label).toBe("段位");
    expect(top.reasons[0]?.enemy.length).toBeGreaterThan(0);
  });

  it("三路以上能配上对才算有覆盖（ARAM 之类要能降级）", () => {
    expect(hasLaneCoverage(laneMatchups(allies, enemies))).toBe(false);
    const full = laneMatchups(allies, allies.map((item, index) => ranked({ assignedPosition: item.assignedPosition, gameName: `对手${index}` })));
    expect(hasLaneCoverage(full)).toBe(true);
  });
});

describe("estimateWinRate", () => {
  const lane = (edge: number): LaneMatchup => ({
    lane: "TOP",
    label: "上路",
    ally: null,
    enemy: null,
    allyRating: 0.5 + edge,
    enemyRating: 0.5,
    edge,
    verdict: edge > 0 ? "ally" : edge < 0 ? "enemy" : "even",
    reasons: [],
  });

  it("五路均势时是 50/50", () => {
    const estimate = estimateWinRate([lane(0), lane(0)]);
    expect(estimate.ally).toBeCloseTo(0.5, 5);
    expect(estimate.enemy).toBeCloseTo(0.5, 5);
  });

  it("一路占优就超过 50%，反向亦然", () => {
    expect(estimateWinRate([lane(0.3), lane(0)]).ally).toBeGreaterThan(0.5);
    expect(estimateWinRate([lane(-0.3), lane(0)]).ally).toBeLessThan(0.5);
  });

  it("再大的优势也不宣称确定性", () => {
    const estimate = estimateWinRate([lane(5), lane(5), lane(5), lane(5), lane(5)]);
    expect(estimate.ally).toBeLessThanOrEqual(0.88);
    expect(estimateWinRate([lane(-5), lane(-5), lane(-5), lane(-5), lane(-5)]).ally).toBeGreaterThanOrEqual(0.12);
  });

  it("两边加起来永远是 1", () => {
    const estimate = estimateWinRate([lane(0.4), lane(-0.1)]);
    expect(estimate.ally + estimate.enemy).toBeCloseTo(1, 10);
  });

  it("一路都配不上时退回 50/50，而不是瞎猜", () => {
    const estimate = estimateWinRate([{ ...lane(0), verdict: "unknown" }]);
    expect(estimate).toEqual({ ally: 0.5, enemy: 0.5, edge: 0, lanes: 0 });
  });
});

describe("focusPoints", () => {
  const EXTRAORDINARY = factsWith({
    akariScore: { total: 9.2, maxScore: 17, outstanding: true, extraordinary: true, components: [] },
  });

  it("通天代要带上 Akari 分数与近期战绩，而不是只给一句「高风险」", () => {
    const enemy = ranked({ assignedPosition: "MIDDLE", gameName: "敌方中单", recentMatches: winLoss(17, 3) });
    const points = focusPoints([], [enemy], [], EXTRAORDINARY);
    const point = points.find((item) => item.key.startsWith("extraordinary-"))!;
    expect(point.tone).toBe("danger");
    expect(point.detail).toContain("9.20");
    expect(point.detail).toContain("17");
  });

  it("只是「优异」不到「通天代」时降一档，语气与颜色都要弱一些", () => {
    const enemy = ranked({ gameName: "敌方中单" });
    const resolveFacts = factsWith({ akariScore: { total: 7, maxScore: 17, outstanding: true, extraordinary: false, components: [] } });
    const point = focusPoints([], [enemy], [], resolveFacts).find((item) => item.key.startsWith("outstanding-"))!;
    expect(point.tone).toBe("warning");
    expect(point.detail).toContain("7.00");
  });

  it("极高胜率要有场次与胜场数", () => {
    const enemy = ranked({ gameName: "敌方射手", recentMatches: winLoss(17, 3) });
    const point = focusPoints([], [enemy], [], NO_AKARI).find((item) => item.key.startsWith("winrate-"))!;
    expect(point.detail).toContain("20 场");
    expect(point.detail).toContain("17 胜");
  });

  it("一组多人组队只报一条，不按人头刷屏", () => {
    const enemies = [ranked({ gameName: "甲", premadeGroup: "g1" }), ranked({ gameName: "乙", premadeGroup: "g1" }), ranked({ gameName: "丙", premadeGroup: "g1" })];
    const premade = focusPoints([], enemies, [], NO_AKARI).filter((item) => item.key.startsWith("premade-"));
    expect(premade).toHaveLength(1);
    expect(premade[0].detail).toContain("甲");
    expect(premade[0].detail).toContain("丙");
  });

  it("闪现 D/F 都有时提示可能换人上号", () => {
    const template = structuredClone(TEMPLATE.recentMatches[0]);
    const FLASH = 4;
    /** 索引 0 = D、索引 1 = F；`slot` 指定闪现放在哪一位。 */
    const flashOn = (slot: 0 | 1, index: number): RecentMatch => ({
      ...structuredClone(template),
      gameId: 800000 + index,
      win: true,
      durationMinutes: 30,
      summonerSpells: [
        { id: slot === 0 ? FLASH : 12, name: slot === 0 ? "闪现" : "传送", iconUrl: "" },
        { id: slot === 1 ? FLASH : 12, name: slot === 1 ? "闪现" : "传送", iconUrl: "" },
      ],
    });
    const enemy = ranked({ gameName: "敌方上单", recentMatches: [flashOn(1, 0), flashOn(0, 1)] });
    const point = focusPoints([], [enemy], [], NO_AKARI).find((item) => item.key.startsWith("flash-"))!;
    expect(point.detail).toContain("换人上号");
  });

  it("什么都查不出来时也要给一条「双方数据接近」，并且说明查过哪些", () => {
    const plain = ranked({ gameName: "普通人" });
    const points = focusPoints([plain], [plain], [], NO_AKARI);
    expect(points).toHaveLength(1);
    expect(points[0].key).toBe("even");
    expect(points[0].detail).toContain("极高胜率");
  });

  it("按严重度排序，最多给 6 条", () => {
    const enemies = [1, 2, 3, 4, 5, 6, 7].map((index) => ranked({ gameName: `敌人${index}`, recentMatches: winLoss(17, 3) }));
    const points = focusPoints([], enemies, [], EXTRAORDINARY);
    expect(points).toHaveLength(6);
    expect(points[0].severity).toBeGreaterThanOrEqual(points[1].severity);
  });

  it("只盯敌方：我方再强也不会被列成「重点关注」", () => {
    const star = ranked({ gameName: "我方大腿", recentMatches: winLoss(17, 3) });
    const plain = ranked({ gameName: "普通人" });
    const points = focusPoints([star], [plain], [], EXTRAORDINARY);
    expect(points.every((item) => !item.title.includes("我方大腿"))).toBe(true);
  });
});

describe("aggregateTeam", () => {
  it("平均段位按段位分算，显示成可读段位", () => {
    const team = aggregateTeam([
      ranked({ rankTier: "GOLD", rankDivision: "IV", leaguePoints: 0 }),
      ranked({ rankTier: "GOLD", rankDivision: "II", leaguePoints: 0 }),
    ]);
    expect(team.averageRankLabel).toBe("黄金 III");
    expect(team.rankedCount).toBe(2);
  });

  it("平均胜率按场次加权，短样本不会把整队拉飞", () => {
    const big = ranked({ recentMatches: winLoss(5, 15) });
    const small = ranked({ recentMatches: winLoss(1, 0) });
    const team = aggregateTeam([big, small]);
    // 6 胜 / 21 场，而不是 (25% + 100%) / 2。
    expect(team.averageWinRate).toBeCloseTo(6 / 21, 5);
  });

  it("统计组队人数，供界面提示用", () => {
    const team = aggregateTeam([ranked({ isPremade: true }), ranked({ isPremade: true }), ranked()]);
    expect(team.premadeCount).toBe(2);
  });
});

describe("matchVerdict", () => {
  it("没有可用对位时给出降级说明，而不是硬造结论", () => {
    expect(matchVerdict([], { ally: 0.5, enemy: 0.5, edge: 0, lanes: 0 })).toContain("位置信息不全");
  });

  it("有对位时说清几路占优并带上百分比", () => {
    const allies = [ranked({ assignedPosition: "TOP" })];
    const enemies = [ranked({ assignedPosition: "TOP", rankTier: "BRONZE", rankDivision: "IV", leaguePoints: 0 })];
    const matchups = laneMatchups(allies, enemies);
    const verdict = matchVerdict(matchups, estimateWinRate(matchups));
    expect(verdict).toContain("估算我方胜率");
    expect(verdict).toMatch(/\d+%/);
  });
});
