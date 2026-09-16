import { describe, expect, it } from "vitest";
import { fixtureLobby } from "../fixtures/data";
import type { PlayerProfile } from "../types/domain";
import { analyzeTeamStats, resolvePremadeTeamTags, type PremadeGroupRef } from "./teamStats";

const baseMatch = fixtureLobby.ally[0].recentMatches[0];

interface MatchSpec {
  win: boolean;
  kills: number;
  deaths: number;
  assists: number;
}

function player(name: string, matches: MatchSpec[]): PlayerProfile {
  return {
    ...structuredClone(fixtureLobby.ally[0]),
    puuid: `puuid-${name}`,
    gameName: name,
    isPremade: false,
    premadeWith: [],
    recentMatches: matches.map((match, index) => ({
      ...structuredClone(baseMatch),
      gameId: index + 1,
      durationMinutes: 30,
      ...match,
    })),
  };
}

const repeat = (count: number, spec: MatchSpec) => Array.from({ length: count }, () => ({ ...spec }));

describe("team stats", () => {
  it("aggregates kills/deaths/assists across the whole team instead of averaging per-player KDA", () => {
    const first = player("甲", [
      { win: true, kills: 10, deaths: 2, assists: 5 },
      { win: false, kills: 0, deaths: 8, assists: 2 },
    ]);
    const second = player("乙", [
      { win: false, kills: 4, deaths: 4, assists: 4 },
      { win: true, kills: 4, deaths: 4, assists: 4 },
    ]);

    const stats = analyzeTeamStats([first, second]);
    expect(stats).not.toBeNull();
    expect(stats!.kills).toBe(18);
    expect(stats!.deaths).toBe(18);
    expect(stats!.assists).toBe(15);
    expect(stats!.games).toBe(4);
    expect(stats!.wins).toBe(2);
    expect(stats!.losses).toBe(2);
    expect(stats!.avgWinRate).toBeCloseTo(0.5, 6);
    // (18 + 15) / 18 —— 不是「逐人 KDA 求平均」。
    expect(stats!.avgKda).toBeCloseTo(33 / 18, 6);
  });

  it("returns null for an empty team and zeroes the averages instead of dividing by zero", () => {
    expect(analyzeTeamStats([])).toBeNull();

    const fresh = player("新号", []);
    const stats = analyzeTeamStats([fresh]);
    expect(stats!.games).toBe(0);
    expect(stats!.avgWinRate).toBe(0);
    expect(stats!.avgKda).toBe(0);
  });
});

describe("premade team tags", () => {
  it("marks a three-stack as a win-rate team when one member is a high win-rate outlier", () => {
    const ace = player("大腿", repeat(13, { win: true, kills: 8, deaths: 2, assists: 6 }));
    const mateOne = player("队友甲", repeat(6, { win: true, kills: 3, deaths: 3, assists: 5 }));
    const mateTwo = player("队友乙", repeat(6, { win: true, kills: 3, deaths: 3, assists: 5 }));
    const groups: PremadeGroupRef[] = [
      { id: "A", tone: 0, puuids: [ace.puuid, mateOne.puuid, mateTwo.puuid] },
    ];

    const tags = resolvePremadeTeamTags(groups, [ace, mateOne, mateTwo]);
    expect(tags.get("A")?.type).toBe("win-rate-team");
  });

  it("marks a two-stack as a loss-rate team when everyone is under the win-rate ceiling", () => {
    const first = player("摆烂甲", repeat(4, { win: false, kills: 1, deaths: 7, assists: 1 }));
    const second = player("摆烂乙", repeat(4, { win: false, kills: 1, deaths: 7, assists: 1 }));
    const groups: PremadeGroupRef[] = [{ id: "B", tone: 1, puuids: [first.puuid, second.puuid] }];

    const tags = resolvePremadeTeamTags(groups, [first, second]);
    expect(tags.get("B")?.type).toBe("loss-rate-team");
  });

  it("leaves an ordinary duo untagged and ignores single-player groups", () => {
    const first = player("普通甲", [
      ...repeat(3, { win: true, kills: 2, deaths: 4, assists: 6 }),
      ...repeat(3, { win: false, kills: 2, deaths: 4, assists: 6 }),
    ]);
    const second = player("普通乙", [
      ...repeat(3, { win: true, kills: 2, deaths: 4, assists: 6 }),
      ...repeat(3, { win: false, kills: 2, deaths: 4, assists: 6 }),
    ]);
    const groups: PremadeGroupRef[] = [
      { id: "C", tone: 2, puuids: [first.puuid, second.puuid] },
      { id: "D", tone: 3, puuids: [first.puuid] },
    ];

    const tags = resolvePremadeTeamTags(groups, [first, second]);
    expect(tags.has("C")).toBe(false);
    expect(tags.has("D")).toBe(false);
  });

  it("never labels a win-rate team as a loss-rate team", () => {
    // 两个判定其实互斥：胜率队要求有人胜率 ≥ 90%，而败率队要求全员 ≤ 25%。
    // 这条用例把这个不变量钉住，避免以后调阈值时出现「既是胜率队又是败率队」。
    const ace = player("甲", repeat(13, { win: true, kills: 5, deaths: 1, assists: 3 }));
    const mateOne = player("乙", repeat(5, { win: true, kills: 2, deaths: 2, assists: 4 }));
    const mateTwo = player("丙", repeat(5, { win: true, kills: 2, deaths: 2, assists: 4 }));
    const groups: PremadeGroupRef[] = [
      { id: "E", tone: 4, puuids: [ace.puuid, mateOne.puuid, mateTwo.puuid] },
    ];

    const tags = resolvePremadeTeamTags(groups, [ace, mateOne, mateTwo]);
    expect(tags.get("E")?.type).toBe("win-rate-team");
  });
});
