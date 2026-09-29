import { QueryClient, VueQueryPlugin } from "@tanstack/vue-query";
import { flushPromises, mount } from "@vue/test-utils";
import { beforeEach, describe, expect, it } from "vitest";
import type { ChampionAbilities } from "../types/domain";
import ChampionAbilityPanel from "./ChampionAbilityPanel.vue";

/**
 * 技能面板盯的是**真机数据形状**上的几处坑：
 *
 * 1. 技能名和描述来自 LCU 本地文件（`/lol-game-data/assets/v1/champions/{id}.json`），
 *    已经按客户端语言本地化好——所以不该有任何我们自己的翻译表参与。
 * 2. 槽位由 `spellKey`（q/w/e/r）决定，**不能按下标猜**：有的英雄少了某一格
 *    （Yasuo 的 Q 走 wrapper），硬编四个标签会点出一片空白。
 * 3. 冷却/耗蓝/射程是**每级数组**，真机上长度 5 或 6。展示只取前 5 格，而且
 *    0.5 这种小数不能被取整成 0（亚索 E）。
 */

const { abilitiesState } = vi.hoisted(() => ({
  abilitiesState: { data: null as ChampionAbilities | null, error: null as Error | null, calls: 0 },
}));

vi.mock("../services/backend", () => ({
  isTauri: () => false,
  backend: {
    championAbilities: async () => {
      abilitiesState.calls += 1;
      if (abilitiesState.error) throw abilitiesState.error;
      return abilitiesState.data as never;
    },
  },
}));

/** 图标桩：真组件会去拉远程图，这里只关心「挂了几个」与路径有没有传下来。 */
const LcuAssetStub = { props: ["path", "alt"], template: '<i class="lcu-stub" :data-path="path" :data-alt="alt" />' };

function abilitiesFixture(overrides: Partial<ChampionAbilities> = {}): ChampionAbilities {
  return {
    championId: 103,
    alias: "Ahri",
    name: "九尾妖狐",
    title: "九尾妖狐",
    passive: {
      name: "摄魂夺魄",
      description: "用技能命中敌人后获得一层<b>摄魂夺魄</b>。",
      iconPath: "/lol-game-data/assets/ASSETS/Characters/Ahri/HUD/Icons2D/Icons_Ahri_Passive.png",
      videoPath: "champion-abilities/0103/ability_0103_P1.webm",
      videoImagePath: "champion-abilities/0103/ability_0103_P1.jpg",
    },
    spells: ["q", "w", "e", "r"].map((slot, index) => ({
      slot,
      name: `技能${slot.toUpperCase()}`,
      description: `技能${slot.toUpperCase()} 的简版说明`,
      dynamicDescription: `造成 <magicDamage>@TotalDamage@ 魔法伤害</magicDamage>`,
      // 真机长度 5 或 6；这里给 6 格来证明**只展示前 5 格**。
      cooldown: [7 + index, 7 + index, 7 + index, 7 + index, 7 + index, 99],
      cost: [55, 65, 75, 85, 95, 95],
      range: [970, 970, 970, 970, 970, 970],
      iconPath: `/lol-game-data/assets/ASSETS/Characters/Ahri/HUD/Icons2D/Icons_Ahri_${slot.toUpperCase()}.png`,
      videoPath: `champion-abilities/0103/ability_0103_${slot.toUpperCase()}1.webm`,
      videoImagePath: `champion-abilities/0103/ability_0103_${slot.toUpperCase()}1.jpg`,
    })),
    ...overrides,
  };
}

function mountPanel(championId = 103) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return mount(ChampionAbilityPanel, {
    props: { championId, championName: "九尾妖狐" },
    global: { plugins: [[VueQueryPlugin, { queryClient }]], stubs: { LcuAssetImage: LcuAssetStub } },
  });
}

/**
 * 每个用例都必须从干净状态开始。
 *
 * `abilitiesState` 是模块级的桩状态，上一个用例塞的 `error` 会漏到下一个——
 * 2026-09-29 正是这么让「换英雄回 Q」那条红了一次（它拿到的是上一个用例的失败态）。
 */
beforeEach(() => {
  abilitiesState.data = null;
  abilitiesState.error = null;
  abilitiesState.calls = 0;
});

