import { QueryClient, VueQueryPlugin } from "@tanstack/vue-query";
import { flushPromises, mount } from "@vue/test-utils";
import { describe, expect, it } from "vitest";
import MatchRecordingPanel from "./MatchRecordingPanel.vue";
import type { GameRecording, GameRecordingPlayer } from "../types/domain";

/**
 * 这一层盯的是「可选功能」的四条边界，而不是排版：
 * - **没录到就什么都不渲染**（开关默认关，绝大多数人看到的就是这个）；
 * - 录到了才出时间轴，游标默认停最后一帧（开局帧十个人全是 0，停在那里像坏了）；
 * - 开关开着却没录到，要给一句解释，不能默默消失；
 * - 而且**「这一局没录」和「本机一局都没录过」必须分开说**——两者的排查方向完全不同。
 */
const { backendState, appState } = vi.hoisted(() => ({
  backendState: { recording: null as GameRecording | null },
  appState: { recordingEnabled: false },
}));

vi.mock("naive-ui", () => ({
  // 关掉 attrs 透传：`:size` / `:secondary` 会被当成原生属性塞给 <button>。
  // 但**必须自己把 click 转出来**——`inheritAttrs: false` 会连同 `onClick` 一起拦下，
  // 不转的话 `@click="step(-1)"` 在测试里点了等于没点（真踩过）。
  NButton: {
    inheritAttrs: false,
    props: ["disabled"],
    emits: ["click"],
    template: '<button :disabled="disabled" @click="$emit(\'click\', $event)"><slot /></button>',
  },
}));

vi.mock("../stores/app", async () => {
  const { fixtureConfig } = await import("../fixtures/data");
  return {
    useAppStore: () => ({
      config: {
        ...fixtureConfig,
        providers: { ...fixtureConfig.providers, recording: { enabled: appState.recordingEnabled, intervalSeconds: 15 } },
      },
    }),
  };
});

vi.mock("../services/backend", () => ({
  backend: { gameRecording: async () => backendState.recording },
}));

function player(overrides: Partial<GameRecordingPlayer> = {}): GameRecordingPlayer {
  return {
    puuid: "p1",
    rid: "玩家一#CN1",
    team: "ORDER",
    champ: "Aatrox",
    cid: 266,
    pos: "TOP",
    lvl: 11,
    k: 3,
    d: 1,
    a: 4,
    cs: 142,
    ward: 6,
    dead: false,
    respawn: 0,
    bot: false,
    items: [3153],
    spells: ["闪现", "传送"],
    ...overrides,
  };
}

/** 三帧：00:00 / 00:15 / 03:15。最后一帧带一个正在复活的人。 */
function recording(): GameRecording {
  return {
    gameId: 7,
    intervalSeconds: 15,
    recordedGames: 1,
    frames: [
      { t: 0, gameId: 7, sampledAt: "2026-09-26T10:00:00.000Z", players: [player({ k: 0, d: 0, a: 0, cs: 0, lvl: 1, items: [] })], me: null },
      { t: 15, gameId: 7, sampledAt: "2026-09-26T10:00:15.000Z", players: [player({ k: 1, cs: 12 })], me: null },
      {
        t: 195,
        gameId: 7,
        sampledAt: "2026-09-26T10:03:15.000Z",
        players: [
          player({ dead: true, respawn: 7.4, items: [3153, 3006] }),
          player({ puuid: "p2", rid: "对手#CN1", team: "CHAOS", champ: "Ahri", cid: 103, d: 5 }),
        ],
        me: { rid: "玩家一#CN1", gold: 8210, lvl: 11, ad: 128, ap: 14.5, armor: 76, mr: 52, ms: 355, hp: 1240, maxHp: 1810 },
      },
    ],
  };
}

function mountPanel(gameId = 7) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return mount(MatchRecordingPanel, {
    props: { gameId },
    global: {
      plugins: [[VueQueryPlugin, { queryClient }]],
      stubs: { AssetIcon: { inheritAttrs: false, props: ["kind", "id", "name", "fallbackUrl", "size"], template: '<i class="asset-icon-stub" />' } },
    },
  });
}

describe("MatchRecordingPanel 可选录制的四条边界", () => {
  it("没录到就整块不渲染（默认关的开关就是这个样子）", async () => {
    backendState.recording = { gameId: 7, intervalSeconds: 15, recordedGames: 0, frames: [] };
    appState.recordingEnabled = false;
    const wrapper = mountPanel();
    await flushPromises();

    expect(wrapper.find(".recording").exists()).toBe(false);
    // 开关关着时连「没录到」都不要提示——那是噪声。
    expect(wrapper.find(".recording__empty").exists()).toBe(false);
    expect(wrapper.text()).toBe("");
  });

  it("开关开着、这一局没录但本机录过别的局 → 说「这一局没有」，并带上已录局数", async () => {
    backendState.recording = { gameId: 7, intervalSeconds: 15, recordedGames: 2, frames: [] };
    appState.recordingEnabled = true;
    const wrapper = mountPanel();
    await flushPromises();

    expect(wrapper.find(".recording").exists()).toBe(false);
    const note = wrapper.get(".recording__empty").text();
    expect(note).toContain("这一局没有本地录制");
    expect(note).toContain("本机已录 2 局");
  });

  it("本机一局都没录过 → 文案改成「从来没录到过」+ 三条自查，而不是甩一句「这一局没有」", async () => {
    // 这条是那次「开了开关打了几把、一帧都没有」的教训：两种「空」长得一模一样，
    // 用户没法判断是用法不对还是功能坏了。
    backendState.recording = { gameId: 7, intervalSeconds: 15, recordedGames: 0, frames: [] };
    appState.recordingEnabled = true;
    const wrapper = mountPanel();
    await flushPromises();

    const note = wrapper.get(".recording__empty").text();
    expect(note).toContain("从来没录到过");
    expect(note).toContain("你本机在打");
    expect(note).not.toContain("本机已录");
  });

  it("录到了才出时间轴，游标默认停在最后一帧，时钟显示游戏内时间", async () => {
    backendState.recording = recording();
    appState.recordingEnabled = true;
    const wrapper = mountPanel();
    await flushPromises();

    expect(wrapper.get(".recording__meta").text()).toContain("共 3 帧");
    const range = wrapper.get(".recording__range").element as HTMLInputElement;
    // 最后一帧 = 03:15，而不是 00:00（开局帧十个人全是 0，看着像没数据）。
    expect(range.value).toBe("2");
    expect(wrapper.get(".recording__clock").text()).toContain("03:15");
    expect(wrapper.findAll(".recording__row")).toHaveLength(2);
  });

  it("上一帧能把游标退回中间那一帧", async () => {
    backendState.recording = recording();
    appState.recordingEnabled = true;
    const wrapper = mountPanel();
    await flushPromises();

    await wrapper.findAll("button")[0]!.trigger("click");
    expect((wrapper.get(".recording__range").element as HTMLInputElement).value).toBe("1");
    expect(wrapper.get(".recording__clock").text()).toContain("00:15");
  });

  it("阵亡的人标出复活倒计时；本人那一份 AD/护甲只挂在本人身上", async () => {
    backendState.recording = recording();
    appState.recordingEnabled = true;
    const wrapper = mountPanel();
    await flushPromises();

    const dead = wrapper.findAll(".recording__row").find((row) => row.classes().includes("is-dead"));
    expect(dead?.get(".recording__respawn").text()).toBe("7s");
    expect(wrapper.get(".recording__self").text()).toContain("移速");
    expect(wrapper.get(".recording__self").text()).toContain("355");
  });
});
