import { flushPromises, mount } from "@vue/test-utils";
import { QueryClient, VueQueryPlugin } from "@tanstack/vue-query";
import { nextTick } from "vue";
import type { Plugin } from "vue";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { fixtureEncounters, fixtureLobby, fixtureMatches } from "../fixtures/data";
import type { PlayerProfile } from "../types/domain";
import PlayerDetailDrawer from "./PlayerDetailDrawer.vue";

const { encounters, matches, matchDetail, junglePath, push } = vi.hoisted(() => ({ encounters: vi.fn(), matches: vi.fn(), matchDetail: vi.fn(), junglePath: vi.fn(), push: vi.fn() }));

vi.mock("vue-router", () => ({
  useRouter: () => ({ push }),
}));

vi.mock("../services/backend", () => ({
  backend: { encounters, matches, matchDetail, junglePath },
  isTauri: () => false,
}));

vi.mock("../stores/app", () => ({
  useAppStore: () => ({
    mode: "fixture",
    connection: { platformId: "HN1", gameName: "测试账号", tagLine: "TEST" },
    config: { providers: { hideUnfinishedMatches: false } },
  }),
}));

const DrawerStub = {
  template: "<div><slot /></div>",
};

const DrawerContentStub = {
  template: "<div><slot name='header' /><slot /></div>",
};

function testPlugins(): (Plugin | [Plugin, ...unknown[]])[] {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return [[VueQueryPlugin, { queryClient }]];
}

