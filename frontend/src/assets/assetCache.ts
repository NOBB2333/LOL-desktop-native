/**
 * 图标字节的会话级缓存（前端这一侧）。
 *
 * **为什么需要**（2026-09-26 实测）：每个 `AssetIcon` 都是一次独立的桥调用，而后端
 * 每次都要**新开一条 WinHTTP 连接**去打 LCU —— 一个英雄头像实测平均 **39.7ms**，
 * 同样 30 个请求复用一条连接只要 **4.4ms** 一个。一局十人的对局页要画约 **90 个**
 * 图标，串起来就是 **3.5 秒**。再叠上两个放大因素：
 *
 * - 玩家身份落定（占位 puuid → 真 puuid）会让 `playerCardKey` 变化 → 整张卡片重挂
 *   → 卡片里每个图标都重新拉一遍；
 * - 加载期间前端每 400ms 轮询一次，版本一变十张卡全量重渲染。
 *
 * 结果就是用户看到的「数据 0.8 秒就到了，图标却一个一个慢慢冒出来」。
 *
 * 这里做三件事：**按 key 记住结果**、**把同一 key 的并发请求合并成一次**、
 * 以及**限制同时在飞的请求数**（见下面的 `MAX_INFLIGHT`）。空结果不缓存——
 * 那表示「这一次没取到」（客户端还没起来），缓存住会把空白焊死。
 */

const resolved = new Map<string, string>();
const inflight = new Map<string, Promise<string>>();

/**
 * 同时在飞的取图请求上限。
 *
 * # 为什么必须有这个上限（2026-10-03 实测）
 *
 * 后端把 `lol.get_asset` 和 `lol.get_champion_abilities` 放在**同一条 lane**
 * （`.query` → `lcu.Client.localBudget()` 的 `else` 分支 → `.lcu` 预算，
 * `http_windows.zig` 里 `budget_limits = {6, 2, 1, 1, 2}` 的第一项 = **6 个名额**）。
 *
 * 而英雄页默认把 **245 行**全渲染出来，每行一个 `AssetIcon`，于是首屏一次性打出去
 * **245 个** `lol.get_asset`。`acquireBudget()` 是「抢到名额才走」的**自旋 + 5ms sleep**，
 * 245 个请求会把 6 个名额长期占满 —— 用户这时点开某个英雄，那条
 * `get_champion_abilities` 也只能在这一堆取图后面抢名额。
 * 这正是用户 2026-10-03 报的「**第一个英雄要等半分钟，第二个却很快**」
 * （第二次时图标已经进缓存，没有请求再跟他抢）。
 *
 * ⚠️ 一开始试的是「用 `IntersectionObserver` 只给接近视口的图标取图」，
 * **已回退**：在这套 WebView 里回调用没有按预期触发，`visible` 一直是 `false`，
 * 结果**所有头像都不再加载**（用户报「头像加载不出来了」）。限流不依赖任何
 * 可见性回调，行为上是「一定会加载，只是分批」，符合直觉。
 *
 * # 2026-10-04 更新：根因已从「限流」升级为「后端并行」
 *
 * 上面那段「同一条 lane、6 个名额」描述的是**当时**的后端。现在后端已经：
 *   - 给 `lol.get_asset` 拆出独立的 `asset` lane 与独立配额（8 个名额）；
 *   - 每条 lane 起**多个** worker（`asset` / `query` 各 4 个），不再串行消费。
 * 也就是说前端这里再压到 4 反而成了瓶颈：后端开得出 4 个 worker、8 个名额，
 * 前端却只放 4 个请求出去。所以上限提到 **16**：
 *   - 足够喂满后端的 4 个 worker × 8 个名额（还留了余量，网络抖动时不至于断供）；
 *   - 仍远低于 bridge 每 lane 64 条的排队上限，不会把队列打爆；
 *   - 依然给交互式查询留下充分空间——它走的是**另一条 lane**，根本不在这个池子里排队。
 *
 * 一句话：这个数字现在的作用是「别一次性把 245 个请求全灌给 JS↔原生桥」，
 * 而不是「和交互式查询抢名额」——后者已经由后端的 lane 拆分解决了。
 */
const MAX_INFLIGHT = 16;

/** 导出只为让用例能钉住这个上限（改小/改大时测试会跟着提醒）。 */
export const ASSET_MAX_INFLIGHT = MAX_INFLIGHT;

/** 当前在飞的数量。 */
let active = 0;
/** 排队等名额的任务，FIFO —— 挂载顺序就是文档顺序，所以先出现的图标先取。 */
const waiting: (() => void)[] = [];

/** 名额空出来就立刻补给队首。 */
function pump(): void {
  while (active < MAX_INFLIGHT && waiting.length > 0) {
    const next = waiting.shift();
    if (next) next();
  }
}

/** 取一个名额；拿得到就立刻返回，拿不到就排队。 */
function acquire(): Promise<void> {
  if (active < MAX_INFLIGHT) {
    active += 1;
    return Promise.resolve();
  }
  return new Promise<void>((resolve) => {
    waiting.push(() => {
      active += 1;
      resolve();
    });
  });
}

/** 还回名额。**必须和 `acquire` 一一配对**，漏掉一次就永久少一个名额。 */
function release(): void {
  active -= 1;
  pump();
}

/** 同步取缓存值。命中时组件首帧就能直接用上，重挂不会再闪一下占位块。 */
export function peekAsset(key: string): string {
  return resolved.get(key) ?? "";
}

/** 拿 key 对应的图标 URL；同一 key 只会真正请求一次。 */
export function cachedAsset(key: string, load: () => Promise<string>): Promise<string> {
  const hit = resolved.get(key);
  if (hit !== undefined) return Promise.resolve(hit);
  const flying = inflight.get(key);
  if (flying) return flying;
  // 先排到名额再真正发请求：`acquire()` 之前不动 `load`，
  // 这样「谁在飞」始终不超过 `MAX_INFLIGHT` 个。
  const promise = acquire()
    .then(() => load())
    .then(
      (url) => {
        release();
        inflight.delete(key);
        if (url) resolved.set(key, url);
        return url;
      },
      (error: unknown) => {
        release();
        inflight.delete(key);
        throw error;
      },
    );
  inflight.set(key, promise);
  return promise;
}

/** 测试用：清空缓存，避免用例之间互相污染。 */
export function resetAssetCache(): void {
  resolved.clear();
  inflight.clear();
}
