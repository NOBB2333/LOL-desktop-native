import type { PlayerProfile } from "../types/domain";

/**
 * 与 `tags/tones.ts` 的 `PREMADE_GROUP_COLORS`（A~L，共 12 组）保持同长：
 * 分组序号超出调色板就会绕回 A 的颜色，之前是 8 组，第 9 组起会撞色。
 */
export const PREMADE_TONE_COUNT = 12;
export const PREMADE_INFERENCE_MATCH_THRESHOLD = 5;

function normalizedName(value: string) {
  return value.trim().toLocaleLowerCase();
}

export function findLocalPlayer(players: readonly PlayerProfile[], gameName?: string | null, tagLine?: string | null) {
  const name = normalizedName(gameName ?? "");
  const tag = normalizedName(tagLine ?? "");
  if (!name) return null;
  return players.find((player) => {
    if (normalizedName(player.gameName) !== name) return false;
    return !tag || !player.tagLine || normalizedName(player.tagLine) === tag;
  }) ?? null;
}

export function isLocalPartyMember(local: PlayerProfile | null, player: PlayerProfile, tones: ReadonlyMap<PlayerProfile, number>) {
  if (!local || local === player || (local.puuid && player.puuid && local.puuid === player.puuid)) return false;
  const localTone = tones.get(local);
  if (localTone !== undefined && tones.get(player) === localTone) return true;
  const localGroup = local.premadeGroup?.trim();
  if (localGroup && localGroup !== "0" && localGroup === player.premadeGroup?.trim()) return true;
  return local.premadeWith.some((name) => normalizedName(name) === normalizedName(player.gameName))
    || player.premadeWith.some((name) => normalizedName(name) === normalizedName(local.gameName));
}

function teamPremadeGroups(players: readonly PlayerProfile[]) {
  const names = new Map<string, number[]>();
  players.forEach((player, index) => {
    const name = normalizedName(player.gameName);
    if (!name || name === "未知玩家") return;
    const matches = names.get(name) ?? [];
    matches.push(index);
    names.set(name, matches);
  });

  const links = players.map(() => new Set<number>());
  const groupKeys = new Map<string, number[]>();
  players.forEach((player, index) => {
    if (!player.isPremade) return;
    const groupKey = player.premadeGroup?.trim();
    if (groupKey) {
      const members = groupKeys.get(groupKey) ?? [];
      members.push(index);
      groupKeys.set(groupKey, members);
    }
    for (const teammateName of player.premadeWith) {
      const matches = names.get(normalizedName(teammateName));
      // A name without a unique player match is not strong enough evidence to
      // color multiple cards as one party.
      if (matches?.length !== 1 || matches[0] === index) continue;
      const teammate = matches[0];
      links[index].add(teammate);
      links[teammate].add(index);
    }
  });

  // The LCU group id is available before Riot IDs are deobfuscated in some
  // queues. Link those seats directly so a party does not lose its shared
  // color merely because premadeWith cannot contain display names yet.
  for (const members of groupKeys.values()) {
    if (members.length < 2) continue;
    for (let index = 1; index < members.length; index += 1) {
      links[members[0]].add(members[index]);
      links[members[index]].add(members[0]);
    }
  }

  // Match LeagueAkari's local inference: players on the same current team
  // who repeatedly appear in the same recent games are very likely queued
  // together. This also restores the actual grouping when Tencent's client
  // exposes isPremade but keeps teammate identities obfuscated.
  const matchIds = players.map(
    (player) => new Set(player.recentMatches.map((match) => String(match.gameId)).filter((id) => id !== "0")),
  );
  for (let left = 0; left < players.length; left += 1) {
    for (let right = left + 1; right < players.length; right += 1) {
      const smaller = matchIds[left].size <= matchIds[right].size ? matchIds[left] : matchIds[right];
      const larger = smaller === matchIds[left] ? matchIds[right] : matchIds[left];
      let shared = 0;
      for (const gameId of smaller) {
        if (larger.has(gameId)) shared += 1;
        if (shared >= PREMADE_INFERENCE_MATCH_THRESHOLD) break;
      }
      if (shared < PREMADE_INFERENCE_MATCH_THRESHOLD) continue;
      links[left].add(right);
      links[right].add(left);
    }
  }

  const visited = new Set<number>();
  const groups: number[][] = [];
  links.forEach((neighbors, start) => {
    if (!neighbors.size || visited.has(start)) return;
    const group: number[] = [];
    const queue = [start];
    visited.add(start);
    while (queue.length) {
      const current = queue.shift()!;
      group.push(current);
      for (const neighbor of links[current]) {
        if (visited.has(neighbor)) continue;
        visited.add(neighbor);
        queue.push(neighbor);
      }
    }
    if (group.length > 1) groups.push(group.sort((left, right) => left - right));
  });
  return groups;
}

/**
 * Assigns one visual tone to every confirmed party. Teams are evaluated
 * separately so an identical display name on the other side cannot join two
 * unrelated parties. Tone numbers remain unique within the available palette.
 */
export function assignPremadeTones(teams: readonly (readonly PlayerProfile[])[]) {
  const tones = new Map<PlayerProfile, number>();
  let nextTone = 0;
  for (const players of teams) {
    for (const group of teamPremadeGroups(players)) {
      const tone = nextTone % PREMADE_TONE_COUNT;
      group.forEach((index) => tones.set(players[index], tone));
      nextTone += 1;
    }
  }
  return tones;
}
