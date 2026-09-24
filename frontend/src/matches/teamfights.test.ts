import { describe, expect, it } from "vitest";
import type { MatchTimelineEvent, MatchTimelineParticipant } from "../types/domain";
import { describeLocation, deriveMultiKills, deriveTeamfights, firstBlood, hasPosition, multiKillLabel } from "./teamfights";

/** 1~5 蓝、6~10 红，英雄 id 直接用座位号放大一点，方便断言。 */
const participants: MatchTimelineParticipant[] = Array.from({ length: 10 }, (_, index) => ({
  participantId: index + 1,
  team: index < 5 ? 100 : 200,
  championId: (index + 1) * 10,
}));

function kill(
  seconds: number,
  killerId: number,
  victimId: number,
  extra: Partial<MatchTimelineEvent> = {},
): MatchTimelineEvent {
  const team = killerId <= 5 ? 100 : 200;
  return {
    type: "CHAMPION_KILL",
    seconds,
    team,
    killerId,
    victimId,
    assistCount: 0,
    assistIds: [],
    killerChampionId: killerId * 10,
    victimChampionId: victimId * 10,
    posX: 0,
    posY: 0,
    monsterType: "",
    monsterSubType: "",
    buildingType: "",
    towerType: "",
    laneType: "",
    ...extra,
  };
}

function objective(seconds: number, type: string): MatchTimelineEvent {
  return {
    type,
    seconds,
    team: 100,
    killerId: 2,
    victimId: 0,
    assistCount: 0,
    assistIds: [],
    killerChampionId: 20,
    victimChampionId: 0,
    posX: 4700,
    posY: 10300,
    monsterType: "DRAGON",
    monsterSubType: "FIRE_DRAGON",
    buildingType: "",
    towerType: "",
    laneType: "",
  };
}

describe("deriveTeamfights", () => {
  it("把间隔近、参与者多的击杀聚成一波团，并算出人头归属与中心点", () => {
    const events = [
      // 一波中路团：蓝方 3 换 1，三次击杀在 8 秒内，参战者一共 6 人。
      kill(600, 1, 6, { assistIds: [2, 3], posX: 7000, posY: 7000 }),
      kill(604, 7, 2, { assistIds: [6], posX: 7200, posY: 7100 }),
      kill(608, 3, 7, { assistIds: [1], posX: 7400, posY: 7200 }),
      // 90 秒后一条单独的击杀：参与者只有 2 人，不够成团。
      kill(700, 4, 9, { posX: 3000, posY: 3000 }),
      // 再一波（下路）：间隔在窗口内，参与者 4 人。
      kill(1000, 8, 4, { assistIds: [9], posX: 13000, posY: 3000 }),
      kill(1006, 5, 8, { assistIds: [4, 10], posX: 13200, posY: 3100 }),
    ];

    const fights = deriveTeamfights(events, participants);
    expect(fights.length).toBe(2);

    const first = fights[0];
    expect(first.index).toBe(1);
    expect(first.startSeconds).toBe(600);
    expect(first.endSeconds).toBe(608);
    expect(first.kills.length).toBe(3);
    expect(first.killsByTeam[100]).toBe(2);
    expect(first.killsByTeam[200]).toBe(1);
    expect(first.winningTeam).toBe(100);
    // 参战者去重后按阵营排序：蓝 {1,2,3}、红 {6,7}。
    expect(first.involved.map((item) => item.participantId)).toEqual([1, 2, 3, 6, 7]);
    expect(first.involved[0]).toEqual({ participantId: 1, championId: 10, team: 100 });
    expect(first.center).toEqual({ x: 7200, y: 7100 });

    const second = fights[1];
    expect(second.index).toBe(2);
    // 1 换 1，平手。
    expect(second.winningTeam).toBe(0);
    expect(second.involved.map((item) => item.participantId)).toEqual([4, 5, 8, 9, 10]);
  });

  it("不把对线单杀、以及拿龙推塔算成团战", () => {
    // 1 换 1：参与者只有 2 人，达不到阈值。
    const soloKill = [kill(300, 1, 6), kill(320, 6, 1)];
    expect(deriveTeamfights(soloKill, participants).length).toBe(0);

    // 拿龙/推塔不是击杀，既不能单独成团，也不能把两侧的击杀粘成一波。
    const events = [
      kill(500, 1, 6, { assistIds: [2, 3] }),
      kill(505, 2, 7, { assistIds: [1] }),
      objective(512, "ELITE_MONSTER_KILL"),
      objective(520, "BUILDING_KILL"),
      kill(900, 8, 4, { assistIds: [9] }),
      kill(906, 9, 5, { assistIds: [8] }),
    ];
    const fights = deriveTeamfights(events, participants);
    // 两次击杀分别成团（各自 2 人头、4~5 人参与），但条件是「相邻击杀间隔」——
    // 中间隔着 395 秒，所以必然是两波而不是一波。
    expect(fights.length).toBe(2);
    expect(fights[0].endSeconds).toBe(505);
    expect(fights[1].startSeconds).toBe(900);
  });

  it("阈值可以调，用来区分「连杀」和「团战」", () => {
    const events = [kill(100, 1, 6, { assistIds: [2] }), kill(104, 2, 7, { assistIds: [1] })];
    // 2 人头、4 人参与 → 默认口径就是一波团。
    expect(deriveTeamfights(events, participants).length).toBe(1);
    // 把下限抬到 3 人头，同一份数据就不再是团战。
    expect(deriveTeamfights(events, participants, { minKills: 3 }).length).toBe(0);
  });

  it("center 只在真的有位置时才算，缺位置的击杀不会被当成左下场", () => {
    const events = [
      kill(200, 1, 6, { assistIds: [2], posX: 8000, posY: 8000 }),
      // 这条没有位置（后端写 0/0），不能参与平均。
      kill(204, 2, 7, { assistIds: [1] }),
    ];
    const fight = deriveTeamfights(events, participants)[0];
    expect(fight.center).toEqual({ x: 8000, y: 8000 });

    const noPosition = deriveTeamfights([kill(200, 1, 6, { assistIds: [2] }), kill(204, 2, 7, { assistIds: [1] })], participants)[0];
    expect(noPosition.center).toBeNull();
    expect(hasPosition(kill(0, 1, 6))).toBe(false);
    expect(hasPosition(kill(0, 1, 6, { posX: 1, posY: 0 }))).toBe(true);
  });

  it("participants 表缺失时按座位号兜底阵营，与后端口径一致", () => {
    const fight = deriveTeamfights([kill(100, 1, 6, { assistIds: [9] }), kill(104, 2, 7, { assistIds: [10] })], [])[0];
    // 参战者 {1,2,6,7,9,10}：前三个人在蓝、后三个在红。
    expect(fight.involved.map((item) => item.team)).toEqual([100, 100, 200, 200, 200, 200]);
    // 没有 participants 就查不到英雄 id，但不能因此崩掉。
    expect(fight.involved.every((item) => item.championId === 0)).toBe(true);
  });
});

