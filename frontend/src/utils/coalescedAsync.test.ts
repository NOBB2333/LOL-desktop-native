import { describe, expect, it } from "vitest";
import { createCoalescedAsyncRunner } from "./coalescedAsync";

describe("coalesced async runner", () => {
  it("keeps one request in flight and performs one catch-up run", async () => {
    const releases: Array<() => void> = [];
    let calls = 0;
    const runner = createCoalescedAsyncRunner(async () => {
      calls += 1;
      await new Promise<void>((resolve) => releases.push(resolve));
    });

    const first = runner.run();
    void runner.run();
    void runner.run();
    expect(calls).toBe(1);
    releases.shift()?.();
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(calls).toBe(2);
    releases.shift()?.();
    await first;
  });

  it("can run again after the task rejects", async () => {
    let calls = 0;
    const runner = createCoalescedAsyncRunner(async () => {
      calls += 1;
      if (calls === 1) throw new Error("temporary failure");
    });

    await expect(runner.run()).rejects.toThrow("temporary failure");
    await expect(runner.run()).resolves.toBeUndefined();
    expect(calls).toBe(2);
  });
});
