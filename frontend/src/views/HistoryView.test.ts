import { QueryClient, VueQueryPlugin } from "@tanstack/vue-query";
import { flushPromises, mount } from "@vue/test-utils";
import type { VueWrapper } from "@vue/test-utils";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { createFixtureMatchTimeline, fixtureEncounters, fixtureMatches } from "../fixtures/data";
import HistoryView from "./HistoryView.vue";

/**
 * 历史页重做后的结构（**只有两个页签**）：
 * - 「对局」= 对局列表，点开一局才去拉那一局的逐帧数据，展开区给首杀 / 每波团 / 事件流 / 同场的人；
 * - 「人」= 首页「关系记录」那批人的详细版，展开一行看逐局对比。
 *
 * 旧的四页签（最近对局 / 遇到的玩家 / 对局时间线 / BP 记录）已经删掉，
 * 所以这里的断言也把「删干净了」写进去——否则下次谁把那半页经济曲线捡回来没人拦得住。
 */
const { pushedRoutes, routeState, timelineRequests } = vi.hoisted(() => ({
  pushedRoutes: [] as Array<{ path: string; query?: Record<string, string> }>,
  /** 假的 URL query：深链测试要在挂载前写好。 */
  routeState: { query: {} as Record<string, unknown> },
  /** 逐帧数据是按需拉的，记录到底拉过哪几局。 */
  timelineRequests: [] as number[],
}));

vi.mock("vue-router", () => ({
  useRouter: () => ({
    push: async (route: { path: string; query?: Record<string, string> }) => {
      pushedRoutes.push(route);
    },
  }),
  useRoute: () => ({ query: routeState.query }),
}));

vi.mock("../stores/app", () => ({
  // 逐帧查询会带 `connection.puuid` 做账号归属校验，所以这里必须把 connection 补齐，
  // 否则 queryFn 会抛错、详情永远停在错误态（曾经漏过一次，测试只看到空区块）。
  useAppStore: () => ({ mode: "fixture", initialized: true, connection: { puuid: "self-puuid" } }),
}));

vi.mock("../services/backend", async () => {
  const { createFixtureMatchTimeline, fixtureChampions, fixtureEncounters, fixtureMatches } = await import("../fixtures/data");
  return {
    isTauri: () => false,
    backend: {
      champions: async () => structuredClone(fixtureChampions),
      encounters: async () => structuredClone(fixtureEncounters),
      matches: async () => structuredClone(fixtureMatches),
      matchTimeline: async (gameId: number) => {
        timelineRequests.push(gameId);
        return createFixtureMatchTimeline(gameId);
      },
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
        NSpin: { template: '<span class="n-spin-stub" />' },
      },
    },
  });
}

/**
 * 按文字点页签。
 *
 * **不要用 `nth-child`**：页签顺序、以及中间那条分隔主次的分组竖线都会变，
 * 按下标取会在下次调整页签时静默点到别的地方（重做前已经踩过一次）。
 */
function tab(wrapper: VueWrapper, label: string) {
  const found = wrapper.findAll(".history-tabs button").find((item) => item.text().includes(label));
  if (!found) throw new Error(`没有找到页签：${label}`);
  return found;
}

/**
 * 展开一局的链是三跳的：拉最近对局 → 点开 → 按 gameId 拉该局逐帧，
 * 一次 `flushPromises` 只够跳一步。
 */
async function settle() {
  for (let tick = 0; tick < 6; tick += 1) await flushPromises();
}

beforeEach(() => {
  pushedRoutes.length = 0;
  timelineRequests.length = 0;
  routeState.query = {};
});

