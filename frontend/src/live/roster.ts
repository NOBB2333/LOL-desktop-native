import type { LiveLobby, PlayerProfile } from "../types/domain";

function numericGameId(value: string) {
  return /^\d+$/.test(value.trim()) ? value.trim() : "";
}

export function playerIdentity(player: PlayerProfile) {
  if (playerIdQuality(player.puuid) > 0) return `puuid:${player.puuid.trim().toLowerCase()}`;
  const name = player.gameName.trim().toLocaleLowerCase();
  if (name && name !== "未知玩家") {
    return `name:${name}#${player.tagLine.trim().toLocaleLowerCase()}`;
  }
  return "";
}

function playerIdQuality(value: string) {
  const id = value.trim();
  if (!id || id === "0" || id === "00000000-0000-0000-0000-000000000000" || id.includes("-slot-")) return 0;
  return /^\d+$/.test(id) ? 1 : 2;
}

function samePlayer(left: PlayerProfile, right: PlayerProfile) {
  if (playerIdQuality(left.puuid) === 2 && playerIdQuality(right.puuid) === 2) return left.puuid.toLowerCase() === right.puuid.toLowerCase();
  if (hasKnownName(left) && hasKnownName(right)) return left.gameName.toLowerCase() === right.gameName.toLowerCase()
    && (!left.tagLine || !right.tagLine || left.tagLine.toLowerCase() === right.tagLine.toLowerCase());
  if (left.rosterKey && right.rosterKey) return left.rosterKey === right.rosterKey;
  return Boolean(playerIdentity(left) && playerIdentity(left) === playerIdentity(right));
}

function namesConflict(left: PlayerProfile, right: PlayerProfile) {
  return hasKnownName(left) && hasKnownName(right) && (left.gameName.toLowerCase() !== right.gameName.toLowerCase()
    || Boolean(left.tagLine && right.tagLine && left.tagLine.toLowerCase() !== right.tagLine.toLowerCase()));
}

export function playerCardKey(player: PlayerProfile, index: number) {
  return player.rosterKey || playerIdentity(player) || (player.puuid.includes("-slot-") ? player.puuid : `slot:${index}`);
}

function hasKnownName(player: PlayerProfile) {
  const name = player.gameName.trim();
  return Boolean(name && name !== "未知玩家" && !name.startsWith("蓝方玩家") && !name.startsWith("红方玩家"));
}

function isUnresolvedPlayer(player: PlayerProfile) {
  return !hasKnownName(player) || playerIdQuality(player.puuid) === 0;
}

function knownPosition(value: string) {
  const position = value.trim().toUpperCase();
  return ["TOP", "JUNGLE", "MIDDLE", "MID", "BOTTOM", "BOT", "ADC", "UTILITY", "SUPPORT"].includes(position);
}

export function isDifferentRosterContext(base: LiveLobby, fast: LiveLobby) {
  const baseId = numericGameId(base.id);
  const fastId = numericGameId(fast.id);
  if (baseId && fastId && baseId !== fastId) return true;
  return fast.phase === "ChampSelect" && base.phase !== "ChampSelect";
}

function mergePlayer(original: PlayerProfile, dynamic: PlayerProfile) {
  const hasChampion = dynamic.championId > 0;
  const puuid = playerIdQuality(dynamic.puuid) >= playerIdQuality(original.puuid) ? dynamic.puuid : original.puuid;
  const premadeWith = [...original.premadeWith];
  for (const teammate of dynamic.premadeWith) {
    if (!premadeWith.some((name) => name.toLocaleLowerCase() === teammate.toLocaleLowerCase())) premadeWith.push(teammate);
  }
  const isPremade = original.isPremade === true || dynamic.isPremade === true
    ? true
    : dynamic.isPremade ?? original.isPremade;
  // 富化字段（段位、战绩、评分、标签）只来自 original；overlay 只负责拓扑。
  return {
    ...original,
    puuid,
    gameName: hasKnownName(dynamic) ? dynamic.gameName : original.gameName,
    tagLine: dynamic.tagLine || original.tagLine,
    isBot: original.isBot || dynamic.isBot,
    championId: hasChampion ? dynamic.championId : original.championId,
    championName: hasChampion ? dynamic.championName : original.championName,
    profileIconId: dynamic.profileIconId || original.profileIconId,
    assignedPosition: knownPosition(dynamic.assignedPosition) ? dynamic.assignedPosition : original.assignedPosition,
    isPremade,
    premadeWith,
  };
}

