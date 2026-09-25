/**
 * 召唤师峡谷的**建筑**（防御塔 / 水晶）坐标与「到某一刻还剩几座」的推导。
 *
 * 为什么需要它：观战面板的小地图上原来只有十个英雄头像和团战编号钉，看不出
 * 「哪一路推穿了、哪一路还守着」。把建筑画上去之后，拖时间轴就能看着塔一座座掉
 * ——这也是转播小地图的核心信息之一。
 *
 * 坐标是 Riot 官方 `map11` 的建筑坐标（Hextech Docs 的 `map data` 表，与
 * `live/gameMap.ts` 的 `0..14820 × 0..14881` 域同口径；**y 越大越靠地图上方**，
 * 蓝方基地在左下、红方在右上）。不要凭感觉手改，改了就是「塔长在河道里」。
 */
import type { MatchTimelineEvent } from "../types/domain";
import { TEAM_BLUE, TEAM_RED } from "./timeline";

/** Riot 的 `towerType`（水晶借用 `INHIBITOR_BUILDING`）。 */
export type StructureTier = "OUTER_TURRET" | "INNER_TURRET" | "BASE_TURRET" | "NEXUS_TURRET" | "INHIBITOR_BUILDING";

export interface StructureSpot {
  /** 稳定 id（门牙塔有两座、同 tier 同分路，只能靠编号区分）。 */
  id: string;
  /** 这座建筑**属于**哪一方。 */
  team: number;
  kind: "turret" | "inhibitor";
  lane: "TOP_LANE" | "MID_LANE" | "BOT_LANE";
  tier: StructureTier;
  x: number;
  y: number;
}

function spot(team: number, lane: StructureSpot["lane"], tier: StructureTier, x: number, y: number, suffix = ""): StructureSpot {
  return {
    id: `${team === TEAM_BLUE ? "blue" : "red"}-${tier}-${lane}${suffix}`,
    team,
    kind: tier === "INHIBITOR_BUILDING" ? "inhibitor" : "turret",
    lane,
    tier,
    x,
    y,
  };
}

/**
 * 22 座防御塔 + 6 座水晶，坐标取自 Riot 的 `map11` 建筑表。
 *
 * 门牙塔（`NEXUS_TURRET`）在 Riot 的表里被拆成两座，但都贴在基地里、`laneType` 也常给
 * `MID_LANE`——所以给它们加编号后缀，匹配时按「先到先得」逐个消耗（见下面的单趟推导）。
 */
export const STRUCTURES: StructureSpot[] = [
  // ── 蓝方（左下）────────────────────────────────────────────────────
  spot(TEAM_BLUE, "TOP_LANE", "OUTER_TURRET", 981, 10441),
  spot(TEAM_BLUE, "TOP_LANE", "INNER_TURRET", 1512, 6699),
  spot(TEAM_BLUE, "TOP_LANE", "BASE_TURRET", 1169, 4287),
  spot(TEAM_BLUE, "MID_LANE", "OUTER_TURRET", 5846, 6396),
  spot(TEAM_BLUE, "MID_LANE", "INNER_TURRET", 5048, 4812),
  spot(TEAM_BLUE, "MID_LANE", "BASE_TURRET", 3651, 3696),
  spot(TEAM_BLUE, "BOT_LANE", "OUTER_TURRET", 10504, 1029),
  spot(TEAM_BLUE, "BOT_LANE", "INNER_TURRET", 6919, 1483),
  spot(TEAM_BLUE, "BOT_LANE", "BASE_TURRET", 4281, 1253),
  spot(TEAM_BLUE, "MID_LANE", "NEXUS_TURRET", 1748, 2270, "-1"),
  spot(TEAM_BLUE, "MID_LANE", "NEXUS_TURRET", 2177, 1807, "-2"),
  spot(TEAM_BLUE, "TOP_LANE", "INHIBITOR_BUILDING", 1171, 3571),
  spot(TEAM_BLUE, "MID_LANE", "INHIBITOR_BUILDING", 3203, 3208),
  spot(TEAM_BLUE, "BOT_LANE", "INHIBITOR_BUILDING", 3452, 1236),
  // ── 红方（右上）────────────────────────────────────────────────────
  spot(TEAM_RED, "TOP_LANE", "OUTER_TURRET", 4318, 13875),
  spot(TEAM_RED, "TOP_LANE", "INNER_TURRET", 7943, 13411),
  spot(TEAM_RED, "TOP_LANE", "BASE_TURRET", 10481, 13650),
  spot(TEAM_RED, "MID_LANE", "OUTER_TURRET", 8955, 8510),
  spot(TEAM_RED, "MID_LANE", "INNER_TURRET", 9767, 10113),
  spot(TEAM_RED, "MID_LANE", "BASE_TURRET", 11134, 11207),
  spot(TEAM_RED, "BOT_LANE", "OUTER_TURRET", 13866, 4505),
  spot(TEAM_RED, "BOT_LANE", "INNER_TURRET", 13327, 8226),
  spot(TEAM_RED, "BOT_LANE", "BASE_TURRET", 13624, 10572),
  spot(TEAM_RED, "MID_LANE", "NEXUS_TURRET", 12611, 13084, "-1"),
  spot(TEAM_RED, "MID_LANE", "NEXUS_TURRET", 13052, 12612, "-2"),
  spot(TEAM_RED, "TOP_LANE", "INHIBITOR_BUILDING", 11261, 13676),
  spot(TEAM_RED, "MID_LANE", "INHIBITOR_BUILDING", 11598, 11667),
  spot(TEAM_RED, "BOT_LANE", "INHIBITOR_BUILDING", 13604, 11316),
];

