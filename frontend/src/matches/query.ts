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

/**
 * 单局完整详情（十人 + BP）的缓存键。
 *
 * 与列表分开：列表键按「谁的战绩 + 第几页」区分，详情键按「哪一局 + 以谁的视角」，
 * 这样同一局换个视角看不会命中同一份缓存。
 */
export function matchDetailQueryKey(scope: {
  mode: DataMode;
  platformId?: string | null;
  gameId: number;
  subjectPuuid: string;
}) {
  return [
    `${MATCH_HISTORY_QUERY_ROOT}-detail`,
    scope.mode,
    scope.platformId?.trim().toLocaleLowerCase() ?? "",
    scope.gameId,
    scope.subjectPuuid.trim().toLocaleLowerCase(),
  ] as const;
}
