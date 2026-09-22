import { flushPromises, mount } from "@vue/test-utils";
import { describe, expect, it, vi } from "vitest";
import ClientFirstAid from "./ClientFirstAid.vue";

vi.mock("../stores/app", () => ({
  useAppStore: () => ({ mode: "live" }),
}));

vi.mock("naive-ui", async (importOriginal) => {
  const actual = await importOriginal<typeof import("naive-ui")>();
  const noop = () => undefined;
  return { ...actual, useMessage: () => ({ success: noop, warning: noop, error: noop, info: noop }) };
});

const stubs = {
  // 只渲染触发器：确认文案与 positive-click 不是这个用例要验的东西。
  NPopconfirm: { template: '<div class="popconfirm-stub"><slot name="trigger" /></div>' },
};

describe("ClientFirstAid", () => {
  it("急救动作把失败原因写在结果行里，而不是抛出去", async () => {
    const wrapper = mount(ClientFirstAid, { global: { stubs } });
    await flushPromises();

    const button = wrapper.findAll(".game-first-aid button").find((item) => item.text().includes("退出结算"));
    expect(button).toBeTruthy();
    await button!.trigger("click");
    await flushPromises();

    const result = wrapper.get(".game-first-aid__result");
    expect(result.attributes("data-ok")).toBe("false");
    expect(result.text()).toContain("浏览器预览不支持客户端操作");
  });

  it("实时模式下不显示「不生效」提示", async () => {
    const wrapper = mount(ClientFirstAid, { global: { stubs } });
    await flushPromises();
    expect(wrapper.find(".game-first-aid__notice").exists()).toBe(false);
  });
});
