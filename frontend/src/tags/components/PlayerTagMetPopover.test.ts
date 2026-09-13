import { mount } from "@vue/test-utils";
import { describe, expect, it } from "vitest";
import { fixtureEncounters, fixtureLobby } from "../../fixtures/data";
import { encounterGames } from "../../encounters/records";
import PlayerTagMetPopover from "./PlayerTagMetPopover.vue";

const TARGET = fixtureLobby.ally[2];
const games = encounterGames(fixtureEncounters, TARGET.puuid, Number(fixtureLobby.id) || 0);

function mountPopover(props: Record<string, unknown> = {}) {
  return mount(PlayerTagMetPopover, {
    props: { games, total: games.length, targetName: TARGET.gameName, ...props },
    global: { stubs: { AssetIcon: true } },
  });
}

describe("PlayerTagMetPopover", () => {
  it("按 LeagueAkari 的列结构渲染逐局对照表", () => {
    const wrapper = mountPopover();

    const headers = wrapper.findAll("thead th").map((cell) => cell.text());
    expect(headers).toEqual(["对局 ID", "对局日期", "结果", "关系", "自己", TARGET.gameName]);
    expect(wrapper.findAll("[data-testid='met-row']")).toHaveLength(3);
    wrapper.unmount();
  });

  it("每行都能查看整局详情，并把同场记录回传", async () => {
    const wrapper = mountPopover();

    const rows = wrapper.findAll("[data-testid='met-row']");
    // 最近一局在前：fixture 里 gameIndex 0 的相遇时间最新。
    expect(rows[0].find("[data-testid='met-inspect']").text()).toBe("查看 910000");

    await rows[0].find("[data-testid='met-inspect']").trigger("click");
    const emitted = wrapper.emitted("inspect");
    expect(emitted).toHaveLength(1);
    const records = emitted![0][0] as unknown[];
    // 一场对局里除自己以外的 9 名玩家都会随整局详情一并回传。
    expect(records).toHaveLength(9);
    wrapper.unmount();
  });

  it("表头汇总相遇次数，并说明只展示最近几场", () => {
    const wrapper = mountPopover({ total: 7 });

    expect(wrapper.text()).toContain("共遇到过 7 次");
    expect(wrapper.text()).toContain("仅显示最近 3 场对局");
    wrapper.unmount();
  });

  it("没有可展示的对局时给出空态", () => {
    const wrapper = mountPopover({ games: [], total: 4, lastMetAt: "2026-09-01T00:00:00.000Z" });

    expect(wrapper.findAll("[data-testid='met-row']")).toHaveLength(0);
    expect(wrapper.text()).toContain("没有可展示的共同对局");
    expect(wrapper.text()).toContain("共遇到过 4 次");
    wrapper.unmount();
  });

  it("hideSummary 供抽屉复用时不重复渲染汇总文案", () => {
    const wrapper = mountPopover({ hideSummary: true });

    expect(wrapper.text()).not.toContain("共遇到过");
    expect(wrapper.findAll("[data-testid='met-row']")).toHaveLength(3);
    wrapper.unmount();
  });
});
