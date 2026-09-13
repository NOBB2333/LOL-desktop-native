import { expect, it } from "vitest";
import { createFixtureLobby, fixtureConfig, fixtureMatches } from "../fixtures/data";
import { migrateAppConfig } from "../utils/config";
import { isRankedMatch, visibleMatches } from "./filters";
import { matchHistoryQueryKey } from "./query";

it("排位开关按队列编号筛选并在关闭后恢复全部记录", () => {
  const records = [420, 450, 440, 400, 1700].map((queueId) => ({ ...fixtureMatches[0], queueId }));
  expect(visibleMatches(records, false, true).map((match) => match.queueId)).toEqual([420, 440]);
  expect(visibleMatches(records, false, false)).toHaveLength(5);
  expect(isRankedMatch({ queueId: 450, queueName: "单双排" })).toBe(false);
  expect(isRankedMatch({ queueName: "灵活组排" })).toBe(true);
});

it("旧设置默认保留全部模式且两种口径使用不同查询缓存", () => {
  const config = structuredClone(fixtureConfig);
  delete (config.providers as Partial<typeof config.providers>).rankedOnly;
  migrateAppConfig(config);
  expect(config.providers.rankedOnly).toBe(false);
  config.providers.rankedOnly = true;
  migrateAppConfig(config);
  expect(config.providers.rankedOnly).toBe(true);
  const scope = { mode: "live" as const, page: 0, pageSize: 10, hideUnfinishedMatches: false };
  expect(matchHistoryQueryKey({ ...scope, rankedOnly: true })).not.toEqual(matchHistoryQueryKey({ ...scope, rankedOnly: false }));
});

it("演示卡片和打野统计使用同一排位样本", () => {
  const ranked = createFixtureLobby(true);
  const all = createFixtureLobby(false);
  for (const player of [...ranked.ally, ...ranked.enemy]) {
    expect(player.recentMatches.every(isRankedMatch)).toBe(true);
    expect(player.recentMatches).toHaveLength(9);
    if (player.junglePreference) expect(player.junglePreference.sampleSize).toBe(9);
  }
  expect(all.ally[0].recentMatches).toHaveLength(10);
});
