import { computed, toValue, type ComputedRef, type MaybeRefOrGetter } from "vue";
import type { EncounterRecord, PlayerProfile } from "../types/domain";
import { deriveTagFacts } from "./facts";
import type { PlayerTagSettings } from "./settings";
import type { PlayerTagContext } from "./types";

/** 构建标签上下文所需的数据源；全部以 getter 传入，保持惰性与响应性。 */
export interface PlayerTagContextSource {
  player: MaybeRefOrGetter<PlayerProfile>;
  selfPuuid: MaybeRefOrGetter<string | null>;
  selfPlayer: MaybeRefOrGetter<PlayerProfile | null>;
  settings: MaybeRefOrGetter<PlayerTagSettings>;
  encounterRecords: MaybeRefOrGetter<EncounterRecord[]>;
  encounterLoading: MaybeRefOrGetter<boolean>;
  encounterError: MaybeRefOrGetter<boolean>;
  currentGameId: MaybeRefOrGetter<number>;
  premadeTone: MaybeRefOrGetter<number | undefined>;
  playerNotes: MaybeRefOrGetter<string[]>;
  canEditNotes: MaybeRefOrGetter<boolean>;
  onEditNotes?: () => void;
  openEncounterGame: (records: EncounterRecord[]) => void;
  retryEncounters: () => void;
}

/**
 * 组装标签渲染上下文。
 *
 * 与 LeagueAkari 的 `usePlayerCardTagContext` 对应：把散落在组件里的数据收拢成
 * 一份只读上下文，标签定义因此不需要知道任何组件结构。
 * `facts` 在这里推导一次，所有标签共享同一份样本统计。
 */
export function usePlayerCardTagContext(source: PlayerTagContextSource): ComputedRef<PlayerTagContext> {
  return computed<PlayerTagContext>(() => {
    const player = toValue(source.player);
    return {
      player,
      selfPuuid: toValue(source.selfPuuid) ?? null,
      selfPlayer: toValue(source.selfPlayer) ?? null,
      settings: toValue(source.settings),
      facts: deriveTagFacts(player),
      encounterRecords: toValue(source.encounterRecords),
      encounterLoading: toValue(source.encounterLoading),
      encounterError: toValue(source.encounterError),
      currentGameId: toValue(source.currentGameId),
      premadeTone: toValue(source.premadeTone),
      playerNotes: toValue(source.playerNotes),
      canEditNotes: toValue(source.canEditNotes),
      onEditNotes: source.onEditNotes,
      openEncounterGame: source.openEncounterGame,
      retryEncounters: source.retryEncounters,
    };
  });
}
