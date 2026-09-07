import { describe, expect, it } from "vitest";
import { fixtureLobby } from "../fixtures/data";
import type { PlayerProfile } from "../types/domain";
import { assignPremadeTones } from "./premadeGroups";

function player(name: string, premadeWith: string[] = [], isPremade = premadeWith.length > 0): PlayerProfile {
  return {
    ...structuredClone(fixtureLobby.ally[0]),
    puuid: `puuid-${name}`,
    gameName: name,
    isPremade,
    premadeWith,
    recentMatches: [],
  };
}

describe("premade card tones", () => {
  it("assigns one tone to every member of a party and a different tone to another party", () => {
    const first = player("甲", ["乙"]);
    const second = player("乙", ["甲"]);
    const third = player("丙", ["丁"]);
    const fourth = player("丁", ["丙"]);
    const tones = assignPremadeTones([[first, second], [third, fourth]]);

    expect(tones.get(first)).toBe(tones.get(second));
    expect(tones.get(third)).toBe(tones.get(fourth));
    expect(tones.get(first)).not.toBe(tones.get(third));
  });

  it("does not color a solo player or an unconfirmed one-person marker", () => {
    const solo = player("单排");
    const unconfirmed = player("未知队友", [], true);
    const tones = assignPremadeTones([[solo, unconfirmed]]);

    expect(tones.has(solo)).toBe(false);
    expect(tones.has(unconfirmed)).toBe(false);
  });

  it("recovers a party when only one member carries the teammate list", () => {
    const first = player("甲", ["乙"]);
    const second = player("乙", [], true);
    const tones = assignPremadeTones([[first, second]]);

    expect(tones.get(first)).toBe(tones.get(second));
  });

  it("uses the LCU group key when player names are unavailable", () => {
    const first = { ...player("未知玩家 A", [], true), premadeGroup: "party-7" };
    const second = { ...player("未知玩家 B", [], true), premadeGroup: "party-7" };
    const solo = { ...player("单排", [], false), premadeGroup: null };
    const tones = assignPremadeTones([[first, second, solo]]);

    expect(tones.get(first)).toBe(tones.get(second));
    expect(tones.has(solo)).toBe(false);
  });

  it("infers local premades from at least five shared recent games", () => {
    const first = player("甲", [], true);
    const second = player("乙", [], true);
    first.recentMatches = structuredClone(fixtureLobby.ally[0].recentMatches.slice(0, 5));
    second.recentMatches = structuredClone(first.recentMatches);
    const unrelated = player("丙");
    unrelated.recentMatches = structuredClone(fixtureLobby.enemy[0].recentMatches).map((match) => ({
      ...match,
      gameId: match.gameId + 100_000,
    }));
    const tones = assignPremadeTones([[first, second, unrelated]]);

    expect(tones.get(first)).toBe(tones.get(second));
    expect(tones.has(unrelated)).toBe(false);
  });

  it("does not infer a party from fewer than five shared games", () => {
    const first = player("甲", [], true);
    const second = player("乙", [], true);
    first.recentMatches = structuredClone(fixtureLobby.ally[0].recentMatches.slice(0, 4));
    second.recentMatches = structuredClone(first.recentMatches);

    expect(assignPremadeTones([[first, second]]).size).toBe(0);
  });

  it("keeps equal names on opposing teams in separate groups", () => {
    const allyFirst = player("同名", ["我方队友"]);
    const allySecond = player("我方队友", ["同名"]);
    const enemyFirst = player("同名", ["敌方队友"]);
    const enemySecond = player("敌方队友", ["同名"]);
    const tones = assignPremadeTones([[allyFirst, allySecond], [enemyFirst, enemySecond]]);

    expect(tones.get(allyFirst)).toBe(tones.get(allySecond));
    expect(tones.get(enemyFirst)).toBe(tones.get(enemySecond));
    expect(tones.get(allyFirst)).not.toBe(tones.get(enemyFirst));
  });
});
