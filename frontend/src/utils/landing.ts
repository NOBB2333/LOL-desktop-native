import type { ConnectionStatus, DataMode } from "../types/domain";

/**
 * 首次落地该去哪一页。
 *
 * 规则（用户口径）：**客户端已经在跑 → 留在首页**；**客户端没跑 → 去「客户端」页**
 * 让人先启动游戏。只有这两条，别的不许自作主张。
 *
 * 返回 `null` = 不跳。返回 `"/client"` = 该切到客户端页。
 *
 * 三个例外：
 * - 还没初始化完（状态是空的）→ 不判断；
 * - `status === "connecting"` → 连接探测还没落地，**必须等一下**。启动瞬间读到的
 *   往往是 bootstrap 里的旧快照，拿旧快照判断就会出现「客户端明明开着却被推到
 *   客户端页 / 明明没开却把人留在首页」这种反向错误；
 * - 不是首页、或用户切到了演示模式 → 不跳（用户主动翻页面时别把他弹走）。
 */
export function landingRedirect(input: { initialized: boolean; path: string; mode: DataMode; status: ConnectionStatus }): string | null {
  if (!input.initialized) return null;
  if (input.status === "connecting") return null;
  if (input.path !== "/") return null;
  if (input.mode !== "live") return null;
  return input.status === "connected" ? null : "/client";
}
