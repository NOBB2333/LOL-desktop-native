import { describe, expect, it } from "vitest";
import {
  OPGG_FALLBACK_REGION,
  OPGG_FALLBACK_TIER,
  opggRegionOptions,
  platformToOpggRegion,
  resolveStatsRegion,
  resolveStatsTier,
} from "./statsScope";

describe("platformToOpggRegion", () => {
  it("把常见 platformId 映射到 OP.GG 区服", () => {
    expect(platformToOpggRegion("NA1")).toBe("na");
    expect(platformToOpggRegion("KR")).toBe("kr");
    expect(platformToOpggRegion("EUW1")).toBe("euw");
    expect(platformToOpggRegion("EUN1")).toBe("eune");
    expect(platformToOpggRegion("JP1")).toBe("jp");
    expect(platformToOpggRegion("TW2")).toBe("tw");
  });

  it("也认不带数字的写法，并忽略大小写与空白", () => {
    expect(platformToOpggRegion("euw")).toBe("euw");
    expect(platformToOpggRegion("  Kr ")).toBe("kr");
  });

  it("拉美北/拉美南必须整串区分，不能剥掉数字后混为一谈", () => {
    expect(platformToOpggRegion("LA1")).toBe("lan");
    expect(platformToOpggRegion("LA2")).toBe("las");
  });

  it("国服与认不出的平台落回 global（OP.GG 没有大陆服数据）", () => {
    expect(platformToOpggRegion("TENCENT")).toBe(OPGG_FALLBACK_REGION);
    expect(platformToOpggRegion("HN1")).toBe(OPGG_FALLBACK_REGION);
    expect(platformToOpggRegion("")).toBe(OPGG_FALLBACK_REGION);
    expect(platformToOpggRegion(null)).toBe(OPGG_FALLBACK_REGION);
    expect(platformToOpggRegion(undefined)).toBe(OPGG_FALLBACK_REGION);
  });

  it("映射出来的区服一定在后端白名单对应的选项表里", () => {
    for (const platform of ["NA1", "KR", "EUW1", "EUN1", "JP1", "BR1", "LA1", "LA2", "OC1", "TR1", "RU", "SG2", "PH2", "TH2", "VN2", "TW2", "ME1"]) {
      const region = platformToOpggRegion(platform);
      expect(opggRegionOptions.some((option) => option.value === region)).toBe(true);
    }
  });
});

describe("resolveStatsRegion", () => {
  it("手动选过就听用户的，不跟随本机大区", () => {
    expect(resolveStatsRegion("kr", "NA1")).toBe("kr");
    expect(resolveStatsRegion("global", "KR")).toBe("global");
  });

  it("没选过（或存的值已不合法）就跟随本机大区", () => {
    expect(resolveStatsRegion(null, "KR")).toBe("kr");
    expect(resolveStatsRegion(undefined, "EUW1")).toBe("euw");
    expect(resolveStatsRegion("", "NA1")).toBe("na");
    expect(resolveStatsRegion("not-a-region", "JP1")).toBe("jp");
  });
});

describe("resolveStatsTier", () => {
  it("界面提供的值原样返回，空值落回默认", () => {
    expect(resolveStatsTier("master_plus")).toBe("master_plus");
    expect(resolveStatsTier("all")).toBe("all");
    expect(resolveStatsTier(null)).toBe(OPGG_FALLBACK_TIER);
    expect(resolveStatsTier("nope")).toBe(OPGG_FALLBACK_TIER);
  });

  it("后端白名单里的值如果界面不提供，也落回默认（界面表是白名单的子集）", () => {
    // 后端 `opgg_tiers` 有 10 个（含 "master" / "ibsg"），界面只暴露 8 个。
    // 存到这类值时不该照用——用户在新界面上根本看不到它，等于卡在一个不可见的状态。
    expect(resolveStatsTier("master")).toBe(OPGG_FALLBACK_TIER);
    expect(resolveStatsTier("ibsg")).toBe(OPGG_FALLBACK_TIER);
  });
});