/// 上下文切换（换局、进入选人）时按身份把已加载的富化字段带到新拓扑上，
/// 避免整块数据被未富化的快速快照覆盖后界面"闪一下又没了"。
function carryEnrichedPlayers(base: PlayerProfile[], fast: PlayerProfile[]) {
  if (!base.length || !fast.length) return fast;
  const pool = base.map((player) => ({ player, used: false }));
  return fast.map((dynamic, index) => {
    const identity = playerIdentity(dynamic);
    let match = identity ? pool.findIndex((entry) => !entry.used && samePlayer(entry.player, dynamic)) : -1;
    if (match < 0 && index < pool.length && !pool[index].used) {
      // 槽位兜底同样要确认身份不冲突，否则会把上一位玩家的段位和战绩搬过来。
      const candidate = pool[index].player;
      const candidateIdentity = playerIdentity(candidate);
      if (!namesConflict(candidate, dynamic) && (!identity || !candidateIdentity || isUnresolvedPlayer(candidate))) match = index;
    }
    if (match < 0) return dynamic;
    pool[match].used = true;
    const merged = mergePlayer(pool[match].player, dynamic);
    // 组队是「这一局」的关系，换局后必须采用新快照的判断，不能沿用上一局。
    return { ...merged, isPremade: dynamic.isPremade ?? false, premadeWith: [...dynamic.premadeWith] };
  });
}

export function mergeRosterPlayers(base: PlayerProfile[], fast: PlayerProfile[]) {
  if (!base.length) return fast;
  if (fast.length >= base.length) {
    const used = new Set<number>();
    return fast.map((dynamic, index) => {
      const identity = playerIdentity(dynamic);
      let baseIndex = identity
        ? base.findIndex((candidate, candidateIndex) => !used.has(candidateIndex) && samePlayer(candidate, dynamic))
        : -1;
      const indexed = base[index];
      if (baseIndex < 0 && indexed && !used.has(index) && !namesConflict(dynamic, indexed) && (isUnresolvedPlayer(dynamic) || !playerIdentity(indexed))) baseIndex = index;
      if (baseIndex < 0) return dynamic;
      used.add(baseIndex);
      return mergePlayer(base[baseIndex], dynamic);
    });
  }
  const used = new Set<number>();
  const merged = base.map((original, index) => {
    const identity = playerIdentity(original);
    let fastIndex = identity
      ? fast.findIndex((candidate, candidateIndex) => !used.has(candidateIndex) && samePlayer(candidate, original))
      : -1;
    const indexed = fast[index];
    if (fastIndex < 0 && indexed && !used.has(index)) {
      const indexedIdentity = playerIdentity(indexed);
      if (!namesConflict(original, indexed) && (!identity || !indexedIdentity || isUnresolvedPlayer(indexed))) fastIndex = index;
    }
    if (fastIndex < 0) return original;
    used.add(fastIndex);
    return mergePlayer(original, fast[fastIndex]);
  });
  for (let index = 0; index < fast.length; index += 1) {
    if (!used.has(index)) merged.push(fast[index]);
  }
  return merged;
}

function rosterTopology(players: PlayerProfile[]) {
  return players.map((player) => playerIdentity(player) || `slot:${player.championId}:${player.assignedPosition}`).join("|");
}