describe("HistoryView", () => {
  it("只剩下「对局」与「人」两个页签，默认落在对局，旧的四页签不留痕", async () => {
    const wrapper = mountView();
    await settle();

    const labels = wrapper.findAll(".history-tabs button").map((item) => item.text());
    expect(labels).toHaveLength(2);
    expect(labels[0]).toContain("对局");
    expect(labels[1]).toContain("人");
    expect(tab(wrapper, "对局").classes()).toContain("active");

    // 一次只渲染一个区块：两个页签是 v-if / v-else，漏了就会两块同时出现。
    expect(wrapper.findAll(".history-section")).toHaveLength(1);
    expect(wrapper.findAll(".match-card")).toHaveLength(fixtureMatches.length);

    // 重做删掉的东西：分组竖线、经济曲线、BP 记录。
    expect(wrapper.find(".history-tabs__divider").exists()).toBe(false);
    expect(wrapper.find(".timeline-chart").exists()).toBe(false);
    expect(wrapper.find(".bp-champion-list").exists()).toBe(false);
    expect(wrapper.text()).not.toContain("BP 记录");
  });

  it("逐帧数据只在展开那一局时才拉，展开后给出首杀 / 每波团 / 事件流", async () => {
    const wrapper = mountView();
    await settle();
    expect(timelineRequests).toHaveLength(0);

    await wrapper.get(".match-card__head").trigger("click");
    await settle();

    const first = fixtureMatches[0];
    expect(timelineRequests).toEqual([first.gameId]);
    expect(wrapper.get(".match-card").classes()).toContain("is-open");

    const timeline = createFixtureMatchTimeline(first.gameId);
    const summary = wrapper.get(".match-detail__summary").text();
    expect(summary).toContain("首杀");
    expect(summary).toContain("（红方）");
    expect(summary).toContain("击杀");
    expect(summary).toContain("多杀");

    // fixture 里刻意设计了三波团（中路 / 红方下路 / 大龙坑）。
    expect(summary).toContain("3 波");
    expect(wrapper.findAll(".teamfight")).toHaveLength(3);
    expect(wrapper.findAll(".teamfights__pin")).toHaveLength(3);
    expect(wrapper.get(".teamfight__head").text()).toContain("蓝方 3 : 1 红方");
    expect(wrapper.findAll(".teamfight__head").map((item) => item.text())[1]).toContain("1 : 2");
    expect(wrapper.findAll(".teamfight__head").map((item) => item.text())[2]).toContain("3 : 0");

    expect(wrapper.findAll(".match-event")).toHaveLength(timeline.events.length);
    const badges = wrapper.findAll(".match-event__badges i").map((item) => item.text());
    // 第一杀的标记 + 两串多杀的标记 + 每波团的三个人头各挂一次团号。
    for (const badge of ["首杀", "三杀", "双杀", "团1", "团2", "团3"]) expect(badges).toContain(badge);
  });

  it("展开区里同时给出「同场的人」，点名字去战绩页", async () => {
    const wrapper = mountView();
    await settle();
    pushedRoutes.length = 0;

    await wrapper.get(".match-card__head").trigger("click");
    await settle();

    const met = wrapper.get(".match-card__met");
    expect(met.text()).toContain("同场的人");
    const labels = met.findAll(".met-players__label").map((item) => item.text());
    expect(labels[0]).toContain("队友 4");
    expect(labels[1]).toContain("对手 5");
    // fixture 的相遇记录覆盖最近三局，第一局应该全部 join 得上（一个都不能显示「未记录」）。
    expect(met.findAll(".met-players__chip")).toHaveLength(9);

    const expected = fixtureEncounters.filter((record) => record.gameId === fixtureMatches[0].gameId);
    await met.get(".met-players__chip").trigger("click");
    await flushPromises();
    expect(pushedRoutes).toHaveLength(1);
    expect(pushedRoutes[0].path).toBe("/matches");
    expect(pushedRoutes[0].query?.summoner).toContain(expected[0].gameName);
  });

  it("「人」页签按玩家聚合成一行，展开后能看到逐局细节，并能跳战绩页", async () => {
    const wrapper = mountView();
    await settle();

    await tab(wrapper, "人").trigger("click");
    await settle();

    // 原始记录是「每局每人一行」，同一个人 3 局就会出现 3 次；聚合后每人只占一行。
    const uniquePlayers = new Set(fixtureEncounters.map((record) => record.puuid)).size;
    expect(wrapper.findAll(".encounter-table__row")).toHaveLength(uniquePlayers);
    expect(wrapper.findAll(".encounter-detail__row")).toHaveLength(0);

    await wrapper.get(".encounter-table__row").trigger("click");
    await settle();
    expect(wrapper.get(".encounter-table__row").classes()).toContain("is-open");
    // 这套 fixture 里每位玩家都出现在全部 3 局中。
    expect(wrapper.findAll(".encounter-detail__row")).toHaveLength(3);
    // 表头必须解释「他 / 我」两列，否则两串 KDA 只能猜。
    const head = wrapper.get(".encounter-detail__head").text();
    for (const column of ["英雄", "他", "我", "结果"]) expect(head).toContain(column);
    const detail = wrapper.get(".encounter-detail__row");
    expect(detail.findAll(".encounter-detail__side")).toHaveLength(1);
    expect(detail.text()).toMatch(/队友|对手/);
    expect(detail.text()).toContain("单双排");

    pushedRoutes.length = 0;
    const rowName = wrapper.get(".encounter-table__row .encounter-player strong").text().split("#")[0];
    await wrapper.get(".encounter-detail__foot button").trigger("click");
    await flushPromises();
    expect(pushedRoutes).toHaveLength(1);
    expect(pushedRoutes[0].path).toBe("/matches");
    expect(pushedRoutes[0].query?.summoner).toContain(rowName);
  });

  it("首页「关系记录」的深链：切到「人」并直接把那一行展开", async () => {
    // 这个链接是首页写出去的（`/history?player=<puuid>&tab=players`）。不读 query
    // 就等于点了没反应——用户点了一个名字，落到的却是一张要自己再找一遍的表。
    const target = fixtureEncounters[0];
    routeState.query = { tab: "players", player: target.puuid };

    const wrapper = mountView();
    await settle();

    expect(tab(wrapper, "人").classes()).toContain("active");
    expect(wrapper.findAll(".encounter-table__row.is-open")).toHaveLength(1);
    expect(wrapper.get(".encounter-table__row.is-open").text()).toContain(target.gameName);
    expect(wrapper.findAll(".encounter-detail__row")).toHaveLength(3);
  });
});
