import { mount } from "@vue/test-utils";
import { describe, expect, it, vi } from "vitest";
import { fixtureEncounters, fixtureLobby } from "../fixtures/data";
import type { JunglePathMap } from "../types/domain";
import PlayerCard from "./PlayerCard.vue";

vi.mock("../services/backend", () => ({
  backend: {},
  isTauri: () => false,
}));

vi.mock("../stores/app", () => ({
  useAppStore: () => ({
    mode: "fixture",
    connection: { platformId: "HN1", gameName: "测试账号", tagLine: "TEST" },
    // 不提供 playerTags：标签系统应当按默认值兜底。
    config: {},
  }),
}));

describe("PlayerCard", () => {
  it("renders recent matches, common champions, tags, and at most two positions", () => {
    const player = {
      ...fixtureLobby.ally[1],
      recentMatches: fixtureLobby.ally[1].recentMatches.map((match, index) => ({
        ...match,
        position: index < 5 ? "JUNGLE" : index < 8 ? "MIDDLE" : "TOP",
      })),
    };
    const wrapper = mount(PlayerCard, {
      props: { player, showRecent: true, recentLimit: 10, recentColumns: 2 },
    });

    expect(wrapper.findAll("[data-testid='player-recent-match']")).toHaveLength(10);
    expect(wrapper.find(".bp-player-card__section-label").text()).toContain("最近对局 10场");
    expect(wrapper.findAll(".bp-player-card__recent-mode")).toHaveLength(10);
    expect(wrapper.find(".bp-player-card__recent-mode").text()).toBe(player.recentMatches[0].queueName);
    expect(wrapper.findAll(".bp-player-card__recent-time")).toHaveLength(10);
    expect(wrapper.find(".bp-player-card__recent-time").attributes("datetime")).toBe(player.recentMatches[0].playedAt);
    expect(wrapper.find(".bp-player-card__recent-time").text()).toContain("/");
    expect(wrapper.find(".bp-player-card__recent-time").text()).toContain(`${player.recentMatches[0].durationMinutes}m`);
    expect(wrapper.findAll(".bp-player-card__champion")).toHaveLength(3);
    expect(wrapper.find(".bp-player-card__champions").text()).toContain("常用英雄");
    expect(wrapper.findAll(".bp-player-card__position strong")).toHaveLength(2);
    expect(wrapper.find(".bp-player-card__position").text()).toContain("打野 5场");
    expect(wrapper.find(".bp-player-card__position").text()).toContain("中路 3场");
    expect(wrapper.find(".bp-player-card__queue-ranks").text()).toContain("单双翡翠 I");
    expect(wrapper.find(".bp-player-card__queue-ranks").text()).toContain("灵活铂金 IV");
  });

  it("标签区由注册表驱动渲染统一 chip", () => {
    const wrapper = mount(PlayerCard, { props: { player: fixtureLobby.ally[1] } });

    const area = wrapper.get("[data-testid='player-tags']");
    expect(area.text()).toContain("标签");
    // 所有标签共用同一个 chip 组件与尺寸。
    expect(area.findAll(".tag-chip").length).toBeGreaterThan(0);
  });

  it("uses one recent-match column by default and shows both ranked queues", () => {
    const wrapper = mount(PlayerCard, {
      props: { player: fixtureLobby.ally[0], showRecent: true },
    });

    expect(wrapper.find(".bp-player-card__recent").classes()).toContain("bp-player-card__recent--single");
    expect(wrapper.findAll(".bp-player-card__recent-time")).toHaveLength(10);
    expect(wrapper.find(".bp-player-card__queue-ranks").text()).toContain("单双钻石 II");
    expect(wrapper.find(".bp-player-card__queue-ranks").text()).toContain("灵活黄金 II");
  });

  it("shows explicit empty states when online analysis has no samples", () => {
    const player = {
      ...fixtureLobby.ally[0],
      recentMatches: [],
      topChampions: [],
      tags: [],
      championPoolConcentration: 0,
      isPremade: false,
      premadeWith: [],
    };
    const wrapper = mount(PlayerCard, { props: { player, showRecent: true } });

    expect(wrapper.text()).toContain("暂无最近对局");
    expect(wrapper.text()).toContain("暂无常用英雄");
    expect(wrapper.text()).toContain("暂无标签");
  });

  it("highlights an identified premade even before teammate names resolve", () => {
    const player = {
      ...fixtureLobby.ally[0],
      isPremade: true,
      premadeGroup: null,
      premadeWith: [],
    };
    const wrapper = mount(PlayerCard, { props: { player } });

    expect(wrapper.classes()).toContain("bp-player-card--premade");
    expect(wrapper.classes()).toContain("bp-player-card--premade-unresolved");
    expect(wrapper.find(".bp-player-card__premade").text()).toContain("组队");
    // LeagueAkari 标准：预组队标签必须绑定到分组 id，分组未解析时不渲染该标签。
    expect(wrapper.get("[data-testid='player-tags']").text()).not.toContain("小队");
  });

  it("以 AK 的字母分组渲染预组队标签", () => {
    const player = {
      ...fixtureLobby.ally[0],
      isPremade: true,
      premadeGroup: null,
      premadeWith: [],
    };
    const wrapper = mount(PlayerCard, { props: { player, premadeTone: 1 } });

    const tags = wrapper.get("[data-testid='player-tags']");
    expect(tags.text()).toContain("小队 B");
    expect(wrapper.classes()).toContain("bp-player-card--premade-1");
  });

  it("以统一 chip 呈现「遇到过」，次数收进弹层而不是挤在标签上", () => {
    const player = fixtureLobby.ally[2];
    const wrapper = mount(PlayerCard, { props: { player, encounterRecords: fixtureEncounters } });

    const tags = wrapper.get("[data-testid='player-tags']");
    expect(tags.text()).toContain("遇到过");
    expect(tags.find(".tag-chip--met").exists()).toBe(true);
    // LeagueAkari 标准：chip 只写关系，不写次数。
    expect(tags.text()).not.toContain("遇到过 3 次");
  });

  it("hides encounter tags for a member of the local party", () => {
    const player = fixtureLobby.ally[2];
    const wrapper = mount(PlayerCard, { props: { player, suppressEncounters: true } });

    expect(wrapper.find("[data-testid='player-tags']").text()).not.toContain("遇到过");
  });

  it("opens a specific recent match without firing the generic card selection", async () => {
    const player = fixtureLobby.ally[0];
    const wrapper = mount(PlayerCard, { props: { player, showRecent: true } });

    await wrapper.get("[data-testid='player-recent-match']").trigger("click");

    expect(wrapper.emitted("select-match")).toEqual([[player, player.recentMatches[0].gameId]]);
    expect(wrapper.emitted("select")).toBeUndefined();
  });

  it("把标签区的相遇记录回传给外层，且不触发玩家抽屉", async () => {
    const player = fixtureLobby.ally[2];
    const wrapper = mount(PlayerCard, { props: { player, encounterRecords: fixtureEncounters } });

    // 标签 chip 本身不是按钮：点击卡片仍应选中玩家（与 LeagueAkari 一致），
    // 而逐局详情由弹层内的按钮单独回传。
    await wrapper.get("[data-testid='player-tags'] .tag-chip--met").trigger("click");
    expect(wrapper.emitted("select")).toHaveLength(1);
    expect(wrapper.emitted("select-encounter")).toBeUndefined();
  });

  // 路线图必须摆在卡片上直接看得见，而不是「点开抽屉才看得到」——
  // 所以这块的显隐判定（本局打野 + 有打野样本）单独钉住。
  const junglePathMap: JunglePathMap = {
    games: 3,
    championId: 64,
    zone: { top: 0.3, mid: 0.4, bot: 0.3 },
    camps: {
      blueOwn: { blue: 2, red: 0, wolves: 1, raptors: 0 },
      blueInvade: { blue: 0, red: 0, wolves: 0, raptors: 0 },
      redOwn: { blue: 0, red: 1, wolves: 0, raptors: 0 },
      redInvade: { blue: 0, red: 0, wolves: 0, raptors: 0 },
    },
    level3: 1,
    level4: 2,
    blueGames: 2,
    redGames: 1,
    minutePoints: [{ x: 3830, y: 7880, zone: "bot" }],
    gankPoints: [{ x: 7760, y: 4010, zone: "top" }],
    level3Points: [{ x: 3800, y: 6440, zone: "bot" }],
    level4Points: [],
  };

  it("本局打野的卡片上直接内嵌路线图，不需要点开抽屉", () => {
    // fixture 里 ally[1] 是打野（带 junglePreference），路线图应就地展开。
    const wrapper = mount(PlayerCard, { props: { player: fixtureLobby.ally[1], jungleMap: junglePathMap } });

    const block = wrapper.get("[data-testid='player-card-jungle-map']");
    expect(block.text()).toContain("打野路线图");
    expect(block.text()).toContain("3 局样本");
    // inline 变体：卡片宽度只有 180~260px，塞不下侧栏，只能是正方形自适应 + 两行速览。
    expect(block.find("[data-testid='jungle-route-map']").classes()).toContain("jungle-map--inline");
    expect(block.findAll("[data-testid='jungle-camp-marker']").length).toBeGreaterThan(0);
  });

  it("路线数据还没回来时给出占位文案，不留下空块", () => {
    const wrapper = mount(PlayerCard, { props: { player: fixtureLobby.ally[1], jungleMapLoading: true } });

    const block = wrapper.get("[data-testid='player-card-jungle-map']");
    expect(block.text()).toContain("解析逐帧数据");
    expect(block.find("[data-testid='jungle-route-map']").exists()).toBe(false);
  });

  it("非打野的卡片上不出现路线图", () => {
    // ally[0] 是上单，没有 junglePreference；即使外层误传了数据也不该渲染。
    const wrapper = mount(PlayerCard, { props: { player: fixtureLobby.ally[0], jungleMap: junglePathMap } });

    expect(wrapper.find("[data-testid='player-card-jungle-map']").exists()).toBe(false);
  });
});
