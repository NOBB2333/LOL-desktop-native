import { describe, expect, it } from "vitest";
import type { MatchTimelineEvent, MatchTimelineFrame } from "../types/domain";
import { animatedPositions, buildingLabel, clockOf, compactGold, eventDetail, eventTitle, freezePositionWhileDead, killTally, monsterLabel, pathFrom, positionHistory, signedGold, splitBySign, teamLabel } from "./timeline";

const event = (base: Partial<MatchTimelineEvent> & Pick<MatchTimelineEvent, "type">): MatchTimelineEvent => ({
  seconds: 60,
  team: 100,
  killerId: 0,
  victimId: 0,
  assistCount: 0,
  assistIds: [],
  killerChampionId: 0,
  victimChampionId: 0,
  posX: 0,
  posY: 0,
  monsterType: "",
  monsterSubType: "",
  buildingType: "",
  towerType: "",
  laneType: "",
  ...base,
});

describe("timeline formatting", () => {
  it("formats clock and gold values without leaking negative time", () => {
    expect(clockOf(0)).toBe("00:00");
    expect(clockOf(59)).toBe("00:59");
    expect(clockOf(65)).toBe("01:05");
    expect(clockOf(1832)).toBe("30:32");
    // 脏数据不该画出 `-1:-3` 这种东西。
    expect(clockOf(-5)).toBe("00:00");
    expect(clockOf(Number.NaN)).toBe("00:00");
  });

  it("compacts gold and keeps the sign", () => {
    expect(compactGold(999)).toBe("999");
    expect(compactGold(1250)).toBe("1.3k");
    // 两位数 k 必须保住小数：用户报的就是「一过 10k 就只剩 10/11/12」。
    expect(compactGold(6520)).toBe("6.5k");
    expect(compactGold(10500)).toBe("10.5k");
    expect(compactGold(24300)).toBe("24.3k");
    // 到三位数 k 才舍小数，免得 Y 轴被挤爆。
    expect(compactGold(123400)).toBe("123k");
    expect(signedGold(2400)).toBe("+2.4k");
    expect(signedGold(-8100)).toBe("-8.1k");
    expect(signedGold(0)).toBe("0");
  });

  it("names both teams, and admits when it does not know", () => {
    expect(teamLabel(100)).toBe("蓝方");
    expect(teamLabel(200)).toBe("红方");
    expect(teamLabel(0)).toBe("未知方");
  });
});

