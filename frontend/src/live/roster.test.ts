import { describe, expect, it } from "vitest";
import { fixtureLobby } from "../fixtures/data";
import type { LiveLobby, PlayerProfile } from "../types/domain";
import { enrichedRosterCoversOverlay, mergeRosterSnapshot, playerCardKey, playerIdentity } from "./roster";

it("五名敌方从空身份乱序补全后保留各自战绩和稳定卡片键", () => {
  const fast = structuredClone(fixtureLobby);
  fast.id = "789";
  fast.phase = "InProgress";
  fast.enemy = fast.enemy.map((player, index) => ({ ...player, puuid: "00000000-0000-0000-0000-000000000000", rosterKey: `enemy-slot-${index}`, gameName: `敌方${index}`, recentMatches: [], dataComplete: false }));
  const base = structuredClone(fast);
  for (const index of [3, 1, 4, 0, 2]) {
    base.enemy[index] = { ...base.enemy[index], puuid: `已解析-${index}`, recentMatches: [{ ...fixtureLobby.enemy[index].recentMatches[0], gameId: 1000 + index }], dataComplete: true };
    const merged = mergeRosterSnapshot(base, fast);
    expect(merged.enemy.map((player) => player.recentMatches.map((match) => match.gameId))).toEqual(base.enemy.map((player) => player.recentMatches.map((match) => match.gameId)));
    expect(merged.enemy.map(playerCardKey)).toEqual(fast.enemy.map(playerCardKey));
    expect(merged.teams?.find((team) => team.side === "enemy")?.players).toEqual(merged.enemy);
  }
  expect(playerIdentity({ ...fast.enemy[0], gameName: "未知玩家" })).toBe("");
  expect(new Set(fast.enemy.map((player, index) => playerCardKey({ ...player, rosterKey: undefined, gameName: "未知玩家" }, index))).size).toBe(5);
});

function lobby(id: string, player: Partial<PlayerProfile>): LiveLobby {
  const value = structuredClone(fixtureLobby);
  value.id = id;
  value.ally = [{ ...value.ally[0], ...player }];
  value.enemy = [];
  value.teams = [];
  return value;
}

