import { afterEach, describe, expect, it, vi } from "vitest";
import type { NativeSdkApi } from "./native";

afterEach(() => {
  vi.unstubAllGlobals();
  vi.resetModules();
});

describe("原生消息的会话边界", () => {
  it("切换模式后丢弃还在前端队列中的消息", async () => {
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
    await vi.waitFor(() => expect(sends).toBe(1));
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