describe("timeline event labels", () => {
  it("prefers the dragon sub-type so the timeline is not all just 小龙", () => {
    expect(monsterLabel(event({ type: "ELITE_MONSTER_KILL", monsterType: "DRAGON", monsterSubType: "FIRE_DRAGON" }))).toBe("火龙");
    expect(monsterLabel(event({ type: "ELITE_MONSTER_KILL", monsterType: "DRAGON", monsterSubType: "ELDER_DRAGON" }))).toBe("远古龙");
    expect(monsterLabel(event({ type: "ELITE_MONSTER_KILL", monsterType: "DRAGON" }))).toBe("小龙");
    expect(monsterLabel(event({ type: "ELITE_MONSTER_KILL", monsterType: "BARON_NASHOR" }))).toBe("大龙");
    expect(monsterLabel(event({ type: "ELITE_MONSTER_KILL", monsterType: "RIFTHERALD" }))).toBe("峡谷先锋");
  });

  it("keeps lane and tower tier for buildings, and drops the tier for inhibitors", () => {
    expect(buildingLabel(event({ type: "BUILDING_KILL", buildingType: "TOWER_BUILDING", towerType: "OUTER_TURRET", laneType: "BOT_LANE" }))).toBe("下路一塔");
    expect(buildingLabel(event({ type: "BUILDING_KILL", buildingType: "TOWER_BUILDING", towerType: "BASE_TURRET", laneType: "MID_LANE" }))).toBe("中路高地塔");
    expect(buildingLabel(event({ type: "BUILDING_KILL", buildingType: "INHIBITOR_BUILDING", laneType: "TOP_LANE" }))).toBe("上路水晶");
    // 认不出塔型时退回「防御塔」，不要吐出空字符串。
    expect(buildingLabel(event({ type: "BUILDING_KILL", buildingType: "TOWER_BUILDING", laneType: "MID_LANE" }))).toBe("中路防御塔");
  });

  it("describes who did what, and says 单杀 instead of 0 助攻", () => {
    expect(eventTitle(event({ type: "CHAMPION_KILL" }))).toBe("击杀");
    expect(eventDetail(event({ type: "CHAMPION_KILL", assistCount: 3 }))).toBe("蓝方 · 3 助攻");
    expect(eventDetail(event({ type: "CHAMPION_KILL", assistCount: 0 }))).toBe("蓝方 · 单杀");
    expect(eventDetail(event({ type: "ELITE_MONSTER_KILL", monsterType: "BARON_NASHOR", team: 200 }))).toBe("红方拿到");
    expect(eventDetail(event({ type: "BUILDING_KILL", buildingType: "TOWER_BUILDING", team: 100 }))).toBe("蓝方推掉");
    expect(eventDetail(event({ type: "TURRET_PLATE_DESTROYED", team: 200 }))).toBe("红方拆掉");
  });

  it("uses the lane for a turret plate title", () => {
    expect(eventTitle(event({ type: "TURRET_PLATE_DESTROYED", laneType: "MID_LANE" }))).toBe("中路镀层");
  });

  it("counts kills per side and ignores the other event types", () => {
    const tally = killTally([
      event({ type: "CHAMPION_KILL", team: 100 }),
      event({ type: "CHAMPION_KILL", team: 100 }),
      event({ type: "CHAMPION_KILL", team: 200 }),
      event({ type: "ELITE_MONSTER_KILL", team: 200 }),
      event({ type: "BUILDING_KILL", team: 200, buildingType: "TOWER_BUILDING" }),
    ]);
    expect(tally).toEqual({ blue: 2, red: 1 });
  });
});

describe("timeline curve splitting", () => {
  it("splits the curve at the zero crossing so both halves keep a point on the axis", () => {
    const runs = splitBySign(
      [
        { x: 0, y: 80, value: -800 },
        { x: 10, y: 20, value: -200 },
        { x: 20, y: 20, value: 200 },
        { x: 30, y: 80, value: 800 },
      ],
      50,
    );

    expect(runs).toHaveLength(2);
    expect(runs[0].leading).toBe(false);
    expect(runs[1].leading).toBe(true);
    // 交点在 15 处（-200 → 200 的中点），y 落在零轴。
    expect(runs[0].points[runs[0].points.length - 1]).toEqual({ x: 15, y: 50 });
    expect(runs[1].points[0]).toEqual({ x: 15, y: 50 });
  });

  it("keeps a single run when the whole game is one-sided", () => {
    const runs = splitBySign(
      [
        { x: 0, y: 40, value: 100 },
        { x: 10, y: 30, value: 300 },
      ],
      50,
    );
    expect(runs).toHaveLength(1);
    expect(runs[0].leading).toBe(true);
  });

  it("renders a polyline path", () => {
    expect(pathFrom([{ x: 1, y: 2 }, { x: 3, y: 4 }])).toBe("M1.0,2.0 L3.0,4.0");
    expect(pathFrom([])).toBe("");
  });
});

