import { describe, expect, it, vi } from "vitest";
import { createShortcutSendQueue } from "./shortcutSendQueue";

describe("消息发送队列", () => {
  it("重复快捷键共用同次发送，其他消息在完成后继续", async () => {
    const send = createShortcutSendQueue();
    let finish!: () => void;
    const firstTask = vi.fn(() => new Promise<void>((resolve) => { finish = resolve; }));
    const secondTask = vi.fn(async () => "第二批");
    const first = send("我方", firstTask);
    expect(send("我方", firstTask)).toBe(first);
    const second = send("敌方", secondTask);
    await Promise.resolve();
    await Promise.resolve();
    expect(firstTask).toHaveBeenCalledTimes(1);
    expect(secondTask).not.toHaveBeenCalled();
    finish();
    await first;
    await expect(second).resolves.toBe("第二批");
  });
  it("发送失败后仍可处理下一批消息", async () => {
    const send = createShortcutSendQueue();
    const first = send("失败消息", async () => { throw new Error("已中断"); });
    const second = send("后续消息", async () => "完成");
    await expect(first).rejects.toThrow("已中断");
    await expect(second).resolves.toBe("完成");
  });
});
