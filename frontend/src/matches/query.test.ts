import { describe, expect, it } from "vitest";
import { matchHistoryQueryKey } from "./query";

const currentScope = {
  mode: "live" as const,
  platformId: "HN1",
  gameName: "Current Player",
  tagLine: "TAG",
  page: 0,
  pageSize: 10,
  hideUnfinishedMatches: false,
};

describe("matchHistoryQueryKey", () => {
  it("shares the current account page between dashboard, history and drawer", () => {
    const dashboard = matchHistoryQueryKey(currentScope);
    const matchesPage = matchHistoryQueryKey({ ...currentScope, summonerName: "" });
    const drawer = matchHistoryQueryKey({ ...currentScope, summonerName: "current player#tag" });

    expect(matchesPage).toEqual(dashboard);
    expect(drawer).toEqual(dashboard);
  });

  it("keeps other players and pages in separate cache entries", () => {
    const current = matchHistoryQueryKey(currentScope);
    const otherPlayer = matchHistoryQueryKey({ ...currentScope, summonerName: "Other#TAG" });
    const nextPage = matchHistoryQueryKey({ ...currentScope, page: 1 });

    expect(otherPlayer).not.toEqual(current);
    expect(nextPage).not.toEqual(current);
  });
});
