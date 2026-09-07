import { describe, expect, it } from "vitest";
import { championImage, platformRegionGuide, platformRegionName, platformRegionOverview, rankName, relativeTime, roleName, shortDate } from "./format";

describe("display formatting", () => {
  it("localizes ranks and positions", () => {
    expect(rankName("DIAMOND")).toBe("钻石");
    expect(roleName("JUNGLE")).toBe("打野");
  });

  it("resolves bundled champion assets", () => {
    expect(championImage(103)).toBe("./fixtures/champions/Ahri.png");
    expect(championImage(999)).toBe("");
  });

  it("repairs legacy signed-millisecond timestamps", () => {
    expect(shortDate("2026-08-24T14:36:37.+766Z")).not.toBe("时间未知");
    expect(relativeTime("not-a-timestamp")).toBe("时间未知");
  });

  it("highlights the current region while retaining the complete region guide", () => {
    const overview = platformRegionOverview("TENCENT_NJ100");
    expect(platformRegionName("TENCENT_NJ100")).toBe("NJ100 · 联盟一区");
    expect(overview.current).toMatchObject({ id: "NJ100", name: "联盟一区", group: "联盟大区" });
    expect(overview.groups.flatMap((group) => group.regions)).toHaveLength(8);

    const guide = platformRegionGuide("NJ100");
    expect(guide).toContain("当前大区：NJ100 · 联盟一区");
    for (const id of ["HN1", "HN10", "BGP2", "NJ100", "GZ100", "CQ100", "TJ100", "TJ101"]) {
      expect(guide).toContain(id);
    }
  });
});
