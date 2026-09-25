/**
 * 座位（时间线的 `participantId` + **绝对阵营**）与十人详情（`MatchParticipant`）的配对。
 *
 * 为什么值得单开一个模块：观战面板、每波团面板、事件流三处都要回答同一个问题
 * ——「这个座位号是谁」，而这条规则曾经在三处各写一遍、并且都写错过：
 *
 *   `(seat.team === 蓝方) === (player.side !== "enemy")`
 *
 * 后端的 `side` 是**相对视角**的（`ally` = 这一局主视角方的队），时间线座位带的却是
 * **绝对阵营**（100 = 蓝 / 200 = 红）。主视角落在红方时，他自己那一行 `side` 是 `ally`
 * 而 `team` 是 200 —— 上面那条式子于是把十个座位全部配空，界面表现是
 * 「每个人 KDA 都是 0/0/0、装备与对塔伤害整片空白」，而主视角在蓝方时一切正常，
 * 看起来就像「有的对局有、有的对局没有」。
 *
 * 所以：优先用后端的绝对 `team`（新缓存 / 新对局都有），只在老缓存缺该字段时
 * 退回相对 `side` 那条旧规则（fixture 与历史落盘数据仍然能配上）。
 */
import type { MatchParticipant, MatchTimelineParticipant } from "../types/domain";

export const TEAM_BLUE = 100;
export const TEAM_RED = 200;

/** 十人详情里这名玩家的绝对阵营；老缓存没有该字段时返回 null。 */
export function teamOf(player: MatchParticipant): number | null {
  const team = player.team;
  return typeof team === "number" && Number.isFinite(team) && team > 0 ? team : null;
}

/**
 * 这名玩家是否坐在 `seatTeam` 这一方。
 *
 * `seatTeam` 必须是**绝对值**（100/200），不能用 `side` 反推——那正是踩过的坑。
 */
export function sameTeamAsSeat(player: MatchParticipant, seatTeam: number): boolean {
  const team = teamOf(player);
  if (team !== null) return team === seatTeam;
  // 老数据兜底：`side` 只有「我方 / 敌方」两种取值，按「我方 = 蓝方」这一历史口径配对。
  return (seatTeam === TEAM_BLUE) === (player.side !== "enemy");
}

/**
 * 座位号 → 玩家。
 *
 * 同一局里英雄可以跨队重复（匹配、极地很常见），所以必须**英雄 + 阵营**一起判，
 * 只看英雄名会把镜像对局的两个人对调（「九尾妖狐 击杀 九尾妖狐」就是这么来的）。
 *
 * 配上的从池子里取走（`splice`），避免同队同英雄时两行都指向同一个人。
 * 帧里缺的座位（`championId` 为 0）直接跳过：那不是真座位，摆出来只会是一行空白。
 */
export function pairSeatsWithPlayers(
  seats: readonly MatchTimelineParticipant[],
  players: readonly MatchParticipant[] | undefined,
): Map<number, MatchParticipant> {
  const pool = [...(players ?? [])];
  const table = new Map<number, MatchParticipant>();
  for (const seat of seats) {
    if (seat.championId <= 0) continue;
    const index = pool.findIndex((player) => player.championId === seat.championId && sameTeamAsSeat(player, seat.team));
    if (index < 0) continue;
    table.set(seat.participantId, pool.splice(index, 1)[0]);
  }
  return table;
}

/** 时间线里**真实存在**的座位：帧数据缺人的对局会出现 `team/championId` 全 0 的占位。 */
export function realSeats(seats: readonly MatchTimelineParticipant[]): MatchTimelineParticipant[] {
  return seats.filter((seat) => seat.championId > 0 && seat.participantId > 0);
}
