import { flushPromises, mount } from "@vue/test-utils";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { resetAssetCache } from "../assets/assetCache";
import AssetIcon from "./AssetIcon.vue";

/** 由用例控制的「原生宿主」状态：拿不拿得到字节、拿到什么。 */
let nativeHost = false;
let nativeAsset: (kind: string, id: number) => Promise<{ dataUrl: string }> = async () => ({ dataUrl: "" });
let assetCalls = 0;

vi.mock("../services/backend", () => ({
  isTauri: () => nativeHost,
  backend: { asset: (kind: string, id: number) => { assetCalls += 1; return nativeAsset(kind, id); } },
}));

beforeEach(() => {
  nativeHost = false;
  nativeAsset = async () => ({ dataUrl: "" });
  assetCalls = 0;
  resetAssetCache();
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

  it("同一个英雄图标只过一次桥；重挂（身份落定会让 key 变）也不会重新拉", async () => {
    nativeHost = true;
    nativeAsset = async () => ({ dataUrl: "data:image/png;base64,AAAA" });
    const first = mount(AssetIcon, { props: { kind: "champion", id: 875, name: "腕豪" } });
    await flushPromises();
    expect(first.get("img").attributes("src")).toBe("data:image/png;base64,AAAA");
    expect(assetCalls).toBe(1);
    first.unmount();

    // 再挂一次（模拟卡片重挂）：缓存命中，同步就该有图，且不再过桥。
    const second = mount(AssetIcon, { props: { kind: "champion", id: 875, name: "腕豪" } });
    expect(second.get("img").attributes("src")).toBe("data:image/png;base64,AAAA");
    await flushPromises();
    expect(assetCalls).toBe(1);
    second.unmount();
  });

  it("同一张图并发渲染多次只发一次请求", async () => {
    nativeHost = true;
    let resolveAsset: (value: { dataUrl: string }) => void = () => undefined;
    nativeAsset = () => new Promise((resolve) => { resolveAsset = resolve; });
    const a = mount(AssetIcon, { props: { kind: "champion", id: 103, name: "阿狸" } });
    const b = mount(AssetIcon, { props: { kind: "champion", id: 103, name: "阿狸" } });
    await flushPromises();
    expect(assetCalls).toBe(1);
    resolveAsset({ dataUrl: "data:image/png;base64,BBBB" });
    await flushPromises();
    expect(a.get("img").attributes("src")).toBe("data:image/png;base64,BBBB");
    expect(b.get("img").attributes("src")).toBe("data:image/png;base64,BBBB");
    a.unmount();
    b.unmount();
  });

  it("空载荷不进缓存：下一张卡还会再试一次", async () => {
    nativeHost = true;
    nativeAsset = async () => ({ dataUrl: "" });
    const first = mount(AssetIcon, { props: { kind: "champion", id: 64, name: "盲僧" } });
    await flushPromises();
    expect(assetCalls).toBe(1);
    first.unmount();
    const second = mount(AssetIcon, { props: { kind: "champion", id: 64, name: "盲僧" } });
    await flushPromises();
    expect(assetCalls).toBe(2);
    second.unmount();
  });
});
