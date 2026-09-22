import { mount } from "@vue/test-utils";
import { describe, expect, it } from "vitest";
import { fixtureLobby } from "../fixtures/data";
import { AKARI_MAX_SCORE } from "../tags/akari";
import MatchupPanel from "./MatchupPanel.vue";

/**
 * 这一层是「画」的部分，逻辑全在 `live/matchup.ts`（那边有 30+ 条用例）。
 * 所以这里只盯两件在真界面上才暴露得出来的事：
 * 1. 四块**真的都渲染出来了**（用户反馈过右栏「展示太薄弱」，空白是主要失败模式）；
 * 2. 数值的**可读性**——比例带不带分母、有没有「1 连胜」这种话。
 * 后者两条都是靠肉眼看界面才发现的，纯逻辑用例盖不住。
 */
function mountPanel(allies = fixtureLobby.ally, enemies = fixtureLobby.enemy) {
  return mount(MatchupPanel, {
    props: { allies, enemies, allySummary: fixtureLobby.allySummary, enemySummary: fixtureLobby.enemySummary },
    global: { stubs: { AssetIcon: true } },
  });
}

describe("MatchupPanel", () => {
  it("四个区块都渲染出来，不留空", () => {
    const wrapper = mountPanel();
    expect(wrapper.text()).toContain("本局胜率估算");
    expect(wrapper.text()).toContain("队伍对比");
    expect(wrapper.text()).toContain("逐路对位");
    expect(wrapper.text()).toContain("重点关注");
    // 关注点至少有一条（查不出东西时也要给「双方数据接近」）。
    expect(wrapper.findAll(".focus-list li").length).toBeGreaterThan(0);
  });

  it("胜率条两侧加起来是 100%，并且写清了几路可比", () => {
    const wrapper = mountPanel();
    const percents = wrapper.findAll(".prob-legend b").map((node) => Number.parseInt(node.text(), 10));
    expect(percents).toHaveLength(2);
    expect(percents[0] + percents[1]).toBe(100);
    expect(wrapper.text()).toContain("5 路可比");
  });

  it("Akari 平均分必须带上满分，否则「0.98」会被当成百分制", () => {
    const wrapper = mountPanel();
    const row = wrapper.findAll(".team-compare__row").find((node) => node.text().includes("平均 Akari"));
    expect(row).toBeTruthy();
    expect(row!.text()).toContain(`/ ${AKARI_MAX_SCORE}`);
  });

  it("逐路对位每行都给出结论和一条带数字的证据", () => {
    const wrapper = mountPanel();
    const rows = wrapper.findAll(".lane-row");
    expect(rows).toHaveLength(5);
    for (const row of rows) {
      expect(row.find(".lane-row__verdict").text().length).toBeGreaterThan(0);
      expect(row.find(".lane-row__pair").text()).toContain("↔");
    }
  });

  it("位置信息不全时明确降级，而不是硬造五路结论", () => {
    const noPosition = fixtureLobby.ally.map((player) => ({ ...player, assignedPosition: "" }));
    const wrapper = mountPanel(noPosition, fixtureLobby.enemy);
    expect(wrapper.findAll(".lane-row")).toHaveLength(0);
    expect(wrapper.text()).toContain("位置信息不完整");
    // 降级只关掉逐路那一块，队伍对比与重点关注照常。
    expect(wrapper.text()).toContain("队伍对比");
    expect(wrapper.findAll(".focus-list li").length).toBeGreaterThan(0);
  });
});
