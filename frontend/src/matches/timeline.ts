/**
 * 对局时间线的纯函数部分：时间/经济格式化，以及把后端事件翻译成中文文案。
 *
 * 拆出来单独放，是为了让「翻译口径」这一层能被单测覆盖——时间线最容易出的错不是
 * 画不出图，而是把「谁推了谁的塔」说反了。它不依赖任何组件状态。
 */
import type { MatchTimelineEvent, MatchTimelineFrame } from "../types/domain";

export const TEAM_BLUE = 100;
export const TEAM_RED = 200;

export const teamLabel = (team: number) => (team === TEAM_BLUE ? "蓝方" : team === TEAM_RED ? "红方" : "未知方");

/** 事件归属方：事件里的 `team` 一律是**做这件事的一方**（后端已推导）。 */
export const eventSide = (event: MatchTimelineEvent) => teamLabel(event.team);

/** mm:ss。负数和 NaN 都夹成 00:00，免得图上出现 `-1:-3`。 */
export function clockOf(seconds: number): string {
  const total = Number.isFinite(seconds) ? Math.max(0, Math.round(seconds)) : 0;
  return `${String(Math.floor(total / 60)).padStart(2, "0")}:${String(total % 60).padStart(2, "0")}`;
}

/**
 * 1.2k 这种紧凑写法：折线图的 Y 轴只有几十像素宽，写全数字会被挤爆。
 *
 * 小数位只在**三位数 k**（≥100k）时才舍掉，`6.5k / 10.5k / 24.3k` 都要保住小数——
 * 之前是 ≥10k 就 `toFixed(0)`，于是两位数的 k 全变成 `10k/11k/12k`，
 * 用户看到的就是「一过 10k 小数就没了」。
 */
export function compactGold(value: number): string {
  const abs = Math.abs(Math.round(value));
  if (abs < 1000) return String(abs);
  const k = abs / 1000;
  return `${k.toFixed(k >= 100 ? 0 : 1)}k`;
}

/** 带符号的经济差，用于「谁领先多少」。 */
export function signedGold(value: number): string {
  if (value === 0) return "0";
  return `${value > 0 ? "+" : "-"}${compactGold(value)}`;
}

const monsterLabels: Record<string, string> = {
  DRAGON: "小龙",
  BARON_NASHOR: "大龙",
  RIFTHERALD: "峡谷先锋",
  HORDE: "虚空巢虫",
};

const dragonLabels: Record<string, string> = {
  FIRE_DRAGON: "火龙",
  OCEAN_DRAGON: "海龙",
  EARTH_DRAGON: "土龙",
  AIR_DRAGON: "风龙",
  HEXTECH_DRAGON: "海克斯龙",
  CHEMTECH_DRAGON: "化工龙",
  ELDER_DRAGON: "远古龙",
};

const towerLabels: Record<string, string> = {
  OUTER_TURRET: "一塔",
  INNER_TURRET: "二塔",
  BASE_TURRET: "高地塔",
  NEXUS_TURRET: "门牙塔",
};

const laneLabels: Record<string, string> = { TOP_LANE: "上路", MID_LANE: "中路", BOT_LANE: "下路" };

export const laneLabel = (lane: string) => laneLabels[lane] ?? "";

/** 野怪名：有亚种（火龙/海龙…）就用亚种，名字比「小龙」有信息量。 */
export function monsterLabel(event: MatchTimelineEvent): string {
  if (event.monsterType === "DRAGON" && dragonLabels[event.monsterSubType]) return dragonLabels[event.monsterSubType];
  return monsterLabels[event.monsterType] ?? event.monsterType ?? "野怪";
}

/** 建筑名：水晶没有「几塔」的概念，塔则带分路。 */
export function buildingLabel(event: MatchTimelineEvent): string {
  if (event.buildingType === "INHIBITOR_BUILDING") return `${laneLabel(event.laneType)}水晶`;
  const tower = towerLabels[event.towerType] ?? "防御塔";
  return `${laneLabel(event.laneType)}${tower}`;
}

