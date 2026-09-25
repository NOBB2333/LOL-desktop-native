import { mount } from "@vue/test-utils";
import { describe, expect, it } from "vitest";
import type { MatchParticipant, MatchTimelineEvent, MatchTimelineFrame, MatchTimelineParticipant } from "../types/domain";
import TeamfightList from "./TeamfightList.vue";
import { deriveTeamfights } from "../matches/teamfights";

const BLUE = 100;
const RED = 200;

const seats: MatchTimelineParticipant[] = Array.from({ length: 10 }, (_, index) => ({
  participantId: index + 1,
  team: index < 5 ? BLUE : RED,
  championId: (index + 1) * 10,
}));

function event(seconds: number, extra: Partial<MatchTimelineEvent>): MatchTimelineEvent {
  return {
    type: "CHAMPION_KILL",
    seconds,
    team: BLUE,
    killerId: 0,
    victimId: 0,
    assistCount: 0,
    assistIds: [],
    killerChampionId: 0,
    victimChampionId: 0,
    posX: 7400,
    posY: 7400,
    monsterType: "",
    monsterSubType: "",
    buildingType: "",
    towerType: "",
    laneType: "",
    ...extra,
  };
}

/** 一波团：174~182 秒之间四个人头，双方各两人参与。窗口**跨过第 3 分钟**——
 *  「本波」是帧差值，两端落在同一分钟帧里差值必然是 0，那样测不出东西。 */
const events: MatchTimelineEvent[] = [
  event(174, { killerId: 1, victimId: 6, killerChampionId: 10, victimChampionId: 60, assistIds: [2], assistCount: 1 }),
  event(176, { killerId: 2, victimId: 7, killerChampionId: 20, victimChampionId: 70, assistIds: [1], assistCount: 1 }),
  event(178, { killerId: 6, victimId: 3, killerChampionId: 60, victimChampionId: 30, team: RED }),
  event(182, { killerId: 8, victimId: 4, killerChampionId: 80, victimChampionId: 40, team: RED }),
];

const ZERO10 = Array.from({ length: 10 }, () => 0);

function frame(minute: number, damage: number[] = ZERO10): MatchTimelineFrame {
  return {
    minute,
    blueGold: 1500 * minute,
    redGold: 1450 * minute,
    goldDiff: 50 * minute,
    blueCs: 12 * minute,
    redCs: 11 * minute,
    gold: Array.from({ length: 10 }, () => 1500 * minute),
    level: Array.from({ length: 10 }, () => Math.min(18, minute + 1)),
    damage,
    taken: ZERO10,
    positions: Array.from({ length: 10 }, () => ({ x: 7000, y: 7000 })),
  };
}

/** 视角方在红方：红队 side=ally、蓝队 side=enemy（side 是相对的）。 */
function players(redView = false): MatchParticipant[] {
  return seats.map((seat, index) => ({
    puuid: `puuid-${seat.participantId}`,
    gameName: `玩家${seat.participantId}`,
    isBot: false,
    championId: seat.championId,
    championName: `英雄${seat.championId}`,
    side: (seat.team === (redView ? RED : BLUE) ? "ally" : "enemy") as MatchParticipant["side"],
    team: seat.team,
    position: "MIDDLE",
    kills: 4,
    deaths: 4,
    assists: 4,
    damageDealt: 10000 + index * 1000,
    damageTaken: 9000 + index * 500,
    goldEarned: 12000,
    cs: 180,
    win: true,
    items: [{ id: 3000 + index, name: `装备${index}`, iconUrl: "" }],
    towerDamage: 900,
  }));
}

const AssetIconStub = { props: { id: { default: 0 }, name: { default: "" } }, template: '<i class="asset-icon-stub" />' };

function mountList(options: { frames?: MatchTimelineFrame[]; redView?: boolean } = {}) {
  return mount(TeamfightList, {
    props: {
      fights: deriveTeamfights(events, seats),
      championNameOf: (id: number) => `英雄${id}`,
      participants: seats,
      players: players(options.redView ?? false),
      frames: options.frames ?? [frame(0), frame(5), frame(10)],
      selectedIndex: 0,
    },
    global: { stubs: { AssetIcon: AssetIconStub } },
  });
}

