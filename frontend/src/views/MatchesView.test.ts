import { QueryClient, VueQueryPlugin } from "@tanstack/vue-query";
import { flushPromises, mount } from "@vue/test-utils";
import { describe, expect, it } from "vitest";
import MatchesView from "./MatchesView.vue";
import { fixtureConfig, fixtureMatches } from "../fixtures/data";

/**
 * 这一层只盯「账号信息条」这一件事（用户反馈过战绩页看不到等级和段位）：
 * - 没在查别人时读**当前账号**（数据来自连接状态，不发请求）；
 * - 在查别人时改读**被查玩家**，并且跨区拿不到数据时显示「—」而不是「无段位」。
 * 对局列表本身有别的用例覆盖，这里让它空着。
 */
const { route, backendState } = vi.hoisted(() => ({
  route: { query: {} as Record<string, unknown> },
  backendState: { matchRows: [] as unknown[] },
}));

vi.mock("vue-router", () => ({
  useRoute: () => route,
  useRouter: () => ({ replace: async () => {} }),
}));

vi.mock("naive-ui", () => ({
  // 三个桩都关掉 attrs 透传：否则 `:options` / `:size` 会被当成原生 DOM 属性塞给
  // <select> / <input>，触发 "Failed setting prop options" 这类只读属性报错。
  NButton: { inheritAttrs: false, template: "<button><slot /></button>" },
  NInput: { inheritAttrs: false, props: ["value"], template: "<input />" },
  NSelect: { inheritAttrs: false, props: ["value"], template: "<select />" },
  useMessage: () => ({ info: () => {}, warning: () => {}, success: () => {}, error: () => {} }),
}));

vi.mock("../stores/app", async () => {
  const { fixtureConfig } = await import("../fixtures/data");
  return {
    useAppStore: () => ({
      mode: "fixture",
      initialized: true,
      config: fixtureConfig,
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
        soloRank: { queueType: "RANKED_SOLO_5x5", tier: "EMERALD", division: "II", leaguePoints: 63, wins: 62, losses: 49 },
        flexRank: { queueType: "RANKED_FLEX_SR", tier: "GOLD", division: "II", leaguePoints: 31, wins: 38, losses: 34 },
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
    encounters: async () => [],
    friends: async () => ({ groups: [], friends: [] }),
    matchDetail: async () => null,
    // 深详情（`MatchDeepDetail`）还要这几样：面板自己取数，缺一个就会在挂载时抛异常。
    matchTimeline: async () => null,
    champions: async () => [],
    gameRecording: async () => ({ gameId: 0, intervalSeconds: 5, recordedGames: 0, frames: [] }),
    // 被查玩家的等级和段位由这个命令补回来（真机上是本地 LCU 的响应）。
    searchSummoner: async (query: string) => ({
      query,
      hasTag: true,
      requiresTag: false,
      candidates: [
        {
          gameName: "对手",
          tagLine: "1234",
          puuid: "enemy-puuid",
          summonerLevel: 99,
          soloRank: { queueType: "RANKED_SOLO_5x5", tier: "DIAMOND", division: "IV", leaguePoints: 12, wins: 30, losses: 28 },
          flexRank: null,
        },
      ],
    }),
  },
}));

function mountView() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return mount(MatchesView, {
    global: {
      plugins: [[VueQueryPlugin, { queryClient }]],
      stubs: {
        PageHeader: { template: "<header><slot /></header>" },
        LoadingState: { template: "<div />" },
        MatchDetailCard: { template: "<div />" },
        MatchHistoryDetail: { template: "<div />" },
        AssetIcon: { template: "<i />" },
      },
    },
  });
}

