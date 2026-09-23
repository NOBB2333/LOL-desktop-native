/**
 * 对局时间线的纯函数部分：时间/经济格式化，以及把后端事件翻译成中文文案。
 *
 * 拆出来单独放，是为了让「翻译口径」这一层能被单测覆盖——时间线最容易出的错不是
 * 画不出图，而是把「谁推了谁的塔」说反了。它不依赖任何组件状态。
 */
import type { MatchTimelineEvent } from "../types/domain";

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

/** 1.2k 这种紧凑写法：折线图的 Y 轴只有几十像素宽，写全数字会被挤爆。 */
export function compactGold(value: number): string {
  const abs = Math.abs(Math.round(value));
  if (abs < 1000) return String(abs);
  return `${(abs / 1000).toFixed(abs >= 10000 ? 0 : 1)}k`;
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
