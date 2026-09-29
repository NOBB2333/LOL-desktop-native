import { mount } from "@vue/test-utils";
import type { VueWrapper } from "@vue/test-utils";
import { beforeEach, describe, expect, it } from "vitest";
import { nextTick } from "vue";
import type { GameRecordingFrame, GameRecordingPlayer, MatchParticipant, MatchSummary, MatchTimeline, MatchTimelineEvent, MatchTimelineFrame } from "../types/domain";
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

function mountPanel(options: { frames?: MatchTimelineFrame[]; redView?: boolean; events?: MatchTimelineEvent[]; recording?: GameRecordingFrame[] } = {}) {
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
      recording: options.recording ?? [],
    },
    global: { stubs: { AssetIcon: AssetIconStub } },
  });
}

/**
 * 本机录制的某一帧。
 *
 * 真机上这是后端按采样间隔存下来的快照（见 `backend/game_recording.zig`）：每人当时的
 * 装备（只有 itemID）与 K/D/A。这里给十个人同一份数值——用例关心的是「游标拖到哪一刻
 * 取哪一帧」，不是十个人之间的差异。
 *
 * ⚠️ `puuid` **必须是空串**，照真机来：Live Client Data 的 `allPlayers` 里**根本没有
 * `puuid` 字段**（官方字段集只有 championName/isBot/isDead/items/level/position/
 * rawChampionName/respawnTimer/runes/scores/skinID/summonerName/summonerSpells/team），
 * 所以后端写出来恒为 `""`。桩里如果填上能对上的 puuid，就会把
 * 「按 puuid 配对所以永远配不上」这个真 bug **遮住**——2026-09-29 正是这么漏掉的，
 * 用户侧表现是「拖时间轴，战绩和装备一点都不变」。
 */
