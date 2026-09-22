/**
 * 本地「见过的玩家」索引与模糊搜索。
 *
 * 数据只来自本地已经沉淀下来的东西——历史遇到记录（`lol.get_encounters`）与
 * 好友列表（`lol.get_friends`）——**不发任何网络请求**。
 *
 * 为什么只能搜到「见过的人」：本地没有任何 `名字 → 全服玩家` 的反向索引。LCU 的
 * 按名查询只覆盖当前登录大区、且必须精确匹配；Riot Client 的别名查询虽然是全局的，
 * 但要求 `名字` 与 `标签` 两个字段都给全。所以「只记得半截名字」这种查询，唯一能回答
 * 的数据源就是我们自己攒下来的本地档案。**搜不到只代表本地没有记录，不代表这个人不存在。**
 */
import type { EncounterRecord, FriendRecord, LocalPlayerHit } from "../types/domain";

export interface LocalPlayerSources {
  encounters: EncounterRecord[];
  friends: FriendRecord[];
}

/**
 * 把两份本地数据合成「一人一条」的索引。
 *
 * 遇到记录贡献 `encounterGames` / `lastSeenAt` / `lastChampion`，好友列表只补
 * `isFriend` 与缺失的名字。同 puuid 的多条遇到记录合并成一条：局数累加，最近一次
 * 遇到时间取更晚的那个，并连带记住那一局用的英雄。
 */
export function buildLocalPlayerIndex({ encounters, friends }: LocalPlayerSources): LocalPlayerHit[] {
  const index = new Map<string, LocalPlayerHit>();
  for (const record of encounters) {
    const puuid = record.puuid?.trim();
    if (!puuid) continue;
    const gameName = record.gameName?.trim() ?? "";
    const tagLine = record.tagLine?.trim() ?? "";
    const champion = record.championName?.trim() ?? "";
    const seenAt = record.encounteredAt ?? null;
    const existing = index.get(puuid);
    if (!existing) {
      index.set(puuid, { puuid, gameName, tagLine, encounterGames: 1, isFriend: false, lastSeenAt: seenAt, lastChampion: champion });
      continue;
    }
    existing.encounterGames += 1;
    if (!existing.gameName) existing.gameName = gameName;
    if (!existing.tagLine) existing.tagLine = tagLine;
    if (seenAt && (!existing.lastSeenAt || seenAt > existing.lastSeenAt)) {
      existing.lastSeenAt = seenAt;
      existing.lastChampion = champion || existing.lastChampion;
    }
  }
  for (const friend of friends) {
    const puuid = friend.puuid?.trim();
    if (!puuid) continue;
    const existing = index.get(puuid);
    if (existing) {
      existing.isFriend = true;
      if (!existing.gameName) existing.gameName = friend.gameName?.trim() ?? "";
      if (!existing.tagLine) existing.tagLine = friend.gameTag?.trim() ?? "";
      continue;
    }
    index.set(puuid, {
      puuid,
      gameName: friend.gameName?.trim() ?? "",
      tagLine: friend.gameTag?.trim() ?? "",
      encounterGames: 0,
      isFriend: true,
      lastSeenAt: null,
      lastChampion: "",
    });
  }
  return [...index.values()];
}

/**
 * 给一个候选名打分，`null` 表示不匹配。
 *
 * 规则刻意保持简单、可预测（本地档案只有几十到几百条，不需要索引结构）：
 *
 * 1. **整串包含**优先——「河道」命中「河道观察者」。命中位置越靠前、多出来的字数越少，
 *    分越高，所以「河道」比「观察者」排序靠前。
 * 2. 否则试**子序列**（「河道观」也要能命中），按跨越的空隙扣分：空隙越小越像。
 * 3. 大小写不敏感；不做拼音/全半角转换（玩家名本来就以中文与数字为主）。
 */
export function scorePlayerName(query: string, gameName: string, tagLine: string): number | null {
  const needle = query.trim().toLocaleLowerCase();
  if (!needle) return null;
  const haystack = `${gameName}#${tagLine}`.toLocaleLowerCase();
  const slack = Math.min(120, Math.max(0, haystack.length - needle.length));
  const direct = haystack.indexOf(needle);
  if (direct >= 0) return 1000 - direct * 4 - slack;
  let cursor = 0;
  let gaps = 0;
  for (const char of needle) {
    const found = haystack.indexOf(char, cursor);
    if (found < 0) return null;
    gaps += found - cursor;
    cursor = found + 1;
  }
  return 500 - gaps * 3 - slack;
}

export function scoreLocalPlayer(query: string, hit: LocalPlayerHit): number | null {
  return scorePlayerName(query, hit.gameName, hit.tagLine);
}

/**
 * 排序后的搜索结果。
 *
 * 同分时先看「遇到过几局」，再看最近一次遇到的时间——名字像的人里，你更可能想找的是
 * 那个反复遇到的。最后用名字兜底，保证同一个索引每次返回的顺序都一样。
 */
export function searchLocalPlayers(query: string, index: LocalPlayerHit[], limit = 8): LocalPlayerHit[] {
  if (!query.trim() || !index.length) return [];
  return index
    .map((hit) => ({ hit, score: scoreLocalPlayer(query, hit) }))
    .filter((entry): entry is { hit: LocalPlayerHit; score: number } => entry.score !== null)
    .sort((left, right) =>
      right.score - left.score ||
      right.hit.encounterGames - left.hit.encounterGames ||
      (right.hit.lastSeenAt ?? "").localeCompare(left.hit.lastSeenAt ?? "") ||
      left.hit.gameName.localeCompare(right.hit.gameName, "zh-CN"))
    .slice(0, Math.max(1, limit))
    .map((entry) => entry.hit);
}

/** `名字#标签`；没有标签时只用名字。 */
export function localPlayerRiotId(hit: Pick<LocalPlayerHit, "gameName" | "tagLine">) {
  return hit.tagLine ? `${hit.gameName}#${hit.tagLine}` : hit.gameName;
}