describe("deriveMultiKills", () => {
  it("同一个击杀者在窗口内连续拿人头才算多杀", () => {
    const events = [
      kill(100, 1, 6),
      kill(105, 1, 7),
      kill(110, 1, 8),
      // 间隔 40 秒，另起一次。
      kill(150, 1, 9),
      kill(155, 1, 10),
      // 中间换人，双方都不连。
      kill(160, 3, 1),
      kill(165, 3, 2),
    ];
    const multi = deriveMultiKills(events);
    expect(multi.map((item) => `${item.label}@${item.endSeconds}`)).toEqual(["三杀@110", "双杀@155", "双杀@165"]);
    expect(multi[0]).toMatchObject({ killerId: 1, championId: 10, team: 100, count: 3, startSeconds: 100 });
  });

  it("超过窗口就断开，单杀不产生条目", () => {
    expect(deriveMultiKills([kill(100, 1, 6), kill(111, 1, 7)])).toEqual([]);
    expect(deriveMultiKills([kill(100, 1, 6)])).toEqual([]);
  });

  it("五杀及以上的标签收敛到「五杀」", () => {
    expect(multiKillLabel(2)).toBe("双杀");
    expect(multiKillLabel(4)).toBe("四杀");
    expect(multiKillLabel(5)).toBe("五杀");
    expect(multiKillLabel(1)).toBe("");
  });
});

describe("describeLocation", () => {
  it("按最近邻点位给团战落点起名，没有位置时不编", () => {
    expect(describeLocation({ x: 4900, y: 9800 })).toBe("大龙坑");
    expect(describeLocation({ x: 9900, y: 4400 })).toBe("小龙坑");
    expect(describeLocation({ x: 7450, y: 7380 })).toBe("中路");
    expect(describeLocation({ x: 13100, y: 3450 })).toBe("红方下路");
    // 坐标域外的怪值也不该崩，只会落到某个最近点上。
    expect(describeLocation({ x: 0, y: 0 })).toBe("蓝方下路");
    expect(describeLocation(null)).toBe("位置未知");
  });
});

describe("firstBlood", () => {
  it("取全场最早的一次击杀，拿不到就是 null", () => {
    expect(firstBlood([kill(400, 1, 6), kill(200, 8, 3)])?.seconds).toBe(200);
    expect(firstBlood([objective(100, "ELITE_MONSTER_KILL")])).toBeNull();
    expect(firstBlood([])).toBeNull();
  });
});