describe("PlayerDetailDrawer", () => {
  beforeEach(() => {
    push.mockReset();
    encounters.mockReset();
    matches.mockReset();
    matchDetail.mockReset();
    encounters.mockResolvedValue(structuredClone(fixtureEncounters));
    matches.mockResolvedValue(structuredClone(fixtureMatches));
    matchDetail.mockImplementation(async (gameId: number) => {
      const found = fixtureMatches.find((item) => item.gameId === gameId);
      if (!found) throw new Error("该对局的完整详情不可用");
      return structuredClone(found);
    });
    junglePath.mockReset();
    junglePath.mockResolvedValue(null);
  });

  /**
   * 打野分析排在「分析标签 / 共同战绩 / 组队信息」后面，抽屉打开时默认停在顶部，
   * 所以从卡片上的打野入口进来必须额外滚一次。
   *
   * jsdom 不实现 `scrollIntoView`，这里自己装一个把「滚的是哪个元素」记下来。
   * 抽屉必须 `attachTo` 到 document —— 组件里用 `isConnected` 挡掉「已经不在文档上
   * 的旧目标」，detached 的树会让断言永远看不到滚动。
   */
  const originalScrollIntoView = Element.prototype.scrollIntoView;
  let mountedDrawers: ReturnType<typeof mount>[] = [];

  afterEach(() => {
    // 卸载是必须的：补正滚动挂在 160/420/900ms 的定时器上，不卸载的话
    // 上一个用例的定时器会打进球面下一个用例的 spy（已经踩过一次）。
    for (const drawer of mountedDrawers) drawer.unmount();
    mountedDrawers = [];
    Element.prototype.scrollIntoView = originalScrollIntoView;
  });

  // `player` 是组件的必填 prop，不能用 Record<string, unknown> 兜住——
  // 展开这种索引签名后 `player` 会退化成 unknown，vue-tsc 直接报 TS2322。
  // 只声明这个 helper 真正用到的两个 prop，类型由组件契约本身约束。
  /**
   * 等第一次落位跑完。走的是 `nextFrame`（rAF 退化成 16ms 定时器），所以给一点余量。
   *
   * ⚠️ **别把「等落位」放在断言高亮之前**。高亮由 `focusedSection` 驱动、挂载后同步就有，
   * 但组件里有 1600ms 的自动清除定时器；沙箱负载高时事件循环一次停顿就可能超过 1600ms，
   * 那时 40ms 的等待实际是「等待 1600ms 之后才被调度到」——断言读到的已经是被清掉的状态。
   * 所以顺序固定：先断言高亮（不需要等），再等落位、断言滚到了谁。
   */
  const waitForLanding = () => new Promise((resolve) => setTimeout(resolve, 40));

  async function mountScrolledDrawer(props: { player: PlayerProfile | null; focusSection?: "jungle" | null }) {
    const scrolled: Element[] = [];
    Element.prototype.scrollIntoView = function scrollIntoViewSpy(this: Element) { scrolled.push(this); };
    const wrapper = mount(PlayerDetailDrawer, {
      props: { show: true, ...props },
      attachTo: document.body,
      global: {
        plugins: testPlugins(),
        stubs: { Drawer: DrawerStub, DrawerContent: DrawerContentStub, AssetIcon: true, EncounterMatchModal: true },
      },
    });
    mountedDrawers.push(wrapper);
    await flushPromises();
    await nextTick();
    return { wrapper, scrolled };
  }

  it("从卡片打野入口进来时滚到打野分析那一段", async () => {
    // fixture 里只有打野位带 junglePreference，抽屉里才会有那一段。
    const { wrapper, scrolled } = await mountScrolledDrawer({ player: fixtureLobby.ally[1], focusSection: "jungle" });

    const section = wrapper.get("[data-testid='jungle-preference']");
    // 滚到位还不够，得闪一下，否则「停在某一屏」看不出该看哪儿。
    // 先读高亮，再等落位——理由见 `waitForLanding` 上面那段。
    expect(section.attributes("data-focus")).toBe("true");
    await waitForLanding();
    expect(scrolled).toContain(section.element);
  });

  /**
   * 「不滚」这类**否定断言**必须等过全部补正窗口才成立。
   *
   * 组件会把同一个目标在 0 / 160 / 420 / 900ms 各落一次位（抽屉进入动画与上方异步区块
   * 会持续撑高内容），只等 40ms 等于只否掉了第一次——后面三次照样可能打到这个段上。
   * 所以这里等 1000ms（900 + 余量），`expect(scrolled).toEqual([])` 才是真的。
   */
  const waitForCorrections = () => new Promise((resolve) => setTimeout(resolve, 1000));

  it("普通入口（不指定 focusSection）不滚打野那一段", async () => {
    const { wrapper, scrolled } = await mountScrolledDrawer({ player: fixtureLobby.ally[1] });
    const section = wrapper.get("[data-testid='jungle-preference']");

    expect(section.attributes("data-focus")).toBeUndefined();
    await waitForCorrections();
    expect(scrolled).not.toContain(section.element);
  });

  it("玩家没有打野样本时不硬滚（抽屉里根本没有那一段）", async () => {
    const { wrapper, scrolled } = await mountScrolledDrawer({ player: fixtureLobby.ally[0], focusSection: "jungle" });

    expect(wrapper.find("[data-testid='jungle-preference']").exists()).toBe(false);
    await waitForCorrections();
    expect(scrolled).toEqual([]);
  });

  it("先前玩家的慢请求不会覆盖当前玩家相遇记录", async () => {
    let finishFirst!: (records: typeof fixtureEncounters) => void;
    encounters.mockImplementationOnce(() => new Promise((resolve) => { finishFirst = resolve; }));
    const first = fixtureLobby.ally[2];
    const second = fixtureLobby.enemy[1];
    const secondRecord = { ...fixtureEncounters[0], gameId: 7654321, puuid: second.puuid, gameName: second.gameName, championName: "新玩家英雄" };
    encounters.mockResolvedValueOnce([secondRecord]);
    const wrapper = mount(PlayerDetailDrawer, {
      props: { show: true, player: first },
      global: { plugins: testPlugins(), stubs: { Drawer: DrawerStub, DrawerContent: DrawerContentStub, AssetIcon: true, MatchDetailCard: true, EncounterMatchModal: true } },
    });
    await flushPromises();
    await wrapper.setProps({ player: second });
    await flushPromises();
    finishFirst(structuredClone(fixtureEncounters));
    await flushPromises();
    const rows = wrapper.findAll('[data-testid="met-inspect"]');
    expect(rows).toHaveLength(1);
    expect(rows[0].text()).toContain("7654321");
    expect(wrapper.text()).not.toContain("最近一年");
    wrapper.unmount();
  });

  it("opens the selected player's match history from the drawer identity", async () => {
    const player = fixtureLobby.ally[0];
    const wrapper = mount(PlayerDetailDrawer, {
      props: { show: true, player },
      global: {
        plugins: testPlugins(),
        stubs: {
          Drawer: DrawerStub,
          DrawerContent: DrawerContentStub,
          Button: { template: "<button><slot name='icon' /><slot /></button>" },
          AssetIcon: true,
          MatchDetailCard: true,
        },
      },
    });

    await wrapper.get("[data-testid='player-history-link']").trigger("click");

    expect(wrapper.emitted("update:show")).toEqual([[false]]);
    expect(push).toHaveBeenCalledWith({
      name: "matches",
      query: { summoner: `${player.gameName}#${player.tagLine}` },
    });

    await wrapper.get("[data-testid='player-history-action']").trigger("click");
    expect(push).toHaveBeenCalledTimes(2);
  });

  it("shows both players and opens the complete encountered match", async () => {
    const player = fixtureLobby.ally[2];
    const wrapper = mount(PlayerDetailDrawer, {
      props: { show: true, player, lobby: fixtureLobby },
      global: {
        plugins: testPlugins(),
        stubs: {
          Drawer: DrawerStub,
          DrawerContent: DrawerContentStub,
          Button: { template: "<button><slot name='icon' /><slot /></button>" },
          AssetIcon: true,
          MatchDetailCard: true,
          EncounterMatchModal: { props: ["show", "records", "targetPuuid"], template: "<div data-testid='encounter-modal'>{{ records.length }}</div>" },
        },
      },
    });
    await flushPromises();

    expect(encounters).toHaveBeenCalledWith(player.puuid, 40, Number(fixtureLobby.id) || 0);
    // 「遇到过的对局」分区复用标签系统的表格弹层：两侧玩家一列自己、一列该玩家。
    const table = wrapper.get(".player-drawer__encounters .met-table");
    expect(table.findAll("thead th").map((cell) => cell.text())).toEqual([
      "对局 ID",
      "对局日期",
      "结果",
      "关系",
      "自己",
      player.gameName,
    ]);
    const rows = table.findAll("[data-testid='met-row']");
    expect(rows).toHaveLength(3);
    // 每一行都同时给出自己与该玩家的 KDA。
    expect(rows[0].findAll("td")).toHaveLength(6);
    expect(rows[0].text()).toMatch(/\d+\/\d+\/\d+/);
    await wrapper.get("[data-testid='met-inspect']").trigger("click");
    expect(wrapper.get("[data-testid='encounter-modal']").text()).toBe("9");
  });

  it("loads complete match summaries and expands the selected ten-player match in place", async () => {
    const player = fixtureLobby.ally[2];
    const wrapper = mount(PlayerDetailDrawer, {
      props: { show: true, player },
      global: {
        plugins: testPlugins(),
        stubs: {
          Drawer: DrawerStub,
          DrawerContent: DrawerContentStub,
          Button: { template: "<button><slot name='icon' /><slot /></button>" },
          AssetIcon: true,
          EncounterMatchModal: true,
          MatchDetailCard: {
            props: ["match", "expanded", "expandable"],
            emits: ["toggle"],
            template: "<button data-testid='detailed-match' :data-participants='match.participants ? match.participants.length : 0' :data-expanded='String(expanded)' @click='$emit(\"toggle\")' />",
          },
        },
      },
    });
    await flushPromises();

    expect(matches).toHaveBeenCalledWith(`${player.gameName}#${player.tagLine}`, 0, 10);
    expect(wrapper.findAll("[data-testid='detailed-match']")).toHaveLength(10);
    expect(wrapper.get("[data-testid='detailed-match']").attributes("data-participants")).toBe("10");
    expect(wrapper.get("[data-testid='detailed-match']").attributes("data-expanded")).toBe("false");

    await wrapper.get("[data-testid='detailed-match']").trigger("click");
    expect(wrapper.get("[data-testid='detailed-match']").attributes("data-expanded")).toBe("true");
  });

  it("loads the selected match page and expands that match immediately", async () => {
    const selected = { ...structuredClone(fixtureMatches[0]), gameId: 999_999 };
    const player = {
      ...structuredClone(fixtureLobby.ally[2]),
      recentMatches: [...structuredClone(fixtureLobby.ally[2].recentMatches), { ...selected, win: true }],
    };
    matches.mockResolvedValueOnce([selected]);
    const wrapper = mount(PlayerDetailDrawer, {
      props: { show: true, player, initialMatchId: selected.gameId },
      global: {
        plugins: testPlugins(),
        stubs: {
          Drawer: DrawerStub,
          DrawerContent: DrawerContentStub,
          Button: { template: "<button><slot name='icon' /><slot /></button>" },
          AssetIcon: true,
          EncounterMatchModal: true,
          MatchDetailCard: {
            props: ["match", "expanded", "expandable"],
            template: "<div data-testid='selected-detailed-match' :data-game-id='match.gameId' :data-expanded='String(expanded)' />",
          },
        },
      },
    });
    await flushPromises();

    // 目标那一局排在第二页（索引 10+）：抽屉必须把请求深度补到覆盖它，
    // 否则自动展开会落空。后端总是先拉满 50 场窗口再本地切片，所以用
    // 「起点 0 + 已加载条数」一次拿齐，不必按页并发再拼。
    expect(matches).toHaveBeenCalledWith(`${player.gameName}#${player.tagLine}`, 0, 20);
    expect(wrapper.get("[data-testid='selected-detailed-match']").attributes("data-game-id")).toBe(String(selected.gameId));
    expect(wrapper.get("[data-testid='selected-detailed-match']").attributes("data-expanded")).toBe("true");
  });

  it("fetches the full ten-player detail for the expanded match", async () => {
    const player = fixtureLobby.ally[2];
    const local = fixtureLobby.ally[0];
    // 列表接口只给查询者本人一条 participants；完整十人数据要按 gameId 再拉一次。
    const listed = { ...structuredClone(fixtureMatches[0]), participants: [structuredClone(fixtureMatches[0].participants[0])] };
    const full = { ...structuredClone(fixtureMatches[0]), championName: "十人详情" };
    matches.mockResolvedValueOnce([listed]);
    matchDetail.mockResolvedValueOnce(full);
    const wrapper = mount(PlayerDetailDrawer, {
      props: { show: true, player, localPlayer: local },
      global: {
        plugins: testPlugins(),
        stubs: {
          Drawer: DrawerStub,
          DrawerContent: DrawerContentStub,
          Button: { template: "<button><slot name='icon' /><slot /></button>" },
          AssetIcon: true,
          EncounterMatchModal: true,
          MatchDetailCard: {
            props: ["match", "expanded", "expandable", "detailLoading", "detailError"],
            emits: ["toggle"],
            template: "<button data-testid='detail-row' :data-champion='match.championName' :data-participants='match.participants ? match.participants.length : 0' :data-expanded='String(expanded)' @click='$emit(\"toggle\")' />",
          },
        },
      },
    });
    await flushPromises();
    expect(wrapper.get("[data-testid='detail-row']").attributes("data-participants")).toBe("1");
    expect(matchDetail).not.toHaveBeenCalled();

    await wrapper.get("[data-testid='detail-row']").trigger("click");
    await flushPromises();

    // selfPuuid 是账号归属（当前登录的我），targetPuuid / subjectPuuid 都是被查看的玩家：
    // 那一局里通常没有我，所以行内视角必须是「他」。
    expect(matchDetail).toHaveBeenCalledWith(listed.gameId, "HN1", local.puuid, player.puuid, player.puuid);
    const row = wrapper.get("[data-testid='detail-row']");
    expect(row.attributes("data-expanded")).toBe("true");
    expect(row.attributes("data-champion")).toBe("十人详情");
    expect(row.attributes("data-participants")).toBe("10");
  });

  it("roster 轮询换掉 player 对象引用时不会收起已展开的对局", async () => {
    // LiveView 每 1.2~1.5s 会用后端快照重建 roster，`selectedPlayer` 因此每次都是
    // 新对象：同 puuid、新引用。抽屉的 watch 不能因此把 expandedMatchId 重置为 null
    // （否则用户手动展开的下拉框一秒后自己收回）。
    const player = fixtureLobby.ally[2];
    const wrapper = mount(PlayerDetailDrawer, {
      props: { show: true, player },
      global: {
        plugins: testPlugins(),
        stubs: {
          Drawer: DrawerStub,
          DrawerContent: DrawerContentStub,
          Button: { template: "<button><slot name='icon' /><slot /></button>" },
          AssetIcon: true,
          EncounterMatchModal: true,
          MatchDetailCard: {
            props: ["match", "expanded", "expandable", "detailLoading", "detailError"],
            emits: ["toggle"],
            template: "<button class='poll-row' :data-game-id='match.gameId' :data-expanded='String(expanded)' @click='$emit(\"toggle\")' />",
          },
        },
      },
    });
    await flushPromises();

    const targetGameId = fixtureMatches[1].gameId;
    const rowFor = () => wrapper.findAll(".poll-row").find((row) => row.attributes("data-game-id") === String(targetGameId))!;
    await rowFor().trigger("click");
    await flushPromises();
    expect(rowFor().attributes("data-expanded")).toBe("true");

    // 同 puuid、新对象引用 —— 相当于一次 roster 轮询。
    await wrapper.setProps({ player: { ...player } });
    await flushPromises();
    expect(rowFor().attributes("data-expanded")).toBe("true");

    // 真的换了人（不同 puuid）时才应该清空展开态。
    await wrapper.setProps({ player: { ...player, puuid: "another-puuid" } });
    await flushPromises();
    expect(rowFor().attributes("data-expanded")).toBe("false");

    wrapper.unmount();
  });

  it("does not load or show encounter history for a member of the local party", async () => {
    const player = fixtureLobby.ally[2];
    const wrapper = mount(PlayerDetailDrawer, {
      props: { show: true, player, suppressEncounters: true },
      global: {
        plugins: testPlugins(),
        stubs: {
          Drawer: DrawerStub,
          DrawerContent: DrawerContentStub,
          Button: { template: "<button><slot name='icon' /><slot /></button>" },
          AssetIcon: true,
          MatchDetailCard: true,
          EncounterMatchModal: true,
        },
      },
    });
    await flushPromises();

    expect(encounters).not.toHaveBeenCalled();
    expect(wrapper.text()).not.toContain("遇到过的对局");
    expect(wrapper.find("[data-testid='player-tags'] .tag-chip--met").exists()).toBe(false);
  });
});