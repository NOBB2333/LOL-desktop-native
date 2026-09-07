import { mount } from "@vue/test-utils";
import { describe, expect, it, vi } from "vitest";
import { fixtureLobby } from "../fixtures/data";
import PlayerCard from "./PlayerCard.vue";

vi.mock("../services/backend", () => ({
  backend: {},
  isTauri: () => false,
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

    expect(wrapper.findAll(".bp-player-card__recent > div")).toHaveLength(10);
    expect(wrapper.find(".bp-player-card__section-label").text()).toContain("最近对局 10场");
    expect(wrapper.findAll(".bp-player-card__recent-mode")).toHaveLength(10);
    expect(wrapper.find(".bp-player-card__recent-mode").text()).toBe(player.recentMatches[0].queueName);
    expect(wrapper.findAll(".bp-player-card__recent-time")).toHaveLength(10);
    expect(wrapper.find(".bp-player-card__recent-time").attributes("datetime")).toBe(player.recentMatches[0].playedAt);
    expect(wrapper.find(".bp-player-card__recent-time").text()).toContain("/");
    expect(wrapper.find(".bp-player-card__recent-time").text()).toContain(`${player.recentMatches[0].durationMinutes}m`);
    expect(wrapper.findAll(".bp-player-card__champion")).toHaveLength(3);
    expect(wrapper.find(".bp-player-card__champions").text()).toContain("常用英雄");
    expect(wrapper.find(".bp-player-card__tags").text()).toContain("位置样本少");
    expect(wrapper.findAll(".bp-player-card__position strong")).toHaveLength(2);
    expect(wrapper.find(".bp-player-card__position").text()).toContain("打野 5场");
    expect(wrapper.find(".bp-player-card__position").text()).toContain("中路 3场");
    expect(wrapper.find(".bp-player-card__queue-ranks").text()).toContain("单双翡翠 I");
    expect(wrapper.find(".bp-player-card__queue-ranks").text()).toContain("灵活铂金 IV");
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
  });

  it("shows the encounter count and latest time directly on the player card", () => {
    const player = fixtureLobby.ally[2];
    const wrapper = mount(PlayerCard, { props: { player } });

    const label = wrapper.find(".bp-player-card__tags").text();
    expect(label).toContain(`遇到过 ${player.encounterCount} 次`);
    expect(label).toContain("最近");
  });
});