/** 水晶被推掉后 5 分钟重生（游戏机制）。不建模它的话，15 分钟掉的水晶到 40 分钟还画成「没了」。 */
export const INHIBITOR_RESPAWN_SECONDS = 300;

export interface StructureState {
  spot: StructureSpot;
  destroyed: boolean;
}

/** `event.team` 是**推塔方**，所以被推掉的建筑属于另一方。 */
function victimTeamOf(event: MatchTimelineEvent): number {
  if (event.team === TEAM_BLUE) return TEAM_RED;
  if (event.team === TEAM_RED) return TEAM_BLUE;
  return 0;
}

/** 事件里的 tier：水晶看 `buildingType`，防御塔看 `towerType`。 */
function tierOf(event: MatchTimelineEvent): string {
  return event.buildingType === "INHIBITOR_BUILDING" ? "INHIBITOR_BUILDING" : event.towerType;
}

/** 某座建筑在 `seconds` 这一刻是不是「不在场上」——水晶到期会自己回来。 */
function isDown(spot: StructureSpot, lastDown: Map<string, number>, seconds: number): boolean {
  const since = lastDown.get(spot.id);
  if (since === undefined) return false;
  if (spot.kind !== "inhibitor") return true;
  return seconds - since < INHIBITOR_RESPAWN_SECONDS;
}

/**
 * 到 `seconds` 这一刻，每座建筑是立着还是被推了。
 *
 * **单趟**按时间顺序消耗建筑，而不是拿 `(阵营, 分路, tier)` 直接查表：门牙塔两座同分路
 * 同 tier，先掉的那座必须消掉「第一个」，否则两座会一起变灰（第二座明明还立着）。
 */
export function structureStatesAt(events: MatchTimelineEvent[], seconds: number): StructureState[] {
  const lastDown = new Map<string, number>();
  const ordered = events
    .filter((event) => event.type === "BUILDING_KILL" && event.seconds <= seconds)
    .sort((left, right) => left.seconds - right.seconds);

  for (const event of ordered) {
    const team = victimTeamOf(event);
    const tier = tierOf(event);
    if (!team || !tier) continue;
    const found = STRUCTURES.find(
      (candidate) => candidate.team === team && candidate.tier === tier && (tier === "NEXUS_TURRET" || candidate.lane === event.laneType) && !isDown(candidate, lastDown, event.seconds),
    );
    if (found) lastDown.set(found.id, event.seconds);
  }

  return STRUCTURES.map((item) => ({ spot: item, destroyed: isDown(item, lastDown, seconds) }));
}
