import { beforeEach, describe, expect, it } from "vitest";
import { cachedAsset, peekAsset, resetAssetCache } from "./assetCache";

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
    expect(calls).toBe(1);
    release("data:image/png;base64,BBBB");
    await expect(first).resolves.toBe("data:image/png;base64,BBBB");
    await expect(second).resolves.toBe("data:image/png;base64,BBBB");
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
