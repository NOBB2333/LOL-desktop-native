import { afterEach, describe, expect, it, vi } from "vitest";
import { createCommandScheduler, createInvocationScheduler, openExternalUrl } from "./native";

describe("原生调用调度", () => {
  it("不超过配置的并发上限", async () => {
    const schedule = createInvocationScheduler(4);
    const requestCount = 128;
    const releases: Array<() => void> = [];
    let active = 0;
    let maximumActive = 0;

    const calls = Array.from({ length: requestCount }, (_, index) => schedule(async () => {
      active += 1;
      maximumActive = Math.max(maximumActive, active);
      await new Promise<void>((resolve) => releases.push(resolve));
      active -= 1;
      return index;
    }));

    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(active).toBe(4);
    expect(releases).toHaveLength(4);

    while (releases.length > 0) {
      releases.shift()?.();
      await new Promise((resolve) => setTimeout(resolve, 0));
    }

    await expect(Promise.all(calls)).resolves.toEqual(Array.from({ length: requestCount }, (_, index) => index));
    expect(maximumActive).toBe(4);
  });

  it("请求失败后继续处理队列", async () => {
    const schedule = createInvocationScheduler(1);
    const first = schedule(async () => { throw new Error("请求失败"); });
    const second = schedule(async () => "已完成");

    await expect(first).rejects.toThrow("请求失败");
    await expect(second).resolves.toBe("已完成");
  });

  it("战绩通道占满时状态、阵容和发送仍可完成", async () => {
    const schedule = createCommandScheduler();
    const releases: Array<() => void> = [];
    const slow = Array.from({ length: 2 }, () => schedule("lol.get_match_history", () => new Promise<void>((resolve) => releases.push(resolve))));
    await Promise.resolve();
    expect(releases).toHaveLength(2);
    const completed = await Promise.all([
      schedule("lol.get_live_lobby", async () => "状态"),
      schedule("lol.get_live_roster", async () => "阵容"),
      schedule("lol.send_shortcut", async () => "发送"),
    ]);
    expect(completed).toEqual(["状态", "阵容", "发送"]);
    releases.forEach((release) => release());
    await Promise.all(slow);
  });
});

describe("外链走系统浏览器", () => {
  const originalZero = window.zero;
  const originalOpen = window.open;

  afterEach(() => {
    window.zero = originalZero;
    window.open = originalOpen;
  });

  it("有宿主桥时优先用宿主打开，不动 WebView", async () => {
    const opened: string[] = [];
    // 宿主侧受 app.json 的 external_links 白名单管控，这里只验证我们确实把 URL 递了过去。
    window.zero = { invoke: async () => undefined, on: () => () => undefined, off: () => undefined, credentials: { get: async () => null, set: async () => true, delete: async () => true }, os: { openUrl: async (url: string) => { opened.push(url); return true; } } } as never;
    const webviewOpen = vi.fn();
    window.open = webviewOpen as never;

    await expect(openExternalUrl("https://github.com/NOBB2333/LOL-desktop-native")).resolves.toBe(true);
    expect(opened).toEqual(["https://github.com/NOBB2333/LOL-desktop-native"]);
    expect(webviewOpen).not.toHaveBeenCalled();
  });

  it("宿主拒绝（白名单没覆盖）时返回 false 而不是抛错", async () => {
    window.zero = { invoke: async () => undefined, on: () => () => undefined, off: () => undefined, credentials: { get: async () => null, set: async () => true, delete: async () => true }, os: { openUrl: async () => { throw new Error("NavigationDenied"); } } } as never;

    await expect(openExternalUrl("https://evil.example.com/")).resolves.toBe(false);
  });

  it("没有宿主桥（浏览器预览）时退回新标签页", async () => {
    window.zero = undefined;
    const webviewOpen = vi.fn();
    window.open = webviewOpen as never;

    await expect(openExternalUrl("https://github.com/NOBB2333/LOL-desktop-native")).resolves.toBe(true);
    expect(webviewOpen).toHaveBeenCalledWith("https://github.com/NOBB2333/LOL-desktop-native", "_blank", "noopener,noreferrer");
  });

  it("非 http(s) 协议直接不放行", async () => {
    const opened: string[] = [];
    window.zero = { invoke: async () => undefined, on: () => () => undefined, off: () => undefined, credentials: { get: async () => null, set: async () => true, delete: async () => true }, os: { openUrl: async (url: string) => { opened.push(url); return true; } } } as never;

    await expect(openExternalUrl("mailto:hi@example.com")).resolves.toBe(false);
    await expect(openExternalUrl("file:///C:/Windows")).resolves.toBe(false);
    expect(opened).toEqual([]);
  });
});
