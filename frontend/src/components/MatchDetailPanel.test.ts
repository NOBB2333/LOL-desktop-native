import { mount } from "@vue/test-utils";
import { describe, expect, it } from "vitest";
import type { MatchParticipant, MatchTimeline, MatchTimelineEvent, MatchTimelineParticipant } from "../types/domain";
import MatchDetailPanel from "./MatchDetailPanel.vue";
import { deriveTeamfights } from "../matches/teamfights";

/** 1~5 蓝、6~10 红；英雄 id 取座位号 ×10，断言里好认。 */
const participants: MatchTimelineParticipant[] = Array.from({ length: 10 }, (_, index) => ({
  participantId: index + 1,
  team: index < 5 ? 100 : 200,
  championId: (index + 1) * 10,
}));

function event(seconds: number, extra: Partial<MatchTimelineEvent>): MatchTimelineEvent {
  return {
    type: "CHAMPION_KILL",
    seconds,
    team: 100,
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

const championNameOf = (id: number) => `英雄${id}`;

/**
 * 一局编排得很小的事件：
 * - 01:40 小龙（离团战太远，不该出现在团战事件流里）
 * - 03:12 大龙（团战前 8 秒拿下 → **要**出现在这一波的事件流里）
 * - 03:20 / 03:25 两具人头（团战本体）
 * - 06:40 推掉中路一塔（离团战太远，不该出现）
 */
const events: MatchTimelineEvent[] = [
  event(100, { type: "ELITE_MONSTER_KILL", killerId: 2, killerChampionId: 20, monsterType: "DRAGON", monsterSubType: "FIRE_DRAGON" }),
  event(192, { type: "ELITE_MONSTER_KILL", killerId: 2, killerChampionId: 20, monsterType: "BARON_NASHOR" }),
  event(200, { killerId: 1, victimId: 6, killerChampionId: 10, victimChampionId: 60, assistIds: [3], assistCount: 1 }),
  event(205, { killerId: 1, victimId: 7, killerChampionId: 10, victimChampionId: 70, assistIds: [3], assistCount: 1 }),
  event(400, { type: "BUILDING_KILL", killerId: 1, killerChampionId: 10, buildingType: "TOWER_BUILDING", towerType: "OUTER_TURRET", laneType: "MID_LANE" }),
];

const timeline: MatchTimeline = { gameId: 1, durationSeconds: 1560, participants, frames: [], events };

/** 头像用桩替掉：真组件会去拉远程图，这里只需要知道「这一行挂了几个头像」。 */
const AssetIconStub = { props: { id: { default: 0 }, name: { default: "" } }, template: '<i class="asset-icon-stub" />' };

function mountPanel(options: { selectedFightIndex?: number; players?: MatchParticipant[] } = {}) {
  return mount(MatchDetailPanel, {
    props: {
      timeline,
      championNameOf,
      fights: deriveTeamfights(events, participants),
      selectedFightIndex: options.selectedFightIndex,
      players: options.players,
    },
    global: { stubs: { AssetIcon: AssetIconStub } },
  });
}

describe("MatchDetailPanel 事件流", () => {
  it("只列选中那一波的事件：击杀严格按窗，龙 / 塔放宽 ±15 秒", () => {
    const wrapper = mountPanel({ selectedFightIndex: 0 });
    const rows = wrapper.findAll(".match-event");
    // 03:12 大龙（团战前 8 秒，落在 ±15 秒内）+ 两具人头 = 3 行；
    // 01:40 的小龙与 06:40 的推塔都离这一波太远，必须被滤掉。
    expect(rows.map((row) => row.get(".match-event__time").text())).toEqual(["03:12", "03:20", "03:25"]);
    expect(wrapper.get(".match-detail__feed").text()).not.toContain("推掉");

    // 标题要说清「这是哪一波的、不是整局」。
    expect(wrapper.findAll(".match-detail__block h4")[1].text()).toContain("只看这一波");

    // 大龙那行写清**是谁拿的**，而不是干巴巴一句「大龙」。
    const baronRow = rows[0];
    expect(baronRow.attributes("data-kind")).toBe("ELITE_MONSTER_KILL");
    expect(baronRow.get(".match-event__body").text()).toContain("英雄20");
    expect(baronRow.get(".match-event__body").text()).toContain("大龙");
  });

  it("每行都带英雄头像：击杀是「谁杀谁」两张脸，拿龙只有一头", () => {
    const wrapper = mountPanel({ selectedFightIndex: 0 });
    const rows = wrapper.findAll(".match-event");
    // 大龙：只有拿龙的那张脸；两具人头：击杀者 + 阵亡者两张脸。
    expect(rows[0].findAll(".match-event__faces .asset-icon-stub")).toHaveLength(1);
    expect(rows[1].findAll(".match-event__faces .asset-icon-stub")).toHaveLength(2);
    expect(rows[2].findAll(".match-event__faces .asset-icon-stub")).toHaveLength(2);
    expect(wrapper.findAll(".match-event__faces .asset-icon-stub")).toHaveLength(5);
    // 阵亡者压暗一档（一眼分出哪张是被杀的），所以必须挂 is-victim。
    expect(rows[1].findAll(".match-event__faces .is-victim")).toHaveLength(1);
  });

  it("有十人详情时写玩家名：镜像对局下英雄名会变成「X 击杀 X」", () => {
    const players: MatchParticipant[] = participants.map((seat) => ({
      puuid: `puuid-${seat.participantId}`,
      gameName: `玩家${seat.participantId}`,
      isBot: false,
      championId: seat.championId,
      championName: `英雄${seat.championId}`,
      side: seat.team === 100 ? "ally" : "enemy",
      position: "MIDDLE",
      kills: 0,
      deaths: 0,
      assists: 0,
      damageDealt: 0,
      damageTaken: 0,
      goldEarned: 0,
      cs: 0,
      win: true,
    }));
    const wrapper = mountPanel({ selectedFightIndex: 0, players });
    const titles = wrapper.findAll(".match-event__body b").map((node) => node.text());
    expect(titles[0]).toContain("玩家2");
    expect(titles[1]).toBe("玩家1 击杀 玩家6");
    // 名字之外的角标/小字不受影响。
    expect(titles[1]).not.toContain("英雄");
  });

  it("压暗的「团N」角标不再重复出现，首杀 / 多杀这类真信息留着", () => {
    const wrapper = mountPanel({ selectedFightIndex: 0 });
    const badges = wrapper.findAll(".match-event__badges i").map((badge) => badge.text());
    expect(badges).toContain("首杀");
    expect(badges.some((badge) => badge.startsWith("团"))).toBe(false);
  });

  it("没选中团战时退回整局事件流（总得让人看到点什么）", () => {
    const wrapper = mountPanel();
    expect(wrapper.findAll(".match-event")).toHaveLength(events.length);
    expect(wrapper.findAll(".match-detail__block h4")[1].text()).not.toContain("只看这一波");
  });
});
