import { describe, expect, it } from "vitest";
import { createCommandScheduler, createInvocationScheduler } from "./native";

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
