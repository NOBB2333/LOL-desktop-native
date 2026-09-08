import type { DataMode } from "../types/domain";

export const MATCH_HISTORY_QUERY_ROOT = "match-history";

interface MatchHistoryQueryScope {
  mode: DataMode;
  platformId?: string | null;
  gameName?: string | null;
  tagLine?: string | null;
  summonerName?: string | null;
  page: number;
  pageSize: number;
  hideUnfinishedMatches: boolean;
  rankedOnly?: boolean;
}

function riotId(gameName?: string | null, tagLine?: string | null) {
  const name = gameName?.trim() ?? "";
  const tag = tagLine?.trim() ?? "";
  return tag ? `${name}#${tag}` : name;
}

export function matchHistoryQueryKey(scope: MatchHistoryQueryScope) {
  const subject = scope.summonerName?.trim() || riotId(scope.gameName, scope.tagLine) || "current";
  return [
    MATCH_HISTORY_QUERY_ROOT,
    scope.mode,
    scope.platformId?.trim().toLocaleLowerCase() ?? "",
    subject.toLocaleLowerCase(),
    scope.page,
    scope.pageSize,
    scope.hideUnfinishedMatches,
    scope.rankedOnly ?? false,
  ] as const;
}
