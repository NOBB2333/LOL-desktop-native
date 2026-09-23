import { mount } from "@vue/test-utils";
import { describe, expect, it } from "vitest";
import { createFixtureMatchTimeline } from "../fixtures/data";
import MatchTimelinePanel from "./MatchTimelinePanel.vue";

/**
 * 这一层只盯界面把后端数据摆对了没有：
 * 1. 曲线按零轴切成了蓝/红两段（而不是一整条单色线）；
 * 2. 事件轴把「谁做的」说出来了，且击杀事件带上了双方英雄图标；
 * 3. 没有逐帧数据时给一句人话，而不是画一张空图。
 */
const AssetIconStub = {
  props: ["id", "name"],
  template: '<i class="asset-icon-stub" :data-id="id" :data-name="name" />',
};

function mountPanel(gameId = 7001) {
  return mount(MatchTimelinePanel, {
    props: { timeline: createFixtureMatchTimeline(gameId), championName: (id: number) => `英雄${id}` },
    global: { stubs: { AssetIcon: AssetIconStub } },
  });
}

describe("MatchTimelinePanel", () => {
  it("splits the economy curve by the zero axis and labels both sides", () => {
    const wrapper = mountPanel();
    const blue = wrapper.findAll(".timeline-chart__line--blue");
    const red = wrapper.findAll(".timeline-chart__line--red");
    expect(blue.length).toBeGreaterThan(0);
    expect(red.length).toBeGreaterThan(0);
    // 蓝红两段必须都能画出路径，否则等于有一半的比赛不显示。
    expect(blue[0].attributes("d")).toContain("M");
    expect(red[0].attributes("d")).toContain("M");
    expect(wrapper.get(".timeline-chart__legend").text()).toContain("蓝方领先");
    expect(wrapper.get(".timeline-chart__legend").text()).toContain("红方领先");
    // 面积也是两段（零轴上下各一份）。
    expect(wrapper.findAll(".timeline-chart__area").length).toBe(2);
  });

  it("renders the kill score and the final economy in the summary strip", () => {
    const wrapper = mountPanel();
    const summary = wrapper.get(".timeline-summary").text();
    expect(summary).toContain("时长");
    expect(summary).toContain("最终经济");
    expect(summary).toContain("关键事件");
  });

  it("lists events with the acting side and champion icons for kills", async () => {
    const wrapper = mountPanel();
    const rows = wrapper.findAll(".timeline-event");
    expect(rows.length).toBeGreaterThan(0);

    const killRow = wrapper.findAll(".timeline-event").find((row) => row.text().includes("击杀"));
    expect(killRow).toBeTruthy();
    // 击杀行必须同时有击杀者与受害者两个英雄图标。
    expect(killRow!.findAll(".asset-icon-stub").length).toBe(2);
    // 「哪一方做的」写在行内文案里（不再单独放一个右侧色块，避免和文案重复）。
    expect(killRow!.get(".timeline-event__detail").text()).toMatch(/^(蓝方|红方)/);

    // 第一次阵亡来自红方，行首的时间戳必须是 mm:ss。
    expect(rows[0].get(".timeline-event__time").text()).toMatch(/^\d{2}:\d{2}$/);
  });

  it("says so when there is no frame data instead of drawing an empty chart", () => {
    const timeline = createFixtureMatchTimeline(7001);
    const wrapper = mount(MatchTimelinePanel, {
      props: { timeline: { ...timeline, frames: [], events: [] } },
      global: { stubs: { AssetIcon: AssetIconStub } },
    });
    expect(wrapper.find(".timeline-chart").exists()).toBe(false);
    expect(wrapper.get(".timeline-empty").text()).toContain("逐帧数据");
  });
});
