import { flushPromises, mount } from "@vue/test-utils";
import { describe, expect, it, vi } from "vitest";
import ToolboxView from "./ToolboxView.vue";

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
  PageHeader: { template: "<header><slot /></header>" },
  NButton: { emits: ["click"], template: '<button type="button" @click="$emit(\'click\')"><slot name="icon" /><slot /></button>' },
  NCheckbox: { props: ["checked"], emits: ["update:checked"], template: '<label class="checkbox-stub" @click="$emit(\'update:checked\', !checked)" />' },
  // 只渲染触发器：确认文案与 positive-click 不是这两个用例要验的东西。
  NPopconfirm: { template: '<div class="popconfirm-stub"><slot name="trigger" /></div>' },
};

describe("ToolboxView", () => {
  it("列出可领项，领取之后该条从清单里消失", async () => {
    const wrapper = mount(ToolboxView, { global: { stubs } });
    await flushPromises();
    const before = wrapper.findAll(".toolkit-item").length;
    expect(before).toBeGreaterThan(0);

    await wrapper.get(".toolkit-item__claim").trigger("click");
    await flushPromises();

    expect(wrapper.findAll(".toolkit-item")).toHaveLength(before - 1);
    expect(wrapper.get(".toolkit-results").text()).toContain("已领取");
  });

  it("急救动作把失败原因写在结果行里，而不是抛出去", async () => {
    const wrapper = mount(ToolboxView, { global: { stubs } });
    await flushPromises();

    const button = wrapper.findAll(".toolkit-actions button").find((item) => item.text().includes("退出结算页面"));
    expect(button).toBeTruthy();
    await button!.trigger("click");
    await flushPromises();

    const result = wrapper.get(".toolkit-result");
    expect(result.attributes("data-ok")).toBe("false");
    expect(result.text()).toContain("浏览器预览不支持客户端操作");
  });
});