/** 事件的「做了什么」——时间线左侧的粗体。 */
export function eventTitle(event: MatchTimelineEvent): string {
  switch (event.type) {
    case "CHAMPION_KILL":
      return "击杀";
    case "ELITE_MONSTER_KILL":
      return monsterLabel(event);
    case "BUILDING_KILL":
      return buildingLabel(event);
    case "TURRET_PLATE_DESTROYED":
      return `${laneLabel(event.laneType)}镀层`;
    default:
      return event.type;
  }
}

/** 事件的「谁做的」——时间线右侧的小字。 */
export function eventDetail(event: MatchTimelineEvent): string {
  const side = eventSide(event);
  switch (event.type) {
    case "CHAMPION_KILL":
      // 助攻数是 0 时说「单杀」，比「0 助攻」更像人话。
      return event.assistCount > 0 ? `${side} · ${event.assistCount} 助攻` : `${side} · 单杀`;
    case "ELITE_MONSTER_KILL":
      return `${side}拿到`;
    case "BUILDING_KILL":
      return `${side}推掉`;
    case "TURRET_PLATE_DESTROYED":
      return `${side}拆掉`;
    default:
      return side;
  }
}

export const isKill = (event: MatchTimelineEvent) => event.type === "CHAMPION_KILL";
export const isBuilding = (event: MatchTimelineEvent) => event.type === "BUILDING_KILL" || event.type === "TURRET_PLATE_DESTROYED";

/** 各阵营的击杀数；时间线顶部的比分用它。 */
export function killTally(events: MatchTimelineEvent[]) {
  let blue = 0;
  let red = 0;
  for (const event of events) {
    if (!isKill(event)) continue;
    if (event.team === TEAM_BLUE) blue += 1;
    else if (event.team === TEAM_RED) red += 1;
  }
  return { blue, red };
}

/** 折线上某个点属于领先还是落后，用来切分蓝红两段曲线。 */
export function splitBySign(points: { x: number; y: number; value: number }[], zeroY: number) {
  const runs: { leading: boolean; points: { x: number; y: number }[] }[] = [];
  for (let index = 0; index < points.length; index += 1) {
    const point = points[index];
    const leading = point.value >= 0;
    const current = runs[runs.length - 1];
    if (!current || current.leading !== leading) {
      const previous = points[index - 1];
      let start = { x: point.x, y: point.y };
      if (previous && previous.value !== point.value && (previous.value >= 0) !== leading) {
        // 两条线在零轴上的交点：线性插值补一个点，否则曲线会在 0 处断开。
        const ratio = (0 - previous.value) / (point.value - previous.value);
        start = { x: previous.x + (point.x - previous.x) * ratio, y: zeroY };
        current?.points.push(start);
      } else if (current) {
        start = current.points[current.points.length - 1] ?? start;
      }
      runs.push({ leading, points: [start, { x: point.x, y: point.y }] });
      continue;
    }
    current.points.push({ x: point.x, y: point.y });
  }
  return runs;
}

export const pathFrom = (points: { x: number; y: number }[]) =>
  points.map((point, index) => `${index === 0 ? "M" : "L"}${point.x.toFixed(1)},${point.y.toFixed(1)}`).join(" ");

/**
 * 观战式时间轴的插值原语：时刻 t（秒）在分钟帧之间的线性插值。
 *
 * 帧是 60 秒一拍的快照，但时间轴上的游标可以停在任意秒——这几个函数都按
 * 「左帧 + (右帧-左帧) × 比例」取值，落在帧范围之外（开局前 / 结尾）就近取端点。
 * 帧缺失（旧对局没有 frames）时返回 null，调用方自行决定隐藏还是降级。
 *
 * **只对「本该连续的量」插值**：金币、等级、累计伤害这些都是单调累积的，两点之间线性
 * 过渡只是「显示得顺一点」，不会伪造出不存在的东西。**位置（`animatedPositions`）是
 * 唯一「插值只是为了让画面连贯」的一个**——分钟帧之间玩家的真实走位数据里没有，
 * 所以它必须在地图上说明「这是插值出来的」，另外用 `positionHistory` 给出真采样点。
 */
