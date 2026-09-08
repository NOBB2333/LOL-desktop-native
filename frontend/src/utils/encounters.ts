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

export function encounterLabel(games: EncounterGame[], player: PlayerProfile, self?: PlayerProfile | null) {
  const latest = games[0];
  const lastGame = (profile?: PlayerProfile | null) => profile?.recentMatches
    .filter((match) => match.durationMinutes > 0)
    .sort((a, b) => timestamp(b.playedAt) - timestamp(a.playedAt))[0]?.gameId;
  if (latest && latest.target.side !== "unknown" && lastGame(self) === latest.gameId && lastGame(player) === latest.gameId) {
    return latest.target.side === "ally" ? "上局队友" : "上局对手";
  }
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
