import { mount } from "@vue/test-utils";
import type { VueWrapper } from "@vue/test-utils";
import { beforeEach, describe, expect, it } from "vitest";
import { nextTick } from "vue";
import type { MatchParticipant, MatchSummary, MatchTimeline, MatchTimelineEvent, MatchTimelineFrame } from "../types/domain";
import MatchSpectatePanel from "./MatchSpectatePanel.vue";
import { deriveTeamfights } from "../matches/teamfights";

/**
 * 这一组用例盯的是**真机数据形状**——fixture 是「理想数据」，真机上两处不一样：
 *
 * 1. 客户端本地的分钟帧里**没有伤害字段**（`damage` / `taken` 全 0）。后端现在会拿
 *    同一局 SGP `DETAILS` 里那份完整时间线把伤害补上（见 `matches/timeline.ts` 的
 *    `framesHaveDamage`），但**合并会失败**（离线 / 区服不在白名单 / 对局太新），
 *    这时必须降级到全场总账、并把口径写清，而不是画一排全零的柱子。两类用例都有。
 * 2. 十人详情的 `side` 是**相对视角**的，视角方在红方时 `side:"ally"` 的那些人属于 200。
 *    老代码拿 `side` 跟座位的绝对 `team` 配，红方对局里十个座位全配空（KDA 全 0）。
 */

const BLUE = 100;
const RED = 200;

/** 座位 1~5 蓝（英雄 10..50），6~10 红（英雄 60..100）。 */
const seats = Array.from({ length: 10 }, (_, index) => ({
  participantId: index + 1,
  team: index < 5 ? BLUE : RED,
  championId: (index + 1) * 10,
}));

const ZERO10 = Array.from({ length: 10 }, () => 0);

/** 真机形状的帧：金币 / 等级 / 位置都有，伤害一项都没有（全 0）。 */
function frame(minute: number, damage: number[] = ZERO10, taken: number[] = ZERO10): MatchTimelineFrame {
  return {
    minute,
    blueGold: 1500 * minute,
    redGold: 1400 * minute,
    goldDiff: 100 * minute,
    blueCs: 12 * minute,
    redCs: 11 * minute,
    gold: Array.from({ length: 10 }, (_, slot) => (slot < 5 ? 1500 : 1400) * minute),
    level: Array.from({ length: 10 }, () => Math.min(18, minute + 1)),
    damage,
    taken,
    positions: Array.from({ length: 10 }, (_, slot) => ({ x: 2000 + slot * 900, y: 2000 + slot * 800 })),
  };
}

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

const events: MatchTimelineEvent[] = [
  event(180, { killerId: 1, victimId: 6, killerChampionId: 10, victimChampionId: 60, assistIds: [2], assistCount: 1 }),
  event(190, { killerId: 6, victimId: 2, killerChampionId: 60, victimChampionId: 20 }),
];

/**
 * 十人详情。`redView` = 这一局的视角方在红方（真机上就是用户自己排在红队那些局）：
 * 红队五个人 `side:"ally"`（我这边），蓝队五个人 `side:"enemy"`。
 */
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
    kills: 3 + index,
    deaths: 2 + index,
    assists: 5 + index,
    damageDealt: 10000 + index * 1000,
    damageTaken: 8000 + index * 500,
    goldEarned: 12000,
    cs: 180,
    win: true,
    items: [{ id: 3000 + index, name: `装备${index}`, iconUrl: "" }],
    towerDamage: 500 + index * 100,
    visionScore: 20,
  }));
}

