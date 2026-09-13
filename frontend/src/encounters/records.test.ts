import { describe, expect, it } from "vitest";
import { fixtureEncounters, fixtureLobby } from "../fixtures/data";
import { encounterGames, encounterKda, encounterLabel } from "./records";

describe("共同对局", () => {
  const record = fixtureEncounters.find((item) => item.puuid === fixtureLobby.ally[2].puuid)!;
  it("合并去重并排除当前局且按实际时间排序", () => {
    const records = [
      { ...record, gameId: 1, encounteredAt: "2023-01-01T00:00:00Z" },
      { ...record, gameId: 2, encounteredAt: "2026-09-08T09:00:00+08:00" },
      { ...record, gameId: 3, encounteredAt: "2026-09-08T02:00:00Z" },
      { ...record, gameId: 4 },
      { ...record, gameId: 5, liveSnapshot: true },
    ];
    expect(encounterGames([...records, ...records], record.puuid, 4).map((game) => game.gameId)).toEqual([3, 2, 1]);
  });
  it("保留完整参与者且最多四十局", () => {
    const records = Array.from({ length: 45 }, (_, index) => [
      { ...record, gameId: index + 1 }, { ...record, gameId: index + 1, puuid: "another-player" },
    ]).flat();
    const games = encounterGames(records, record.puuid);
    expect(games).toHaveLength(40);
    expect(games.every((game) => game.records.length === 2)).toBe(true);
  });
  it("仅双方最新战绩都是共同对局时标记上局关系", () => {
    const games = encounterGames([record], record.puuid);
    const player = structuredClone(fixtureLobby.ally[2]);
    const self = structuredClone(fixtureLobby.ally[0]);
    player.recentMatches = [{ ...player.recentMatches[0], gameId: record.gameId }];
    self.recentMatches = [{ ...self.recentMatches[0], gameId: record.gameId }];
    expect(encounterLabel(games, player, self)).toBe(record.side === "ally" ? "上局队友" : "上局对手");
    self.recentMatches[0].gameId += 1;
    expect(encounterLabel(games, player, self)).toBe("遇到过 1 次");
  });
  it("不将缺失战绩算成零死亡或失败", () => {
    expect(encounterKda(undefined, 0, 2)).toBe("--");
    const games = encounterGames([{ ...record, kills: undefined, win: undefined }, record], record.puuid);
    expect(games[0].target.win).toBe(record.win);
  });
});