describe("live roster merging", () => {
  it("never carries player data across numeric game ids", () => {
    const previous = lobby("1001", { puuid: "old", gameName: "旧账号", score: { ...fixtureLobby.ally[0].score, total: 91 } });
    const next = lobby("1002", { puuid: "new", gameName: "新账号", score: { ...fixtureLobby.ally[0].score, total: 7 } });
    const merged = mergeRosterSnapshot(previous, next);
    expect(merged.ally).toHaveLength(1);
    expect(merged.ally[0].gameName).toBe("新账号");
    expect(merged.ally[0].score.total).toBe(7);
  });

  it("does not erase a selected champion on a transient zero snapshot", () => {
    const base = lobby("1001", { puuid: "same", championId: 103, championName: "九尾妖狐", assignedPosition: "MIDDLE" });
    const fast = lobby("1001", { puuid: "same", championId: 0, championName: "等待选择", assignedPosition: "NONE" });
    const merged = mergeRosterSnapshot(base, fast);
    expect(merged.ally[0].championId).toBe(103);
    expect(merged.ally[0].championName).toBe("九尾妖狐");
    expect(merged.ally[0].assignedPosition).toBe("MIDDLE");
  });

  it("keeps a resolved identity when a same-seat refresh only has a numeric id", () => {
    const base = lobby("1001", { puuid: "resolved-puuid", gameName: "已解析玩家", wins: 12 });
    const fast = lobby("1001", { puuid: "123456", gameName: "未知玩家", wins: 0, championId: 112, championName: "奥术先驱" });
    const merged = mergeRosterSnapshot(base, fast);
    expect(merged.ally[0].puuid).toBe("resolved-puuid");
    expect(merged.ally[0].gameName).toBe("已解析玩家");
    expect(merged.ally[0].wins).toBe(12);
    expect(merged.ally[0].championId).toBe(112);
  });

  it("does not inherit statistics by array position after an account change", () => {
    const previous = lobby("1001", { puuid: "old", gameName: "旧账号", wins: 99 });
    const next = lobby("1001", { puuid: "new", gameName: "新账号", wins: 3 });
    const merged = mergeRosterSnapshot(previous, next);
    expect(merged.ally).toHaveLength(1);
    expect(merged.ally[0].gameName).toBe("新账号");
    expect(merged.ally[0].wins).toBe(3);
  });

  it("keeps a larger fast roster until the enriched refresh catches up", () => {
    const overlay = structuredClone(fixtureLobby);
    const partial = structuredClone(fixtureLobby);
    partial.ally = partial.ally.slice(0, 1);
    partial.enemy = partial.enemy.slice(0, 1);
    expect(enrichedRosterCoversOverlay(partial, overlay)).toBe(false);
    expect(enrichedRosterCoversOverlay(structuredClone(overlay), overlay)).toBe(true);
  });

  it("keeps the in-game order when end-of-game enrichment has the same players in pick order", () => {
    const overlay = structuredClone(fixtureLobby);
    overlay.id = "1001";
    overlay.phase = "EndOfGame";
    overlay.ally = [overlay.ally[2], overlay.ally[0], overlay.ally[1], overlay.ally[4], overlay.ally[3]];
    overlay.enemy = [overlay.enemy[1], overlay.enemy[3], overlay.enemy[0], overlay.enemy[4], overlay.enemy[2]];
    const pickOrder = structuredClone(fixtureLobby);
    pickOrder.id = "1001";
    pickOrder.phase = "EndOfGame";

    expect(enrichedRosterCoversOverlay(pickOrder, overlay)).toBe(false);
    const merged = mergeRosterSnapshot(pickOrder, overlay);
    expect(merged.ally.map((player) => player.puuid)).toEqual(overlay.ally.map((player) => player.puuid));
    expect(merged.enemy.map((player) => player.puuid)).toEqual(overlay.enemy.map((player) => player.puuid));
  });

  it("keeps the fast overlay until enrichment contains the same champion and name", () => {
    const overlay = lobby("1001", { puuid: "same", gameName: "队友", championId: 112, championName: "奥术先驱" });
    const staleChampion = lobby("1001", { puuid: "same", gameName: "队友", championId: 0, championName: "等待选择" });
    const staleName = lobby("1001", { puuid: "same", gameName: "未知玩家", championId: 112, championName: "奥术先驱" });
    expect(enrichedRosterCoversOverlay(staleChampion, overlay)).toBe(false);
    expect(enrichedRosterCoversOverlay(staleName, overlay)).toBe(false);
    expect(enrichedRosterCoversOverlay(structuredClone(overlay), overlay)).toBe(true);
  });

  it("does not discard a newer phase overlay with an older enriched response", () => {
    const overlay = lobby("1001", { puuid: "same", championId: 112, championName: "奥术先驱" });
    overlay.phase = "InProgress";
    const enriched = structuredClone(overlay);
    enriched.phase = "ChampSelect";
    expect(enrichedRosterCoversOverlay(enriched, overlay)).toBe(false);
  });

  it("keeps confirmed premade evidence when an end-of-game refresh reports false", () => {
    const base = lobby("1001", { puuid: "same", gameName: "甲", isPremade: true, premadeWith: ["乙"] });
    const endOfGame = lobby("1001", { puuid: "same", gameName: "甲", isPremade: false, premadeWith: [] });
    endOfGame.phase = "EndOfGame";
    base.phase = "InProgress";
    const merged = mergeRosterSnapshot(base, endOfGame);
    expect(merged.ally[0].isPremade).toBe(true);
    expect(merged.ally[0].premadeWith).toEqual(["乙"]);
  });

  it("does not clear a premade overlay until enrichment contains the same evidence", () => {
    const overlay = lobby("1001", { puuid: "same", gameName: "甲", isPremade: true, premadeWith: ["乙"] });
    overlay.phase = "EndOfGame";
    const missing = lobby("1001", { puuid: "same", gameName: "甲", isPremade: false, premadeWith: [] });
    missing.phase = "EndOfGame";
    const complete = lobby("1001", { puuid: "same", gameName: "甲", isPremade: true, premadeWith: ["乙"] });
    complete.phase = "EndOfGame";
    expect(enrichedRosterCoversOverlay(missing, overlay)).toBe(false);
    expect(enrichedRosterCoversOverlay(complete, overlay)).toBe(true);
  });

  it("never carries premade evidence into another numeric game", () => {
    const previous = lobby("1001", { puuid: "same", gameName: "甲", isPremade: true, premadeWith: ["乙"] });
    const next = lobby("1002", { puuid: "same", gameName: "甲", isPremade: false, premadeWith: [] });
    const merged = mergeRosterSnapshot(previous, next);
    expect(merged.ally[0].isPremade).toBe(false);
    expect(merged.ally[0].premadeWith).toEqual([]);
  });

  it("carries rank and score into another numeric game when the same player stays", () => {
    const previous = lobby("1001", { puuid: "same", gameName: "甲", rankTier: "GOLD", score: { ...fixtureLobby.ally[0].score, total: 91 } });
    const next = lobby("1002", { puuid: "same", gameName: "甲", rankTier: "UNRANKED", score: { ...fixtureLobby.ally[0].score, total: 0 }, championId: 0, championName: "等待选择" });
    next.phase = "ChampSelect";
    const merged = mergeRosterSnapshot(previous, next);
    expect(merged.ally).toHaveLength(1);
    expect(merged.ally[0].rankTier).toBe("GOLD");
    expect(merged.ally[0].score.total).toBe(91);
    // 拓扑字段同样只增不减：新快照还没锁定英雄时保留上一次的已选英雄。
    expect(merged.ally[0].championId).toBe(fixtureLobby.ally[0].championId);
  });

  it("takes the locked champion from the newest overlay across a context change", () => {
    const previous = lobby("1001", { puuid: "same", gameName: "甲", championId: 266, championName: "旧英雄", rankTier: "GOLD" });
    const next = lobby("1002", { puuid: "same", gameName: "甲", championId: 112, championName: "新英雄" });
    next.phase = "ChampSelect";
    const merged = mergeRosterSnapshot(previous, next);
    expect(merged.ally[0].championId).toBe(112);
    expect(merged.ally[0].championName).toBe("新英雄");
    expect(merged.ally[0].rankTier).toBe("GOLD");
  });
});
