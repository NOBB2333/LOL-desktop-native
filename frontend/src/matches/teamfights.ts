/**
 * 「每波团」的推导。
 *
 * ⚠️ 先说清楚一件事：**Riot 的数据里没有团战这种事件**。
 *
 * 我们读的 LCU 逐帧数据只有三类事件（击杀 / 拿野怪 / 推建筑），连伤害都没有；
 * SGP 的 DETAILS 会多出 `victimTeamfightDamageDealt` 这类**团战期间**的伤害字段，
 * 但它给的仍然是「击杀时附带的一次统计」，**团战的边界依然要自己划**。
 * 所以下面这套规则是我们定的口径，不是抄某个接口的字段——这也是为什么它值得
 * 单独一个文件、单独一套单测：口径变了，只有这里会变。
 *
 * 划法（三条，缺一不可）：
 *
 * 1. 只看 `CHAMPION_KILL`。拿龙/推塔常常是团战的**结果**而不是过程，
 *    拿它们划界会把「一波团之后顺手拿的龙」算成两波。
 * 2. 相邻两次击杀间隔 ≤ `gapSeconds`（默认 12 秒）算同一波，超过就断开。
 * 3. 一波里至少 `minKills`（默认 2）个人头，且去重后的**参与人数**
 *    （击杀者 + 助攻者 + 阵亡者）≥ `minParticipants`（默认 3）。
 *    单杀换单杀只是对线摩擦，不该被叫成团战。
 *
 * 位置：一波团的落点取该波有位置的击杀的**平均**坐标。全都没位置时为 `null`
 * ——注意后端对没有 `position` 的事件写的是 0/0，**0/0 在本图域里是个真实坐标**
 * （左下角），所以判定「有没有位置」必须用 `posX > 0 || posY > 0`，不能只看 falsy。
 */
import type { MatchTimelineEvent, MatchTimelineParticipant } from "../types/domain";
import { isKill, TEAM_BLUE, TEAM_RED } from "./timeline";

/** 相邻击杀超过这个间隔就断开，不再算同一波团。 */
export const DEFAULT_GAP_SECONDS = 12;
/** 一波团最少要几个人头。 */
export const DEFAULT_MIN_KILLS = 2;
/** 一波团最少要几个人参与（击杀者 + 助攻者 + 阵亡者，去重）。 */
export const DEFAULT_MIN_PARTICIPANTS = 3;
/** 多杀的判定窗口：同一个人的两次击杀间隔超过这个值就不连起来。 */
export const MULTI_KILL_WINDOW_SECONDS = 10;

export interface TeamfightParticipant {
  participantId: number;
  championId: number;
  team: number;
}

export interface Teamfight {
  /** 第几波团（本局内从 1 开始，按时间顺序）。 */
  index: number;
  startSeconds: number;
  endSeconds: number;
  kills: MatchTimelineEvent[];
  /** 阵营 → 该阵营在这一波里拿到的人头数。 */
  killsByTeam: Record<number, number>;
  /** 人头更多的那一方；平手为 0。 */
  winningTeam: number;
  /** 去重后的参战者，按阵营再按座位号排好，前端直接渲染头像。 */
  involved: TeamfightParticipant[];
  /** 团战中心的游戏坐标；这一波没有任何位置信息时为 null。 */
  center: { x: number; y: number } | null;
}

export interface MultiKill {
  killerId: number;
  championId: number;
  team: number;
  /** 连杀人数（2~5）。 */
  count: number;
  label: string;
  startSeconds: number;
  endSeconds: number;
}

export interface TeamfightOptions {
  gapSeconds?: number;
  minKills?: number;
  minParticipants?: number;
}

/** 事件里有没有可用位置。后端对缺失位置写 0/0，而 0/0 在本图域里是真实坐标。 */
export const hasPosition = (event: MatchTimelineEvent) => event.posX > 0 || event.posY > 0;

/**
 * 座位号 → 阵营。优先查 `participants`（权威），查不到按「1~5 蓝、6~10 红」兜底
 * ——这条兜底与后端 `timeline.zig` 的 `teamOfKiller` 完全一致，两边不能各说各话。
 */
function teamResolver(participants: MatchTimelineParticipant[]) {
  const table = new Map(participants.map((item) => [item.participantId, item]));
  return (participantId: number) => {
    if (participantId <= 0) return 0;
    const found = table.get(participantId);
    if (found && found.team > 0) return found.team;
    return participantId <= 5 ? TEAM_BLUE : TEAM_RED;
  };
}

function championResolver(participants: MatchTimelineParticipant[]) {
  const table = new Map(participants.map((item) => [item.participantId, item.championId]));
  return (participantId: number) => table.get(participantId) ?? 0;
}

/**
 * 把击杀事件切成「每波团」。
 *
 * `participants` 用来把助攻/阵亡的座位号翻成阵营与英雄，所以必须传——
 * 只有事件本身的话，助攻名单就只是一串没有阵营的数字。
 */
