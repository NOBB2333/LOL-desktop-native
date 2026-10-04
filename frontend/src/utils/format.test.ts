import { describe, expect, it } from "vitest";
import { championImage, percentOrDash, platformRegionGuide, platformRegionLabel, platformRegionName, platformRegionOverview, rankName, relativeTime, roleName, shortDate } from "./format";

describe("display formatting", () => {
  it("localizes ranks and positions", () => {
    expect(rankName("DIAMOND")).toBe("钻石");
    expect(roleName("JUNGLE")).toBe("打野");
  });

  /**
   * 参团率这类「队伍级占比」拿不到整队数据时后端写 `null`。显示必须是「—」：
   * 写成 0% 或 100% 都会让人以为那是真实数据。
   */
  it("renders a missing team ratio as a dash instead of a number", () => {
    expect(percentOrDash(0.62)).toBe("62%");
    expect(percentOrDash(0)).toBe("0%");
    expect(percentOrDash(null)).toBe("—");
    expect(percentOrDash(undefined)).toBe("—");
    expect(percentOrDash(Number.NaN)).toBe("—");
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

  /**
   * 大区名**只能有这一份来源**。
   *
   * 回归锁：2026-10-03 战绩页自己另抄了一张表，把机房代号当城市名 ——
   * `HN1` 写成「河南一区」、`TJ101` 写成「天津二区」。真名是艾欧尼亚 / 联盟五区：
   * 用户一眼就看出来了（「联盟一区、二区、三区，只是用特殊的标符」），
   * 而名字错本身不报错，只会让人以为「搜索坏了」。
   */
  it("大区名用真实名称，不会把机房代号当城市名", () => {
    const expected: Record<string, string> = {
      HN1: "艾欧尼亚",
      HN10: "黑色玫瑰",
      BGP2: "峡谷之巅",
      NJ100: "联盟一区",
      GZ100: "联盟二区",
      CQ100: "联盟三区",
      TJ100: "联盟四区",
      TJ101: "联盟五区",
    };
    for (const [id, name] of Object.entries(expected)) {
      expect(platformRegionLabel(id)).toBe(name);
      // `TENCENT_` 前缀与「名字 / ID 混排」两种客户端的写法都要认。
      expect(platformRegionLabel(`TENCENT_${id}`)).toBe(name);
      expect(platformRegionLabel(`${name} / ${id}`)).toBe(name);
    }
    // 认不出来时原样返回 id，不猜、不编。
    expect(platformRegionLabel("TJ999")).toBe("TJ999");
    expect(platformRegionLabel("")).toBe("");
    expect(platformRegionLabel(null)).toBe("");
  });
});
