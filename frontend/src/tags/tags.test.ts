import { mount } from "@vue/test-utils";
import { computed } from "vue";
import { describe, expect, it } from "vitest";
import { fixtureLobby } from "../fixtures/data";
import type { EncounterRecord, PlayerProfile, RecentMatch } from "../types/domain";
import type { PlayerTagFacts } from "./facts";
import { defaultPlayerTagSettings } from "./settings";
import { PLAYER_CARD_TAGS } from "./registry";
import type { PlayerTagContext, PlayerTagDefinition } from "./types";
import { usePlayerTags } from "./usePlayerTags";

const SELF = fixtureLobby.ally[0];
const TARGET = fixtureLobby.ally[2];
const BASE_MATCH = fixtureLobby.ally[0].recentMatches[0];

function facts(overrides: Partial<PlayerTagFacts> = {}): PlayerTagFacts {
  return {
    sample: 10,
    wins: 5,
    winRate: 0.5,
    averageDeaths: 4,
    averageParticipation: 0.5,
    averageDamageShare: 0.2,
    averageCsPerMinute: 6,
    averageSoloKills: null,
    soloKillsSample: 0,
    averageVisionScore: null,
    visionSample: 0,
    averageEarlyDeathsWithJungler: null,
    earlyDeathsSample: 0,
    winningStreak: 0,
    losingStreak: 0,
    currentChampionGames: 0,
    isJungler: false,
    ...overrides,
  };
}

/** 干净玩家：清掉 fixture 里会顺手触发其它标签的字段，便于逐标签断言。 */
function player(overrides: Partial<PlayerProfile> = {}): PlayerProfile {
  return {
    ...structuredClone(TARGET),
    score: { ...TARGET.score, total: 0 },
    championPoolConcentration: 0,
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
  it("顺序与 LeagueAkari 的 PLAYER_CARD_TAGS 对齐", () => {
    expect(PLAYER_CARD_TAGS.map((tag) => tag.id)).toEqual([
      "self",
      "tagged",
      "premade",
      "high-win-rate",
      "met",
      "winning-streak",
      "losing-streak",
      "great-performance",
      "easy-gank",
      "solo-kills",
      "damage-share",
      "cs-per-minute",
      "vision-score",
      "deaths",
      "participation",
      "pool-concentration",
      "score",
    ]);
  });

  it("usePlayerTags 只产出成立的标签且保持注册顺序", () => {
    const ctx = context({
      player: player({ score: { ...TARGET.score, total: 90 } }),
      selfPuuid: TARGET.puuid,
      facts: facts({ winningStreak: 3 }),
    });
    const ids = usePlayerTags(computed(() => ctx)).value.map((tag) => tag.id);
    expect(ids).toEqual(["self", "winning-streak", "great-performance", "score"]);
  });
});

describe("身份类标签", () => {
  it("self 只在本地玩家身上出现", () => {
    expect(renderText("self", context({ player: player({ puuid: SELF.puuid }), selfPuuid: SELF.puuid }))).toBe("自己");
    expect(renderText("self", context({ player: player({ puuid: TARGET.puuid }), selfPuuid: SELF.puuid }))).toBeNull();
    expect(renderText("self", context({ player: player({ puuid: SELF.puuid }), selfPuuid: null }))).toBeNull();
  });

  it("premade 在已知分组时带组号，未知分组时退化为「开黑」", () => {
    expect(renderText("premade", context({ premadeTone: 1 }))).toBe("开黑 2");
    expect(renderText("premade", context({ player: player({ isPremade: true }) }))).toBe("开黑");
    expect(renderText("premade", context())).toBeNull();
  });

  it("tagged 只有存在备注且允许编辑时才渲染", () => {
    expect(renderText("tagged", context({ playerNotes: ["   "], canEditNotes: true }))).toBeNull();
    expect(renderText("tagged", context({ playerNotes: ["爱打野"], canEditNotes: false }))).toBeNull();
    expect(renderText("tagged", context({ playerNotes: ["爱打野"], canEditNotes: true }))).toBe("已标记");
  });

  it("关掉开关后对应标签不再渲染", () => {
    const off = { ...defaultPlayerTagSettings, showSelfTag: false, showMetTag: false, showTaggedTag: false };
    expect(renderText("self", context({ player: player({ puuid: SELF.puuid }), selfPuuid: SELF.puuid, settings: off }))).toBeNull();
    expect(renderText("tagged", context({ playerNotes: ["备注"], canEditNotes: true, settings: off }))).toBeNull();
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

  it("连胜 / 连败阈值为 3", () => {
    expect(renderText("winning-streak", context({ facts: facts({ winningStreak: 3 }) }))).toBe("3 连胜");
    expect(renderText("winning-streak", context({ facts: facts({ winningStreak: 2 }) }))).toBeNull();
    expect(renderText("losing-streak", context({ facts: facts({ losingStreak: 4 }) }))).toBe("4 连败");
  });

  it("great-performance 与 score 都要求有样本", () => {
    const extraordinary = player({ score: { ...TARGET.score, total: 90 } });
    const outstanding = player({ score: { ...TARGET.score, total: 80 } });
    expect(renderText("great-performance", context({ player: extraordinary }))).toBe("通天代");
    expect(renderText("great-performance", context({ player: outstanding }))).toBe("优异");
    expect(renderText("score", context({ player: extraordinary }))).toBe("评分 90.0");
    expect(renderText("score", context({ player: extraordinary, facts: facts({ sample: 0 }) }))).toBeNull();
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
    expect(renderText("solo-kills", ctx(0.5, 5))).toBe("0.5 单杀");
    expect(renderText("solo-kills", ctx(0, 5))).toBeNull();
    expect(renderText("solo-kills", ctx(0.9, 2))).toBeNull();
  });

  it("伤害占比 / 分均补刀 / 视野得分按阈值出现", () => {
    expect(renderText("damage-share", context({ facts: facts({ averageDamageShare: 0.3 }) }))).toBe("伤害 30%");
    expect(renderText("cs-per-minute", context({ facts: facts({ averageCsPerMinute: 8 }) }))).toBe("分均补刀 8.0");
    expect(renderText("vision-score", context({ facts: facts({ averageVisionScore: 30, visionSample: 6 }) }))).toBe("视野分 30");
    expect(renderText("vision-score", context({ facts: facts({ averageVisionScore: 8, visionSample: 6 }) }))).toBe("视野偏少 8");
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
});