export function interpolatedGold(frames: MatchTimelineFrame[], seconds: number): number[] | null {
  const pair = framePairAt(frames, seconds);
  if (!pair) return null;
  const [left, right, fraction] = pair;
  return left.gold.map((value, index) => Math.round(value + ((right.gold[index] ?? value) - value) * fraction));
}

/**
 * 分钟帧里到底有没有「逐分钟伤害」。
 *
 * 背景（2026-09-25 真机实测）：LCU 本地的 `game-timelines` 是**裁剪版**，帧里没有伤害
 * 字段——`participantFrames` 只有 `currentGold` / `totalGold` / `level` /
 * `minionsKilled` / `jungleMinionsKilled` / `xp` / `position`，既没有扁平的
 * `totalDamageDoneToChampions`，也没有嵌套的 `damageStats`（召唤师峡谷和极地大乱斗
 * 都一样，一局 30 个帧从头到尾都是 0）。
 *
 * 所以后端改成**合并**同一局 SGP `DETAILS` 里嵌的 match-v5 完整时间线（那里面有
 * `damageStats`），把它写进 `frames[].damage` / `frames[].taken`。也就是说：
 * 现在**正常情况下这两项是有值的**，柱子会随游标变化。
 *
 * 这个判定仍然保留，因为合并是**会失败**的：离线、区服不在 SGP 白名单、拿不到
 * entitlement，或者那时对局太新/已被清理。取不到就照旧写 0 —— 这时降级到
 * `get_match_detail` 里的**全场总账**（那张表一直有），并把口径写清楚，
 * 而不是画一排宽度为 0 的柱子假装有数据。
 */
export function framesHaveDamage(frames: readonly MatchTimelineFrame[]): boolean {
  return frames.some((frame) => (frame.damage ?? []).some((value) => value > 0) || (frame.taken ?? []).some((value) => value > 0));
}

/** 各人的累计对英雄伤害；差值用法：`f(t2)[i] - f(t1)[i]` = 这段时间 i 号位打了多少伤害。 */
export function interpolatedDamage(frames: MatchTimelineFrame[], seconds: number): number[] | null {
  const pair = framePairAt(frames, seconds);
  if (!pair) return null;
  const [left, right, fraction] = pair;
  return left.damage.map((value, index) => Math.round(value + ((right.damage[index] ?? value) - value) * fraction));
}

/** 各人的累计承受伤害；与 `interpolatedDamage` 同构，团战「承伤」指标用。 */
export function interpolatedTaken(frames: MatchTimelineFrame[], seconds: number): number[] | null {
  const pair = framePairAt(frames, seconds);
  if (!pair) return null;
  const [left, right, fraction] = pair;
  return left.taken.map((value, index) => Math.round(value + ((right.taken[index] ?? value) - value) * fraction));
}

export function interpolatedLevel(frames: MatchTimelineFrame[], seconds: number): number[] | null {
  const pair = framePairAt(frames, seconds);
  if (!pair) return null;
  const [left, right, fraction] = pair;
  return left.level.map((value, index) => Math.max(1, Math.round(value + ((right.level[index] ?? value) - value) * fraction)));
}

/**
 * 一帧内两个人之间「瞬移」的判定半径（地图坐标单位；召唤师峡谷 ≈ 14800×14800）。
 *
 * 走路时一分钟的位移通常只有几百~两三千单位；闪现（400）/ 传送 / 回城 / 复活出场
 * 会一次跳掉半张地图（数千~上万）。超过这个阈值就当成「瞬间位移」，
 * 让它**在很短的一小段时间内完成**，而不是整分钟匀速平移过去。
 *
 * 3200 是实测出来的分界：常规对线走位（含打野在地图上半区巡游）都在这以内；
 * 一旦超过基本就是位移技能 / 传送 / 回城 / 复活。取整数是为了好记、好调。
 */
