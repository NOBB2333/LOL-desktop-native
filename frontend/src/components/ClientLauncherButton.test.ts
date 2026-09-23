import { flushPromises, mount } from "@vue/test-utils";
import { afterEach, describe, expect, it, vi } from "vitest";
import { reactive } from "vue";
import { fixtureClientInstallations } from "../fixtures/data";
import ClientLauncherButton from "./ClientLauncherButton.vue";

// 必须是响应式的：用例靠改 `connection.status` 来切换按钮的可见性。
const appStub = reactive({ initialized: true, mode: "live", connection: { status: "error" } });
const notices: string[] = [];

vi.mock("../stores/app", () => ({
  useAppStore: () => appStub,
}));

vi.mock("naive-ui", async (importOriginal) => {
  const actual = await importOriginal<typeof import("naive-ui")>();
  const record = (kind: string) => (text: string) => notices.push(`${kind}:${text}`);
  return { ...actual, useMessage: () => ({ success: record("success"), warning: record("warning"), info: record("info"), error: record("error") }) };
});

afterEach(() => {
  notices.length = 0;
  appStub.connection.status = "error";
  localStorage.clear();
});

describe("ClientLauncherButton", () => {
  it("未连接时出现，默认自动挑第一优先入口，也能记住切换结果", async () => {
    const wrapper = mount(ClientLauncherButton);
    await flushPromises();

    expect(wrapper.find(".client-launcher").exists()).toBe(true);
    const first = fixtureClientInstallations.entries[0];
    expect(wrapper.get(".client-launcher__go").attributes("title")).toContain(first.path);

    // 下拉里应该能看到全部探测到的入口，且第一条是选中态。
    const options = wrapper.findAll(".client-launcher__popover button");
    expect(options.length).toBe(fixtureClientInstallations.entries.length);
    expect(options[0].attributes("data-active")).toBe("true");

    // 换成第二条：记住它，并反馈给用户。
    const second = fixtureClientInstallations.entries[1];
    await options[1].trigger("click");
    expect(localStorage.getItem("lol-desktop-launch-target")).toBe(second.id);
    expect(notices.some((item) => item.startsWith("info:") && item.includes(second.label))).toBe(true);

    // 重挂载后应该仍然用记住的那条，而不是退回第一优先。
    const remounted = mount(ClientLauncherButton);
    await flushPromises();
    expect(remounted.get(".client-launcher__go").attributes("title")).toContain(second.path);
    wrapper.unmount();
    remounted.unmount();
  });

  it("连上客户端后按钮消失（不再有存在意义）", async () => {
    const wrapper = mount(ClientLauncherButton);
    await flushPromises();
    expect(wrapper.find(".client-launcher").exists()).toBe(true);

    appStub.connection.status = "connected";
    await flushPromises();
    expect(wrapper.find(".client-launcher").exists()).toBe(false);
    wrapper.unmount();
  });

  it("点击启动走的是记住的入口，并把可读标签写进提示", async () => {
    const wrapper = mount(ClientLauncherButton);
    await flushPromises();
    await wrapper.get(".client-launcher__go").trigger("click");
    await flushPromises();

    const entry = fixtureClientInstallations.entries[0];
    expect(notices.some((item) => item.startsWith("success:") && item.includes(entry.label))).toBe(true);
    wrapper.unmount();
  });
});
