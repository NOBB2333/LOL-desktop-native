import { flushPromises, mount } from "@vue/test-utils";
import { afterEach, describe, expect, it, vi } from "vitest";
import { reactive } from "vue";
import { fixtureClientInstallations } from "../fixtures/data";
import ClientView from "./ClientView.vue";

const appStub = reactive({ mode: "live", connection: { status: "error" } as { status: string } });
const notices: string[] = [];
const launchCalls: string[] = [];

vi.mock("../stores/app", () => ({
  useAppStore: () => appStub,
}));

vi.mock("naive-ui", async (importOriginal) => {
  const actual = await importOriginal<typeof import("naive-ui")>();
  const record = (kind: string) => (text: string) => notices.push(`${kind}:${text}`);
  return {
    ...actual,
    NButton: { template: "<button :disabled=\"$attrs.disabled\" @click=\"$emit('click', $event)\"><slot /><slot name=\"icon\" /></button>" },
    useMessage: () => ({ success: record("success"), warning: record("warning"), info: record("info"), error: record("error") }),
  };
});

vi.mock("../services/backend", () => ({
  backend: {
    clientInstallations: async () => structuredClone(fixtureClientInstallations),
    launchClient: async (id: string) => {
      launchCalls.push(id);
      const entry = fixtureClientInstallations.entries.find((item) => item.id === id);
      return { ok: true, reason: "", id, label: entry?.label ?? "" };
    },
  },
}));

// clipboard 在 jsdom 里不存在；给出一个可断言的桩，顺带验证写进去的就是完整路径。
const writeText = vi.fn(async () => {});
Object.defineProperty(navigator, "clipboard", { value: { writeText }, configurable: true });

afterEach(() => {
  notices.length = 0;
  launchCalls.length = 0;
  writeText.mockClear();
  appStub.connection.status = "error";
});

describe("ClientView", () => {
  it("列出全部探测入口：图标、名称、完整路径、来源都在", async () => {
    const wrapper = mount(ClientView);
    await flushPromises();

    const rows = wrapper.findAll(".client-row");
    expect(rows.length).toBe(fixtureClientInstallations.entries.length);
    expect(wrapper.find("img.client-row__icon").exists()).toBe(true);
    expect(rows[0].get("strong").text()).toContain("英雄联盟");
    expect(rows[0].get("code").text()).toBe(fixtureClientInstallations.entries[0].path);
    expect(rows[0].text()).toContain("来源：");
  });

  it("点启动走对应入口，成功提示带上可读标签", async () => {
    const wrapper = mount(ClientView);
    await flushPromises();

    const launchButtons = wrapper.findAll(".client-row__actions button").filter((button) => button.text().includes("启动"));
    await launchButtons[1].trigger("click");
    await flushPromises();

    const second = fixtureClientInstallations.entries[1];
    expect(launchCalls).toEqual([second.id]);
    expect(notices.some((item) => item.startsWith("success:") && item.includes(second.label))).toBe(true);
    wrapper.unmount();
  });

  it("复制路径把完整路径写进剪贴板", async () => {
    const wrapper = mount(ClientView);
    await flushPromises();

    const copyButtons = wrapper.findAll(".client-row__actions button").filter((button) => button.text().includes("复制"));
    await copyButtons[0].trigger("click");
    await flushPromises();

    expect(writeText).toHaveBeenCalledWith(fixtureClientInstallations.entries[0].path);
    wrapper.unmount();
  });

  it("一个入口都没有时显示空态；已连接时仍照常展示", async () => {
    const { backend } = await import("../services/backend");
    (backend as { clientInstallations: () => Promise<{ entries: unknown[] }> }).clientInstallations = async () => ({ entries: [] });

    const wrapper = mount(ClientView);
    await flushPromises();
    expect(wrapper.find(".client-empty").exists()).toBe(true);
    wrapper.unmount();

    // 已连接不该隐藏信息：用户可能就是想看一眼安装路径。
    (backend as { clientInstallations: () => Promise<{ entries: unknown[] }> }).clientInstallations = async () => structuredClone(fixtureClientInstallations);
    appStub.connection.status = "connected";
    const connected = mount(ClientView);
    await flushPromises();
    expect(connected.findAll(".client-row").length).toBe(fixtureClientInstallations.entries.length);
    expect(connected.find(".client-connected").exists()).toBe(true);
    connected.unmount();
  });
});
