import { mount } from "@vue/test-utils";
import { describe, expect, it } from "vitest";
import LcuAssetImage from "./LcuAssetImage.vue";

const mountWith = (path: string | null) => mount(LcuAssetImage, {
  props: { path, alt: "奖励" },
  slots: { default: '<span class="glyph" />' },
});

describe("LcuAssetImage", () => {
  it("没有路径时渲染兜底插槽，而不是空框", () => {
    const wrapper = mountWith(null);
    expect(wrapper.find("img").exists()).toBe(false);
    expect(wrapper.find(".glyph").exists()).toBe(true);
  });

  it("LCU 路径映射到 CommunityDragon（预览里没有原生宿主可问）", () => {
    const wrapper = mountWith("/lol-game-data/assets/v1/Missions/Icons/Reward.PNG");
    expect(wrapper.get("img").attributes("src")).toBe(
      "https://raw.communitydragon.org/latest/plugins/rcp-be-lol-game-data/global/default/v1/missions/icons/reward.png",
    );
  });

  it("本身就能当 src 用的值原样显示", () => {
    const dataUrl = "data:image/svg+xml,%3Csvg%20xmlns=%22http://www.w3.org/2000/svg%22/%3E";
    expect(mountWith(dataUrl).get("img").attributes("src")).toBe(dataUrl);
    expect(mountWith("https://example.com/icon.png").get("img").attributes("src")).toBe("https://example.com/icon.png");
  });

  it("图片加载失败后退回兜底插槽", async () => {
    const wrapper = mountWith("/lol-game-data/assets/v1/missions/reward.png");
    await wrapper.get("img").trigger("error");
    expect(wrapper.find("img").exists()).toBe(false);
    expect(wrapper.find(".glyph").exists()).toBe(true);
  });
});