export function mergeRosterSnapshot(base: LiveLobby | undefined, fast: LiveLobby) {
  if (!base) return fast;
  // 上下文切换（换局或进入选人）时不能整体退回未富化的快速快照：已加载的
  // 段位和战绩按身份带过去，只让拓扑字段以最新阵容为准。
  if (isDifferentRosterContext(base, fast)) {
    const ally = carryEnrichedPlayers(base.ally, fast.ally);
    const enemy = carryEnrichedPlayers(base.enemy, fast.enemy);
    const teams = (fast.teams?.length ? fast.teams : [
      { id: "ally", label: "我方阵容", side: "ally", players: fast.ally, summary: fast.allySummary },
      { id: "enemy", label: "敌方阵容", side: "enemy", players: fast.enemy, summary: fast.enemySummary },
    ]).map((team) => ({
      ...team,
      players: team.side === "ally" ? ally : team.side === "enemy" ? enemy : team.players,
    }));
    return { ...fast, ally, enemy, teams };
  }
  const ally = mergeRosterPlayers(base.ally, fast.ally);
  const enemy = mergeRosterPlayers(base.enemy, fast.enemy);
  const topologyChanged = rosterTopology(base.ally) !== rosterTopology(fast.ally)
    || rosterTopology(base.enemy) !== rosterTopology(fast.enemy);
  const allySummary = topologyChanged ? fast.allySummary : base.allySummary;
  const enemySummary = topologyChanged ? fast.enemySummary : base.enemySummary;
  const fastTeams = fast.teams?.length ? fast.teams : [
    { id: "ally", label: "我方阵容", side: "ally", players: fast.ally, summary: fast.allySummary },
    { id: "enemy", label: "敌方阵容", side: "enemy", players: fast.enemy, summary: fast.enemySummary },
  ];
  const baseTeams = base.teams?.length ? base.teams : [
    { id: "ally", label: "我方阵容", side: "ally", players: base.ally, summary: base.allySummary },
    { id: "enemy", label: "敌方阵容", side: "enemy", players: base.enemy, summary: base.enemySummary },
  ];
  const teams = fastTeams.map((team) => {
    const original = baseTeams.find((candidate) => candidate.side === team.side || candidate.id === team.id);
    const players = team.side === "ally"
      ? ally
      : team.side === "enemy"
        ? enemy
        : mergeRosterPlayers(original?.players ?? [], team.players);
    const summary = team.side === "ally" ? allySummary : team.side === "enemy" ? enemySummary : team.summary;
    return { ...(original ?? team), ...team, players, summary };
  });
  return {
    ...base,
    id: fast.id || base.id,
    queueId: fast.queueId || base.queueId,
    gameMode: fast.gameMode || base.gameMode,
    phase: fast.phase || base.phase,
    ally,
    enemy,
    teams,
    allySummary,
    enemySummary,
    layoutKind: fast.layoutKind || base.layoutKind,
    generatedAt: fast.generatedAt || base.generatedAt,
  };
}

export function enrichedRosterCoversOverlay(enriched: LiveLobby | undefined, overlay: LiveLobby) {
  if (!enriched) return false;
  if (isDifferentRosterContext(enriched, overlay) || enriched.phase !== overlay.phase) return false;

  const coversTeam = (complete: PlayerProfile[], dynamic: PlayerProfile[]) => {
    if (complete.length < dynamic.length) return false;
    const used = new Set<number>();
    return dynamic.every((player, index) => {
      const identity = playerIdentity(player);
      let completeIndex = identity
        ? complete.findIndex((candidate, candidateIndex) => !used.has(candidateIndex) && samePlayer(candidate, player))
        : -1;
      if (completeIndex < 0 && complete[index] && !used.has(index) && (isUnresolvedPlayer(player) || isUnresolvedPlayer(complete[index]))) {
        completeIndex = index;
      }
      if (completeIndex < 0) return false;
      // Player coverage alone is insufficient here: an EndOfGame response can
      // contain the same ten players in the old champion-select order. Keep
      // the fast in-game topology until enrichment agrees on every slot.
      if (completeIndex !== index) return false;
      used.add(completeIndex);
      const candidate = complete[completeIndex];
      if (player.championId > 0 && candidate.championId !== player.championId) return false;
      if (hasKnownName(player) && (!hasKnownName(candidate) || candidate.gameName.toLocaleLowerCase() !== player.gameName.toLocaleLowerCase())) return false;
      if (knownPosition(player.assignedPosition) && candidate.assignedPosition.toUpperCase() !== player.assignedPosition.toUpperCase()) return false;
      if (player.isPremade === true && candidate.isPremade !== true) return false;
      if (player.premadeWith.some((teammate) => !candidate.premadeWith.some((name) => name.toLocaleLowerCase() === teammate.toLocaleLowerCase()))) return false;
      return true;
    });
  };

  return coversTeam(enriched.ally, overlay.ally) && coversTeam(enriched.enemy, overlay.enemy);
}
