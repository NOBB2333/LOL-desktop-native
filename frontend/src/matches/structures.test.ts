import { describe, expect, it } from "vitest";
import type { MatchTimelineEvent } from "../types/domain";
import { INHIBITOR_RESPAWN_SECONDS, STRUCTURES, structureStatesAt } from "./structures";

/** 只写关心的字段，其余给中性的默认值。 */
function buildingKill(seconds: number, team: number, fields: Partial<MatchTimelineEvent>): MatchTimelineEvent {
  return {
    type: "BUILDING_KILL",
    seconds,
    team,
    killerId: 0,
    victimId: 0,
    assistCount: 0,
    assistIds: [],
    killerChampionId: 0,
    victimChampionId: 0,
    posX: 0,
    posY: 0,
    monsterType: "",
    monsterSubType: "",
    buildingType: "TOWER_BUILDING",
    towerType: "",
    laneType: "",
    ...fields,
  } as MatchTimelineEvent;
}

const stateOf = (events: MatchTimelineEvent[], seconds: number) => new Map(structureStatesAt(events, seconds).map((item) => [item.spot.id, item.destroyed]));

describe("structures", () => {
  it("是 22 座塔 + 6 座水晶，双方各 11 塔 3 水晶", () => {
    expect(STRUCTURES.filter((item) => item.kind === "turret")).toHaveLength(22);
    expect(STRUCTURES.filter((item) => item.kind === "inhibitor")).toHaveLength(6);
    for (const team of [100, 200]) {
      expect(STRUCTURES.filter((item) => item.team === team && item.kind === "turret")).toHaveLength(11);
      expect(STRUCTURES.filter((item) => item.team === team && item.kind === "inhibitor")).toHaveLength(3);
    }
    // 坐标必须落在 map11 的域内，否则会画到地图外面去。
    for (const item of STRUCTURES) {
      expect(item.x).toBeGreaterThan(0);
      expect(item.x).toBeLessThan(14820);
      expect(item.y).toBeGreaterThan(0);
      expect(item.y).toBeLessThan(14881);
    }
    // id 必须唯一：门牙塔两座只靠后缀区分，撞了就会一起变色。
    expect(new Set(STRUCTURES.map((item) => item.id)).size).toBe(STRUCTURES.length);
  });

  it("开局一座都没掉；事件是「推塔方」，所以掉的是对方那座", () => {
    const events = [buildingKill(600, 100, { laneType: "MID_LANE", towerType: "OUTER_TURRET" })];
    expect([...stateOf(events, 0).values()].some(Boolean)).toBe(false);

    const after = stateOf(events, 601);
    expect(after.get("red-OUTER_TURRET-MID_LANE")).toBe(true);
    expect(after.get("blue-OUTER_TURRET-MID_LANE")).toBe(false);
    // 同一路的二塔/高地塔不该跟着掉（塔是一层层掉的）。
    expect(after.get("red-INNER_TURRET-MID_LANE")).toBe(false);
    expect(after.get("red-BASE_TURRET-MID_LANE")).toBe(false);
  });

  it("门牙塔同分路同 tier，按顺序逐个消耗而不是一起变色", () => {
    const one = stateOf([buildingKill(900, 100, { laneType: "MID_LANE", towerType: "NEXUS_TURRET" })], 901);
    const both = stateOf([buildingKill(900, 100, { laneType: "MID_LANE", towerType: "NEXUS_TURRET" }), buildingKill(940, 100, { laneType: "MID_LANE", towerType: "NEXUS_TURRET" })], 941);
    const before = [one.get("red-NEXUS_TURRET-MID_LANE-1"), one.get("red-NEXUS_TURRET-MID_LANE-2")];
    expect(before.filter(Boolean)).toHaveLength(1);
    expect([both.get("red-NEXUS_TURRET-MID_LANE-1"), both.get("red-NEXUS_TURRET-MID_LANE-2")].every(Boolean)).toBe(true);
  });

  it("水晶 5 分钟后重生（不建模的话 15 分钟掉的水晶到 40 分钟还画成没了）", () => {
    const events = [buildingKill(900, 100, { buildingType: "INHIBITOR_BUILDING", laneType: "BOT_LANE" })];
    const id = "red-INHIBITOR_BUILDING-BOT_LANE";
    const respawnsAt = 900 + INHIBITOR_RESPAWN_SECONDS;
    expect(stateOf(events, 901).get(id)).toBe(true);
    expect(stateOf(events, respawnsAt - 1).get(id)).toBe(true);
    expect(stateOf(events, respawnsAt).get(id)).toBe(false);
  });

  it("游标往后拖只会越掉越多（塔不会自己复活）", () => {
    const events = [buildingKill(300, 100, { laneType: "BOT_LANE", towerType: "OUTER_TURRET" }), buildingKill(800, 200, { laneType: "TOP_LANE", towerType: "OUTER_TURRET" })];
    const counts = [0, 301, 801, 1200].map((seconds) => structureStatesAt(events, seconds).filter((item) => item.destroyed).length);
    expect(counts).toEqual([0, 1, 2, 2]);
  });
});
