import { describe, expect, it } from "vitest";
import { queueLabel } from "./queue";

describe("queueLabel", () => {
  it("maps Riot's KIWI rotating ARAM mode", () => {
    expect(queueLabel(0, "KIWI")).toBe("海克斯大乱斗");
    expect(queueLabel(9999, "KIWI")).toBe("海克斯大乱斗");
    expect(queueLabel(450, "KIWI")).toBe("海克斯大乱斗");
  });
  it("keeps queue 440 identified as flex ranked despite a conflicting archived label", () => {
    expect(queueLabel(440, "无限乱斗 5v5")).toBe("灵活排位");
  });

  it("preserves labels for queues that are not in the stable mapping", () => {
    expect(queueLabel(9999, "新模式")).toBe("新模式");
  });

  it("maps live client CLASS variants instead of exposing internal mode names", () => {
    expect(queueLabel(0, "CLASS")).toBe("召唤师峡谷");
    expect(queueLabel(0, "CLASSIC_SR")).toBe("召唤师峡谷");
    expect(queueLabel(0, "League of Legends")).toBe("召唤师峡谷");
  });
});
