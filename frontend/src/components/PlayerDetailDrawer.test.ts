import { flushPromises, mount } from "@vue/test-utils";
import { QueryClient, VueQueryPlugin } from "@tanstack/vue-query";
import type { Plugin } from "vue";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { fixtureEncounters, fixtureLobby, fixtureMatches } from "../fixtures/data";
import PlayerDetailDrawer from "./PlayerDetailDrawer.vue";

const { encounters, matches, matchDetail, push } = vi.hoisted(() => ({ encounters: vi.fn(), matches: vi.fn(), matchDetail: vi.fn(), push: vi.fn() }));

vi.mock("vue-router", () => ({
  useRouter: () => ({ push }),
}));

vi.mock("../services/backend", () => ({
  backend: { encounters, matches, matchDetail },
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
            props: ["match", "expanded", "clickable"],
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
            props: ["match", "expanded", "clickable"],
            template: "<div data-testid='selected-detailed-match' :data-game-id='match.gameId' :data-expanded='String(expanded)' />",
          },
        },
      },
    });
    await flushPromises();

    expect(matches).toHaveBeenCalledWith(`${player.gameName}#${player.tagLine}`, 1, 10);
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
            props: ["match", "expanded", "clickable", "detailLoading", "detailError"],
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