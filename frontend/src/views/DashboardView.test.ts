import { QueryClient, VueQueryPlugin } from "@tanstack/vue-query";
import { flushPromises, mount } from "@vue/test-utils";
import { beforeEach, describe, expect, it } from "vitest";
import DashboardView from "./DashboardView.vue";
import { fixtureMatches } from "../fixtures/data";

/**
 * 首页最近对局展开后要接上「完整对局详情」（观战面板 + 每波团 + 事件流）。
 *
 * 用户反馈原话：「首页的下边怎么没有对应的明细图表」——这一页原来只挂了
 * `MatchDetailCard`，没往它的 `#deep` 插槽里塞东西，所以展开到十人表就没了。
 *
 * 这条用例只钉两件事，别的由 `MatchDeepDetail` 自己的用例管：
 * - **挂的是真组件**（`.match-deep` 存在），不是空插槽——空插槽看起来「接上了」，
 *   实际一个像素都不显示；
 * - **没展开就不取数**（`champions` / 100 条的 `encounters` 一次都不该发），
 *   首页首屏不能为一个还没打开的展开区白花两个请求。
 */
const { backendState } = vi.hoisted(() => ({
  backendState: { matchRows: [] as unknown[], deepEncounterCalls: 0, championCalls: 0 },
}));

vi.mock("vue-router", () => ({
  useRoute: () => ({ query: {} }),
  useRouter: () => ({ replace: async () => {} }),
}));

vi.mock("naive-ui", () => ({
  NButton: { inheritAttrs: false, template: "<button><slot /></button>" },
  NPopover: { inheritAttrs: false, template: "<span><slot /></span>" },
  useMessage: () => ({ info: () => {}, warning: () => {}, success: () => {}, error: () => {} }),
}));

vi.mock("../stores/app", async () => {
  const { fixtureConfig } = await import("../fixtures/data");
  return {
    useAppStore: () => ({
      mode: "fixture",
      initialized: true,
      config: fixtureConfig,
      bootstrap: { dashboard: { recentMatches: [], recentEncounters: [] } },
      connection: {
        status: "connected",
        phase: "ChampSelect",
        summonerName: "本地玩家",
        gameName: "本地玩家",
        tagLine: "CN1",
        puuid: "self-puuid",
        summonerLevel: 318,
        profileIconId: 1,
        platformId: "HN1",
        region: "HN1",
        presence: "online",
        soloRank: null,
        flexRank: null,
        queueLabel: null,
        message: null,
        checkedAt: "2026-09-22T00:00:00.000Z",
      },
    }),
  };
});

vi.mock("../services/backend", () => ({
  isTauri: () => false,
  backend: {
    matches: async () => backendState.matchRows as never,
    encounters: async (_puuid?: string, limitGames = 40) => {
      // 首页自己那条关系记录用 40 条的窗口；深详情用的是 100 条那一份。分开数。
      if (limitGames === 100) backendState.deepEncounterCalls += 1;
      return [];
    },
    champions: async () => {
      backendState.championCalls += 1;
      return [];
    },
    // 深详情（`MatchDeepDetail`）自己取数，缺一个就会在挂载时抛异常。
    matchDetail: async () => null,
    matchTimeline: async () => null,
    gameRecording: async () => ({ gameId: 0, intervalSeconds: 5, recordedGames: 0, frames: [] }),
  },
}));

/**
 * 卡片桩要**照着真卡片复刻「展开才渲染插槽」**这一条，否则测不出闸门：
 * 一个无条件渲染 `<slot name="deep" />` 的桩会让「没展开也不取数」这条断言失去意义。
 */
const cardStub = {
  props: ["expanded"],
  emits: ["toggle"],
  template: '<div class="card-probe"><button class="card-probe__toggle" @click="$emit(\'toggle\')" /><slot v-if="expanded" name="deep" /></div>',
};

function mountView() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return mount(DashboardView, {
    global: {
      plugins: [[VueQueryPlugin, { queryClient }]],
      stubs: {
        // 模板里的 `<RouterLink>` 没有在 `<script setup>` 里 import（真机由路由插件全局注册），
        // 测试里必须显式给桩，否则 Vue 会一直报 "Failed to resolve component"。
        RouterLink: { template: "<a><slot /></a>" },
        MatchDetailCard: cardStub,
        LoadingState: { template: "<div />" },
        AssetIcon: { template: "<i />" },
      },
    },
  });
}

describe("DashboardView 的完整详情", () => {
  beforeEach(() => {
    backendState.matchRows = [structuredClone(fixtureMatches[0])];
    backendState.deepEncounterCalls = 0;
    backendState.championCalls = 0;
  });

  it("展开一行后挂上真的 MatchDeepDetail，且展开前一次深详情请求都不发", async () => {
    const wrapper = mountView();
    await flushPromises();

    // ① 没展开：插槽不渲染，深详情的两样入参也不去取。
    expect(wrapper.find(".card-probe").exists()).toBe(true);
    expect(wrapper.find(".match-deep").exists()).toBe(false);
    expect(backendState.deepEncounterCalls).toBe(0);
    expect(backendState.championCalls).toBe(0);

    // ② 点开箭头：插槽里出现的必须是真组件（不是空插槽）。
    await wrapper.get(".card-probe__toggle").trigger("click");
    await flushPromises();
    expect(wrapper.findAll(".card-probe .match-deep")).toHaveLength(1);
    expect(backendState.deepEncounterCalls).toBeGreaterThan(0);
    expect(backendState.championCalls).toBeGreaterThan(0);
  });
});
