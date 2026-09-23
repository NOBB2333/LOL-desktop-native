<script setup lang="ts">
import { computed, ref, watchEffect } from "vue";
import { backend, isTauri } from "../services/backend";

const props = withDefaults(defineProps<{
  kind: "champion" | "item" | "spell" | "perk" | "profile";
  id: number;
  name?: string;
  fallbackUrl?: string;
  size?: "xs" | "sm" | "md" | "lg" | "xl";
  /**
   * 圆形裁切。
   *
   * 召唤师头像本身是圆的，方框裁切会把边框切掉一块、看起来「不像那个人」；
   * 英雄/装备/符文都是方形图，不能跟着变圆。
   */
  round?: boolean;
}>(), { name: "", fallbackUrl: "", size: "md", round: false });

const nativeSource = ref("");
/** 已经加载失败的候选地址。**是列表不是布尔**：一个挂了不能把另一个也判死。 */
const broken = ref<string[]>([]);
const initials = computed(() => props.name.trim().slice(0, 1) || "?");

/**
 * 候选顺序：原生取到的字节（LCU 本地、版本最准）在前，调用方给的远程地址兜底。
 *
 * 这里刻意做成「取第一个还没挂的」而不是「取第一个」：远程地址是先到的那一个
 * （同步就能用），原生结果晚几十毫秒才回来；如果远程那张先报错，旧的写法会把整个
 * 图标判死，之后原生明明取到了也不显示——那正是「头像时好时坏」的来源。
 */
const source = computed(() => {
  const candidates = [nativeSource.value, props.fallbackUrl];
  for (const candidate of candidates) {
    if (candidate && !broken.value.includes(candidate)) return candidate;
  }
  return "";
});

watchEffect((onCleanup) => {
  let active = true;
  onCleanup(() => { active = false; });
  broken.value = [];
  nativeSource.value = "";
  if (!isTauri() || props.id <= 0) return;
  void backend.asset(props.kind, props.id).then((asset) => {
    // 空载荷不该抹掉调用方已经给好的 URL。
    if (active && asset.dataUrl) nativeSource.value = asset.dataUrl;
  }).catch(() => {
    // 拿不到就留在远程兜底上，这里不标记失败。
  });
});

function onError() {
  if (source.value && !broken.value.includes(source.value)) broken.value = [...broken.value, source.value];
}
</script>

<template>
  <span class="asset-icon" :class="[`asset-icon--${size}`, { 'asset-icon--round': round }]" :title="name" :aria-label="name || undefined" :role="name ? 'img' : undefined">
    <img v-if="source" :src="source" alt="" @error="onError" />
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
/* 召唤师头像用整圆：客户端里就是这么显示的，方角会让人认不出是谁。 */
.asset-icon--round { border-radius: 50%; }

.asset-icon img {
  width: 100%;
  height: 100%;
  object-fit: cover;
}

.asset-icon__fallback {
  font-weight: 700;
}
</style>
