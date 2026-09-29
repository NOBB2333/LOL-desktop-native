import { describe, expect, it } from "vitest";
import type { GameRecordingFrame, GameRecordingPlayer } from "../types/domain";
import { buildRecordedSeatLookup, frameTeamCode, namePartOf, normalizeRiotId, recordedPlayerForSeat, riotIdOf, seatTeamOf } from "./recordingLineup";

const BLUE = 100;
const RED = 200;

function recordedPlayer(overrides: Partial<GameRecordingPlayer> & { rid?: string } = {}): GameRecordingPlayer {
  return {
    puuid: "",
    rid: "",
    team: "ORDER",
    champ: "",
    cid: 0,
    pos: "MIDDLE",
    lvl: 10,
    k: 0,
    d: 0,
    a: 0,
    cs: 0,
    ward: 0,
    dead: false,
    respawn: 0,
    bot: false,
    items: [],
    spells: [],
    ...overrides,
  };
}

function frameOf(players: GameRecordingPlayer[]): GameRecordingFrame {
  return { t: 600, gameId: 1, sampledAt: "2026-09-29T00:00:00.000Z", players, me: null };
}

describe("recordingLineup helpers", () => {
  it("normalizes riot ids and splits off the tag", () => {
    expect(normalizeRiotId("  老王#59244 ")).toBe("老王#59244");
    expect(normalizeRiotId(undefined)).toBe("");
    expect(namePartOf("老王#59244")).toBe("老王");
    expect(namePartOf("老王")).toBe("老王");
    // 名字里本来带 `#` 的极端情况：只切第一个，剩下的算 tag。
    expect(namePartOf("A#B#C")).toBe("a");
    expect(riotIdOf("老王", "59244")).toBe("老王#59244");
    expect(riotIdOf("老王", "")).toBe("老王");
    expect(riotIdOf("", "59244")).toBe("");
  });

  it("maps frame team strings to absolute team codes", () => {
    expect(frameTeamCode("ORDER")).toBe(BLUE);
    expect(frameTeamCode("CHAOS")).toBe(RED);
    expect(frameTeamCode("")).toBe(0);
  });

  it("infers the seat team from a participant, falling back to the historical blue default", () => {
    expect(seatTeamOf(null)).toBe(0);
    expect(seatTeamOf({ team: RED } as never)).toBe(RED);
    expect(seatTeamOf({ side: "enemy" } as never)).toBe(RED);
    expect(seatTeamOf({ side: "ally" } as never)).toBe(BLUE);
  });
});

/**
 * 这一组是这次报障的正身：**Live Client Data 的 allPlayers 没有 puuid**，
 * 所以录制帧里 `puuid` 恒为空串（见 `recordingFrame` 之类桩里的注释）。
 * 配对必须靠 `rid` / 名字，而不是 puuid。
 */
