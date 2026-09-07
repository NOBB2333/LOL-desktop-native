<script setup lang="ts">
import { computed, ref, watchEffect } from "vue";
import { backend, isTauri } from "../services/backend";

const props = withDefaults(defineProps<{
  kind: "champion" | "item" | "spell" | "perk" | "profile";
  id: number;
  name?: string;
  fallbackUrl?: string;
  size?: "xs" | "sm" | "md" | "lg" | "xl";
}>(), { name: "", fallbackUrl: "", size: "md" });

const source = ref("");
const failed = ref(false);
const initials = computed(() => props.name.trim().slice(0, 1) || "?");

watchEffect((onCleanup) => {
  let active = true;
  failed.value = false;
  source.value = props.fallbackUrl.startsWith("lcu://") ? "" : props.fallbackUrl;
  if (isTauri() && props.id > 0) {
    void backend.asset(props.kind, props.id).then((asset) => {
      if (active) {
        failed.value = false;
        // Keep the local/fixture fallback when the native host has no asset
        // provider yet; an empty bridge payload should not erase a valid URL.
        source.value = asset.dataUrl || source.value;
      }
    }).catch(() => {
      if (active && !source.value) failed.value = true;
    });
  }
  onCleanup(() => { active = false; });
});
</script>

<template>
  <span class="asset-icon" :class="`asset-icon--${size}`" :title="name" :aria-label="name || undefined" :role="name ? 'img' : undefined">
    <img v-if="source && !failed" :src="source" alt="" @error="failed = true" />
    <span v-else class="asset-icon__fallback">{{ initials }}</span>
  </span>
</template>

<style scoped>
.asset-icon {
  position: relative;
  display: inline-grid;
  flex: 0 0 auto;
  place-items: center;
  overflow: hidden;
  border: 1px solid var(--line-strong);
  border-radius: 5px;
  background: var(--surface-raised);
  color: var(--text-muted);
}

.asset-icon--xs { width: 20px; height: 20px; font-size: 9px; }
.asset-icon--sm { width: 26px; height: 26px; font-size: 10px; }
.asset-icon--md { width: 34px; height: 34px; font-size: 12px; }
.asset-icon--lg { width: 44px; height: 44px; font-size: 14px; }
.asset-icon--xl { width: 58px; height: 58px; font-size: 16px; }

.asset-icon img {
  width: 100%;
  height: 100%;
  object-fit: cover;
}

.asset-icon__fallback {
  font-weight: 700;
}
</style>