describe("技能面板：数据形状与口径", () => {
  it("按 spellKey 出标签（被动 + Q/W/E/R），默认停在 Q", async () => {
    abilitiesState.data = abilitiesFixture();
    const wrapper = mountPanel();
    await flushPromises();
    const labels = wrapper.findAll(".abilities__tabs button b").map((node) => node.text());
    expect(labels).toEqual(["被动", "Q", "W", "E", "R"]);
    // 默认选中 Q（不是被动、也不是列表里第一个任意槽）。
    expect(wrapper.get(".abilities__tabs button.active").text()).toContain("Q");
    expect(wrapper.get(".abilities__body header strong").text()).toBe("技能Q");
    wrapper.unmount();
  });

  it("某一格缺技能时不硬点一个空标签出来", async () => {
    // 真机上有英雄少了某一格。这里只给 Q 和 R → 标签里只该有这两个。
    const only = abilitiesFixture();
    only.spells = only.spells.filter((spell) => spell.slot === "q" || spell.slot === "r");
    abilitiesState.data = only;
    const wrapper = mountPanel();
    await flushPromises();
    const labels = wrapper.findAll(".abilities__tabs button b").map((node) => node.text());
    expect(labels).toEqual(["被动", "Q", "R"]);
    expect(labels).not.toContain("W");
    wrapper.unmount();
  });

  it("每级数组只展示前 5 格（第 6 格不是可点等级）", async () => {
    abilitiesState.data = abilitiesFixture();
    const wrapper = mountPanel();
    await flushPromises();
    const stats = wrapper.findAll(".abilities__stats dd").map((node) => node.text());
    // 冷却第 6 格是 99（桩里故意的），不许出现在界面上。
    expect(stats[0]).toBe("7 / 7 / 7 / 7 / 7");
    expect(stats[0]).not.toContain("99");
    wrapper.unmount();
  });

  it("冷却里的小数（亚索 E 的 0.5）不被取整成 0", async () => {
    const yasuo = abilitiesFixture({ championId: 157, alias: "Yasuo", name: "疾风剑豪" });
    const e = yasuo.spells.find((spell) => spell.slot === "e")!;
    e.cooldown = [0.5, 0.5, 0.4, 0.3, 0.2, 0.1];
    abilitiesState.data = yasuo;
    const wrapper = mountPanel(157);
    await flushPromises();
    await wrapper.findAll(".abilities__tabs button")[3].trigger("click");
    expect(wrapper.get(".abilities__stats dd").text()).toBe("0.5 / 0.5 / 0.4 / 0.3 / 0.2");
    wrapper.unmount();
  });

  it("射程五级相同就只写一个数，不同才列成数组", async () => {
    abilitiesState.data = abilitiesFixture();
    const wrapper = mountPanel();
    await flushPromises();
    // Q 的射程五格全是 970 → 只写一个 970。
    expect(wrapper.findAll(".abilities__stats dd")[2].text()).toBe("970");
    wrapper.unmount();
  });

  it("切到被动时显示被动文案与图标（结构不一样，不能复用技能分支）", async () => {
    abilitiesState.data = abilitiesFixture();
    const wrapper = mountPanel();
    await flushPromises();
    await wrapper.findAll(".abilities__tabs button")[0].trigger("click");
    const body = wrapper.get(".abilities__body");
    expect(body.get("header strong").text()).toBe("摄魂夺魄");
    expect(body.get("header small").text()).toBe("被动");
    // 被动没有等级数组 → 不该出现冷却/耗蓝/射程那一块。
    expect(body.find(".abilities__stats").exists()).toBe(false);
    expect(body.get(".lcu-stub").attributes("data-path")).toContain("Ahri_Passive");
    wrapper.unmount();
  });

  it("带 @占位符@ 的官方模板照原样展示，并说明为什么没有数字", async () => {
    abilitiesState.data = abilitiesFixture();
    const wrapper = mountPanel();
    await flushPromises();
    expect(wrapper.get(".abilities__text--muted").text()).toContain("@TotalDamage@");
    // 口径说明必须在：不说清，用户会以为是我们没渲染出来。
    expect(wrapper.get(".abilities__note").text()).toContain("占位符");
    expect(wrapper.get(".abilities__note").text()).toContain("不替它填数字");
    wrapper.unmount();
  });

  it("取不到资料时说清「需要开客户端」，而不是笼统的加载失败", async () => {
    abilitiesState.error = new Error("LcuNotRunning");
    const wrapper = mountPanel();
    // 失败态要等两轮 microtask（vue-query 内部先 reject 再置位）。
    await flushPromises();
    await flushPromises();
    const state = wrapper.get(".abilities__state");
    expect(state.text()).toContain("开启《英雄联盟》客户端");
    // 也要说清「不影响别的」——否则用户会以为整个英雄页都坏了。
    expect(state.text()).toContain("不受影响");
    // 出错时不该画标签页（点进去全是空的更迷惑）。
    expect(wrapper.find(".abilities__tabs").exists()).toBe(false);
    wrapper.unmount();
  });

  it("换英雄时回到 Q，不留在上一个英雄的 R 上", async () => {
    abilitiesState.data = abilitiesFixture();
    const wrapper = mountPanel(103);
    await flushPromises();
    await wrapper.findAll(".abilities__tabs button")[4].trigger("click");
    expect(wrapper.get(".abilities__tabs button.active").text()).toContain("R");
    await wrapper.setProps({ championId: 64, championName: "盲僧" });
    await flushPromises();
    expect(wrapper.get(".abilities__tabs button.active").text()).toContain("Q");
    wrapper.unmount();
  });

  it("同一个英雄只拉一次（staleTime 内不重复请求）", async () => {
    abilitiesState.data = abilitiesFixture();
    abilitiesState.calls = 0;
    const wrapper = mountPanel();
    await flushPromises();
    expect(abilitiesState.calls).toBe(1);
    await wrapper.setProps({ championName: "换个显示名" });
    await flushPromises();
    expect(abilitiesState.calls).toBe(1);
    wrapper.unmount();
  });
});