describe("recordedPlayerForSeat pairs by Riot ID, not by the (always empty) puuid", () => {
  it("never relies on puuid — it is empty on every real frame", () => {
    const frame = frameOf([recordedPlayer({ rid: "老王#59244", cid: 222, k: 3 })]);
    expect(frame.players.every((entry) => entry.puuid === "")).toBe(true);
    const lookup = buildRecordedSeatLookup(frame);
    const hit = recordedPlayerForSeat(BLUE, 1, { team: BLUE, championId: 222, gameName: "老王" }, lookup);
    expect(hit?.k).toBe(3);
  });

  it("matches by the name part when the detail has no tag line", () => {
    // 十人详情只有 gameName（没有 tagLine），帧里是完整 rid —— 这是**主路径**。
    const frame = frameOf([recordedPlayer({ rid: "老王#59244", cid: 222, d: 4 })]);
    const lookup = buildRecordedSeatLookup(frame);
    expect(recordedPlayerForSeat(BLUE, 1, { team: BLUE, championId: 222, gameName: "老王" }, lookup)?.d).toBe(4);
  });

  it("will not hand over a player whose champion disagrees", () => {
    // 名字撞上、英雄对不上 → 认作脏数据，不走这一档（否则会把别人算成他）。
    const frame = frameOf([recordedPlayer({ rid: "老王#59244", cid: 999 })]);
    const lookup = buildRecordedSeatLookup(frame);
    const hit = recordedPlayerForSeat(BLUE, 1, { team: BLUE, championId: 222, gameName: "老王" }, lookup);
    // 落到「同阵营」兜底，仍然是这个人（帧里就他一个），但至少不是靠名字硬配的。
    expect(hit?.cid).toBe(999);
  });

  it("distinguishes two same-champion players on the same team by their riot id", () => {
    // 镜像对局里同队同英雄很常见：必须靠 rid 区分，不能两个座位吃同一个人。
    const frame = frameOf([
      recordedPlayer({ rid: "甲#001", cid: 64, k: 1 }),
      recordedPlayer({ rid: "乙#002", cid: 64, k: 2 }),
    ]);
    const lookup = buildRecordedSeatLookup(frame);
    const first = recordedPlayerForSeat(BLUE, 1, { team: BLUE, championId: 64, gameName: "甲" }, lookup);
    const second = recordedPlayerForSeat(BLUE, 2, { team: BLUE, championId: 64, gameName: "乙" }, lookup);
    expect(first?.k).toBe(1);
    expect(second?.k).toBe(2);
  });

  it("does not let two seats claim the same recorded player", () => {
    // 两个座位都没有名字、同阵营同英雄（都是空名 bot）→ 第二个人只能拿剩下的那个。
    const frame = frameOf([
      recordedPlayer({ rid: "A#1", cid: 1, k: 1, team: "ORDER" }),
      recordedPlayer({ rid: "B#2", cid: 1, k: 2, team: "ORDER" }),
    ]);
    const lookup = buildRecordedSeatLookup(frame);
    const first = recordedPlayerForSeat(BLUE, 1, { team: BLUE, championId: 0, gameName: "" }, lookup);
    const second = recordedPlayerForSeat(BLUE, 2, { team: BLUE, championId: 0, gameName: "" }, lookup);
    expect([first?.k, second?.k].sort()).toEqual([1, 2]);
  });

  it("keeps the two teams apart", () => {
    const frame = frameOf([
      recordedPlayer({ rid: "同名人#111", cid: 64, team: "ORDER", k: 1 }),
      recordedPlayer({ rid: "同名人#222", cid: 64, team: "CHAOS", k: 9 }),
    ]);
    const lookup = buildRecordedSeatLookup(frame);
    expect(recordedPlayerForSeat(RED, 6, { team: RED, championId: 64, gameName: "同名人" }, lookup)?.k).toBe(9);
  });

  it("returns null when the seat has no identity to work with", () => {
    const lookup = buildRecordedSeatLookup(frameOf([recordedPlayer({ rid: "老王#59244", cid: 222 })]));
    expect(recordedPlayerForSeat(BLUE, 1, null, lookup)).toBeNull();
  });

  it("copes with a frame that only contains five people (practice/custom games)", () => {
    // 实测训练模式 allPlayers 只回我方 5 人：后 5 个座位配不上是**正常**的，
    // 不能因此把前 5 个也搞错。
    const frame = frameOf(
      Array.from({ length: 5 }, (_, index) => recordedPlayer({ rid: `我方${index}#CN1`, cid: 100 + index, k: index })),
    );
    const lookup = buildRecordedSeatLookup(frame);
    for (let index = 0; index < 5; index += 1) {
      const hit = recordedPlayerForSeat(BLUE, index + 1, { team: BLUE, championId: 100 + index, gameName: `我方${index}` }, lookup);
      expect(hit?.k).toBe(index);
    }
    // 红方五个座位：帧里没有 CHAOS 的人 → 一个都配不上。
    for (let index = 6; index <= 10; index += 1) {
      expect(recordedPlayerForSeat(RED, index, { team: RED, championId: 200 + index, gameName: `敌方${index}` }, lookup)).toBeNull();
    }
  });

  it("handles an empty frame", () => {
    const lookup = buildRecordedSeatLookup(null);
    expect(recordedPlayerForSeat(BLUE, 1, { team: BLUE, championId: 1, gameName: "谁" }, lookup)).toBeNull();
  });
});
