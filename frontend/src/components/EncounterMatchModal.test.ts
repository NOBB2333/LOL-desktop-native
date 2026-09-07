import { mount } from "@vue/test-utils";
import { describe, expect, it, vi } from "vitest";
import { fixtureEncounters, fixtureLobby } from "../fixtures/data";
import EncounterMatchModal from "./EncounterMatchModal.vue";

vi.mock("./AssetIcon.vue", () => ({ default: { template: "<span />" } }));

describe("EncounterMatchModal", () => {
  it("reconstructs the self player and all nine encountered players", () => {
    const records = fixtureEncounters.filter((record) => record.gameId === fixtureEncounters[0].gameId);
    const target = fixtureLobby.ally[2];
    const wrapper = mount(EncounterMatchModal, {
      props: { show: true, records, targetPuuid: target.puuid },
      global: {
        stubs: {
          Modal: { template: "<section><slot /></section>" },
          AssetIcon: true,
        },
      },
    });

    expect(wrapper.findAll(".encounter-match__player")).toHaveLength(10);
    expect(wrapper.text()).toContain(`${fixtureLobby.ally[0].gameName}#${fixtureLobby.ally[0].tagLine}`);
    expect(wrapper.text()).toContain(`${target.gameName}#${target.tagLine}`);
    expect(wrapper.findAll(".encounter-match__player--self")).toHaveLength(1);
    expect(wrapper.findAll(".encounter-match__player--target")).toHaveLength(1);
  });
});