export const INSTANT_MOVE_DISTANCE = 3200;

/**
 * 瞬间位移在整分钟里占的时间比例。
 *
 * 0.12 = 整整一分钟里，前 12%（≈7 秒）走完这段大跨度位移，剩下 88% 停在终点。
 * 不取 0 是因为「完全瞬移」会跟 60 秒的采样粒度打架——我们并不知道他是在这一分钟的
 * 第几秒闪的，硬切会让画面像丢帧；留一小段过渡既是「很快」，又不会闪得莫名其妙。
 */
export const INSTANT_MOVE_SHARE = 0.12;

/** 把线性进度按「位移大小」重映射：大跨度位移走得更快，小步走保持匀速。 */
function easedFraction(fraction: number, distance: number): number {
  if (fraction <= 0 || fraction >= 1) return fraction;
  if (distance <= INSTANT_MOVE_DISTANCE) return fraction;
  // 瞬时位移：把整分钟的前 12% 用来完成它，之后一直停在终点。
  return Math.min(1, fraction / INSTANT_MOVE_SHARE);
}

/**
 * 各人在游标这一刻的地图位置：在前后两帧之间**平滑过渡**。
 *
 * 坐标 0/0 表示这一帧没带位置，调用方要跳过（不画点）。
 *
 * 为什么是插值（2026-09-27 一度改成「不插值、一分钟一跳」，当晚按用户反馈改回来）：
 * 帧是 60 秒一拍，不插值的话拖游标时十个小人**整整一分钟纹丝不动、然后集体闪现**，
 * 读起来像卡死。用户原话：「原本在地图上来回跑那个移动没有了，现在变成了瞬间跳」。
 * 所以这里保留平滑移动——**这是为了让画面连贯，不是真实路径**，地图的 `title` 里
 * 必须把这一点写出来（`MAP_GRANULARITY_NOTE`），别让人以为 60fps 的走位是采到的。
 * 想看**真**数据点请用 `positionHistory`（悬停某位玩家画的那串点）。
 *
 * **不是匀速**（2026-09-29 用户指出）：玩家真实的移动包含闪现 / 传送 / 回城 / 复活，
 * 这些是**瞬间**换位置，不是慢慢平移过去。所以按位移量做一次进度重映射
 * （`easedFraction`）——常规走位匀速走完，大跨度位移在很短一小段里完成。
 * 这是**近似**：帧里没有「他是第几秒闪的」，只能把它压到分钟前部；所以地图 `title`
 * 依然要写清「分钟之间是插值」。
 *
 * ⚠️ 另一条必须防的坑：**两端任一端坐标未知时绝不插值**。旧实现只判了左端，右端为
 * (0,0) 时照样按比例往它靠 → 小人被拉向地图角，看起来就是「往他没去过的地方走」。
 * 那才是当初被误当成「插值本身有问题」的真 bug。
 */
export function animatedPositions(frames: MatchTimelineFrame[], seconds: number): { x: number; y: number }[] | null {
  const pair = framePairAt(frames, seconds);
  if (!pair) return null;
  const [left, right, fraction] = pair;
  return left.positions.map((position, index) => {
    const target = right.positions[index] ?? position;
    const startKnown = position.x > 0 || position.y > 0;
    const endKnown = target.x > 0 || target.y > 0;
    // 只有两端都有坐标才能插值；否则原地保留已知的那一端（两端都没有就交 0/0 给上游跳过）。
    if (!startKnown) return endKnown ? { x: target.x, y: target.y } : { x: 0, y: 0 };
    if (!endKnown) return { x: position.x, y: position.y };
    if (fraction <= 0) return { x: position.x, y: position.y };
    const distance = Math.hypot(target.x - position.x, target.y - position.y);
    const progress = easedFraction(fraction, distance);
    return {
      x: Math.round(position.x + (target.x - position.x) * progress),
      y: Math.round(position.y + (target.y - position.y) * progress),
    };
  });
}