function recordingFrame(t: number, kills: number, items: number[], overrides: Partial<Record<number, Partial<GameRecordingPlayer>>> = {}): GameRecordingFrame {
  return {
    t,
    gameId: 1,
    sampledAt: "2026-09-27T10:00:00.000Z",
    players: seats.map((seat) => ({
      puuid: "",
      rid: `玩家${seat.participantId}#CN1`,
      team: seat.team === BLUE ? "ORDER" : "CHAOS",
      champ: `英雄${seat.championId}`,
      cid: seat.championId,
      pos: "MIDDLE",
      lvl: 10,
      k: kills,
      d: 0,
      a: 0,
      cs: 150,
      ward: 5,
      dead: false,
      respawn: 0,
      bot: false,
      items,
      spells: [],
      ...overrides[seat.participantId],
    })),
    me: null,
  };
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

/**
 * 本机录制接进观战面板（2026-09-27）。
 *
 * 官方数据源里只有**终局**装备与终局 KDA，中间过程看不到——「那一刻他什么装备、几杀几死」
 * 这两项只能靠本机录制（设置里可选的开关，默认关）。所以两个方向都要钉住：
 * 有录制时跟着游标走；没录到这一局时原样退回终局口径（数值和版面都不变）。
 */
describe("观战面板：本机录制的「此刻」口径", () => {
  const RECORDING = [recordingFrame(60, 1, [100]), recordingFrame(600, 5, [200, 300])];

  it("有录制时 K/D/A 跟着游标走（不再永远是终局值）", async () => {
    const wrapper = mountPanel({ recording: RECORDING });
    // 默认停在终局（26:00）→ 取 600 秒那一帧。
    expect(wrapper.findAll(".spectate-kda").map((chip) => chip.text())).toEqual(Array.from({ length: 10 }, () => "5/0/0"));
    // 拖回开局 → 只能拿到最早的那一帧（60 秒）；两帧之间没有数据，不做插值。
    await wrapper.get(".spectate__timeline").trigger("keydown", { key: "Home" });
    expect(wrapper.findAll(".spectate-kda").map((chip) => chip.text())).toEqual(Array.from({ length: 10 }, () => "1/0/0"));

    // 口径必须写在界面上：这两项现在是「游标那一刻」，不是终局。
    expect(wrapper.get(".spectate__rowbar").text()).toContain("本局有本机录制");
    expect(wrapper.get(".spectate-kda").attributes("data-live")).toBe("true");
    expect(wrapper.get(".spectate-player__stats").attributes("title")).toContain("那一刻");
  });

  it("有录制时「装备」那一行也跟着游标换（终局出装 → 此刻出装）", async () => {
    const wrapper = mountPanel({ recording: RECORDING });
    await wrapper.findAll(".spectate__rowswitch button")[3].trigger("click");
    expect(wrapper.get(".spectate__rowbar").text()).toContain("此刻出装");
    // 终局那一帧每人两件。
    expect(wrapper.findAll(".spectate-player__items .asset-icon-stub")).toHaveLength(20);

    await wrapper.get(".spectate__timeline").trigger("keydown", { key: "Home" });
    // 第 60 秒那一帧每人一件——数量变了，说明读的确实是录制，而不是十人详情的终局装备。
    expect(wrapper.findAll(".spectate-player__items .asset-icon-stub")).toHaveLength(10);
  });

  it("录制帧里配不上这个人（puuid 缺席）时退回终局口径，而不是显示成没装备", async () => {
    const partial: GameRecordingFrame[] = [{ ...recordingFrame(600, 9, [200]), players: [] }];
    const wrapper = mountPanel({ recording: partial });
    await wrapper.findAll(".spectate__rowswitch button")[3].trigger("click");
    // 十人详情里每人一件装备（见 `players()`），十个人一个都不能少。
    expect(wrapper.findAll(".spectate-player__items .asset-icon-stub")).toHaveLength(10);
    // K/D/A 退回十人详情的终局值（第一行是 3/2/5），且不再标成「此刻」。
    expect(wrapper.findAll(".spectate-kda")[0].text()).toBe("3/2/5");
    expect(wrapper.get(".spectate-kda").attributes("data-live")).toBeUndefined();
  });

  it("没有录制时一切照旧：终局 KDA、终局出装，通栏不出现录制提示", async () => {
    const wrapper = mountPanel();
    expect(wrapper.find(".spectate__rowbar-note[data-tone='recording']").exists()).toBe(false);
    expect(wrapper.findAll(".spectate-kda")[0].text()).toBe("3/2/5");
    await wrapper.findAll(".spectate__rowswitch button")[3].trigger("click");
    expect(wrapper.get(".spectate__rowbar").text()).toContain("终局出装");
  });

  /**
   * 回归：**录制帧里 `puuid` 是空的**（真机如此，见 `recordingFrame` 的注释）。
   *
   * 这条用例是这次报障的正身——用户说「拖动时间轴，人的战绩和装备完全没有变化」。
   * 旧实现只按 `entry.puuid === player.puuid` 配，帧里 puuid 恒空 → 永远配不上 →
   * 静默退回终局值。桩里一旦不写假 puuid（照真机写 ""），这条就会红；
   * 修好之后必须靠 `rid`（名字部分）配上。
   */
  it("帧里 puuid 为空（真机形状）时仍然按 rid 配上，K/D/A 与装备跟着游标走", async () => {
    const pct: GameRecordingFrame[] = [recordingFrame(60, 1, [100]), recordingFrame(600, 5, [200, 300])];
    // 自证桩确实是「空 puuid」这一形状，免得哪天桩被改回去、用例又变成假绿。
    expect(pct[0].players.every((entry) => entry.puuid === "")).toBe(true);

    const wrapper = mountPanel({ recording: pct });
    // 终局 → 600 秒那一帧的 5/0/0，而不是十人详情的终局 3/2/5。
    expect(wrapper.findAll(".spectate-kda")[0].text()).toBe("5/0/0");
    expect(wrapper.get(".spectate-kda").attributes("data-live")).toBe("true");

    await wrapper.get(".spectate__timeline").trigger("keydown", { key: "Home" });
    expect(wrapper.findAll(".spectate-kda")[0].text()).toBe("1/0/0");
  });

  it("名字与英雄都对不上时，退到「同阵营」兜底（宁可给错人也不整行空掉）", async () => {
    // 帧里十个人换了名、也换了英雄 → 前两档（rid / 名字 / 同英雄）全落空，
    // 落到最后一档「同阵营任意未被认领的人」。这是**刻意的**兜底：整行空掉比给错人
    // 更糟（用户看不出是数据缺还是坏了），而且真机上同阵营人数与帧内人数是对得上的。
    const frames: GameRecordingFrame[] = [
      {
        ...recordingFrame(600, 9, [999]),
        players: recordingFrame(600, 9, [999]).players.map((entry) => ({ ...entry, rid: "陌生人#XXX", cid: 1, champ: "别人" })),
      },
    ];
    const wrapper = mountPanel({ recording: frames });
    expect(wrapper.findAll(".spectate-kda")[0].text()).toBe("9/0/0");
  });

  it("帧里五个人全被认领之后，不会被同一个座位重复吃掉（不出现「两个人同一个数」）", async () => {
    // 只留我方 5 人（真机训练/自定义局就是这样），且名字英雄全对不上 →
    // 前 5 个座位各拿一个，后 5 个座位拿不到（返回 null，退回终局值），
    // 而不是 10 个座位都指向同一个人。
    const five = recordingFrame(600, 4, [200]).players.slice(0, 5).map((entry) => ({ ...entry, rid: "陌生人#XXX", cid: 1 }));
    const wrapper = mountPanel({ recording: [{ ...recordingFrame(600, 4, [200]), players: five }] });
    const chips = wrapper.findAll(".spectate-kda").map((chip) => chip.text());
    expect(chips.filter((text) => text === "4/0/0")).toHaveLength(5);
    // 剩下 5 个座位拿不到录制 → 退回十人详情的终局值，而不是继续吃那 5 个人。
    expect(chips.filter((text) => text !== "4/0/0")).toHaveLength(5);
  });
});

/**
 * 阵亡状态：用户要「死了之后头像变灰、给复活读秒」。
 *
 * 数据只在**本机录制**里（`allPlayers[].isDead` 是实时值，官方战绩接口没有「某一刻死没死」），
 * 所以没录制时**不能编**——灰化和读秒都必须消失。
 */
describe("观战面板：阵亡状态灰化与复活读秒", () => {
  it("录制说这个人此刻死了 → 头像标灰 + 出复活读秒", async () => {
    const frames = [recordingFrame(600, 5, [200], { 1: { dead: true, respawn: 7.4 } })];
    const wrapper = mountPanel({ recording: frames });
    const dots = wrapper.findAll(".spectate__dot");
    const dead = dots.filter((dot) => dot.classes().includes("is-dead"));
    expect(dead).toHaveLength(1);
    expect(dead[0].text()).toBe("8"); // ceil(7.4)
    expect(dead[0].attributes("title")).toContain("已阵亡");
  });

  it("没录到这一局时不知道死没死 → 一个灰头像、一个读秒都不画", async () => {
    const wrapper = mountPanel();
    expect(wrapper.findAll(".spectate__dot.is-dead")).toHaveLength(0);
    expect(wrapper.findAll(".spectate__dot-timer")).toHaveLength(0);
  });
});

/**
 * 「人死了之后他还能动」——用户 2026-09-29 报的。
 *
 * **不是数据问题**：客户端分钟帧里的 `positions` 一直是对的（每帧十个人、坐标全非零）。
 * 是我们自己在**两帧之间做平滑插值**（`animatedPositions`，为了走位好读）：阵亡那一刻
 * 人倒在倒地处，下一分钟帧他已经在泉水 → 插值就把尸体**从倒地处一路拖回泉水**。
 *
 * 修法 = 阵亡期间把坐标**钉在他最后一次活着的采样点**（`freezePositionWhileDead`）。
 * 这一组用例盯的是「面板真的这么画」——map 上的圆点用 `left`/`top` 百分比定位。
 */
describe("观战面板：阵亡后不能再动", () => {
  /** 第 1 个座位（蓝方）在地图左下 → 右上，一路走。其余座位不动。 */
  function walking(minute: number, x: number, y: number): MatchTimelineFrame {
    const base = frame(minute);
    return { ...base, positions: base.positions!.map((point, slot) => (slot === 0 ? { x, y } : point)) };
  }

  /** map 上第 `seat` 个圆点的定位百分比。 */
  const dotAt = (wrapper: VueWrapper, index: number) => {
    const style = wrapper.findAll(".spectate__dot")[index].attributes("style") ?? "";
    return { left: style.match(/left:\s*([\d.]+)%/)?.[1], top: style.match(/top:\s*([\d.]+)%/)?.[1] };
  };

  it("阵亡期间拖时间轴，圆点钉在倒地处一动不动", async () => {
    // 第 20 分钟他在 (3000, 3000)，第 21 分钟（已阵亡）帧里他到 (14000, 14000) 了。
    const frames = [walking(20, 3000, 3000), walking(21, 14000, 14000)];
    const recording = [recordingFrame(1260, 5, [200], { 1: { dead: true, respawn: 30 } })];
    const wrapper = mountPanel({ frames, recording });

    // 游标落在第 21 分钟 → 但人已阵亡，位置必须是「最后一次活着」的那点。
    await wrapper.get(".spectate__timeline").trigger("keydown", { key: "End" });
    await nextTick();
    const before = dotAt(wrapper, 0);

    // 往回拖一点点（仍在他倒地之后、同一分钟窗口内）——插值本来会让它移动。
    await wrapper.get(".spectate__timeline").trigger("keydown", { key: "ArrowLeft", shiftKey: true });
    await nextTick();
    expect(dotAt(wrapper, 0)).toEqual(before);
  });

  it("活着的时候照旧随游标移动（钉死只对死人生效，不误伤活人）", async () => {
    const frames = [walking(20, 3000, 3000), walking(21, 14000, 14000)];
    // 没有任何录制 → 不知道死没死 → 纯插值，位置应当随游标连续变化。
    const wrapper = mountPanel({ frames });
    await wrapper.get(".spectate__timeline").trigger("keydown", { key: "End" });
    await nextTick();
    const end = dotAt(wrapper, 0);
    await wrapper.get(".spectate__timeline").trigger("keydown", { key: "Home" });
    await nextTick();
    expect(dotAt(wrapper, 0)).not.toEqual(end);
  });

  it("阵亡之后被钉住，活着的人照旧走插值（同一时刻两者位置不同）", async () => {
    // 走路幅度刻意压在 `INSTANT_MOVE_DISTANCE`（3200）以内：这样插值是**线性**的，
    // 游标落在两帧中间时活人正好在半路上，死人则钉在起点 —— 两者必须能分辨出来。
    // （用大跨度位移会被 `easedFraction` 在前 12% 就送到底，两条线又重合了，测不出东西。）
    const frames = [walking(20, 3000, 3000), walking(21, 3400, 3200)];
    const dead = [recordingFrame(1230, 5, [200], { 1: { dead: true, respawn: 30 } })];
    const alive = [recordingFrame(1230, 5, [200], { 1: { dead: false, respawn: 0 } })];
    const panels = [mountPanel({ frames, recording: alive }), mountPanel({ frames, recording: dead })];
    // 游标落在**两帧中间**（20:30 = 1230 秒，全场 1560 秒 → 横向 78.8% 处）。
    const clientX = Math.round((1230 / 1560) * 600);
    for (const panel of panels) {
      const timelineEl = panel.get(".spectate__timeline");
      const el = timelineEl.element as HTMLElement;
      el.getBoundingClientRect = () =>
        ({ left: 0, right: 600, top: 0, bottom: 40, width: 600, height: 40, x: 0, y: 0, toJSON: () => ({}) }) as DOMRect;
      const created = new Event("pointerdown", { bubbles: true });
      Object.defineProperty(created, "clientX", { value: clientX });
      timelineEl.element.dispatchEvent(created);
      await nextTick();
    }
    // 先证明游标真的落到 20:30 了（否则下面「两者不同」可能只是两个都没动）。
    expect(panels[0].get(".spectate__clock strong").text()).toBe("20:30");
    const [aliveDot, deadDot] = [dotAt(panels[0], 0), dotAt(panels[1], 0)];
    expect(aliveDot).not.toEqual(deadDot);
    // 而且是**死人更靠起点**（钉住），不是反过来。
    expect(Number.parseFloat(deadDot.left!)).toBeLessThan(Number.parseFloat(aliveDot.left!));
  });
});
