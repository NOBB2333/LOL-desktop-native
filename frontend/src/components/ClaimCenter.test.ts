import { flushPromises, mount } from "@vue/test-utils";
import { describe, expect, it, vi } from "vitest";
import ClaimCenter from "./ClaimCenter.vue";

vi.mock("../stores/app", () => ({
  useAppStore: () => ({ mode: "fixture", initialized: true }),
}));

// `useMessage` 在没挂 NMessageProvider 时会抛错；这里只把它换成空实现，
// 其余 naive-ui 组件照旧走真实模块，样式类名才是真的。
vi.mock("naive-ui", async (importOriginal) => {
  const actual = await importOriginal<typeof import("naive-ui")>();
  const noop = () => undefined;
  return { ...actual, useMessage: () => ({ success: noop, warning: noop, error: noop, info: noop }) };
});

const stubs = {
  NButton: { emits: ["click"], template: '<button type="button" @click="$emit(\'click\')"><slot name="icon" /><slot /></button>' },
  NCheckbox: { props: ["checked"], emits: ["update:checked"], template: '<label class="checkbox-stub" @click="$emit(\'update:checked\', !checked)" />' },
};

describe("ClaimCenter", () => {
  it("列出可领项，领取之后该条从清单里消失", async () => {
    const wrapper = mount(ClaimCenter, { global: { stubs } });
    await flushPromises();
    const before = wrapper.findAll(".claim-item").length;
    expect(before).toBeGreaterThan(0);

    await wrapper.get(".claim-item__claim").trigger("click");
    await flushPromises();

    expect(wrapper.findAll(".claim-item")).toHaveLength(before - 1);
    expect(wrapper.get(".claim-results").text()).toContain("已领取");
  });

  it("非实时模式下把「不生效」写在明面上", async () => {
    const wrapper = mount(ClaimCenter, { global: { stubs } });
    await flushPromises();
    expect(wrapper.get(".claim-notice").text()).toContain("实时");
  });
});