/**
 * 某一位玩家在游标这一刻**该停在哪**——阵亡时把他钉在倒下的位置。
 *
 * 用户 2026-09-29 报的原话：「人死了之后，他还能动」。这是真 bug，而且必须说清根因：
 * **这不是采样数据错了，是渲染时不该再插值了**。LCU 的一分钟帧里只给「这一刻他在哪」，
 * 人躺在泉水等复活时那些帧本来就该是同一个坐标；可我们拿的是**前后两帧插值**，
 * 于是「死前的最后一秒 → 复活后的第一步」被当成一次普通位移，小人拖着尸体从倒地处
 * 一路飘回泉水 —— 看着就是「死了还在动」。
 *
 * 判据只能是**录制帧里的 `dead`**（见 `recordingLineup.ts`）：那是官方 `isDead` 字段，
 * 也只有录制里有（分钟帧里没有死亡状态 → `dead` 为 null 时老老实实插值，不猜）。
 *
 * 钉住的位置用**该帧之前最后一个还能动的采样点**：人是在那里倒下的，尸体会停在原地
 * 直到复活（LoL 里阵亡位置不随复活倒计时漂移）。找不到已知点就原样返回，交给上游跳过。
 */
export function freezePositionWhileDead(
  positions: { x: number; y: number }[] | null,
  frames: MatchTimelineFrame[],
  seconds: number,
  index: number,
  dead: boolean,
): { x: number; y: number } | null {
  if (!positions) return null;
  const here = positions[index] ?? null;
  if (!dead || !here) return here;
  const resting = lastKnownPositionBefore(frames, seconds, index) ?? here;
  return resting;
}

/** 游标之前（含游标所在那一帧）最后一个有坐标的采样点；找不到返回 null。 */
function lastKnownPositionBefore(
  frames: MatchTimelineFrame[],
  seconds: number,
  index: number,
): { x: number; y: number } | null {
  const limit = Math.floor(Math.max(0, seconds) / 60);
  let found: { x: number; y: number } | null = null;
  for (const frame of frames) {
    if (frame.minute > limit) break;
    const position = frame.positions[index];
    if (position && (position.x > 0 || position.y > 0)) found = { x: position.x, y: position.y };
  }
  return found;
}

/**
 * 某一位玩家**从开局到游标这一刻**的全部位置采样点（每分钟一个，按时间先后）。
 *
 * 只给点、不给线：相邻两个采样点之间是直线还是绕了一大圈，数据里没有——连成线就是编。
 * 小地图把这些点画成淡色小点（越接近游标越深），这就是「历史轨迹」能如实给出的全部。
 *
 * `index` 是**座位数组下标**（与 `frame.positions` 同序），不是 participantId。
 */
export function positionHistory(frames: MatchTimelineFrame[], seconds: number, index: number): { x: number; y: number }[] {
  const limit = Math.floor(Math.max(0, seconds) / 60);
  const points: { x: number; y: number }[] = [];
  for (const frame of frames) {
    if (frame.minute > limit) break;
    const position = frame.positions[index];
    if (!position || (position.x <= 0 && position.y <= 0)) continue;
    points.push({ x: position.x, y: position.y });
  }
  return points;
}

function framePairAt(frames: MatchTimelineFrame[], seconds: number): [MatchTimelineFrame, MatchTimelineFrame, number] | null {
  if (!frames.length) return null;
  const exact = seconds / 60;
  let left = frames.find((frame) => frame.minute === Math.floor(exact));
  let right: MatchTimelineFrame | undefined;
  if (!left) {
    left = exact < frames[0].minute ? frames[0] : frames[frames.length - 1];
    right = left;
  } else {
    right = frames.find((frame) => frame.minute === left!.minute + 1) ?? left;
  }
  const fraction = right.minute > left.minute ? Math.min(1, Math.max(0, exact - left.minute)) : 0;
  return [left, right, fraction];
}
