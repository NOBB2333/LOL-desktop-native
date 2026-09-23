import { QueryClient, VueQueryPlugin } from "@tanstack/vue-query";
import { flushPromises, mount } from "@vue/test-utils";
import { describe, expect, it, vi } from "vitest";
import { fixtureBpHistory, fixtureEncounters } from "../fixtures/data";
import HistoryView from "./HistoryView.vue";

vi.mock("../stores/app", () => ({
  // 时间线查询会带 `connection.puuid` 做账号归属校验，所以这里必须把 connection 补齐，
  // 否则 queryFn 会抛错、时间线永远停在错误态（曾经漏过一次，测试只看到空区块）。
  useAppStore: () => ({ mode: "fixture", initialized: true, connection: { puuid: "self-puuid" } }),
}));

vi.mock("../services/backend", async () => {
  const { fixtureBpHistory, fixtureChampions, fixtureEncounters, fixtureMatches, createFixtureMatchTimeline } = await import("../fixtures/data");
  return {
    isTauri: () => false,
    backend: {
      bpHistory: async () => structuredClone(fixtureBpHistory),
      champions: async () => structuredClone(fixtureChampions),
      encounters: async () => structuredClone(fixtureEncounters),
      matches: async () => structuredClone(fixtureMatches.slice(0, 6)),
      matchTimeline: async (gameId: number) => createFixtureMatchTimeline(gameId),
    },
  };
});

const AssetIconStub = {
  props: ["id", "name"],
  template: '<i class="asset-icon-stub" :data-id="id" :data-name="name" />',
};

describe("HistoryView", () => {
  it("renders the champion IDs stored on BP and encounter records", async () => {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    const wrapper = mount(HistoryView, {
      global: {
        plugins: [[VueQueryPlugin, { queryClient }]],
        stubs: {
          AssetIcon: AssetIconStub,
          PageHeader: { template: "<header><slot /></header>" },
          NButton: { template: "<button><slot /></button>" },
          NTag: { template: "<span><slot /></span>" },
        },
      },
    });

    await flushPromises();
    const bpIcon = wrapper.get(".bp-champion-list .asset-icon-stub");
    expect(bpIcon.attributes("data-id")).toBe(String(fixtureBpHistory[0].allyChampionIds[0]));
    expect(bpIcon.attributes("data-name")).toBe(fixtureBpHistory[0].allyChampions[0]);

    await wrapper.get(".history-tabs button:nth-child(2)").trigger("click");
    await flushPromises();
    const encounterIcon = wrapper.get(".encounter-champion .asset-icon-stub");
    expect(encounterIcon.attributes("data-id")).toBe(String(fixtureEncounters[0].championId));
    expect(encounterIcon.attributes("data-name")).toBe(fixtureEncounters[0].championName);
  });

  it("shows exactly one section per tab, so the timeline does not sit under 玩家档案", async () => {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    const wrapper = mount(HistoryView, {
      global: {
        plugins: [[VueQueryPlugin, { queryClient }]],
        stubs: {
          AssetIcon: AssetIconStub,
          PageHeader: { template: "<header><slot /></header>" },
          NButton: { template: "<button><slot /></button>" },
          NTag: { template: "<span><slot /></span>" },
        },
      },
    });
    await flushPromises();

    await wrapper.get(".history-tabs button:nth-child(3)").trigger("click");
    // 这条链是三跳的：拉最近对局 → 自动选中第一局 → 按 gameId 拉时间线，
    // 一次 flushPromises 只够跳一步。
    for (let tick = 0; tick < 6; tick += 1) await flushPromises();

    // 玩家档案那一块是 v-else-if，页签有三个时必须真的走掉；
    // 否则两个区块会同时渲染（曾经就是这个 bug）。
    expect(wrapper.findAll(".history-section").length).toBe(1);
    expect(wrapper.find(".encounter-table").exists()).toBe(false);
    expect(wrapper.get(".history-section").text()).toContain("经济曲线与关键事件");
    expect(wrapper.findAll(".timeline-picker__item").length).toBeGreaterThan(0);
    expect(wrapper.find(".timeline-chart").exists()).toBe(true);
  });
});
