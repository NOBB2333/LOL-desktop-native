import { flushPromises, mount } from "@vue/test-utils";
import { beforeEach, describe, expect, it, vi } from "vitest";
import AssetIcon from "./AssetIcon.vue";

/** 由用例控制的「原生宿主」状态：拿不拿得到字节、拿到什么。 */
let nativeHost = false;
let nativeAsset: (kind: string, id: number) => Promise<{ dataUrl: string }> = async () => ({ dataUrl: "" });

vi.mock("../services/backend", () => ({
  isTauri: () => nativeHost,
  backend: { asset: (kind: string, id: number) => nativeAsset(kind, id) },
}));

beforeEach(() => {
  nativeHost = false;
  nativeAsset = async () => ({ dataUrl: "" });
});

describe("AssetIcon", () => {
  it("没有原生宿主时直接用调用方给的远程地址", async () => {
    const wrapper = mount(AssetIcon, { props: { kind: "profile", id: 0, name: "甲", fallbackUrl: "https://cdn/29.jpg" } });
    await flushPromises();
    expect(wrapper.get("img").attributes("src")).toBe("https://cdn/29.jpg");
    wrapper.unmount();
  });

  it("远程地址挂掉就退回首字母，不再反复重试同一个坏地址", async () => {
    const wrapper = mount(AssetIcon, { props: { kind: "profile", id: 0, name: "甲", fallbackUrl: "https://cdn/broken.jpg" } });
    await flushPromises();
    await wrapper.get("img").trigger("error");
    expect(wrapper.find("img").exists()).toBe(false);
    expect(wrapper.get(".asset-icon__fallback").text()).toBe("甲");
    wrapper.unmount();
  });

  it("远程先报错、原生稍后才取到字节时，仍然显示原生那张（不能一次报错就判死）", async () => {
    nativeHost = true;
    let resolveAsset: (value: { dataUrl: string }) => void = () => undefined;
    nativeAsset = () => new Promise((resolve) => { resolveAsset = resolve; });
    const wrapper = mount(AssetIcon, { props: { kind: "profile", id: 3494, name: "甲", fallbackUrl: "https://cdn/broken.jpg" } });
    await flushPromises();

    // 远程那张先失败：此时原生还没回来，界面该退到首字母。
    await wrapper.get("img").trigger("error");
    expect(wrapper.find("img").exists()).toBe(false);

    // 原生字节随后到达 → 应该重新显示出来，而不是一直停在首字母。
    resolveAsset({ dataUrl: "data:image/jpeg;base64,AAAA" });
    await flushPromises();
    expect(wrapper.get("img").attributes("src")).toBe("data:image/jpeg;base64,AAAA");
    wrapper.unmount();
  });

  it("原生返回空载荷时不抹掉已有的远程地址", async () => {
    nativeHost = true;
    nativeAsset = async () => ({ dataUrl: "" });
    const wrapper = mount(AssetIcon, { props: { kind: "champion", id: 103, name: "阿狸", fallbackUrl: "https://cdn/103.png" } });
    await flushPromises();
    expect(wrapper.get("img").attributes("src")).toBe("https://cdn/103.png");
    wrapper.unmount();
  });

  it("round 只加圆形类，方形图标不受影响", async () => {
    const round = mount(AssetIcon, { props: { kind: "profile", id: 29, name: "甲", round: true } });
    const square = mount(AssetIcon, { props: { kind: "champion", id: 103, name: "阿狸" } });
    expect(round.get(".asset-icon").classes()).toContain("asset-icon--round");
    expect(square.get(".asset-icon").classes()).not.toContain("asset-icon--round");
    round.unmount();
    square.unmount();
  });
});