function detail(redView = false): MatchSummary {
  return {
    gameId: 1,
    championId: 10,
    championName: "英雄10",
    position: "MIDDLE",
    queueId: 420,
    queueName: "单双排",
    result: "胜利",
    kda: "3/2/5",
    kills: 3,
    deaths: 2,
    assists: 5,
    durationMinutes: 26,
    items: [],
    summonerSpells: [],
    runes: [],
    damageDealt: 10000,
    damageTaken: 8000,
    damageTakenShare: 0.2,
    heal: 0,
    goldEarned: 12000,
    cs: 180,
    towerDamage: 500,
    turretKills: 1,
    towerLeader: false,
    damageShare: 0.2,
    killParticipation: 0.5,
    performance: "solid",
    mvp: null,
    teamKills: 5,
    participants: players(redView),
    bans: [],
    playedAt: "2026-09-25T10:00:00.000Z",
    dataStatus: { source: "lcu", fetchedAt: "2026-09-25T10:00:00.000Z", expiresAt: null, isStale: false, error: null },
  };
}

function timeline(frames: MatchTimelineFrame[], list: MatchTimelineEvent[] = events): MatchTimeline {
  return { gameId: 1, durationSeconds: 1560, participants: seats, frames, events: list };
}

/** 头像用桩替掉：真组件会去拉远程图，这里只关心「这一行挂了几个图标」。 */
const AssetIconStub = { props: { id: { default: 0 }, name: { default: "" } }, template: '<i class="asset-icon-stub" />' };

function mountPanel(options: { frames?: MatchTimelineFrame[]; redView?: boolean; events?: MatchTimelineEvent[] } = {}) {
  const frames = options.frames ?? [frame(0), frame(26)];
  const list = options.events ?? events;
  return mount(MatchSpectatePanel, {
    props: {
      detail: detail(options.redView ?? false),
      timeline: timeline(frames, list),
      championNameOf: (id: number) => `英雄${id}`,
      fights: deriveTeamfights(list, seats),
      selectedFightIndex: 0,
      selfPuuid: options.redView ? "puuid-6" : "puuid-1",
    },
    global: { stubs: { AssetIcon: AssetIconStub } },
  });
}

/** 第二行那十根柱子的宽度（百分比）。 */
const barWidths = (wrapper: VueWrapper) =>
  wrapper.findAll(".spectate-player__damage-track i").map((bar) => Number.parseFloat(bar.attributes("style")?.match(/width:\s*([\d.]+)%/)?.[1] ?? "0"));

beforeEach(() => {
  // jsdom 没实现指针捕获，组件里是照真浏览器写的。
  Element.prototype.setPointerCapture = () => {};
  Element.prototype.releasePointerCapture = () => {};
});

