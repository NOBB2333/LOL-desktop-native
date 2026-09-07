import { QueryClient, VueQueryPlugin } from "@tanstack/vue-query";
import { flushPromises, mount } from "@vue/test-utils";
import { describe, expect, it, vi } from "vitest";
import { fixtureBpHistory, fixtureEncounters } from "../fixtures/data";
import HistoryView from "./HistoryView.vue";

vi.mock("../stores/app", () => ({
  useAppStore: () => ({ mode: "fixture", initialized: true }),
}));

vi.mock("../services/backend", async () => {
  const { fixtureBpHistory, fixtureChampions, fixtureEncounters } = await import("../fixtures/data");
  return {
    isTauri: () => false,
    backend: {
      bpHistory: async () => structuredClone(fixtureBpHistory),
      champions: async () => structuredClone(fixtureChampions),
      encounters: async () => structuredClone(fixtureEncounters),
    },
  };
});

const AssetIconStub = {
  props: ["id", "name"],
  template: '<i class="asset-icon-stub" :data-id="id" :data-name="name" />',
};

describe("HistoryView", () => {
  it("renders the champion IDs stored on BP and encounter records", async () => {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    const wrapper = mount(HistoryView, {
      global: {
        plugins: [[VueQueryPlugin, { queryClient }]],
        stubs: {
          AssetIcon: AssetIconStub,
          PageHeader: { template: "<header><slot /></header>" },
          NButton: { template: "<button><slot /></button>" },
          NTag: { template: "<span><slot /></span>" },
        },
      },
    });

    await flushPromises();
    const bpIcon = wrapper.get(".bp-champion-list .asset-icon-stub");
    expect(bpIcon.attributes("data-id")).toBe(String(fixtureBpHistory[0].allyChampionIds[0]));
    expect(bpIcon.attributes("data-name")).toBe(fixtureBpHistory[0].allyChampions[0]);

    await wrapper.get(".history-tabs button:nth-child(2)").trigger("click");
    await flushPromises();
    const encounterIcon = wrapper.get(".encounter-champion .asset-icon-stub");
    expect(encounterIcon.attributes("data-id")).toBe(String(fixtureEncounters[0].championId));
    expect(encounterIcon.attributes("data-name")).toBe(fixtureEncounters[0].championName);
  });
});
