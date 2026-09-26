<script setup lang="ts">
import { computed, ref, watchEffect } from "vue";
import { isLcuAssetPath, lcuAssetToCommunityDragon } from "../assets/lcuAsset";
import { cachedAsset, peekAsset } from "../assets/assetCache";
import { backend, isTauri } from "../services/backend";

/**
 * 按 LCU 资源路径显示图标（领取奖励那类只有路径、没有编号的资源）。
 *
 * 取图顺序：原生宿主能用就先要 LCU 的字节（本地、最准），拿不到再退回
 * CommunityDragon；浏览器预览里没有原生宿主，直接走 CommunityDragon——预览不至于
 * 永远是个空框。两条路都失败时把默认插槽的内容当作占位（调用方塞一个图标进去）。
 *
 * `path` 也可以直接给一个能用的 URL 或内联图（fixture 就这么用）：那类值不是 LCU
 * 路径，原样显示即可。
 */
const props = withDefaults(defineProps<{
  path: string | null;
  alt?: string;
  size?: "sm" | "md" | "lg";
}>(), { alt: "", size: "md" });

const source = ref("");
const failed = ref(false);
/** 缓存键：LCU 路径本身就能唯一标识一张图。 */
const assetKey = computed(() => {
  const path = props.path?.trim() ?? "";
  return isLcuAssetPath(path) ? `path:${path}` : "";
});
const communityDragonUrl = computed(() => lcuAssetToCommunityDragon(props.path));
/** 不是 LCU 路径但本身就能当 src 用（http(s) / data: / 站内绝对路径）。 */
const directUrl = computed(() => {
  const path = props.path?.trim() ?? "";
  if (!path || isLcuAssetPath(path)) return "";
  return /^(https?:|data:|\/)/.test(path) ? path : "";
});
const resolved = computed(() => source.value || directUrl.value || communityDragonUrl.value || "");

watchEffect((onCleanup) => {
  let active = true;
  onCleanup(() => { active = false; });
  failed.value = false;
  const key = assetKey.value;
  // 缓存命中时同步就有值，重挂不再闪一下占位。
  source.value = key ? peekAsset(key) : "";
  if (!key || !isTauri()) return;
  void cachedAsset(key, () => backend.assetPath(props.path ?? "").then((asset) => asset.dataUrl ?? ""))
    .then((url) => {
      if (active && url) source.value = url;
    })
    .catch(() => {
      // 交给 CommunityDragon 兜底，这里不标记失败。
    });
});
</script>

<template>
  <span class="lcu-asset" :class="`lcu-asset--${size}`">
    <img v-if="resolved && !failed" :src="resolved" :alt="alt" loading="lazy" @error="failed = true" />
    <span v-else class="lcu-asset__fallback"><slot /></span>
  </span>
</template>

<style scoped>
.lcu-asset {
  display: inline-grid;
  flex: 0 0 auto;
  place-items: center;
  overflow: hidden;
  border: 1px solid var(--line-strong);
  border-radius: 6px;
  background: var(--surface-raised);
  color: var(--text-muted);
}

.lcu-asset--sm { width: 28px; height: 28px; }
.lcu-asset--md { width: 40px; height: 40px; }
.lcu-asset--lg { width: 56px; height: 56px; }

.lcu-asset img {
  width: 100%;
  height: 100%;
  object-fit: cover;
}

.lcu-asset__fallback {
  display: grid;
  place-items: center;
}
</style>
