import { describe, expect, it } from "vitest";
import type { MatchParticipant, MatchTimelineParticipant } from "../types/domain";
import { pairSeatsWithPlayers, realSeats, sameTeamAsSeat, teamOf } from "./lineup";

function player(slot: number, overrides: Partial<MatchParticipant> = {}): MatchParticipant {
  return {
    puuid: `puuid-${slot}`,
    gameName: `玩家${slot}`,
    isBot: false,
    championId: slot * 10,
    championName: `英雄${slot}`,
    side: slot <= 5 ? "ally" : "enemy",
    team: slot <= 5 ? 100 : 200,
    position: "MIDDLE",
    kills: slot,
    deaths: 0,
    assists: 0,
    damageDealt: slot * 1000,
    damageTaken: slot * 500,
    goldEarned: 0,
    cs: 0,
    win: true,
    items: [],
    towerDamage: slot * 100,
    ...overrides,
  };
}

function seat(slot: number, overrides: Partial<MatchTimelineParticipant> = {}): MatchTimelineParticipant {
  return { participantId: slot, team: slot <= 5 ? 100 : 200, championId: slot * 10, ...overrides };
}

const seats = Array.from({ length: 10 }, (_, index) => seat(index + 1));

describe("座位与十人详情的配对", () => {
  it("视角方在蓝方：十个座位全部配上", () => {
    const table = pairSeatsWithPlayers(seats, seats.map((_, index) => player(index + 1)));
    expect(table.size).toBe(10);
    expect(table.get(1)?.gameName).toBe("玩家1");
    expect(table.get(10)?.gameName).toBe("玩家10");
  });

  /**
   * 这就是真机上「每个人 KDA 都是 000、装备一片空白」的那个 bug。
   *
   * 后端 DTO 的 `side` 是**相对视角**的：视角方在红方时，他自己那一行是 `side:"ally"`
   * 而绝对阵营是 200。老规则 `(seat.team === 蓝方) === (player.side !== "enemy")`
   * 于是红方那五个（side=ally）配蓝方座位失败、蓝方那五个（side=enemy）配红方座位也失败
   * ——十个座位全落空。带 `team` 的 DTO 必须按绝对阵营配上。
   */
  it("视角方在红方：side 是相对的，仍要按绝对 team 配上", () => {
    const redView = seats.map((_, index) =>
      player(index + 1, index >= 5 ? { side: "ally", team: 200 } : { side: "enemy", team: 100 }),
    );
    // 老口径（只看 side）在这个数据上会把十个座位**全配空**——先把这个前提钉死，
    // 免得将来有人「简化」回 side 判定，还以为两种写法等价。
    const legacyRuleHits = seats.filter((item) =>
      redView.some((candidate) => candidate.championId === item.championId && (item.team === 100) === (candidate.side !== "enemy")),
    );
    expect(legacyRuleHits).toHaveLength(0);
    const table = pairSeatsWithPlayers(seats, redView);
    expect(table.size).toBe(10);
    expect(table.get(6)?.side).toBe("ally");
    expect(table.get(1)?.side).toBe("enemy");
    expect(teamOf(table.get(6)!)).toBe(200);
  });

  it("老缓存没有 team 字段时退回相对 side 的旧口径（fixture / 历史落盘数据不回归）", () => {
    const legacy = seats.map((_, index) => player(index + 1, index < 5 ? { team: undefined, side: "ally" } : { team: undefined, side: "enemy" }));
    const table = pairSeatsWithPlayers(seats, legacy);
    expect(table.size).toBe(10);
    expect(sameTeamAsSeat(legacy[0], 100)).toBe(true);
    expect(sameTeamAsSeat(legacy[5], 200)).toBe(true);
  });

  it("镜像对局（两队同一个英雄）不会把两个人对调", () => {
    const mirror = seats.map((_, index) => player(index + 1, { championId: 64 }));
    const mirroredSeats = seats.map((item) => ({ ...item, championId: 64 }));
    const table = pairSeatsWithPlayers(mirroredSeats, mirror);
    expect(table.size).toBe(10);
    expect(table.get(1)?.puuid).toBe("puuid-1");
    expect(table.get(6)?.puuid).toBe("puuid-6");
  });

  it("同队同英雄时各配一个，不会两行指向同一个人", () => {
    const twins = [player(1, { championId: 7, puuid: "a" }), player(2, { championId: 7, puuid: "b" })];
    const twinSeats: MatchTimelineParticipant[] = [
      { participantId: 1, team: 100, championId: 7 },
      { participantId: 2, team: 100, championId: 7 },
    ];
    const table = pairSeatsWithPlayers(twinSeats, twins);
    expect([table.get(1)?.puuid, table.get(2)?.puuid]).toEqual(["a", "b"]);
  });

  it("帧里缺人留下的空座位（championId 0）被跳过，不占坑也不摆在界面上", () => {
    const sparse: MatchTimelineParticipant[] = [
      ...seats.slice(0, 7),
      { participantId: 8, team: 0, championId: 0 },
      { participantId: 9, team: 0, championId: 0 },
      { participantId: 10, team: 0, championId: 0 },
    ];
    expect(realSeats(sparse)).toHaveLength(7);
    const table = pairSeatsWithPlayers(sparse, Array.from({ length: 10 }, (_, index) => player(index + 1)));
    expect(table.size).toBe(7);
    expect(table.has(8)).toBe(false);
  });
});
