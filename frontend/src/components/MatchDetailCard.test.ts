import { mount } from "@vue/test-utils";
import { describe, expect, it, vi } from "vitest";
import { fixtureLobby } from "../fixtures/data";
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
});