/**
 * 观战地图的走位口径（2026-09-27 一天内改过两版，这是最终版，勿再回退）。
 *
 * 位置是**每分钟一个采样点**，不是轨迹——中间那 59 秒真实怎么走的，数据里没有。所以：
 * - 画面上**仍然平滑过渡**（`animatedPositions`）。不插值就是「整分钟纹丝不动 + 十个人
 *   集体闪现」，用户当场否掉：「原本在地图上来回跑那个移动没有了，现在变成了瞬间跳」。
 * - 平滑**绝不允许往未知坐标靠**。旧实现只判左端，右端为 (0,0) 时照样按比例插过去，
 *   小人就被拉向地图角——那才是用户最初说的「往他没去过的地方走」。这条必须钉死。
 * - 「原始数据长什么样」由悬停采样点（`positionHistory`）单独承担：只有点、不连线。
 */
describe("map positions glide between per-minute samples without inventing unknown spots", () => {
  const frame = (minute: number, positions: { x: number; y: number }[]): MatchTimelineFrame => ({
    minute,
    blueGold: 0,
    redGold: 0,
    goldDiff: 0,
    blueCs: 0,
    redCs: 0,
    gold: positions.map(() => 0),
    level: positions.map(() => 1),
    damage: positions.map(() => 0),
    taken: positions.map(() => 0),
    positions,
  });
  const seats = (x: number, y: number) => [{ x, y }, { x, y }];

  it("glides between the surrounding samples so the avatar never freezes for a whole minute", () => {
    const frames = [frame(1, seats(1000, 1000)), frame(2, seats(2000, 2000)), frame(3, seats(4000, 4000))];
    // 02:05 = 第 2 帧 + 5/60 → 2000 + (4000-2000) × 5/60 = 2166.7 → 2167。
    // （不插值的旧版这里给的是 2000，正是「瞬间跳」的观感来源。）
    expect(animatedPositions(frames, 125)).toEqual(seats(2167, 2167));
    // 2:59 已经快走到下一帧了，但还没越过整分钟。
    expect(animatedPositions(frames, 179)).toEqual(seats(3967, 3967));
    // 正好落在帧上时按比例 0 处理，取原值。
    expect(animatedPositions(frames, 180)).toEqual(seats(4000, 4000));
  });

  it("never interpolates toward an unknown position (the real 'walking somewhere he never went' bug)", () => {
    // 右端没有坐标：旧实现会按比例往 (0,0) 靠 → 小人被拉向地图角。现在必须原地保留左端。
    const rightUnknown = [frame(1, [{ x: 1000, y: 1000 }]), frame(2, [{ x: 0, y: 0 }])];
    expect(animatedPositions(rightUnknown, 90)).toEqual([{ x: 1000, y: 1000 }]);
    // 左端没有坐标、右端有：用已知的那一端，同样不往 0/0 插。
    const leftUnknown = [frame(1, [{ x: 0, y: 0 }]), frame(2, [{ x: 2000, y: 2000 }])];
    expect(animatedPositions(leftUnknown, 90)).toEqual([{ x: 2000, y: 2000 }]);
    // 两端都没有 → 交 0/0 给上游跳过（不画这个点）。
    const bothUnknown = [frame(1, [{ x: 0, y: 0 }]), frame(2, [{ x: 0, y: 0 }])];
    expect(animatedPositions(bothUnknown, 90)).toEqual([{ x: 0, y: 0 }]);
  });

  it("does not let one unknown seat poison the others", () => {
    const frames = [frame(1, [{ x: 0, y: 0 }, { x: 900, y: 900 }]), frame(2, [{ x: 600, y: 600 }, { x: 1500, y: 1500 }])];
    const at = animatedPositions(frames, 90);
    expect(at?.[0]).toEqual({ x: 600, y: 600 });
    expect(at?.[1]).toEqual({ x: 1200, y: 1200 });
  });

  it("returns null without frames, and holds the earliest frame before the first minute", () => {
    // 后端不写 minute<=0 的帧，所以拖到 0:30 时手上只有第 1 分钟那一份——给最早的一份，
    // 好过整张地图空掉（比例算 0，等于不插值）。
    const frames = [frame(1, seats(700, 700)), frame(2, seats(1400, 1400))];
    expect(animatedPositions(frames, 30)).toEqual(seats(700, 700));
    expect(animatedPositions([], 30)).toBeNull();
  });

  it("collects one seat's sample points up to the cursor, skipping unknown ones", () => {
    const frames = [
      frame(1, [{ x: 100, y: 100 }, { x: 0, y: 0 }]),
      frame(2, [{ x: 200, y: 200 }, { x: 500, y: 500 }]),
      frame(3, [{ x: 300, y: 300 }, { x: 600, y: 600 }]),
    ];
    // 02:05 → 第 1、2 帧两个点。尾巴**不去掉**：头像现在是插值到两帧之间的，
    // 最后一个真采样点仍然有意义（它标的是「最后一次确认他在哪」）。
    expect(positionHistory(frames, 125, 0)).toEqual([{ x: 100, y: 100 }, { x: 200, y: 200 }]);
    // 第 1 帧那个座位没有坐标 → 跳过，不塞一个 0/0 假点到地图左上角。
    expect(positionHistory(frames, 200, 1)).toEqual([{ x: 500, y: 500 }, { x: 600, y: 600 }]);
    // 还没过第 1 分钟：没有任何「之前」的采样点。
    expect(positionHistory(frames, 30, 0)).toEqual([]);
    expect(positionHistory([], 200, 0)).toEqual([]);
  });
});

