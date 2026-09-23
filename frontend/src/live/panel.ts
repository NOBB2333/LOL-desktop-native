import type { ConnectionStatus, DataMode } from "../types/domain";

const visibleGamePhases = new Set([
  "champselect",
  "gamestart",
  "inprogress",
  "reconnect",
  "watchinprogress",
  "spectating",
  "watching",
  "preendofgame",
  "waitingforstats",
  "endofgame",
]);

const activeGamePhases = new Set([
  "champselect",
  "gamestart",
  "inprogress",
  "reconnect",
  "watchinprogress",
  "spectating",
  "watching",
]);

/**
 * 房间/匹配中：还没进选人，能看到的只有本机所在小队（`/lol-lobby/v2/lobby` 的
 * `members`）。对齐 LeagueAkari 的 `queryInLobbyPhase`——它默认也是「房间照查」。
 */
const roomGamePhases = new Set(["lobby", "matchmaking"]);

const normalizedPhase = (phase?: string | null) => phase?.trim().toLocaleLowerCase() ?? "";

export function isRoomGamePhase(phase?: string | null) {
  return roomGamePhases.has(normalizedPhase(phase));
}

/**
 * `roomRoster` = `providers.lobbyRoster`。房间/匹配中只有在开了这个开关时才算
 * 「可见阶段」——关掉时房间就是普通等待界面，对局面板该收就收，和以前一致。
 */
export function isVisibleGamePhase(phase?: string | null, roomRoster = false) {
  if (isRoomGamePhase(phase)) return roomRoster;
  return visibleGamePhases.has(normalizedPhase(phase));
}

export function isActiveGamePhase(phase?: string | null) {
  return activeGamePhases.has(normalizedPhase(phase));
}

function stableGameId(id?: string | null) {
  const value = id?.trim() ?? "";
  return /^[1-9]\d*$/.test(value) ? value.replace(/^0+/, "") : null;
}

export function shouldResetClearedLivePanel(options: {
  previousGameId?: string | null;
  gameId?: string | null;
  previousPhase?: string | null;
  phase?: string | null;
}) {
  const previousGameId = stableGameId(options.previousGameId);
  const gameId = stableGameId(options.gameId);
  if (previousGameId && gameId) return previousGameId !== gameId;
  return isActiveGamePhase(options.phase) && !isActiveGamePhase(options.previousPhase);
}

export function isCurrentLiveSnapshot(options: {
  snapshotPhase?: string | null;
  basePhase?: string | null;
  overlayPhase?: string | null;
  baseRequestStartedAt: number;
  overlayRequestStartedAt: number;
  connectionPhaseChangedAt: number;
}) {
  if (!isActiveGamePhase(options.snapshotPhase)) return true;
  if (isActiveGamePhase(options.overlayPhase) && options.overlayRequestStartedAt >= options.connectionPhaseChangedAt) return true;
  return isActiveGamePhase(options.basePhase) && options.baseRequestStartedAt >= options.connectionPhaseChangedAt;
}

export function shouldAutoHideLivePanel(options: {
  enabled: boolean;
  mode: DataMode;
  connectionStatus: ConnectionStatus;
  connectionPhase?: string | null;
  snapshotPhase?: string | null;
  snapshotIsCurrent?: boolean;
  /** `providers.lobbyRoster`：房间里也统计队友时，房间阶段不该收面板。 */
  roomRoster?: boolean;
}) {
  if (!options.enabled || options.mode !== "live") return false;
  // The game client can make LCU briefly report disconnected/Lobby while the
  // Live Client Data roster remains authoritative. Never hide an active-game
  // snapshot; terminal snapshots still follow clearLobbyAfterGame below.
  if (isActiveGamePhase(options.snapshotPhase)) return false;
  if (options.connectionStatus === "connected" && options.connectionPhase?.trim()) {
    return !isVisibleGamePhase(options.connectionPhase, options.roomRoster);
  }
  if (["disconnected", "error"].includes(options.connectionStatus)) return true;
  return !isVisibleGamePhase(options.snapshotPhase, options.roomRoster);
}
