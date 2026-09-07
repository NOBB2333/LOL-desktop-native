import { describe, expect, it } from "vitest";
import { isCurrentLiveSnapshot, isVisibleGamePhase, shouldAutoHideLivePanel, shouldResetClearedLivePanel } from "./livePanel";

describe("live panel visibility", () => {
  it.each(["PreEndOfGame", "WaitingForStats", "EndOfGame"])("keeps %s visible as part of the game flow", (phase) => {
    expect(isVisibleGamePhase(phase)).toBe(true);
    expect(shouldAutoHideLivePanel({ enabled: true, mode: "live", connectionStatus: "connected", connectionPhase: phase, snapshotPhase: "EndOfGame" })).toBe(false);
  });

  it.each(["Lobby", "None", "Matchmaking", "ReadyCheck"])("hides the retained panel after entering %s", (phase) => {
    expect(shouldAutoHideLivePanel({ enabled: true, mode: "live", connectionStatus: "connected", connectionPhase: phase, snapshotPhase: "EndOfGame" })).toBe(true);
  });

  it("does not auto-hide when the setting is disabled", () => {
    expect(shouldAutoHideLivePanel({ enabled: false, mode: "live", connectionStatus: "connected", connectionPhase: "Lobby", snapshotPhase: "EndOfGame" })).toBe(false);
  });

  it("keeps a fresh active roster visible while the connection phase catches up", () => {
    expect(shouldAutoHideLivePanel({ enabled: true, mode: "live", connectionStatus: "connected", connectionPhase: "Lobby", snapshotPhase: "ChampSelect", snapshotIsCurrent: true })).toBe(false);
    expect(shouldAutoHideLivePanel({ enabled: true, mode: "live", connectionStatus: "connected", connectionPhase: "None", snapshotPhase: "WatchInProgress", snapshotIsCurrent: true })).toBe(false);
  });

  it("keeps the last active roster visible through a transient LCU phase reset", () => {
    expect(shouldAutoHideLivePanel({ enabled: true, mode: "live", connectionStatus: "connected", connectionPhase: "Lobby", snapshotPhase: "ChampSelect", snapshotIsCurrent: false })).toBe(false);
    expect(shouldAutoHideLivePanel({ enabled: true, mode: "live", connectionStatus: "disconnected", snapshotPhase: "InProgress", snapshotIsCurrent: false })).toBe(false);
  });

  it("compares active snapshots with the latest observed connection phase", () => {
    expect(isCurrentLiveSnapshot({ snapshotPhase: "InProgress", basePhase: "InProgress", overlayPhase: null, baseRequestStartedAt: 100, overlayRequestStartedAt: 0, connectionPhaseChangedAt: 200 })).toBe(false);
    expect(isCurrentLiveSnapshot({ snapshotPhase: "WatchInProgress", basePhase: "EndOfGame", overlayPhase: "WatchInProgress", baseRequestStartedAt: 100, overlayRequestStartedAt: 300, connectionPhaseChangedAt: 200 })).toBe(true);
    expect(isCurrentLiveSnapshot({ snapshotPhase: "EndOfGame", basePhase: "EndOfGame", overlayPhase: null, baseRequestStartedAt: 100, overlayRequestStartedAt: 0, connectionPhaseChangedAt: 200 })).toBe(true);
  });

  it("hides a retained terminal snapshot after the client disconnects", () => {
    expect(shouldAutoHideLivePanel({ enabled: true, mode: "live", connectionStatus: "disconnected", snapshotPhase: "EndOfGame" })).toBe(true);
  });

  it("resets a cleared panel for a different stable game ID", () => {
    expect(shouldResetClearedLivePanel({ previousGameId: "90071992547409931", gameId: "90071992547409932", previousPhase: "EndOfGame", phase: "InProgress" })).toBe(true);
    expect(shouldResetClearedLivePanel({ previousGameId: "game-live", gameId: "9001", previousPhase: "ChampSelect", phase: "InProgress" })).toBe(false);
  });

  it("does not reopen a cleared panel when the same game reports an out-of-order active phase", () => {
    expect(shouldResetClearedLivePanel({ previousGameId: "9001", gameId: "9001", previousPhase: "EndOfGame", phase: "InProgress" })).toBe(false);
  });

  it("resets when a new active snapshot follows a terminal snapshot", () => {
    expect(shouldResetClearedLivePanel({ previousGameId: "game-old", gameId: "champ-select-new", previousPhase: "EndOfGame", phase: "ChampSelect" })).toBe(true);
    expect(shouldResetClearedLivePanel({ previousGameId: "game-old", gameId: "game-old", previousPhase: "ChampSelect", phase: "GameStart" })).toBe(false);
  });
});
