import { mount } from "@vue/test-utils";
import { describe, expect, it, vi } from "vitest";
import { fixtureLobby, fixtureMatches } from "../fixtures/data";
import MatchDetailCard from "./MatchDetailCard.vue";

vi.mock("../services/backend", () => ({
  backend: {},
  isTauri: () => false,
}));

describe("MatchDetailCard", () => {
  it("never labels a lost match as carried or a free win", () => {
    const match = {
      ...structuredClone(fixtureLobby.ally[0].recentMatches[0]),
      durationMinutes: 28,
      win: false,
      performance: "carried" as const,
    };
    const wrapper = mount(MatchDetailCard, {
      props: { match },
      global: { stubs: { AssetIcon: true, MatchRecordingPanel: true } },
    });

    expect(wrapper.text()).not.toContain("躺赢局");
    expect(wrapper.find(".match-row__badge").text()).toBe("正常");
  });

  it("renders all ten participants in the expanded detail", () => {
    const match = structuredClone(fixtureMatches[0]);
    const wrapper = mount(MatchDetailCard, {
      props: { match, expanded: true },
      global: { stubs: { AssetIcon: true, MatchRecordingPanel: true } },
    });

    expect(match.participants).toHaveLength(10);
    expect(wrapper.findAll(".participant-line")).toHaveLength(10);
    expect(wrapper.findAll(".participant-team")).toHaveLength(2);
  });

  /**
   * 两个召唤师技能必须贴在**头像右边**（跟外面的对局行同一套读法），不能排到
   * 装备后面去占格子：以前它们排在装备右面，列宽一挤就把装备整片裁掉，
   * 看起来像「技能格把装备挡住了」。
   */
  it("keeps the summoner spells next to the champion avatar, not after the items", () => {
    const wrapper = mount(MatchDetailCard, {
      props: { match: structuredClone(fixtureMatches[0]), expanded: true },
      global: { stubs: { AssetIcon: true, MatchRecordingPanel: true } },
    });

    const children = Array.from(wrapper.get(".participant-line").element.children)
      .map((node) => node.getAttribute("class") ?? "");
    expect(children[0]).toContain("participant-line__champion");
    expect(children[1]).toContain("participant-line__spells");
    expect(children[2]).toContain("participant-line__identity");
    // 装备与符文继续排在名字/数据右边，不再被技能夹在中间。
    expect(children.findIndex((name) => name.includes("participant-line__items")))
      .toBeGreaterThan(children.findIndex((name) => name.includes("participant-line__identity")));
  });

  /** 十人明细的装备栏固定 7 格：6 件装备 + 最后一格饰品/视野位。 */
  it("draws seven item slots with the trinket last", () => {
    const wrapper = mount(MatchDetailCard, {
      props: { match: structuredClone(fixtureMatches[0]), expanded: true },
      global: { stubs: { AssetIcon: true, MatchRecordingPanel: true } },
    });

    const items = wrapper.get(".participant-line .participant-line__items").element;
    expect(items.children).toHaveLength(7);
    expect(items.children[6].getAttribute("class")).toContain("participant-line__item-slot--trinket");
  });

  /**
   * 装备必须待在**客户端给的格子号**上：中间卖掉一件装备后，后面的装备不能整体前移,
   * 否则最后一格就看不出是饰品了。这条用例只给 0 / 5 / 6 三格，验中间是空格。
   */
  it("keeps items on their client slot instead of shifting them left", () => {
    const match = structuredClone(fixtureMatches[0]);
    match.participants[0].items = [
      { id: 6655, name: "卢登的伙伴", iconUrl: "", slot: 0 },
      { id: 3089, name: "灭世者的死亡之帽", iconUrl: "", slot: 5 },
      { id: 3340, name: "警觉眼石", iconUrl: "", slot: 6 },
    ];
    const wrapper = mount(MatchDetailCard, {
      props: { match, expanded: true },
      global: { stubs: { AssetIcon: true, MatchRecordingPanel: true } },
    });

    const slots = Array.from(wrapper.get(".participant-line .participant-line__items").element.children);
    expect(slots).toHaveLength(7);
    // 只给了 0 / 5 / 6 三格 → 中间 4 个是空格（占位符），最后两格是装备。
    expect(slots.filter((node) => (node.getAttribute("class") ?? "").includes("participant-line__item-slot"))).toHaveLength(4);
    expect(slots[5].getAttribute("class") ?? "").not.toContain("participant-line__item-slot");
    expect(slots[6].getAttribute("class") ?? "").not.toContain("participant-line__item-slot");
  });

  /**
   * 战绩列表接口每局只带查询者一条 participants，参团率的分母（队伍击杀）等于自己
   * 的击杀数，算出来恒定 100%。后端现在写 `null`，界面必须显示「—」而不是编一个数。
   */
  it("shows a dash instead of a fake 100% participation when the squad is unknown", () => {
    const row = { ...structuredClone(fixtureLobby.ally[0].recentMatches[0]), killParticipation: null };
    const wrapper = mount(MatchDetailCard, {
      props: { match: row },
      global: { stubs: { AssetIcon: true, MatchRecordingPanel: true } },
    });

    expect(wrapper.get(".match-row__kda small").text()).toBe("— 参团");
  });

  it("keeps the row expanded when the detail area itself is clicked", async () => {
    const wrapper = mount(MatchDetailCard, {
      props: { match: structuredClone(fixtureMatches[0]), expanded: true },
      global: { stubs: { AssetIcon: true, MatchRecordingPanel: true } },
    });

    // 详情区是行的子节点：在里面点任何地方（选文字、点图标）都不该把行收回去。
    await wrapper.get(".match-row__detail").trigger("click");
    await wrapper.get(".participant-line").trigger("click");
    expect(wrapper.emitted("toggle")).toBeUndefined();

    // 摘要区与右上角箭头才负责切换。
    await wrapper.get(".match-row__identity").trigger("click");
    expect(wrapper.emitted("toggle")).toHaveLength(1);
    await wrapper.get(".match-row__toggle").trigger("click");
    expect(wrapper.emitted("toggle")).toHaveLength(2);
  });

  it("explains the single-participant stub while the full detail loads", () => {
    const full = structuredClone(fixtureMatches[0]);
    const stub = { ...full, participants: [full.participants[0]] };
    const wrapper = mount(MatchDetailCard, {
      props: { match: stub, expanded: true, detailLoading: true },
      global: { stubs: { AssetIcon: true, MatchRecordingPanel: true } },
    });

    expect(wrapper.get(".match-row__detail-status").text()).toContain("正在读取");
  });

  it("warns instead of pretending when the full detail failed", () => {
    const full = structuredClone(fixtureMatches[0]);
    const stub = { ...full, participants: [full.participants[0]] };
    const wrapper = mount(MatchDetailCard, {
      props: { match: stub, expanded: true, detailError: "这局的完整十人数据读取失败" },
      global: { stubs: { AssetIcon: true, MatchRecordingPanel: true } },
    });

    const status = wrapper.get(".match-row__detail-status");
    expect(status.text()).toContain("读取失败");
    expect(status.attributes("data-tone")).toBe("warning");
  });

  /**
   * 首页 / 对局页的行是列表级数据（只有查询者本人一条 participants），
   * 展开能力由宿主的 `useMatchDetail` 补上，所以必须显式 `expandable`。
   * 这条用例锁住「显式允许后箭头与详情都出来」以及「不传时保持不可展开」。
   */
  it("list-level rows only expand when the host allows it", async () => {
    // 列表级数据就是 RecentMatch：根本没有 `participants` 这个键。
    const row = structuredClone(fixtureLobby.ally[0].recentMatches[0]);

    const plain = mount(MatchDetailCard, {
      props: { match: row, expanded: true },
      global: { stubs: { AssetIcon: true, MatchRecordingPanel: true } },
    });
    expect(plain.find(".match-row__detail").exists()).toBe(false);
    expect(plain.find(".match-row__toggle").exists()).toBe(false);

    const expandable = mount(MatchDetailCard, {
      props: { match: row, expanded: true, expandable: true, detailLoading: true },
      global: { stubs: { AssetIcon: true, MatchRecordingPanel: true } },
    });
    expect(expandable.find(".match-row__toggle").exists()).toBe(true);
    expect(expandable.get(".match-row__detail-status").text()).toContain("正在读取");
    // 行身也是可点区域：只有右上角小箭头能点的体验太差。
    await expandable.get(".match-row__identity").trigger("click");
    expect(expandable.emitted("toggle")).toHaveLength(1);
  });
});
