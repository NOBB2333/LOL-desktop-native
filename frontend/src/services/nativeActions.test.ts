import { afterEach, describe, expect, it, vi } from "vitest";
import type { NativeSdkApi } from "./native";

afterEach(() => {
  vi.unstubAllGlobals();
  vi.resetModules();
});

describe("原生消息的会话边界", () => {
  // 整仓并行跑时 CPU 争用严重（曾观测到 environment 阶段 350s），
  // vitest 默认 5s 的用例级超时会先于 waitFor 触发；这里把上限一并放宽。
  it("切换模式后丢弃还在前端队列中的消息", { timeout: 30_000 }, async () => {
    let finishSend: (value: string[]) => void = () => undefined;
    let sends = 0;
    const invoke = vi.fn(async (name: string, payload?: unknown) => {
      if (name === "lol.set_data_mode") return (payload as { mode: string }).mode;
      if (name === "lol.send_shortcut") {
        sends += 1;
        return new Promise<string[]>((resolve) => { finishSend = resolve; });
      }
      throw new Error("验证中出现未预期的原生命令");
    });
    vi.stubGlobal("window", { zero: { invoke } as unknown as NativeSdkApi });
    vi.stubGlobal("localStorage", { getItem: () => null });
    const { backend } = await import("./backend");
    await backend.setMode("live");
    const first = backend.sendShortcut("enemy");
    // 排队是异步的；整仓并行跑测试时 CPU 争用明显，默认 1s 的 waitFor 会偶发超时。
    await vi.waitFor(() => expect(sends).toBe(1), { timeout: 10_000, interval: 20 });
    const second = backend.sendShortcut("ally");
    const rejected = expect(second).rejects.toThrow("会话已变化");
    await backend.setMode("fixture");
    finishSend(["模拟发送结果"]);
    await first;
    await rejected;
    expect(sends).toBe(1);
    await expect(backend.setMode("replay")).rejects.toThrow("回看功能尚未开放");
  });
});
