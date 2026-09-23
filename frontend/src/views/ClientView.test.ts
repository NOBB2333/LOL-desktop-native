import { flushPromises, mount } from "@vue/test-utils";
import { afterEach, describe, expect, it, vi } from "vitest";
import { reactive } from "vue";
import { fixtureClientInstallations } from "../fixtures/data";
import ClientView from "./ClientView.vue";

const appStub = reactive({
  mode: "live",
  connection: {
    status: "error",
    phase: null as string | null,
    queueLabel: null as string | null,
    gameName: null as string | null,
    tagLine: null as string | null,
    platformId: null as string | null,
    summonerLevel: null as number | null,
  },
  bootstrap: { appVersion: "2.5.0" },
});
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

/** 组件里有一个跳对局页的 RouterLink；测试没有装 router，给个最小替身。 */
const mountView = () => mount(ClientView, { global: { stubs: { RouterLink: { template: "<a class=\"router-link-stub\" :href=\"to\"><slot /></a>", props: ["to"] } } } });

function resetConnection() {
  appStub.connection.status = "error";
  appStub.connection.phase = null;
  appStub.connection.queueLabel = null;
  appStub.connection.gameName = null;
  appStub.connection.tagLine = null;
  appStub.connection.platformId = null;
  appStub.connection.summonerLevel = null;
}

afterEach(() => {
  notices.length = 0;
  launchCalls.length = 0;
  writeText.mockClear();
  resetConnection();
});

describe("ClientView", () => {
  it("列出全部探测入口：图标、名称、完整路径、来源都在", async () => {
    const wrapper = mountView();
    await flushPromises();

    const cards = wrapper.findAll(".client-card");
    expect(cards.length).toBe(fixtureClientInstallations.entries.length);
    expect(wrapper.find("img.client-card__icon").exists()).toBe(true);
    expect(cards[0].get("strong").text()).toContain("英雄联盟");
    expect(cards[0].get("code").text()).toBe(fixtureClientInstallations.entries[0].path);
    // 来源从「来源：xxx」的小字改成了脚标，内容不能丢。
    expect(cards[0].find(".client-tag").text()).toBe(fixtureClientInstallations.entries[0].detail);
    // 认得出的 id 才给「这个入口是干什么的」，别硬编。
    expect(cards[0].find(".client-card__hint").text()).toContain("腾讯登录器");
  });

  it("首条入口标出优先级：后端就是按这个顺序自动挑的", async () => {
    const wrapper = mountView();
    await flushPromises();

    const cards = wrapper.findAll(".client-card");
    expect(cards[0].attributes("data-recommended")).toBe("true");
    expect(cards[0].text()).toContain("优先级最高");
    expect(cards[1].attributes("data-recommended")).toBe("false");
    wrapper.unmount();
  });

  it("点启动走对应入口，成功提示带上可读标签", async () => {
    const wrapper = mountView();
    await flushPromises();

    const launchButtons = wrapper.findAll(".client-card__foot button").filter((button) => button.text().includes("启动"));
    await launchButtons[1].trigger("click");
    await flushPromises();

    const second = fixtureClientInstallations.entries[1];
    expect(launchCalls).toEqual([second.id]);
    expect(notices.some((item) => item.startsWith("success:") && item.includes(second.label))).toBe(true);
    wrapper.unmount();
  });

  it("复制路径把完整路径写进剪贴板", async () => {
    const wrapper = mountView();
    await flushPromises();

    const copyButtons = wrapper.findAll(".client-card__foot button").filter((button) => button.text().includes("复制"));
    await copyButtons[0].trigger("click");
    await flushPromises();

    expect(writeText).toHaveBeenCalledWith(fixtureClientInstallations.entries[0].path);
    wrapper.unmount();
  });

  it("运行状态面板摊开连接结果，没连上时不放跳转入口", async () => {
    const wrapper = mountView();
    await flushPromises();

    expect(wrapper.findAll(".client-fact").length).toBe(5);
    expect(wrapper.find('.client-fact dd[data-state="error"]').text()).toBe("连接失败");
    // 没连上就别给「去看当前对局」，那是死路。
    expect(wrapper.find(".client-runtime__jump").exists()).toBe(false);
    wrapper.unmount();
  });

  it("连上之后账号、大区、阶段都显示出来，并给出跳对局页的入口", async () => {
    appStub.connection.status = "connected";
    appStub.connection.gameName = "测试召唤师";
    appStub.connection.tagLine = "HN1";
    appStub.connection.platformId = "HN1";
    appStub.connection.summonerLevel = 416;
    appStub.connection.queueLabel = "单双排";

    const wrapper = mountView();
    await flushPromises();

    const facts = wrapper.findAll(".client-fact").map((fact) => fact.text());
    expect(facts.join("|")).toContain("测试召唤师#HN1");
    expect(facts.join("|")).toContain("Lv 416");
    expect(facts.join("|")).toContain("单双排");
    expect(wrapper.find('.client-fact dd[data-state="connected"]').text()).toBe("已连接");
    expect(wrapper.find(".client-runtime__jump").attributes("href")).toBe("/game");
    wrapper.unmount();
  });

  it("一个入口都没有时显示空态；已连接时仍照常展示", async () => {
    const { backend } = await import("../services/backend");
    (backend as { clientInstallations: () => Promise<{ entries: unknown[] }> }).clientInstallations = async () => ({ entries: [] });

    const wrapper = mountView();
    await flushPromises();
    expect(wrapper.find(".client-empty").exists()).toBe(true);
    wrapper.unmount();

    // 已连接不该隐藏信息：用户可能就是想看一眼安装路径。
    (backend as { clientInstallations: () => Promise<{ entries: unknown[] }> }).clientInstallations = async () => structuredClone(fixtureClientInstallations);
    appStub.connection.status = "connected";
    const connected = mountView();
    await flushPromises();
    expect(connected.findAll(".client-card").length).toBe(fixtureClientInstallations.entries.length);
    // 连接状态同时出现在 hero 的状态行里，用 data 属性区分。
    expect(connected.find('.client-status[data-connected="true"]').exists()).toBe(true);
    expect(connected.find(".client-status").text()).toContain("已连接");
    connected.unmount();
  });
});