export function deriveTeamfights(
  events: MatchTimelineEvent[],
  participants: MatchTimelineParticipant[],
  options: TeamfightOptions = {},
): Teamfight[] {
  const gapSeconds = options.gapSeconds ?? DEFAULT_GAP_SECONDS;
  const minKills = options.minKills ?? DEFAULT_MIN_KILLS;
  const minParticipants = options.minParticipants ?? DEFAULT_MIN_PARTICIPANTS;

  const kills = events.filter(isKill).slice().sort((left, right) => left.seconds - right.seconds);

  const groups: MatchTimelineEvent[][] = [];
  for (const kill of kills) {
    const current = groups[groups.length - 1];
    const previous = current?.[current.length - 1];
    if (current && previous && kill.seconds - previous.seconds <= gapSeconds) current.push(kill);
    else groups.push([kill]);
  }

  const teamOf = teamResolver(participants);
  const championOf = championResolver(participants);
  const fights: Teamfight[] = [];

  for (const group of groups) {
    if (group.length < minKills) continue;

    const seats = new Set<number>();
    for (const kill of group) {
      if (kill.killerId > 0) seats.add(kill.killerId);
      if (kill.victimId > 0) seats.add(kill.victimId);
      for (const assistId of kill.assistIds ?? []) if (assistId > 0) seats.add(assistId);
    }
    if (seats.size < minParticipants) continue;

    const killsByTeam: Record<number, number> = {};
    for (const kill of group) {
      if (kill.team > 0) killsByTeam[kill.team] = (killsByTeam[kill.team] ?? 0) + 1;
    }
    // 注意 `killsByTeam` 是普通对象（键是数字、值是数字），所以要走 `Object.entries`
    // 并显式把键转回 number——写成 `killsByTeam.entries()` 会直接抛 TypeError。
    const ordered = Object.entries(killsByTeam)
      .map(([team, count]) => ({ team: Number(team), count }))
      .sort((left, right) => right.count - left.count);
    // 人头多的一方算赢下这波；平手或压根不知道阵营时为 0（前端按「互交」渲染）。
    const winningTeam = ordered[0] && (ordered.length === 1 || ordered[0].count > ordered[1].count) ? ordered[0].team : 0;

    const involved: TeamfightParticipant[] = [...seats]
      .map((participantId) => ({ participantId, championId: championOf(participantId), team: teamOf(participantId) }))
      .sort((left, right) => left.team - right.team || left.participantId - right.participantId);

    const located = group.filter(hasPosition);
    const center = located.length
      ? {
          x: Math.round(located.reduce((total, kill) => total + kill.posX, 0) / located.length),
          y: Math.round(located.reduce((total, kill) => total + kill.posY, 0) / located.length),
        }
      : null;

    fights.push({
      index: fights.length + 1,
      startSeconds: group[0].seconds,
      endSeconds: group[group.length - 1].seconds,
      kills: group,
      killsByTeam,
      winningTeam,
      involved,
      center,
    });
  }

  return fights;
}

export function multiKillLabel(count: number): string {
  if (count >= 5) return "五杀";
  if (count === 4) return "四杀";
  if (count === 3) return "三杀";
  if (count === 2) return "双杀";
  return "";
}

/**
 * 多杀：同一个击杀者在 `windowSeconds` 内连续拿的人头算一次多杀。
 * LCU 没有 `CHAMPION_SPECIAL_KILL`（SGP 才有），所以只能这么推。
 */
export function deriveMultiKills(events: MatchTimelineEvent[], windowSeconds = MULTI_KILL_WINDOW_SECONDS): MultiKill[] {
  const kills = events
    .filter(isKill)
    .filter((kill) => kill.killerId > 0)
    .slice()
    .sort((left, right) => left.seconds - right.seconds);

  const result: MultiKill[] = [];
  let chain: MatchTimelineEvent[] = [];

  const flush = () => {
    if (chain.length >= 2) {
      result.push({
        killerId: chain[0].killerId,
        championId: chain[0].killerChampionId,
        team: chain[0].team,
        count: chain.length,
        label: multiKillLabel(chain.length),
        startSeconds: chain[0].seconds,
        endSeconds: chain[chain.length - 1].seconds,
      });
    }
    chain = [];
  };

  for (const kill of kills) {
    const head = chain[0];
    const tail = chain[chain.length - 1];
    // 换人就断开；同一个人但间隔超窗也断开（中间他去干了别的）。
    if (head && (kill.killerId !== head.killerId || kill.seconds - tail.seconds > windowSeconds)) flush();
    chain.push(kill);
  }
  flush();
  return result;
}

/** 首杀：全场第一次击杀。拿不到击杀事件时为 null。 */
export function firstBlood(events: MatchTimelineEvent[]): MatchTimelineEvent | null {
  const kills = events.filter(isKill).sort((left, right) => left.seconds - right.seconds);
  return kills[0] ?? null;
}

/**
 * 团战落点的**粗略**读法。
 *
 * 这是「离哪个已知点位最近」的最近邻命名，不是真实的分区判定——地图上没有
 * 「中路」这种边界线，硬判会给出假精度。所以这里刻意只给到「大龙坑 / 小龙坑 /
 * 上中下路 / 谁的野区」这个粒度，并在界面上与地图上的编号点互相印证：
 * 用户看图上的点就知道准不准，不会被一个煞有介事的区域名骗到。
 */
const LOCATION_ANCHORS: { name: string; x: number; y: number }[] = [
  { name: "大龙坑", x: 5000, y: 9900 },
  { name: "小龙坑", x: 9866, y: 4410 },
  { name: "中路", x: 7400, y: 7400 },
  { name: "蓝方下路", x: 1200, y: 3600 },
  { name: "红方下路", x: 13200, y: 3400 },
  { name: "蓝方上路", x: 1600, y: 11300 },
  { name: "红方上路", x: 13600, y: 11200 },
  { name: "蓝方野区", x: 3830, y: 7880 },
  { name: "红方野区", x: 10990, y: 7000 },
];

export function describeLocation(center: { x: number; y: number } | null): string {
  if (!center) return "位置未知";
  let best = LOCATION_ANCHORS[0];
  let bestDistance = Number.POSITIVE_INFINITY;
  for (const anchor of LOCATION_ANCHORS) {
    const distance = (anchor.x - center.x) ** 2 + (anchor.y - center.y) ** 2;
    if (distance < bestDistance) {
      bestDistance = distance;
      best = anchor;
    }
  }
  return best.name;
}