describe("MatchesView 账号信息条", () => {
  it("未查询他人时显示当前账号的等级与两个段位", async () => {
    route.query = {};
    const wrapper = mountView();
    await flushPromises();

    const strip = wrapper.get('[data-testid="matches-account-strip"]').text();
    expect(strip).toContain("当前账号");
    expect(strip).toContain("本地玩家#CN1");
    expect(strip).toContain("Lv.318");
    expect(strip).toContain("翡翠 II · 63 LP");
    expect(strip).toContain("黄金 II · 31 LP");
    // 没查别人就不该去解析别人。
    expect(strip).not.toContain("正在查看");
  });

  it("查询他人时改显示对方的等级与段位", async () => {
    route.query = { summoner: "对手#1234" };
    const wrapper = mountView();
    await flushPromises();

    const strip = wrapper.get('[data-testid="matches-account-strip"]').text();
    expect(strip).toContain("正在查看");
    expect(strip).toContain("对手#1234");
    expect(strip).toContain("Lv.99");
    expect(strip).toContain("钻石 IV · 12 LP");
    // 灵活段位缺失时是「—」，不能写成「未定级」——那是另一件事。
    expect(strip).toContain("—");
    expect(strip).not.toContain("未定级");
    expect(strip).not.toContain("Lv.318");
  });
});

describe("MatchesView 过滤口径", () => {
  it("「仅显示排位」不在前端二次筛选，采信数据源返回的那一页", async () => {
    backendState.matchRows = [
      { ...fixtureMatches[0], gameId: 9001, queueId: 420, queueName: "单双排" },
      { ...fixtureMatches[1], gameId: 9002, queueId: 450, queueName: "极地大乱斗" },
    ];
    const previous = fixtureConfig.providers.rankedOnly;
    fixtureConfig.providers.rankedOnly = true;
    try {
      route.query = {};
      const wrapper = mountView();
      await flushPromises();

      // 后端是**先筛选再分页**（`matchHistoryDtoPageWithFilters`，有同名后端用例守着），
      // 所以打开开关时返回的这一页本来就全是排位。前端再筛一遍不加信息量，反而会在
      // 开关刚切换、配置还没落到后端时把整页削成几条——用户看到的就是
      // 「只把上一次请求的结果过了一遍」。这里锁死：返回什么就显示什么。
      expect(wrapper.text()).toContain("显示 2 条");
    } finally {
      fixtureConfig.providers.rankedOnly = previous;
      backendState.matchRows = [];
    }
  });
});

/**
 * 历史页那套「完整详情」（观战面板 + 每波团 + 事件流）在战绩页**两种模式里都要挂上**，
 * 而且必须是同一份组件——用户的要求原话是「抽离成组件…只要维护一套就够了，两个地方都可以看」。
 *
 * 这条用例只钉「挂没挂上 + 是不是同一块」：具体画什么由 `MatchDeepDetail` 自己的用例管。
 */
describe("MatchesView 的完整详情复用", () => {
  const viewStubs = (card: object) => ({
    PageHeader: { template: "<header><slot /></header>" },
    LoadingState: { template: "<div />" },
    MatchDetailCard: card,
    MatchHistoryDetail: { template: "<div />" },
    AssetIcon: { template: "<i />" },
  });
  const mountWith = async (card: object) => {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    const wrapper = mount(MatchesView, { global: { plugins: [[VueQueryPlugin, { queryClient }]], stubs: viewStubs(card) } });
    await flushPromises();
    return wrapper;
  };

  it("索引模式的右栏下面挂一块，完整对局模式则通过插槽塞进展开区", async () => {
    backendState.matchRows = [structuredClone(fixtureMatches[0])];
    const previous = typeof localStorage === "undefined" ? null : localStorage.getItem("lol-desktop-match-view");
    try {
      route.query = {};

      // ① 索引模式：右栏详情卡下面。
      localStorage.setItem("lol-desktop-match-view", "index");
      const indexed = await mountWith({ template: "<div />" });
      expect(indexed.find(".matches-deep").exists()).toBe(true);

      // ② 完整对局模式（默认模式）：插槽里的东西得是**真的** MatchDeepDetail，
      //    不是空插槽——空插槽看起来「挂上了」，实际什么都不显示。
      localStorage.setItem("lol-desktop-match-view", "detail");
      const detailed = await mountWith({ template: '<div class="card-probe"><slot name="deep" /></div>' });
      expect(detailed.find(".card-probe .match-deep").exists()).toBe(true);
      expect(detailed.findAll(".card-probe .match-deep")).toHaveLength(1);
    } finally {
      backendState.matchRows = [];
      if (previous === null) localStorage.removeItem("lol-desktop-match-view");
      else localStorage.setItem("lol-desktop-match-view", previous);
    }
  });
});
