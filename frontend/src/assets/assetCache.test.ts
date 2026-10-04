import { beforeEach, describe, expect, it } from "vitest";
import { ASSET_MAX_INFLIGHT, cachedAsset, peekAsset, resetAssetCache } from "./assetCache";

/** 让所有微任务排空（队列是靠微任务一环扣一环推进的）。 */
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

beforeEach(() => {
  resetAssetCache();
});

describe("assetCache", () => {
  it("记住结果，第二次直接命中缓存", async () => {
    let calls = 0;
    const load = async () => {
      calls += 1;
      return "data:image/png;base64,AAAA";
    };
    await expect(cachedAsset("champion:1", load)).resolves.toBe("data:image/png;base64,AAAA");
    await expect(cachedAsset("champion:1", load)).resolves.toBe("data:image/png;base64,AAAA");
    expect(calls).toBe(1);
    expect(peekAsset("champion:1")).toBe("data:image/png;base64,AAAA");
  });

  it("同一个 key 的并发请求合并成一次", async () => {
    let calls = 0;
    let release: (value: string) => void = () => undefined;
    const load = () => {
      calls += 1;
      return new Promise<string>((resolve) => { release = resolve; });
    };
    const first = cachedAsset("champion:2", load);
    const second = cachedAsset("champion:2", load);
    // 同一个 key 返回的是**同一个 promise 对象**，所以天然只会发一次请求。
    expect(first).toBe(second);
    // ⚠️ 取图现在是「排到名额之后」才真正发出去（见 `MAX_INFLIGHT`），
    // 所以不能再指望「调用即发请求」，要等一个微任务。
    await tick();
    expect(calls).toBe(1);
    release("data:image/png;base64,BBBB");
    await expect(first).resolves.toBe("data:image/png;base64,BBBB");
    await expect(second).resolves.toBe("data:image/png;base64,BBBB");
    expect(calls).toBe(1);
  });

  it("同时在飞的请求压在上限内，超出的排队（保护交互式查询的名额）", async () => {
    let started = 0;
    const finish: (() => void)[] = [];
    const load = () => {
      started += 1;
      return new Promise<string>((resolve) => { finish.push(() => resolve("data:,x")); });
    };
    // 挂出「比上限多 2 个」的图标，这样一定能越过上限、又不必依赖上限的具体数值
    // （上限会随后端并发能力调整，见 `MAX_INFLIGHT` 的说明，用例不该钉死它）。
    const total = ASSET_MAX_INFLIGHT + 2;
    const pending = Array.from({ length: total }, (_, index) => cachedAsset(`k${index}`, load));
    await tick();
    // 只有上限那么多个真发出去了，其余在排队。
    expect(started).toBe(ASSET_MAX_INFLIGHT);
    // 放掉一个 → 队首补上来一个，**始终不超过上限**。
    finish.shift()?.();
    await tick();
    expect(started).toBe(ASSET_MAX_INFLIGHT + 1);
    // 把剩下的全部放掉，队列应能彻底排空（不能有人被永久卡在队里）。
    while (finish.length > 0) {
      finish.shift()?.();
      await tick();
    }
    await Promise.all(pending);
    expect(started).toBe(total);
  });

  it("空结果与失败都不进缓存，下次还会再试", async () => {
    let calls = 0;
    const empty = async () => {
      calls += 1;
      return "";
    };
    await cachedAsset("champion:3", empty);
    await cachedAsset("champion:3", empty);
    expect(calls).toBe(2);
    expect(peekAsset("champion:3")).toBe("");

    const boom = async () => {
      calls += 1;
      throw new Error("桥调用失败");
    };
    await expect(cachedAsset("champion:4", boom)).rejects.toThrow("桥调用失败");
    await expect(cachedAsset("champion:4", boom)).rejects.toThrow("桥调用失败");
    expect(peekAsset("champion:4")).toBe("");
  });
});