describe("观战面板：真机数据形状", () => {
  it("分钟帧里没有伤害字段时，「输出 / 承伤」降级成全场总账并写明口径", () => {
    const wrapper = mountPanel();
    const rowbar = wrapper.get(".spectate__rowbar");
    expect(rowbar.text()).toContain("十人第二行");
    // 口径必须写清是「全场」——要不说，用户会以为拖时间轴应该能看到数字涨。
    expect(rowbar.text()).toContain("全场输出");
    expect(wrapper.get(".spectate__rowbar-note").text()).toContain("全场总账");

    // 柱子按**全场**伤害画：十根都有长度，最高的那个满格（不是一排全零的空轨道）。
    const widths = barWidths(wrapper);
    expect(widths).toHaveLength(10);
    expect(Math.max(...widths)).toBeCloseTo(100, 5);
    expect(widths.filter((width) => width > 0)).toHaveLength(10);
    // 悬浮说明里也要交代为什么是「全场」。
    expect(wrapper.get(".spectate-player__damage").attributes("title")).toContain("全场累计");
  });

  it("帧里**有**伤害字段时仍然是「到此刻累计」（不误伤有数据的对局）", async () => {
    const withDamage = [
      frame(0, ZERO10, ZERO10),
      frame(26, seats.map((_, slot) => (slot + 1) * 1000), seats.map((_, slot) => (slot + 1) * 500)),
    ];
    const wrapper = mountPanel({ frames: withDamage });
    expect(wrapper.get(".spectate__rowbar").text()).toContain("到此刻累计输出");
    expect(wrapper.find(".spectate__rowbar-note").exists()).toBe(false);
    expect(Math.max(...barWidths(wrapper))).toBeCloseTo(100, 5);

    // 拖回开局 → 累计伤害归零，柱子全空（证明它读的确实是帧，而不是全场总账）。
    await wrapper.get(".spectate__timeline").trigger("keydown", { key: "Home" });
    expect(wrapper.get(".spectate__clock strong").text()).toBe("00:00");
    expect(Math.max(...barWidths(wrapper))).toBe(0);
  });

  // 归一化基准必须是**终局**那一帧。若改成「当前游标下十人的最高值」，累计值涨、
  // 分母跟着涨，比值恒定 —— 拖时间轴时只有数字在动，**柱子长度一动不动**，
  // 看上去就和「这一项没数据」完全一样（这正是用户报的那个现象）。
  it("拖动时间轴时柱子长度随游标一起长（不是只有数字在变）", async () => {
    const ramped = [
      frame(0, ZERO10, ZERO10),
      frame(13, seats.map((_, slot) => (slot + 1) * 500), seats.map((_, slot) => (slot + 1) * 100)),
      frame(26, seats.map((_, slot) => (slot + 1) * 1000), seats.map((_, slot) => (slot + 1) * 100)),
    ];
    const wrapper = mountPanel({ frames: ramped });
    const spark = wrapper.get(".spectate__spark");
    const el = spark.element as HTMLElement;
    el.getBoundingClientRect = () =>
      ({ left: 0, right: 600, top: 0, bottom: 68, width: 600, height: 68, x: 0, y: 0, toJSON: () => ({}) }) as DOMRect;
    const pointerEvent = (type: string, clientX: number) => {
      const created = new Event(type, { bubbles: true });
      Object.defineProperty(created, "clientX", { value: clientX });
      Object.defineProperty(created, "pointerId", { value: 1 });
      return created;
    };

    // 终局：最长的那根（10 号位 10000）满格。
    el.dispatchEvent(pointerEvent("pointerdown", 600));
    await nextTick();
    expect(wrapper.get(".spectate__clock strong").text()).toBe("26:00");
    expect(Math.max(...barWidths(wrapper))).toBeCloseTo(100, 5);

    // 拖到一半（13:00）：同样那个人只有 5000，而分母仍是终局的 10000 → 柱子约一半。
    el.dispatchEvent(pointerEvent("pointerup", 600));
    el.dispatchEvent(pointerEvent("pointerdown", 300));
    await nextTick();
    expect(wrapper.get(".spectate__clock strong").text()).toBe("13:00");
    const half = Math.max(...barWidths(wrapper));
    expect(half).toBeGreaterThan(40);
    expect(half).toBeLessThan(60);

    // 回开局：全空。三段连起来 = 柱子确实在随游标长。
    el.dispatchEvent(pointerEvent("pointerup", 300));
    el.dispatchEvent(pointerEvent("pointerdown", 0));
    await nextTick();
    expect(wrapper.get(".spectate__clock strong").text()).toBe("00:00");
    expect(Math.max(...barWidths(wrapper))).toBe(0);
  });

  // 三类事件原来都是「细竖条 + 换颜色」，宽度不到 4px，扫一眼分不出哪根是推塔哪根是击杀。
  // 形状由修饰类决定，所以这里钉的是两件事：三种标记挂**三个不同的**修饰类，
  // 以及图例把三种都列出来——只改时间轴不改图例，图例本身就成了误导。
  it("击杀 / 野怪 / 推塔是三种不同的标记，且图例三种都列了", () => {
    const list: MatchTimelineEvent[] = [
      event(180, { killerId: 1, victimId: 6, killerChampionId: 10, victimChampionId: 60 }),
      event(200, { killerId: 6, victimId: 1, killerChampionId: 60, victimChampionId: 10 }),
      event(300, { type: "ELITE_MONSTER_KILL", monsterType: "DRAGON" }),
      event(420, { type: "BUILDING_KILL", buildingType: "TOWER_BUILDING", laneType: "MID_LANE" }),
    ];
    const wrapper = mountPanel({ events: list });

    for (const selector of [".spectate__mark--kill", ".spectate__mark--monster", ".spectate__mark--building"]) {
      expect(wrapper.findAll(selector).length).toBeGreaterThan(0);
    }
    // 三种标记的修饰类互不相同 —— 否则形状必然相同，区分就没了。
    const modifiers = new Set(
      wrapper.findAll(".spectate__mark").map((mark) => mark.classes().find((name) => name.startsWith("spectate__mark--"))),
    );
    expect(modifiers.size).toBe(3);

    const legend = wrapper.get(".spectate__controls-legend");
    for (const kind of ["kill", "monster", "building"]) {
      expect(legend.findAll(`[data-kind="${kind}"]`).length).toBeGreaterThan(0);
    }
    expect(legend.text()).toContain("击杀");
    expect(legend.text()).toContain("野怪");
    expect(legend.text()).toContain("推塔");
  });

  it("视角方在红方时，十个人的 KDA 与装备照样配得上（不再 000 / 空白）", async () => {
    const wrapper = mountPanel({ redView: true });
    const kda = wrapper.findAll(".spectate-kda").map((chip) => chip.text());
    expect(kda).toHaveLength(10);
    expect(kda).toEqual(players(true).map((item) => `${item.kills}/${item.deaths}/${item.assists}`));
    expect(kda.some((text) => text.startsWith("0/0/0"))).toBe(false);

    // 名字来自十人详情（配不上时会退化成英雄名）。
    expect(wrapper.findAll(".spectate-player")[0].get(".spectate-player__line > b").text()).toContain("玩家1");

    // 「装备」那一行：切过去之后每个人都得有装备图标，而不是一整排「—」。
    await wrapper.findAll(".spectate__rowswitch button")[3].trigger("click");
    expect(wrapper.findAll(".spectate-player__items")).toHaveLength(10);
    expect(wrapper.findAll(".spectate-player__items .asset-icon-stub")).toHaveLength(10);
    expect(wrapper.findAll(".spectate-player__items small")).toHaveLength(0);
  });

  it("「推塔」读的是十人详情里的对塔伤害，红方视角下同样有数", async () => {
    const wrapper = mountPanel({ redView: true });
    await wrapper.findAll(".spectate__rowswitch button")[2].trigger("click");
    const widths = barWidths(wrapper);
    expect(Math.max(...widths)).toBeCloseTo(100, 5);
    expect(widths.filter((width) => width > 0)).toHaveLength(10);
  });

  it("经济差图也能按住拖动擦洗（用户要求「在经济的那个上边也能拖」）", async () => {
    const wrapper = mountPanel();
    const spark = wrapper.get(".spectate__spark");
    const el = spark.element as HTMLElement;
    el.getBoundingClientRect = () =>
      ({ left: 0, right: 600, top: 0, bottom: 68, width: 600, height: 68, x: 0, y: 0, toJSON: () => ({}) }) as DOMRect;
    expect(spark.attributes("title")).toContain("拖动");

    // jsdom 的 MouseEvent 上 `clientX` 只有 getter，VTU 的 trigger 塞不进去，只能自己造事件。
    const pointerEvent = (type: string, clientX: number) => {
      const created = new Event(type, { bubbles: true });
      Object.defineProperty(created, "clientX", { value: clientX });
      Object.defineProperty(created, "pointerId", { value: 1 });
      return created;
    };

    // 一半宽度 → 游标落在总时长一半（1560s / 2 = 13:00）。
    el.dispatchEvent(pointerEvent("pointerdown", 300));
    await nextTick();
    expect(wrapper.get(".spectate__clock strong").text()).toBe("13:00");
    el.dispatchEvent(pointerEvent("pointermove", 0));
    await nextTick();
    expect(wrapper.get(".spectate__clock strong").text()).toBe("00:00");
    // 松手之后再移动就不该有反应了（擦洗必须真的结束）。
    el.dispatchEvent(pointerEvent("pointerup", 0));
    el.dispatchEvent(pointerEvent("pointermove", 300));
    await nextTick();
    expect(wrapper.get(".spectate__clock strong").text()).toBe("00:00");
  });
});
