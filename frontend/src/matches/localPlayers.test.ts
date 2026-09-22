import { describe, expect, it } from "vitest";
import { buildLocalPlayerIndex, localPlayerRiotId, scorePlayerName, searchLocalPlayers } from "./localPlayers";
import type { EncounterRecord, FriendRecord } from "../types/domain";

function encounter(overrides: Partial<EncounterRecord>): EncounterRecord {
  return {
    gameId: 1,
    puuid: "p-1",
    gameName: "河道观察者",
    tagLine: "233",
    championId: 64,
    championName: "盲僧",
    side: "enemy",
    result: null,
    encounteredAt: "2026-09-01T10:00:00.000Z",
    ...overrides,
  };
}

function friend(overrides: Partial<FriendRecord>): FriendRecord {
  return {
    id: "friend-1",
    puuid: "p-1",
    summonerId: 1,
    gameName: "河道观察者",
    gameTag: "233",
    icon: 1,
    groupId: 1,
    availability: "chat",
    gameStatus: "",
    canSpectate: false,
    friendsSince: null,
    lastGameAt: null,
    ...overrides,
  };
}

describe("buildLocalPlayerIndex", () => {
  it("合并同一玩家的多条遇到记录，并记住最近一次遇到的英雄", () => {
    const index = buildLocalPlayerIndex({
      encounters: [
        encounter({ gameId: 1, encounteredAt: "2026-09-01T10:00:00.000Z", championName: "盲僧" }),
        encounter({ gameId: 2, encounteredAt: "2026-09-05T10:00:00.000Z", championName: "蜘蛛女皇" }),
        encounter({ gameId: 3, encounteredAt: "2026-09-03T10:00:00.000Z", championName: "豹女" }),
      ],
      friends: [],
    });
    expect(index).toHaveLength(1);
    expect(index[0].encounterGames).toBe(3);
    expect(index[0].lastSeenAt).toBe("2026-09-05T10:00:00.000Z");
    expect(index[0].lastChampion).toBe("蜘蛛女皇");
    expect(index[0].isFriend).toBe(false);
  });

  it("好友列表补上 isFriend，且只出现在好友里的人也会进索引", () => {
    const index = buildLocalPlayerIndex({
      encounters: [encounter({ puuid: "p-1" })],
      friends: [friend({ puuid: "p-1" }), friend({ id: "friend-2", puuid: "p-2", gameName: "狐狸收藏家", gameTag: "MID" })],
    });
    const met = index.find((hit) => hit.puuid === "p-1");
    expect(met?.isFriend).toBe(true);
    expect(met?.encounterGames).toBe(1);
    const onlyFriend = index.find((hit) => hit.puuid === "p-2");
    expect(onlyFriend?.isFriend).toBe(true);
    expect(onlyFriend?.encounterGames).toBe(0);
  });

  it("忽略没有 puuid 的记录", () => {
    expect(buildLocalPlayerIndex({ encounters: [encounter({ puuid: "" })], friends: [friend({ puuid: "  " })] })).toHaveLength(0);
  });
});

describe("scorePlayerName", () => {
  it("整串包含优先于子序列命中", () => {
    const direct = scorePlayerName("河道", "河道观察者", "233")!;
    const sequence = scorePlayerName("河观", "河道观察者", "233")!;
    expect(direct).toBeGreaterThan(sequence);
  });

  it("标签也参与匹配", () => {
    expect(scorePlayerName("233", "河道观察者", "233")).not.toBeNull();
  });

  it("大小写不敏感，不匹配时返回 null", () => {
    expect(scorePlayerName("mid", "狐狸收藏家", "MID")).not.toBeNull();
    expect(scorePlayerName("不存在的人", "河道观察者", "233")).toBeNull();
  });
});

describe("searchLocalPlayers", () => {
  const index = buildLocalPlayerIndex({
    encounters: [
      encounter({ puuid: "p-1", gameName: "河道观察者", tagLine: "233", encounteredAt: "2026-09-01T10:00:00.000Z" }),
      encounter({ puuid: "p-3", gameName: "河道散步", tagLine: "TOP", encounteredAt: "2026-09-08T10:00:00.000Z" }),
    ],
    friends: [friend({ puuid: "p-2", gameName: "河道", gameTag: "JG" })],
  });

  it("名字越短、命中越靠前的分越高", () => {
    // 三个都是前缀命中「河道」，所以名下的多余字数决定顺序：「河道」自己最短。
    expect(searchLocalPlayers("河道", index).map((hit) => hit.puuid)).toEqual(["p-2", "p-3", "p-1"]);
  });

  it("同分时更常遇到的靠前", () => {
    const tie = buildLocalPlayerIndex({
      encounters: [
        encounter({ gameId: 1, puuid: "p-a", gameName: "同名", tagLine: "X" }),
        encounter({ gameId: 2, puuid: "p-a", gameName: "同名", tagLine: "X" }),
        encounter({ gameId: 3, puuid: "p-b", gameName: "同名", tagLine: "X" }),
      ],
      friends: [],
    });
    expect(searchLocalPlayers("同名", tie).map((hit) => hit.puuid)).toEqual(["p-a", "p-b"]);
  });

  it("空查询与无命中都返回空数组", () => {
    expect(searchLocalPlayers("", index)).toEqual([]);
    expect(searchLocalPlayers("   ", index)).toEqual([]);
    expect(searchLocalPlayers("完全不相干", index)).toEqual([]);
  });

  it("遵守条数上限", () => {
    expect(searchLocalPlayers("河道", index, 2)).toHaveLength(2);
  });

  it("riot id 在缺标签时退化成只用名字", () => {
    expect(localPlayerRiotId({ gameName: "河道", tagLine: "JG" })).toBe("河道#JG");
    expect(localPlayerRiotId({ gameName: "河道", tagLine: "" })).toBe("河道");
  });
});
