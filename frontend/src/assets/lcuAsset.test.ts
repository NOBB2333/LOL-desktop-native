import { describe, expect, it } from "vitest";
import { isLcuAssetPath, lcuAssetToCommunityDragon } from "./lcuAsset";

describe("isLcuAssetPath", () => {
  it("接受 /lol-game-data/assets/ 底下的资源", () => {
    expect(isLcuAssetPath("/lol-game-data/assets/v1/missions/reward.png")).toBe(true);
  });

  it("拒绝别的 LCU 接口和外部地址", () => {
    expect(isLcuAssetPath("/lol-summoner/v1/current-summoner")).toBe(false);
    expect(isLcuAssetPath("https://example.com/x.png")).toBe(false);
    expect(isLcuAssetPath("")).toBe(false);
    expect(isLcuAssetPath(null)).toBe(false);
    expect(isLcuAssetPath(undefined)).toBe(false);
  });

  it("前缀本身不是资源", () => {
    expect(isLcuAssetPath("/lol-game-data/assets/")).toBe(false);
  });
});

describe("lcuAssetToCommunityDragon", () => {
  it("剥掉前缀、整条转小写再拼默认资产根", () => {
    expect(lcuAssetToCommunityDragon("/lol-game-data/assets/v1/Missions/Icons/Reward.PNG")).toBe(
      "https://raw.communitydragon.org/latest/plugins/rcp-be-lol-game-data/global/default/v1/missions/icons/reward.png",
    );
  });

  it("丢掉查询串和 hash", () => {
    expect(lcuAssetToCommunityDragon("/lol-game-data/assets/v1/a/b.png?x=1")).toBe(
      "https://raw.communitydragon.org/latest/plugins/rcp-be-lol-game-data/global/default/v1/a/b.png",
    );
  });

  it("非 LCU 路径返回 null，交给调用方退化", () => {
    expect(lcuAssetToCommunityDragon("/lol-summoner/v1/current-summoner")).toBeNull();
    expect(lcuAssetToCommunityDragon(null)).toBeNull();
    expect(lcuAssetToCommunityDragon("")).toBeNull();
  });
});
