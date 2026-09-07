import { describe, expect, it } from "vitest";
import { createInvocationScheduler } from "./native";

describe("native invocation scheduler", () => {
  it("does not exceed the configured bridge concurrency", async () => {
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

  it("continues queued work after a rejected invocation", async () => {
    const schedule = createInvocationScheduler(1);
    const first = schedule(async () => { throw new Error("request failed"); });
    const second = schedule(async () => "completed");

    await expect(first).rejects.toThrow("request failed");
    await expect(second).resolves.toBe("completed");
  });
});
