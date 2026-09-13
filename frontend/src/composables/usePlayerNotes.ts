import { computed, ref, toValue, watch, type ComputedRef, type MaybeRefOrGetter } from "vue";
import { backend } from "../services/backend";

export interface PlayerNotesController {
  /** puuid → 备注列表。 */
  notes: ComputedRef<Record<string, string[]>>;
  loading: ComputedRef<boolean>;
  error: ComputedRef<string | null>;
  /** 取某位玩家的备注。 */
  notesFor: (puuid: string | null | undefined) => string[];
  /** 只有「别人」才允许写备注。 */
  canEdit: (puuid: string | null | undefined) => boolean;
  /** 覆盖写入备注并就地更新缓存。 */
  save: (puuid: string, notes: string[]) => Promise<void>;
  /** 重新拉取。 */
  reload: () => Promise<void>;
}

/**
 * 本局玩家的备注（玩家标记）。
 *
 * 标签系统本身不关心备注从哪来：这里把「按 puuid 批量读取 + 写回」收拢成一个
 * controller，`PlayerTagArea` 只需要拿到数组即可渲染「玩家标记」标签。
 * 请求按 puuid 集合去重，避免每个玩家卡片各发一次请求。
 */
export function usePlayerNotes(
  puuids: MaybeRefOrGetter<string[]>,
  selfPuuid: MaybeRefOrGetter<string | null>,
): PlayerNotesController {
  const map = ref<Record<string, string[]>>({});
  const loading = ref(false);
  const error = ref<string | null>(null);
  let generation = 0;

  const targets = computed(() =>
    [...new Set(toValue(puuids).map((puuid) => puuid?.trim() ?? "").filter(Boolean))].sort(),
  );
  const targetKey = computed(() => targets.value.join("|"));
  const self = computed(() => (toValue(selfPuuid) ?? "").trim());

  async function reload(): Promise<void> {
    const list = targets.value;
    if (!list.length) {
      map.value = {};
      return;
    }
    const current = ++generation;
    loading.value = true;
    error.value = null;
    try {
      const result = await backend.playerTags(list, self.value || null);
      if (current !== generation) return;
      const next: Record<string, string[]> = {};
      for (const puuid of list) next[puuid] = result[puuid] ?? [];
      map.value = next;
    } catch (cause) {
      if (current !== generation) return;
      error.value = cause instanceof Error ? cause.message : String(cause);
    } finally {
      if (current === generation) loading.value = false;
    }
  }

  watch(targetKey, () => { void reload(); }, { immediate: true });

  function notesFor(puuid: string | null | undefined): string[] {
    return map.value[puuid?.trim() ?? ""] ?? [];
  }

  function canEdit(puuid: string | null | undefined): boolean {
    const target = puuid?.trim() ?? "";
    return Boolean(target) && target !== self.value;
  }

  async function save(puuid: string, notes: string[]): Promise<void> {
    const target = puuid.trim();
    if (!target) return;
    const result = await backend.updatePlayerTag(target, notes, self.value || null);
    map.value = { ...map.value, [target]: result.notes };
  }

  return {
    notes: computed(() => map.value),
    loading: computed(() => loading.value),
    error: computed(() => error.value),
    notesFor,
    canEdit,
    save,
    reload,
  };
}