/**
 * 移动**不是匀速的**（2026-09-29 用户指出）。
 *
 * 玩家真实的位移里混着闪现 / 传送 / 回城 / 复活，这些是**瞬间**换位置，不是慢慢平移。
 * 所以插值按位移量重映射进度：小步走位保持匀速，大跨度位移在整分钟很前面就完成。
 * 这是近似（帧里没有「他第几秒闪的」），但对观感的改善是决定性的：
 * 原来闪现看起来像「花一整分钟慢慢飘过去」。
 */
describe("map movement is not uniform: blinks/teleports cover ground almost instantly", () => {
  const frame = (minute: number, positions: { x: number; y: number }[]): MatchTimelineFrame => ({
    minute,
    blueGold: 0,
    redGold: 0,
    goldDiff: 0,
    blueCs: 0,
    redCs: 0,
    gold: positions.map(() => 0),
    level: positions.map(() => 1),
    damage: positions.map(() => 0),
    taken: positions.map(() => 0),
    positions,
  });

  it("常规走位仍按整分钟匀速走完（不被重映射误伤）", () => {
    // 一分钟只挪了 1000 单位（< 瞬时阈值）：进度就该是线性的。
    const frames = [frame(1, [{ x: 1000, y: 1000 }]), frame(2, [{ x: 2000, y: 1000 }])];
    // 半分钟 → 正好走到一半。
    expect(animatedPositions(frames, 90)).toEqual([{ x: 1500, y: 1000 }]);
    // 1/10 分钟 → 走到 10%。
    expect(animatedPositions(frames, 66)).toEqual([{ x: 1100, y: 1000 }]);
  });

  it("大跨度位移在整分钟的前一小段就到位，之后一直停在终点", () => {
    // 一分钟从 (1000,1000) 跳到 (13000,13000)：位移 ≈16970，远超瞬时阈值 → 按瞬移处理。
    const frames = [frame(1, [{ x: 1000, y: 1000 }]), frame(2, [{ x: 13000, y: 13000 }])];
    // 前 4%（≈2.4 秒）就应该已经走到 4/12 ≈ 33% 的路程，而不是匀速的 4%。
    const early = animatedPositions(frames, 62.4)?.[0];
    expect(early?.x).toBeGreaterThan(4000);
    // 过了 12% 的点（1:07.2）就已经完全到位。
    expect(animatedPositions(frames, 68)).toEqual([{ x: 13000, y: 13000 }]);
    // 之后一直不动（剩下的 50 秒停住），这正是「闪过去然后站着」的观感。
    expect(animatedPositions(frames, 110)).toEqual([{ x: 13000, y: 13000 }]);
  });

  it("同一帧里两个座位各自按自己的位移量决定快慢（不会互相带偏）", () => {
    const frames = [
      frame(1, [{ x: 1000, y: 1000 }, { x: 1000, y: 1000 }]),
      frame(2, [{ x: 13000, y: 13000 }, { x: 2000, y: 1000 }]),
    ];
    const at = animatedPositions(frames, 90); // 半分钟
    // 座位 1 是瞬移 → 早已到位；座位 2 是常规走位 → 只走了一半。
    expect(at?.[0]).toEqual({ x: 13000, y: 13000 });
    expect(at?.[1]).toEqual({ x: 1500, y: 1000 });
  });
});

