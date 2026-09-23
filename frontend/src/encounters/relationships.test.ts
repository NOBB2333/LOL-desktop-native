import { describe, expect, it } from "vitest";
import type { EncounterRecord } from "../types/domain";
import { aggregateRelationships, lastSeenLabel, relationLabel } from "./relationships";

const DAY = 86_400_000;
const now = Date.parse("2026-09-24T12:00:00.000Z");

function record(overrides: Partial<EncounterRecord> & { puuid: string; gameId: number }): EncounterRecord {
  return {
    gameName: overrides.puuid,
    championId: 1,
    championName: "英雄",
    side: "enemy",
    result: "胜利",
    encounteredAt: new Date(now - DAY).toISOString(),
    ...overrides,
  } as EncounterRecord;
}

describe("aggregateRelationships", () => {
  it("按玩家聚合成场次、队友/对手、我方视角胜率", () => {
    const records: EncounterRecord[] = [
      record({ puuid: "a", gameId: 1, side: "ally", selfWin: true, encounteredAt: new Date(now - 3 * DAY).toISOString(), kills: 5, selfKills: 8 }),
      record({ puuid: "a", gameId: 2, side: "enemy", selfWin: false, encounteredAt: new Date(now - DAY).toISOString(), kills: 9, selfKills: 3, queueName: "单双排" }),
      record({ puuid: "b", gameId: 2, side: "ally", selfWin: false }),
    ];
    const result = aggregateRelationships(records, now);

    expect(result).toHaveLength(2);
    const a = result[0];
    expect(a.puuid).toBe("a");
    expect(a.totalGames).toBe(2);
    expect(a.allyGames).toBe(1);
    expect(a.enemyGames).toBe(1);
    expect(a.wins).toBe(1);
    expect(a.decidedGames).toBe(2);
    expect(a.winRate).toBe(0.5);
    // 最近一次交手（gameId 2）排在 games 首位，行上展示的就是它。
    expect(a.last.gameId).toBe(2);
    expect(a.last.kills).toBe(9);
    expect(a.last.selfKills).toBe(3);
    expect(a.last.queueName).toBe("单双排");
    // 窗口总局数 = 不同 gameId 数（1、2），相遇次数的分母。
    expect(a.windowGames).toBe(2);
    expect(relationLabel(a)).toBe("队友 1 · 对手 1");
  });

  it("同局重复行只算一次，并把后到的胜负补上", () => {
    const records: EncounterRecord[] = [
      record({ puuid: "a", gameId: 7, win: undefined, selfWin: undefined, result: null as unknown as string }),
      record({ puuid: "a", gameId: 7, win: true, selfWin: true }),
    ];
    const [a] = aggregateRelationships(records, now);
    expect(a.totalGames).toBe(1);
    expect(a.decidedGames).toBe(1);
    expect(a.wins).toBe(1);
  });

  it("按相遇次数降序，其次按最近交手时间降序", () => {
    const records: EncounterRecord[] = [
      record({ puuid: "少", gameId: 1, encounteredAt: new Date(now - DAY).toISOString() }),
      record({ puuid: "多", gameId: 2, encounteredAt: new Date(now - 5 * DAY).toISOString() }),
      record({ puuid: "多", gameId: 3, encounteredAt: new Date(now - 4 * DAY).toISOString() }),
      record({ puuid: "中", gameId: 4, encounteredAt: new Date(now - 2 * DAY).toISOString() }),
    ];
    // 「多」2 次排第一；「少」「中」各 1 次，按最近交手倒序 → 1 天前的「少」在 2 天前的「中」之前。
    expect(aggregateRelationships(records, now).map((item) => item.puuid)).toEqual(["多", "少", "中"]);
  });

  it("没有胜负信息的对局不计入胜率分母", () => {
    const records: EncounterRecord[] = [
      record({ puuid: "a", gameId: 1, selfWin: true }),
      record({ puuid: "a", gameId: 2, win: undefined, selfWin: undefined, result: null as unknown as string }),
    ];
    const [a] = aggregateRelationships(records, now);
    expect(a.totalGames).toBe(2);
    expect(a.decidedGames).toBe(1);
    expect(a.winRate).toBe(1);
  });

  it("跳过没有 puuid 的行与实时快照行", () => {
    const records: EncounterRecord[] = [
      record({ puuid: "", gameId: 1 }),
      record({ puuid: "a", gameId: 2, liveSnapshot: true }),
    ];
    expect(aggregateRelationships(records, now)).toEqual([]);
  });

  it("天数口径：今天/昨天/天/月", () => {
    const [today] = aggregateRelationships([record({ puuid: "t", gameId: 1, encounteredAt: new Date(now - 3600_000).toISOString() })], now);
    expect(lastSeenLabel(today)).toBe("今天");
    const [yesterday] = aggregateRelationships([record({ puuid: "y", gameId: 2, encounteredAt: new Date(now - DAY - 3600_000).toISOString() })], now);
    expect(lastSeenLabel(yesterday)).toBe("昨天");
    const [week] = aggregateRelationships([record({ puuid: "w", gameId: 3, encounteredAt: new Date(now - 5 * DAY).toISOString() })], now);
    expect(lastSeenLabel(week)).toBe("5 天前");
    const [old] = aggregateRelationships([record({ puuid: "o", gameId: 4, encounteredAt: new Date(now - 70 * DAY).toISOString() })], now);
    expect(lastSeenLabel(old)).toBe("2 个月前");
  });
});
