import { QueryClient, VueQueryPlugin } from "@tanstack/vue-query";
import { flushPromises, mount } from "@vue/test-utils";
import type { VueWrapper } from "@vue/test-utils";
import { describe, expect, it, vi } from "vitest";
import { fixtureBpHistory, fixtureEncounters } from "../fixtures/data";
import HistoryView from "./HistoryView.vue";

/** 点同场玩家的名字会跳战绩页；测试不装真 router，只把跳转记下来。 */
const { pushedRoutes } = vi.hoisted(() => ({ pushedRoutes: [] as Array<{ path: string; query?: Record<string, string> }> }));

vi.mock("vue-router", () => ({
  useRouter: () => ({
    push: async (route: { path: string; query?: Record<string, string> }) => {
      pushedRoutes.push(route);
    },
  }),
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

function mountView() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return mount(HistoryView, {
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
}

/**
 * 按文字点页签。
 *
 * **不要用 `nth-child`**：页签顺序、以及中间那条分隔主次的分组竖线都会变，
 * 按下标取会在下次调整页签时静默点到别的地方（这次重做已经踩过一次）。
 */
function tab(wrapper: VueWrapper, label: string) {
  const found = wrapper.findAll(".history-tabs button").find((item) => item.text().includes(label));
  if (!found) throw new Error(`没有找到页签：${label}`);
  return found;
}

/**
 * 时间线那条链是三跳的：拉最近对局 → 自动选中第一局 → 按 gameId 拉时间线，
 * 一次 `flushPromises` 只够跳一步。
 */
async function settle() {
  for (let tick = 0; tick < 6; tick += 1) await flushPromises();
}

describe("HistoryView", () => {
  it("默认落在「对局时间线」，页签按主次排序并用竖线分组", async () => {
    const wrapper = mountView();
    await settle();

    const labels = wrapper.findAll(".history-tabs button").map((item) => item.text());
    // 主线两项在最前，且默认就是第一项——点进来看到的必须是排最前的那个。
    expect(labels[0]).toContain("对局时间线");
    expect(labels[1]).toContain("遇到的玩家");
    expect(tab(wrapper, "对局时间线").classes()).toContain("active");
    expect(wrapper.get(".history-section").text()).toContain("经济曲线与关键事件");
    // 分组竖线是 DOM 里的真元素，不是靠 CSS 画出来的。
    expect(wrapper.find(".history-tabs__divider").exists()).toBe(true);
    expect(labels[labels.length - 1]).toContain("BP 记录");
  });

  it("renders the champion IDs stored on BP and encounter records", async () => {
    const wrapper = mountView();
    await settle();

    await tab(wrapper, "BP 记录").trigger("click");
    await flushPromises();
    const bpIcon = wrapper.get(".bp-champion-list .asset-icon-stub");
    expect(bpIcon.attributes("data-id")).toBe(String(fixtureBpHistory[0].allyChampionIds[0]));
    expect(bpIcon.attributes("data-name")).toBe(fixtureBpHistory[0].allyChampions[0]);

    await tab(wrapper, "遇到的玩家").trigger("click");
    await flushPromises();
    const encounterIcon = wrapper.get(".encounter-champion .asset-icon-stub");
    expect(encounterIcon.attributes("data-id")).toBe(String(fixtureEncounters[0].championId));
    expect(encounterIcon.attributes("data-name")).toBe(fixtureEncounters[0].championName);
  });

  it("相遇记录按玩家聚合成一行，展开后能看到逐局细节", async () => {
    const wrapper = mountView();
    await settle();
    await tab(wrapper, "遇到的玩家").trigger("click");
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
    const wrapper = mountView();
    await settle();
    await tab(wrapper, "对局时间线").trigger("click");
    await settle();

    // 玩家档案那一块是 v-else-if，页签有四个时必须真的走掉；
    // 否则两个区块会同时渲染（曾经就是这个 bug）。
    expect(wrapper.findAll(".history-section").length).toBe(1);
    expect(wrapper.find(".encounter-table").exists()).toBe(false);
    expect(wrapper.get(".history-section").text()).toContain("经济曲线与关键事件");
    expect(wrapper.findAll(".timeline-picker__item").length).toBeGreaterThan(0);
    expect(wrapper.find(".timeline-chart").exists()).toBe(true);
  });

  it("时间线下面列出这一局的同场玩家，点名字去战绩页", async () => {
    const wrapper = mountView();
    await settle();
    pushedRoutes.length = 0;

    // 默认选中的是最近一局；fixture 里前三局的相遇记录与战绩列表是对齐的。
    const met = wrapper.get(".timeline-met");
    expect(met.text()).toContain("这一局遇到的人");
    const labels = met.findAll(".met-players__label").map((item) => item.text());
    expect(labels[0]).toMatch(/^队友 \d+$/);
    expect(labels[1]).toMatch(/^对手 \d+$/);

    const expected = fixtureEncounters.filter((record) => record.gameId === fixtureEncounters[0].gameId);
    expect(met.findAll(".met-players__chip").length).toBe(expected.length);

    await met.get(".met-players__chip").trigger("click");
    await flushPromises();
    expect(pushedRoutes.length).toBe(1);
    expect(pushedRoutes[0].path).toBe("/matches");
    expect(pushedRoutes[0].query?.summoner).toContain(expected[0].gameName);
  });
});
