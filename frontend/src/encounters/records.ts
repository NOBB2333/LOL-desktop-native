import type { EncounterRecord, PlayerProfile } from "../types/domain";

export interface EncounterGame {
  gameId: number;
  target: EncounterRecord;
  records: EncounterRecord[];
}

const identity = (value?: string) => value?.trim().toLowerCase() ?? "";
const timestamp = (value: string) => Date.parse(value) || 0;

export function encounterGames(records: EncounterRecord[], targetPuuid: string, excludeGameId = 0): EncounterGame[] {
  const games = new Map<number, Map<string, EncounterRecord>>();
  for (const record of records) {
    if (record.gameId <= 0 || record.gameId === excludeGameId || record.liveSnapshot) continue;
    const players = games.get(record.gameId) ?? new Map<string, EncounterRecord>();
    const key = identity(record.puuid);
    const previous = players.get(key);
    if (!previous || (previous.win === undefined && record.win !== undefined)) players.set(key, record);
    games.set(record.gameId, players);
  }
  return [...games].flatMap(([gameId, players]) => {
    const target = players.get(identity(targetPuuid));
    if (!target) return [];
    return [{ gameId, target, records: [...players.values()].filter((record) => identity(record.selfPuuid) === identity(target.selfPuuid)) }];
  }).sort((a, b) => timestamp(b.target.encounteredAt) - timestamp(a.target.encounteredAt) || b.gameId - a.gameId).slice(0, 40);
}

/** 与目标玩家在最近一局中的关系。 */
export type EncounterRelation = "self" | "last-teammate" | "last-opponent" | "met";

/** 取该玩家最近一局（已完成）的 gameId。 */
export function latestFinishedGameId(profile?: PlayerProfile | null): number | undefined {
  return profile?.recentMatches
    .filter((match) => match.durationMinutes > 0)
    .sort((a, b) => timestamp(b.playedAt) - timestamp(a.playedAt))[0]?.gameId;
}

/**
 * 判断共同对局里最新的一局是否就是双方各自的最近一局。
 *
 * 对齐 LeagueAkari 的 `getMetLabelKey`：只有双方最新战绩都指向同一场，
 * 才能说「上局队友 / 上局对手」，否则只是普通的「遇到过」。
 */
export function encounterRelation(
  games: EncounterGame[],
  player: PlayerProfile,
  self?: PlayerProfile | null,
): EncounterRelation {
  const latest = games[0];
  if (!latest || latest.target.side === "unknown") return "met";
  if (latestFinishedGameId(self) !== latest.gameId) return "met";
  if (latestFinishedGameId(player) !== latest.gameId) return "met";
  return latest.target.side === "ally" ? "last-teammate" : "last-opponent";
}

export function encounterLabel(games: EncounterGame[], player: PlayerProfile, self?: PlayerProfile | null) {
  const relation = encounterRelation(games, player, self);
  if (relation === "last-teammate") return "上局队友";
  if (relation === "last-opponent") return "上局对手";
  return `遇到过 ${games.length || player.encounterCount} 次`;
}

export function encounterTime(value: string) {
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? "时间未知" : new Intl.DateTimeFormat("zh-CN", {
    year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hour12: false,
  }).format(date);
}

export function encounterKda(kills?: number, deaths?: number, assists?: number) {
  return kills == null || deaths == null || assists == null ? "--" : `${kills}/${deaths}/${assists}`;
}
