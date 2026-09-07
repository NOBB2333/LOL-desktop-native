import type { MatchSummary } from "../types/domain";

const hiddenMarkers = ["训练", "自定义", "practice", "tutorial", "custom"];

export function isHiddenMatch(match: Pick<MatchSummary, "durationMinutes" | "result" | "queueName">) {
  const queue = match.queueName.trim().toLowerCase();
  return match.durationMinutes === 0
    || match.result === "未完成"
    || match.result === "待定"
    || hiddenMarkers.some((marker) => queue.includes(marker));
}

export function visibleMatches(matches: MatchSummary[], hideUnfinished: boolean) {
  return hideUnfinished ? matches.filter((match) => !isHiddenMatch(match)) : matches;
}
