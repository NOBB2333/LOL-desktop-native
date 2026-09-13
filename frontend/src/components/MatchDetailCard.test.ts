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
      global: { stubs: { AssetIcon: true } },
    });

    expect(wrapper.text()).not.toContain("躺赢局");
    expect(wrapper.find(".match-row__badge").text()).toBe("正常");
  });

  it("renders all ten participants in the expanded detail", () => {
    const match = structuredClone(fixtureMatches[0]);
    const wrapper = mount(MatchDetailCard, {
      props: { match, expanded: true },
      global: { stubs: { AssetIcon: true } },
    });

    expect(match.participants).toHaveLength(10);
    expect(wrapper.findAll(".participant-line")).toHaveLength(10);
    expect(wrapper.findAll(".participant-team")).toHaveLength(2);
  });

  it("keeps the row expanded when the detail area itself is clicked", async () => {
    const wrapper = mount(MatchDetailCard, {
      props: { match: structuredClone(fixtureMatches[0]), expanded: true, clickable: true },
      global: { stubs: { AssetIcon: true } },
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
      global: { stubs: { AssetIcon: true } },
    });

    expect(wrapper.get(".match-row__detail-status").text()).toContain("正在读取");
  });

  it("warns instead of pretending when the full detail failed", () => {
    const full = structuredClone(fixtureMatches[0]);
    const stub = { ...full, participants: [full.participants[0]] };
    const wrapper = mount(MatchDetailCard, {
      props: { match: stub, expanded: true, detailError: "这局的完整十人数据读取失败" },
      global: { stubs: { AssetIcon: true } },
    });

    const status = wrapper.get(".match-row__detail-status");
    expect(status.text()).toContain("读取失败");
    expect(status.attributes("data-tone")).toBe("warning");
  });
});
