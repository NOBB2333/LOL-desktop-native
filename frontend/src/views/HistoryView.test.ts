import { QueryClient, VueQueryPlugin } from "@tanstack/vue-query";
import { flushPromises, mount } from "@vue/test-utils";
import { describe, expect, it, vi } from "vitest";
import { fixtureBpHistory, fixtureEncounters } from "../fixtures/data";
import HistoryView from "./HistoryView.vue";

vi.mock("vue-router", () => ({
  // 「遇到的玩家」里点名字会跳到战绩页；测试不装真 router，给个空壳即可。
  useRouter: () => ({ push: async () => {} }),
}));

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
    // 默认页签是「最近对局」，BP 现在排在最后一个页签。
    await wrapper.get(".history-tabs button:nth-child(4)").trigger("click");
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

  it("相遇记录按玩家聚合成一行，展开后能看到逐局细节", async () => {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    const wrapper = mount(HistoryView, {
      global: {
        plugins: [[VueQueryPlugin, { queryClient }]],
        stubs: {
          AssetIcon: AssetIconStub,
          PageHeader: { template: "<header><slot /></header>" },
          NButton: { template: "<button><slot /></button>" },
          NInput: { props: ["value"], template: "<input />" },
        },
      },
    });
    await flushPromises();
    await wrapper.get(".history-tabs button:nth-child(2)").trigger("click");
    await flushPromises();

    // 原始记录是「每局每人一行」，同一个人 3 局就会出现 3 次；聚合后每人只占一行。
    const uniquePlayers = new Set(fixtureEncounters.map((record) => record.puuid)).size;
    expect(wrapper.findAll(".encounter-table__row").length).toBe(uniquePlayers);
    expect(wrapper.findAll(".encounter-detail__row").length).toBe(0);

    await wrapper.get(".encounter-table__row").trigger("click");
    await flushPromises();
    expect(wrapper.get(".encounter-table__row").classes()).toContain("is-open");
    // 这套 fixture 里每位玩家都出现在全部 3 局中。
    expect(wrapper.findAll(".encounter-detail__row").length).toBe(3);
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
