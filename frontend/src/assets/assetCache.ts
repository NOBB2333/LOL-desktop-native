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
 * 这里做两件事：**按 key 记住结果**，以及**把同一 key 的并发请求合并成一次**。
 * 空结果不缓存——那表示「这一次没取到」（客户端还没起来），缓存住会把空白焊死。
 */

const resolved = new Map<string, string>();
const inflight = new Map<string, Promise<string>>();

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
  const promise = load().then(
    (url) => {
      inflight.delete(key);
      if (url) resolved.set(key, url);
      return url;
    },
    (error: unknown) => {
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
