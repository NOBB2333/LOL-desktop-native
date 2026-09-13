<script setup lang="ts">
import { computed, ref, watch } from "vue";
import type { PlayerProfile } from "../types/domain";
import { MAX_TAG_NOTES, MAX_TAG_NOTE_LENGTH, joinTagNotes, splitTagNotes } from "../tags/notes";

const props = defineProps<{
  player: PlayerProfile | null;
  /** 该玩家已有备注。 */
  notes: string[];
  saving?: boolean;
  error?: string;
}>();

const emit = defineEmits<{
  save: [notes: string[]];
  close: [];
}>();

const text = ref("");
/** 编辑框总长度上限：条数 × 单条长度，避免一次粘贴塞进超长文本。 */
const maxLength = computed(() => MAX_TAG_NOTES * MAX_TAG_NOTE_LENGTH);

watch(
  () => [props.player?.puuid, props.notes.join("\n")] as const,
  () => { text.value = joinTagNotes(props.notes ?? []); },
  { immediate: true },
);

function submit() {
  emit("save", splitTagNotes(text.value));
}
</script>

<template>
  <div v-if="player" class="tag-editor" data-testid="player-tag-editor" @click.self="emit('close')">
    <section class="tag-editor__card" role="dialog" aria-modal="true" :aria-label="`编辑 ${player.gameName} 的玩家标记`">
      <header class="tag-editor__header">
        <div>
          <span class="eyebrow">玩家标记</span>
          <h3>
            {{ player.gameName }}<small v-if="player.tagLine">#{{ player.tagLine }}</small>
          </h3>
        </div>
        <button type="button" class="tag-editor__close" aria-label="关闭" @click="emit('close')">×</button>
      </header>

      <p class="tag-editor__hint">每行一条备注，保存后会显示在玩家卡片的「已标记」标签里。</p>

      <textarea
        v-model="text"
        class="tag-editor__input"
        rows="5"
        :maxlength="maxLength"
        placeholder="例如：爱抓下路&#10;上次挂机过"
        data-testid="player-tag-input"
      />

      <footer class="tag-editor__footer">
        <span v-if="error" class="tag-editor__status" data-tone="warning">{{ error }}</span>
        <span v-else class="tag-editor__status" data-tone="muted">最多 8 条，单条 {{ MAX_TAG_NOTE_LENGTH }} 字</span>
        <div class="tag-editor__actions">
          <button type="button" class="tag-editor__button" :disabled="saving" @click="emit('close')">取消</button>
          <button
            type="button"
            class="tag-editor__button tag-editor__button--primary"
            :disabled="saving"
            data-testid="player-tag-save"
            @click="submit"
          >
            {{ saving ? "保存中…" : "保存" }}
          </button>
        </div>
      </footer>
    </section>
  </div>
</template>

<style scoped>
.tag-editor { position: fixed; inset: 0; z-index: 40; display: grid; place-items: center; padding: 20px; background: color-mix(in srgb, #000 45%, transparent); }
.tag-editor__card { width: min(420px, 100%); padding: 14px 16px; border: 1px solid var(--line-strong); border-radius: 8px; color: var(--text-primary); background: var(--surface-raised); box-shadow: 0 18px 48px rgba(0, 0, 0, 0.28); }
.tag-editor__header { display: flex; align-items: flex-start; justify-content: space-between; gap: 10px; }
.tag-editor__header h3 { margin: 3px 0 0; font-size: 14px; }
.tag-editor__header h3 small { margin-left: 4px; color: var(--text-secondary); font-size: 10px; font-weight: 500; }
.tag-editor__close { flex: none; width: 24px; height: 24px; padding: 0; border: 1px solid var(--line); border-radius: 4px; color: var(--text-secondary); background: var(--surface); font-size: 14px; line-height: 1; cursor: pointer; }
.tag-editor__close:hover { color: var(--accent); border-color: var(--accent); }
.tag-editor__hint { margin: 9px 0 7px; color: var(--text-secondary); font-size: 10px; line-height: 1.5; }
.tag-editor__input { width: 100%; min-height: 92px; padding: 8px 9px; border: 1px solid var(--line-strong); border-radius: 5px; color: var(--text-primary); background: var(--surface); font: inherit; font-size: 11px; line-height: 1.6; resize: vertical; }
.tag-editor__input:focus-visible { border-color: var(--accent); outline: none; box-shadow: 0 0 0 2px var(--accent-soft); }
.tag-editor__footer { display: flex; align-items: center; justify-content: space-between; gap: 10px; margin-top: 10px; }
.tag-editor__status { color: var(--text-muted); font-size: 9px; }
.tag-editor__status[data-tone="warning"] { color: var(--amber); }
.tag-editor__actions { display: flex; gap: 6px; }
.tag-editor__button { padding: 5px 12px; border: 1px solid var(--line-strong); border-radius: 4px; color: var(--text-primary); background: var(--surface); font: inherit; font-size: 11px; cursor: pointer; }
.tag-editor__button:hover:not(:disabled) { border-color: var(--accent); }
.tag-editor__button:disabled { opacity: 0.6; cursor: default; }
.tag-editor__button--primary { border-color: var(--accent); color: #fff; background: var(--accent); }
</style>
