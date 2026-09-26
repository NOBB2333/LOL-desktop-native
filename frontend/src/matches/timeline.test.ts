import { describe, expect, it } from "vitest";
import type { MatchTimelineEvent } from "../types/domain";
import { buildingLabel, clockOf, compactGold, eventDetail, eventTitle, killTally, monsterLabel, pathFrom, signedGold, splitBySign, teamLabel } from "./timeline";

const event = (base: Partial<MatchTimelineEvent> & Pick<MatchTimelineEvent, "type">): MatchTimelineEvent => ({
  seconds: 60,
  team: 100,
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
  buildingType: "",
  towerType: "",
  laneType: "",
  ...base,
});

describe("timeline formatting", () => {
  it("formats clock and gold values without leaking negative time", () => {
    expect(clockOf(0)).toBe("00:00");
    expect(clockOf(59)).toBe("00:59");
    expect(clockOf(65)).toBe("01:05");
    expect(clockOf(1832)).toBe("30:32");
    // 脏数据不该画出 `-1:-3` 这种东西。
    expect(clockOf(-5)).toBe("00:00");
    expect(clockOf(Number.NaN)).toBe("00:00");
  });

  it("compacts gold and keeps the sign", () => {
    expect(compactGold(999)).toBe("999");
    expect(compactGold(1250)).toBe("1.3k");
    // 两位数 k 必须保住小数：用户报的就是「一过 10k 就只剩 10/11/12」。
    expect(compactGold(6520)).toBe("6.5k");
    expect(compactGold(10500)).toBe("10.5k");
    expect(compactGold(24300)).toBe("24.3k");
    // 到三位数 k 才舍小数，免得 Y 轴被挤爆。
    expect(compactGold(123400)).toBe("123k");
    expect(signedGold(2400)).toBe("+2.4k");
    expect(signedGold(-8100)).toBe("-8.1k");
    expect(signedGold(0)).toBe("0");
  });

  it("names both teams, and admits when it does not know", () => {
    expect(teamLabel(100)).toBe("蓝方");
    expect(teamLabel(200)).toBe("红方");
    expect(teamLabel(0)).toBe("未知方");
  });
});

describe("timeline event labels", () => {
  it("prefers the dragon sub-type so the timeline is not all just 小龙", () => {
    expect(monsterLabel(event({ type: "ELITE_MONSTER_KILL", monsterType: "DRAGON", monsterSubType: "FIRE_DRAGON" }))).toBe("火龙");
    expect(monsterLabel(event({ type: "ELITE_MONSTER_KILL", monsterType: "DRAGON", monsterSubType: "ELDER_DRAGON" }))).toBe("远古龙");
    expect(monsterLabel(event({ type: "ELITE_MONSTER_KILL", monsterType: "DRAGON" }))).toBe("小龙");
    expect(monsterLabel(event({ type: "ELITE_MONSTER_KILL", monsterType: "BARON_NASHOR" }))).toBe("大龙");
    expect(monsterLabel(event({ type: "ELITE_MONSTER_KILL", monsterType: "RIFTHERALD" }))).toBe("峡谷先锋");
  });

  it("keeps lane and tower tier for buildings, and drops the tier for inhibitors", () => {
    expect(buildingLabel(event({ type: "BUILDING_KILL", buildingType: "TOWER_BUILDING", towerType: "OUTER_TURRET", laneType: "BOT_LANE" }))).toBe("下路一塔");
    expect(buildingLabel(event({ type: "BUILDING_KILL", buildingType: "TOWER_BUILDING", towerType: "BASE_TURRET", laneType: "MID_LANE" }))).toBe("中路高地塔");
    expect(buildingLabel(event({ type: "BUILDING_KILL", buildingType: "INHIBITOR_BUILDING", laneType: "TOP_LANE" }))).toBe("上路水晶");
    // 认不出塔型时退回「防御塔」，不要吐出空字符串。
    expect(buildingLabel(event({ type: "BUILDING_KILL", buildingType: "TOWER_BUILDING", laneType: "MID_LANE" }))).toBe("中路防御塔");
  });

  it("describes who did what, and says 单杀 instead of 0 助攻", () => {
    expect(eventTitle(event({ type: "CHAMPION_KILL" }))).toBe("击杀");
    expect(eventDetail(event({ type: "CHAMPION_KILL", assistCount: 3 }))).toBe("蓝方 · 3 助攻");
    expect(eventDetail(event({ type: "CHAMPION_KILL", assistCount: 0 }))).toBe("蓝方 · 单杀");
    expect(eventDetail(event({ type: "ELITE_MONSTER_KILL", monsterType: "BARON_NASHOR", team: 200 }))).toBe("红方拿到");
    expect(eventDetail(event({ type: "BUILDING_KILL", buildingType: "TOWER_BUILDING", team: 100 }))).toBe("蓝方推掉");
    expect(eventDetail(event({ type: "TURRET_PLATE_DESTROYED", team: 200 }))).toBe("红方拆掉");
  });

  it("uses the lane for a turret plate title", () => {
    expect(eventTitle(event({ type: "TURRET_PLATE_DESTROYED", laneType: "MID_LANE" }))).toBe("中路镀层");
  });

  it("counts kills per side and ignores the other event types", () => {
    const tally = killTally([
      event({ type: "CHAMPION_KILL", team: 100 }),
      event({ type: "CHAMPION_KILL", team: 100 }),
      event({ type: "CHAMPION_KILL", team: 200 }),
      event({ type: "ELITE_MONSTER_KILL", team: 200 }),
      event({ type: "BUILDING_KILL", team: 200, buildingType: "TOWER_BUILDING" }),
    ]);
    expect(tally).toEqual({ blue: 2, red: 1 });
  });
});

describe("timeline curve splitting", () => {
  it("splits the curve at the zero crossing so both halves keep a point on the axis", () => {
    const runs = splitBySign(
      [
        { x: 0, y: 80, value: -800 },
        { x: 10, y: 20, value: -200 },
        { x: 20, y: 20, value: 200 },
        { x: 30, y: 80, value: 800 },
      ],
      50,
    );

    expect(runs).toHaveLength(2);
    expect(runs[0].leading).toBe(false);
    expect(runs[1].leading).toBe(true);
    // 交点在 15 处（-200 → 200 的中点），y 落在零轴。
    expect(runs[0].points[runs[0].points.length - 1]).toEqual({ x: 15, y: 50 });
    expect(runs[1].points[0]).toEqual({ x: 15, y: 50 });
  });

  it("keeps a single run when the whole game is one-sided", () => {
    const runs = splitBySign(
      [
        { x: 0, y: 40, value: 100 },
        { x: 10, y: 30, value: 300 },
      ],
      50,
    );
    expect(runs).toHaveLength(1);
    expect(runs[0].leading).toBe(true);
  });

  it("renders a polyline path", () => {
    expect(pathFrom([{ x: 1, y: 2 }, { x: 3, y: 4 }])).toBe("M1.0,2.0 L3.0,4.0");
    expect(pathFrom([])).toBe("");
  });
});