describe("a dead player is pinned to where they fell (they must not keep walking)", () => {
  const frame = (minute: number, positions: { x: number; y: number }[]): MatchTimelineFrame => ({
    minute,
    blueGold: 0,
    redGold: 0,
    goldDiff: 0,
    blueCs: 0,
    redCs: 0,
    gold: positions.map(() => 0),
    level: positions.map(() => 1),
    damage: positions.map(() => 0),
    taken: positions.map(() => 0),
    positions,
  });

  it("阵亡时钉在倒下的位置，不再朝下一帧插值", () => {
    // 第 5 分钟倒在 (3000,3000)，第 6 分钟的采样点已经在泉水 (12000,12000)。
    const frames = [frame(5, [{ x: 3000, y: 3000 }]), frame(6, [{ x: 12000, y: 12000 }])];
    const animated = animatedPositions(frames, 330); // 5:30，正处在两帧之间
    // 不管的话插值会把他拖到半路——那正是用户看到的「死了还在动」。
    expect(animated?.[0]?.x).toBeGreaterThan(3000);
    // 钉住之后：停在倒下的地方。
    expect(freezePositionWhileDead(animated, frames, 330, 0, true)).toEqual({ x: 3000, y: 3000 });
  });

  it("同一帧里活着的座位照常插值（只钉死掉的那个）", () => {
    const frames = [
      frame(5, [{ x: 3000, y: 3000 }, { x: 1000, y: 1000 }]),
      frame(6, [{ x: 12000, y: 12000 }, { x: 3000, y: 1000 }]),
    ];
    const animated = animatedPositions(frames, 330);
    const dead = freezePositionWhileDead(animated, frames, 330, 0, true);
    const alive = freezePositionWhileDead(animated, frames, 330, 1, false);
    expect(dead).toEqual({ x: 3000, y: 3000 });
    expect(alive).toEqual({ x: 2000, y: 1000 }); // 常规走位，正好一半
  });

  it("复活后（dead=false）立刻恢复正常插值", () => {
    const frames = [frame(5, [{ x: 3000, y: 3000 }]), frame(6, [{ x: 12000, y: 12000 }])];
    const animated = animatedPositions(frames, 330);
    expect(freezePositionWhileDead(animated, frames, 330, 0, false)).toEqual(animated?.[0]);
  });

  it("后面还有更近的采样点时，钉的是「倒下那一刻」而不是开局的位置", () => {
    const frames = [
      frame(3, [{ x: 1000, y: 1000 }]),
      frame(4, [{ x: 2000, y: 2000 }]),
      frame(5, [{ x: 3000, y: 3000 }]),
      frame(6, [{ x: 12000, y: 12000 }]),
    ];
    // 游标 5:30 → 之前最后一个已知点是第 5 帧的 (3000,3000)。
    expect(freezePositionWhileDead(animatedPositions(frames, 330), frames, 330, 0, true)).toEqual({ x: 3000, y: 3000 });
  });

  it("没有位置数据时原样返回 null，不会凭空造一个坐标", () => {
    expect(freezePositionWhileDead(null, [], 330, 0, true)).toBeNull();
  });
});
