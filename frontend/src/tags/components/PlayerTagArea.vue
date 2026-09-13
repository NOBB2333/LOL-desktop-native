<script setup lang="ts">
import { NPopover } from "naive-ui";
import { computed } from "vue";
import { useAppStore } from "../../stores/app";
import type { EncounterRecord, PlayerProfile } from "../../types/domain";
import { usePlayerCardTagContext } from "../context";
import { normalizePlayerTagSettings, type PlayerTagSettings } from "../settings";
import type { PlayerTagPopover } from "../types";
import { usePlayerTags } from "../usePlayerTags";

const props = withDefaults(
  defineProps<{
    player: PlayerProfile;
    /** 本地玩家，用于「自己」标签与「上局队友/对手」判定。 */
    localPlayer?: PlayerProfile | null;
    /** 开黑分组序号，同组同色。 */
    premadeTone?: number;
    /** 我的开黑队友不显示「遇到过」。 */
    suppressEncounters?: boolean;
    encounterRecords?: EncounterRecord[];
    encounterLoading?: boolean;
    encounterError?: boolean;
    currentGameId?: number;
    /** 本地玩家为该玩家写的备注。 */
    playerNotes?: string[];
    /** 是否允许编辑备注。 */
    canEditNotes?: boolean;
    /** 标签区是否显示「标签」前缀。 */
    showLabel?: boolean;
  }>(),
  {
    localPlayer: null,
    encounterRecords: () => [],
    encounterLoading: false,
    encounterError: false,
    currentGameId: 0,
    playerNotes: () => [],
    canEditNotes: false,
    showLabel: true,
  },
);

const emit = defineEmits<{
  "select-encounter": [records: EncounterRecord[]];
  "retry-encounters": [];
  "edit-notes": [];
}>();

const app = useAppStore();

const settings = computed<PlayerTagSettings>(() => {
  const base = normalizePlayerTagSettings(app.config.playerTags);
  // 「我的开黑队友」不需要提示「遇到过」，直接关掉该标签，避免在定义里再开一个分支。
  return props.suppressEncounters ? { ...base, showMetTag: false } : base;
});

const context = usePlayerCardTagContext({
  player: () => props.player,
  selfPuuid: computed(() => props.localPlayer?.puuid ?? null),
  selfPlayer: () => props.localPlayer ?? null,
  settings,
  encounterRecords: () => props.encounterRecords ?? [],
  encounterLoading: () => props.encounterLoading,
  encounterError: () => props.encounterError,
  currentGameId: () => props.currentGameId,
  premadeTone: () => props.premadeTone,
  playerNotes: () => props.playerNotes ?? [],
  canEditNotes: () => props.canEditNotes,
  onEditNotes: () => emit("edit-notes"),
  openEncounterGame: (records) => emit("select-encounter", records),
  retryEncounters: () => emit("retry-encounters"),
});

const tags = usePlayerTags(context);

const popoverStyle = (popover: PlayerTagPopover) => ({
  maxHeight: popover.maxHeight ? `${popover.maxHeight}px` : undefined,
  overflowY: popover.scrollable ? ("auto" as const) : undefined,
});
</script>

<template>
  <section class="tag-area" data-testid="player-tags">
    <small v-if="showLabel" class="tag-area__label">标签</small>
    <template v-for="tag in tags" :key="tag.id">
      <NPopover
        v-if="tag.popover"
        :delay="tag.popover.delay ?? 50"
        :keep-alive-on-hover="tag.popover.keepAliveOnHover ?? false"
        :show-arrow="false"
        :style="{ maxWidth: 'min(92vw, 560px)' }"
      >
        <template #trigger>
          <component :is="tag.label" />
        </template>
        <div class="tag-area__popover" :style="popoverStyle(tag.popover)" @click.stop>
          <component :is="tag.popover.content" />
        </div>
      </NPopover>
      <component :is="tag.label" v-else />
    </template>
    <span v-if="!tags.length" class="tag-area__empty">暂无标签</span>
  </section>
</template>

<style scoped>
.tag-area {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 4px;
  min-width: 0;
}

.tag-area__label {
  margin-right: 2px;
  color: var(--text-muted);
  font-size: 9px;
  font-weight: 700;
}

.tag-area__popover {
  max-width: min(92vw, 560px);
}

.tag-area__empty {
  color: var(--text-muted);
  font-size: 9px;
  font-weight: 500;
}
</style>
