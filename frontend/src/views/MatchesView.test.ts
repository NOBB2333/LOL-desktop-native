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
  backendState: { matchRows: [] as unknown[], matchesError: "", regionProbe: null as unknown, searchCandidates: null as unknown },
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
    matches: async () => {
      if (backendState.matchesError) throw new Error(backendState.matchesError);
      return backendState.matchRows as never;
    },
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
      regions: backendState.regionProbe ?? undefined,
      // `searchCandidates` 置空数组可以造出「压根没解析到人」的形状：
      // 那是「都没这个人」唯一有资格说出口的场合（见下面那两条用例）。
      candidates: (backendState.searchCandidates ?? [
        {
          gameName: "对手",
          tagLine: "1234",
          puuid: "enemy-puuid",
          summonerLevel: 99,
          soloRank: { queueType: "RANKED_SOLO_5x5", tier: "DIAMOND", division: "IV", leaguePoints: 12, wins: 30, losses: 28 },
          flexRank: null,
        },
      ]) as never,
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

/**
 * 「全大区搜索」必须看得见。
 *
 * 用户原话：「全大区搜索你最起码显示一下吧，说当前大区搜不到，然后在哪个正在搜哪个大区、
 * 搜索结果什么的」。跨区玩家在本区是**搜得到人、查不到战绩**的，不把大区亮出来，
 * 用户的结论就是「搜不到」。
 */
describe("MatchesView 的全大区搜索提示", () => {
  const submitSearch = async (query: string) => {
    route.query = { summoner: query };
    const wrapper = mountView();
    await flushPromises();
    await wrapper.get(".matches-query-form").trigger("submit");
    await flushPromises();
    return wrapper;
  };

  it("定位到别的玩家在另一个大区时，列出搜过的大区与命中项", async () => {
    backendState.regionProbe = {
      located: "CQ100",
      probed: [
        { serverId: "TJ101", found: false },
        { serverId: "TJ100", found: false },
        { serverId: "CQ100", found: true },
      ],
    };
    try {
      const wrapper = await submitSearch("对手#1234");
      const note = wrapper.get('[data-testid="matches-region-probe"]');

      // 结论：搜了 3 个区、人在**联盟三区**（`CQ100`），并且说清楚**不是**本机所在的区。
      //
      // ⚠️ 这里的大区名只能是 `utils/format.ts` 那一份：`CQ100` 是「联盟三区」，
      // `HN1` 是「艾欧尼亚」。以前战绩页自己抄过一张表，把它们写成「重庆一区」
      // 和「河南一区」——名字错不会报错，只会让用户以为搜索坏了（用户实报）。
      expect(note.text()).toContain("已搜索 3 个大区");
      expect(note.text()).toContain("联盟三区");
      // 本机大区取自 `connection.platformId`（这个用例里是 HN1 = 艾欧尼亚），
      // 必须点明「命中的不是本机那个区」，否则用户还是不知道为什么要跨区取。
      expect(note.text()).toContain("不是本机所在的艾欧尼亚");

      // 逐区痕迹：3 个胶囊，只有命中那个标「命中」。
      expect(note.findAll(".matches-region-probe__chip")).toHaveLength(3);
      expect(note.findAll('.matches-region-probe__chip[data-found="true"]')).toHaveLength(1);
      expect(note.get('.matches-region-probe__chip[data-found="true"]').text()).toContain("联盟三区");
      // 错名字一个都不许再冒出来。
      expect(note.text()).not.toContain("重庆一区");
      expect(note.text()).not.toContain("河南一区");
    } finally {
      backendState.regionProbe = null;
    }
  });

  /**
   * **账号解析到了、逐区定位失败时，不许说「都没这个人」。**
   *
   * 这是 2026-10-03 用户实报形状的回归锁：精确匹配命中 1 个账号，下面紧接着
   * 「8 个大区全问过一遍，都没这个人」—— 自相矛盾。人明明已经解析出来了，
   * 真正的故障是**逐区定位**（`summoner-ledge`）没能问出他属于哪个大区，
   * 而那句话把故障归因成了「这个人不存在」，方向完全错了。
   */
  it("账号已解析但逐区定位失败时，说的是定位失败而不是「没这个人」", async () => {
    backendState.regionProbe = {
      located: null,
      probed: ["TJ101", "TJ100", "CQ100"].map((serverId) => ({ serverId, found: false })),
    };
    try {
      const wrapper = await submitSearch("对手#1234");
      const text = wrapper.get('[data-testid="matches-region-probe"]').text();

      expect(text).toContain("都没能定位到这个账号");
      expect(text).not.toContain("都没这个人");
      expect(wrapper.findAll('.matches-region-probe__chip[data-found="true"]')).toHaveLength(0);
    } finally {
      backendState.regionProbe = null;
    }
  });

  it("真的一个候选都没解析到时，才说各大区都没这个人", async () => {
    backendState.regionProbe = {
      located: null,
      probed: ["TJ101", "TJ100", "CQ100"].map((serverId) => ({ serverId, found: false })),
    };
    backendState.searchCandidates = [];
    try {
      const wrapper = await submitSearch("查无此人#9999");
      const text = wrapper.get('[data-testid="matches-region-probe"]').text();

      expect(text).toContain("搜不到");
      expect(text).toContain("都没这个人");
      expect(text).not.toContain("定位");
      expect(wrapper.findAll('.matches-region-probe__chip[data-found="true"]')).toHaveLength(0);
    } finally {
      backendState.regionProbe = null;
      backendState.searchCandidates = null;
    }
  });

  /**
   * 取战绩失败必须说出来。
   *
   * 以前这里是**完全静默**的：`get_match_history` 抛错 → `rows` 是空数组 →
   * 页面只剩一句「没有匹配的对局」。跨区玩家最容易撞上（解析成功、大区也定位到了，
   * 死在取战绩那一步），用户看到的却是「搜不到人」。
   */
  it("取战绩失败时给出可操作的说明，而不是只留一个空列表", async () => {
    backendState.matchesError = "LcuRequestFailed";
    try {
      route.query = {};
      const wrapper = mountView();
      await flushPromises();

      const note = wrapper.get('[data-testid="matches-error"]');
      expect(note.text()).toContain("取战绩失败");
      expect(note.text()).toContain("跨区");
      // 原始错误也要带上，方便反馈时定位。
      expect(note.text()).toContain("LcuRequestFailed");
    } finally {
      backendState.matchesError = "";
    }
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
