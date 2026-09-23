import { describe, expect, it } from "vitest";
import { createFixtureRoomLobby, fixtureBpHistory, fixtureChampions, fixtureConfig, fixtureEncounters, fixtureLobby, fixtureMatches } from "./data";

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

  it("models the lobby room snapshot the way the backend emits it", () => {
    const room = createFixtureRoomLobby(false);
    // 房间没有局号，id 退回占位值——后端 `liveSessionEnvelopePhaseContext` 同口径。
    expect(room.id).toBe("lcu-session");
    expect(room.phase).toBe("Lobby");
    // 房间里只有本机所在小队，不该凭空造出敌方。
    expect(room.ally.length).toBeGreaterThan(0);
    expect(room.ally.length).toBeLessThanOrEqual(5);
    expect(room.enemy).toHaveLength(0);
    // 一支队伍就够，硬摆 0 人的敌方阵容会误导人。
    expect(room.teams).toHaveLength(1);
    expect(room.teams?.[0].label).toBe("房间成员");
    expect(room.enemySummary.score).toBeGreaterThan(0);
  });
});
