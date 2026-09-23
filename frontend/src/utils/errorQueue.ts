/**
 * 运行时错误提示的排队规则（纯函数，便于单测）。
 *
 * 以前只留一条 `error`，接连出错时后一条会直接盖掉前一条——用户只看得到最新的
 * 那句，前面到底出了什么事就查不到了。这里按「最新的排最前、关掉一条露出下一条」
 * 排队，并且：
 *
 * - 同一条错误**连着**报（每次轮询都失败之类）不重复入队，也不该把自己挤掉；
 * - 队列有上限，长时间运行不会堆成山。
 */
export const MAX_PENDING_ERRORS = 8;

export function pushError(queue: readonly string[], message: string): string[] {
  const text = message.trim();
  if (!text) return queue as string[];
  // 连着重复的忽略；历史里出现过的先摘掉再置顶，避免「A B A」变成两条 A。
  if (queue[0] === text) return queue as string[];
  return [text, ...queue.filter((item) => item !== text)].slice(0, MAX_PENDING_ERRORS);
}

/** 关掉当前这条，把下一条顶上来。 */
export function shiftError(queue: readonly string[]): string[] {
  return queue.slice(1);
}
