import type { EncounterRecord } from "../types/domain";

/**
 * 把「每局每人一行」的相遇记录聚合成**按玩家**的关系档案。
 *
 * 为什么要聚合：单局行只能回答「这一局他是谁」，用户真正想看的其实是
 * 「我跟他一共打了多少局、最近一次是什么时候、跟他打是赢多还是输多」。
 *
 * 口径（重要，别当成终身数据）：
 * - 分母 `windowGames` = 本次分析窗口内的**不同对局数**（后端最多给 40 局）。
 *   后端相遇记录是从本地保存的战绩现算的，没有终身归档，所以这里只能诚实地说
 *   「最近 N 局里遇到 X 次」，不能写成「一共」。
 * - 同一玩家在同局只会出现一次（按 `gameId` 去重，缺 `gameId` 的行按序号兜底）。
 * - 胜负统一取**我方视角**的 `selfWin`（没有时退回 `result`），这样队友与对手可加总。
 */

export interface RelationshipGame {
  gameId: number;
  side: "ally" | "enemy";
  championId: number;
  championName: string;
  /** 这一局**我**用的英雄；旧记录可能缺（缺了界面显示「未记录」）。 */
  selfChampionId?: number;
  selfChampionName?: string;
  kills: number;
  deaths: number;
  assists: number;
  selfKills: number;
  selfDeaths: number;
  selfAssists: number;
  queueName: string;
  won: boolean | null;
  encounteredAt: string;
}

export interface RelationshipAggregate {
  puuid: string;
  gameName: string;
  tagLine: string;
  /** 最近一次交手用的英雄与数据。 */
  last: RelationshipGame;
  /** 分析窗口内的不同对局数（= 相遇次数的分母）。 */
  windowGames: number;
  totalGames: number;
  allyGames: number;
  enemyGames: number;
  /** 我方视角的胜场数与胜率；没有胜负信息的局不计入分母。 */
  wins: number;
  decidedGames: number;
  winRate: number;
  lastEncounteredAt: string;
  /** 最近一次交手距今天数（用于「x 天前」文案）。 */
  daysSinceLast: number;
  /** 常见英雄（最近一局的英雄，出现次数最多时以它为准）。 */
  games: RelationshipGame[];
}

const timestamp = (value: string) => Date.parse(value) || 0;

function kda(record: EncounterRecord) {
  return {
    kills: record.kills ?? 0,
    deaths: record.deaths ?? 0,
    assists: record.assists ?? 0,
    selfKills: record.selfKills ?? 0,
    selfDeaths: record.selfDeaths ?? 0,
    selfAssists: record.selfAssists ?? 0,
  };
}

function won(record: EncounterRecord): boolean | null {
  if (typeof record.selfWin === "boolean") return record.selfWin;
  if (record.result === "胜利") return true;
  if (record.result === "失败") return false;
  return null;
}

function toGame(record: EncounterRecord): RelationshipGame {
  return {
    gameId: record.gameId,
    side: record.side === "ally" ? "ally" : "enemy",
    championId: record.championId,
    championName: record.championName,
    // 「他玩了什么，我玩了什么」要成对出现：我的英雄在同一行记录里就有。
    selfChampionId: record.selfChampionId,
    selfChampionName: record.selfChampionName,
    queueName: record.queueName ?? "",
    encounteredAt: record.encounteredAt,
    won: won(record),
    ...kda(record),
  };
}

/**
 * 聚合相遇记录。`now` 可注入，便于测试「最近 x 天」。
 * 排序：先按相遇次数降序，再按最近交手时间降序——「关系最深」的人排前面。
 */
export function aggregateRelationships(records: EncounterRecord[], now: number = Date.now()): RelationshipAggregate[] {
  const windowGames = new Set<number>();
  const byPuuid = new Map<string, { record: EncounterRecord; games: Map<number, EncounterRecord> }>();

  records.forEach((record, index) => {
    if (record.liveSnapshot) return;
    const puuid = record.puuid?.trim();
    if (!puuid) return;
    // 缺少 gameId 的记录（个别旧数据）用「负序号」当键，保证同一条只算一次。
    const gameKey = record.gameId > 0 ? record.gameId : -(index + 1);
    if (record.gameId > 0) windowGames.add(record.gameId);
    const entry = byPuuid.get(puuid) ?? { record, games: new Map<number, EncounterRecord>() };
    const existing = entry.games.get(gameKey);
    if (!existing) entry.games.set(gameKey, record);
    else if (existing.win === undefined && record.win !== undefined) entry.games.set(gameKey, record);
    if (timestamp(record.encounteredAt) >= timestamp(entry.record.encounteredAt)) entry.record = record;
    byPuuid.set(puuid, entry);
  });

  const aggregates = [...byPuuid.values()].map(({ record, games }) => {
    const list = [...games.values()].map(toGame).sort((left, right) => timestamp(right.encounteredAt) - timestamp(left.encounteredAt));
    const last = list[0] ?? toGame(record);
    const allyGames = list.filter((game) => game.side === "ally").length;
    const decided = list.filter((game) => game.won !== null);
    const wins = decided.filter((game) => game.won).length;
    return {
      puuid: record.puuid,
      gameName: record.gameName,
      tagLine: record.tagLine ?? "",
      last,
      windowGames: windowGames.size,
      totalGames: list.length,
      allyGames,
      enemyGames: list.length - allyGames,
      wins,
      decidedGames: decided.length,
      winRate: decided.length ? wins / decided.length : 0,
      lastEncounteredAt: last.encounteredAt,
      daysSinceLast: Math.max(0, Math.floor((now - timestamp(last.encounteredAt)) / 86_400_000)),
      games: list,
    };
  });

  return aggregates.sort((left, right) =>
    right.totalGames - left.totalGames || timestamp(right.lastEncounteredAt) - timestamp(left.lastEncounteredAt));
}

/** 「x 天前 / 今天 / 昨天」文案；时间缺失时返回空串。 */
export function lastSeenLabel(aggregate: RelationshipAggregate): string {
  if (!aggregate.lastEncounteredAt) return "";
  if (aggregate.daysSinceLast <= 0) return "今天";
  if (aggregate.daysSinceLast === 1) return "昨天";
  if (aggregate.daysSinceLast < 30) return `${aggregate.daysSinceLast} 天前`;
  const months = Math.floor(aggregate.daysSinceLast / 30);
  return `${months} 个月前`;
}

/** 关系描述：队友 / 对手 / 两者都有。 */
export function relationLabel(aggregate: RelationshipAggregate): string {
  if (aggregate.allyGames > 0 && aggregate.enemyGames > 0) return `队友 ${aggregate.allyGames} · 对手 ${aggregate.enemyGames}`;
  if (aggregate.allyGames > 0) return `队友 ${aggregate.allyGames} 次`;
  return `对手 ${aggregate.enemyGames} 次`;
}