describe("每波团面板：指标可用性", () => {
  it("分钟帧里没有伤害字段时，「本波」两项置灰、自动落到全场输出，并说明原因", () => {
    const wrapper = mountList();
    const metrics = wrapper.findAll(".teamfight-detail__metrics button");
    expect(metrics.map((item) => item.text())).toEqual(["本波输出", "本波承伤", "全场输出", "全场承伤", "出装"]);
    expect(metrics[0].attributes("disabled")).toBeDefined();
    expect(metrics[1].attributes("disabled")).toBeDefined();
    expect(metrics[2].attributes("disabled")).toBeUndefined();
    // 默认不能停在「本波输出」那张全零的图上。
    expect(metrics[2].classes()).toContain("active");
    expect(wrapper.get(".teamfight-bars__head").text()).toContain("全场输出");
    expect(wrapper.get(".teamfight-detail__metricnote").text()).toContain("没拿到逐分钟伤害");
    // 说明里要点出「伤害本来该从 SGP 取」，否则用户会以为客户端永远没有这个数据。
    expect(wrapper.get(".teamfight-detail__metricnote").text()).toContain("SGP");

    // 柱状图恒在，而且柱子有长度（不是十根空轨道）。
    expect(wrapper.findAll(".teamfight-bars__row")).toHaveLength(10);
    const widths = wrapper
      .findAll(".teamfight-bars__track i")
      .map((bar) => Number.parseFloat(bar.attributes("style")?.match(/width:\s*([\d.]+)%/)?.[1] ?? "0"));
    expect(Math.max(...widths)).toBeCloseTo(100, 5);
  });

  it("帧里有伤害时，「本波」可用且有非零柱（不误伤有数据的对局）", async () => {
    // 第 2、3 分钟各一帧，累计伤害在涨 → 团战窗口（174~182 秒）的差值非零。
    const withDamage = [
      frame(2, seats.map((_, slot) => (slot + 1) * 100)),
      frame(3, seats.map((_, slot) => (slot + 1) * 300)),
    ];
    const wrapper = mountList({ frames: withDamage });
    const metrics = wrapper.findAll(".teamfight-detail__metrics button");
    expect(metrics[0].attributes("disabled")).toBeUndefined();
    expect(metrics[0].classes()).toContain("active");
    expect(wrapper.find(".teamfight-detail__metricnote").exists()).toBe(false);
    expect(wrapper.get(".teamfight-bars__head").text()).toContain("本波输出");
    const widths = wrapper
      .findAll(".teamfight-bars__track i")
      .map((bar) => Number.parseFloat(bar.attributes("style")?.match(/width:\s*([\d.]+)%/)?.[1] ?? "0"));
    expect(widths.filter((width) => width > 0)).toHaveLength(10);
    expect(Math.max(...widths)).toBeCloseTo(100, 5);

    // 手动切到「本波承伤」也应当是可用状态（有帧就有数据；这一局承伤那项恒为 0，会给出提示）。
    await metrics[1].trigger("click");
    expect(metrics[1].classes()).toContain("active");
    expect(wrapper.get(".teamfight-detail__nodata").text()).toContain("本波承伤");
  });

  it("视角方在红方时，全场指标与出装照样配得上人", async () => {
    const wrapper = mountList({ redView: true });
    // 全场输出读的是十人详情，配不上就是全零 → 会掉进「十个人都是 0」的提示里。
    expect(wrapper.find(".teamfight-detail__nodata").exists()).toBe(false);
    // 行按当前指标降序排（「出装」才保持座位序），所以这里比**集合**不比顺序。
    const names = wrapper.findAll(".teamfight-bars__row").map((row) => row.get(".teamfight-bars__name").text());
    expect([...names].sort()).toEqual(players(true).map((item) => item.gameName).sort());

    await wrapper.findAll(".teamfight-detail__metrics button")[4].trigger("click");
    expect(wrapper.findAll(".teamfight-bars__items")).toHaveLength(10);
    expect(wrapper.findAll(".teamfight-bars__items .asset-icon-stub")).toHaveLength(10);
  });

  it("整局没有分钟帧（旧缓存对局）时退回对位表，并保留「为什么」的说明", () => {
    const wrapper = mountList({ frames: [] });
    expect(wrapper.find(".teamfight-detail__bars").exists()).toBe(false);
    expect(wrapper.get(".teamfight-detail__duelnote").text()).toContain("没有分钟帧");
  });
});
