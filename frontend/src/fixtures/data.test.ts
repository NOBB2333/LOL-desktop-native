import { describe, expect, it } from "vitest";
import { fixtureBpHistory, fixtureChampions, fixtureConfig, fixtureEncounters, fixtureLobby, fixtureMatches } from "./data";

describe("fixture data", () => {
  it("contains two complete teams for offline preview", () => {
    expect(fixtureLobby.ally).toHaveLength(5);
    expect(fixtureLobby.enemy).toHaveLength(5);
    expect(fixtureLobby.ally.every((player) => player.dataComplete)).toBe(true);
    expect(fixtureLobby.enemySummary.score).toBeGreaterThan(0);
    expect(fixtureLobby.layoutKind).toBe("classic");
    expect(fixtureLobby.teams).toHaveLength(2);
    expect(fixtureLobby.teams?.every((team) => team.players.length === 5)).toBe(true);
  });

  it("contains cached champion and match records", () => {
    expect(fixtureChampions).toHaveLength(10);
    expect(fixtureChampions.some((champion) => champion.alias === "Ahri")).toBe(true);
    expect(fixtureMatches).toHaveLength(10);
    expect(fixtureMatches[0].items.length).toBeGreaterThan(0);
    expect(fixtureMatches[0].participants).toHaveLength(10);
    expect(fixtureMatches[0].damageDealt).toBeGreaterThan(0);
    expect(fixtureMatches[0].queueId).toBe(420);
    expect(fixtureMatches[5].queueId).toBe(450);
    expect(fixtureEncounters.every((record) => record.championId > 0)).toBe(true);
    expect(fixtureBpHistory.every((record) => record.allyChampionIds.length === record.allyChampions.length)).toBe(true);
    expect(fixtureBpHistory.every((record) => record.enemyChampionIds.length === record.enemyChampions.length)).toBe(true);
  });

  it("ships only valid shortcut placeholders", () => {
    const templates = fixtureConfig.automation.shortcuts.map((shortcut) => shortcut.template);
    expect(templates.join(" ")).not.toContain("{record}");
  });
});
