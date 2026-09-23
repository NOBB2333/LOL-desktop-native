import { describe, expect, it } from "vitest";
import { MAX_PENDING_ERRORS, pushError, shiftError } from "./errorQueue";

describe("runtime error queue", () => {
  it("keeps earlier errors instead of letting the newest clobber them", () => {
    let queue: string[] = [];
    queue = pushError(queue, "连接失败");
    queue = pushError(queue, "配置保存失败");
    // 最新的排在最前，但上一句仍然留着，关掉一条就能看到。
    expect(queue).toEqual(["配置保存失败", "连接失败"]);
    expect(shiftError(queue)).toEqual(["连接失败"]);
  });

  it("ignores a repeated consecutive error but does not drop the queue", () => {
    let queue = pushError(pushError([], "轮询失败"), "轮询失败");
    expect(queue).toEqual(["轮询失败"]);
    queue = pushError(queue, "另一条");
    queue = pushError(queue, "轮询失败");
    // 「A→B→A」只该留两条 A 里的一条，且不能把 B 顶掉。
    expect(queue).toEqual(["轮询失败", "另一条"]);
  });

  it("drops blank messages and caps the queue", () => {
    expect(pushError([], "   ")).toEqual([]);
    let queue: string[] = [];
    for (let index = 0; index < MAX_PENDING_ERRORS + 4; index += 1) queue = pushError(queue, `错误 ${index}`);
    expect(queue).toHaveLength(MAX_PENDING_ERRORS);
    expect(queue[0]).toBe(`错误 ${MAX_PENDING_ERRORS + 3}`);
  });

  it("shifts an empty queue without throwing", () => {
    expect(shiftError([])).toEqual([]);
  });
});
