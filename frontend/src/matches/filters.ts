import type { MatchSummary } from "../types/domain";

const hiddenMarkers = ["训练", "自定义", "practice", "tutorial", "custom"];

export function isHiddenMatch(match: Pick<MatchSummary, "durationMinutes" | "result" | "queueName">) {
  const queue = match.queueName.trim().toLowerCase();
  return match.durationMinutes === 0
    || match.result === "未完成"
    || match.result === "待定"
    || hiddenMarkers.some((marker) => queue.includes(marker));
}

export function isRankedMatch(match: { queueId?: number; queueName: string }) {
  if (match.queueId !== undefined) return match.queueId === 420 || match.queueId === 440;
  // 兼容旧缓存中的摘要，新响应统一使用队列编号。
  return ["单双排", "灵活组排", "灵活排位"].includes(match.queueName.trim());
}

export function visibleMatches(matches: MatchSummary[], hideUnfinished: boolean, rankedOnly = false) {
  return matches.filter((match) => (!hideUnfinished || !isHiddenMatch(match)) && (!rankedOnly || isRankedMatch(match)));
}
