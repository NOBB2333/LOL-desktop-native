import { flushPromises, mount } from "@vue/test-utils";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { fixtureEncounters, fixtureLobby, fixtureMatches } from "../fixtures/data";
import PlayerDetailDrawer from "./PlayerDetailDrawer.vue";

const { encounters, matches, push } = vi.hoisted(() => ({ encounters: vi.fn(), matches: vi.fn(), push: vi.fn() }));

vi.mock("vue-router", () => ({
  useRouter: () => ({ push }),
}));

vi.mock("../services/backend", () => ({
  backend: { encounters, matches },
  isTauri: () => false,
}));

const DrawerStub = {
  template: "<div><slot /></div>",
};

const DrawerContentStub = {
  template: "<div><slot name='header' /><slot /></div>",
};

describe("PlayerDetailDrawer", () => {
  beforeEach(() => {
    push.mockReset();
    encounters.mockResolvedValue(structuredClone(fixtureEncounters));
    matches.mockResolvedValue(structuredClone(fixtureMatches));
  });

  it("opens the selected player's match history from the drawer identity", async () => {
    const player = fixtureLobby.ally[0];
    const wrapper = mount(PlayerDetailDrawer, {
      props: { show: true, player },
      global: {
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

    expect(encounters).toHaveBeenCalledWith(player.puuid, 100);
    expect(wrapper.text()).toContain(`${fixtureLobby.ally[0].gameName}#${fixtureLobby.ally[0].tagLine}`);
    expect(wrapper.text()).toContain(`${player.gameName}#${player.tagLine}`);
    expect(wrapper.get("[data-testid='encounter-tag']").text()).toContain(player.championName);
    expect(wrapper.get("[data-testid='encounter-tag']").text()).toMatch(/\d+\/\d+\/\d+/);
    await wrapper.get("[data-testid='encounter-match-open']").trigger("click");
    expect(wrapper.get("[data-testid='encounter-modal']").text()).toBe("9");
  });

  it("loads complete match summaries and expands the selected ten-player match in place", async () => {
    const player = fixtureLobby.ally[2];
    const wrapper = mount(PlayerDetailDrawer, {
      props: { show: true, player },
      global: {
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
});
