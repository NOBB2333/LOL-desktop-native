<script setup lang="ts">
import { computed, ref, watchEffect } from "vue";
import { cachedAsset, peekAsset } from "../assets/assetCache";
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
   * 召唤师头像本身是圆的，方框裁切会把边框切掉一块、看起来「不像那个人」。
   * 英雄/装备/符文都是方形图，默认**不**跟着变圆；但少数地方会刻意要圆形英雄头像
   * （观战面板的小地图用它当「谁在哪」的记号，方角头像挤在深色底图上认不出来），
   * 这时显式传 `round` 即可——圆形裁切会切掉方形原画的四角，在那些位置无所谓。
   */
  round?: boolean;
}>(), { name: "", fallbackUrl: "", size: "md", round: false });

/** 缓存键。`id <= 0` 没有可取的图（0 不是合法图标 id），此时不进缓存。 */
const assetKey = computed(() => (props.id > 0 ? `${props.kind}:${props.id}` : ""));
const nativeSource = ref(assetKey.value ? peekAsset(assetKey.value) : "");
/** 已经加载失败的候选地址。**是列表不是布尔**：一个挂了不能把另一个也判死。 */
const broken = ref<string[]>([]);
const initials = computed(() => props.name.trim().slice(0, 1) || "?");

/**
 * ⚠️ **不要再在这里加「没滚到眼前就不取图」的 `IntersectionObserver` 门控**（2026-10-03 试过，已回退）。
 *
 * 当时的推理是：英雄页默认渲染 **245 行**，每行一个图标就是 245 次桥调用、
 * 每次都要 `discoverClient` + 新开一条 WinHTTP 连接打 LCU（实测 **39.7ms/张**），
 * 所以只给「接近视口」的那十几行取图。推理没错，但**实测把英雄头像整个卡死了**：
 * `IntersectionObserver` 在这套 WebView 里没有按预期回调，`visible` 一直是 `false`，
 * 于是**没有任何一个图标再去取图**——用户看到的就是「这些英雄头像加载不出来了」。
 *
 * （它另外还埋着一个更隐蔽的坑：`watchEffect` 会在 setup 期间**同步跑第一次**，
 * 被它读到的 `visible` 必须声明在它前面，否则就是暂时性死区
 * `ReferenceError: Cannot access 'visible' before initialization`，而且**只在真有原生宿主时**才炸。
 * 两个问题叠在一起，排查时极容易跑到缓存 / mock 的方向去。）
 *
 * 真正的修法分两处，都**不依赖任何可见性回调**：
 *   1. 后端：`lol.get_asset` 拆出独立的 `asset` lane（多 worker 并行消费）与独立配额，
 *      不再和交互式查询串在一条队列里抢名额（见 `src/lcu.zig` 的 `lane_worker_count`）。
 *   2. 前端：`../assets/assetCache.ts` 限制同时在飞的取图请求数——行为上是
 *      「一定会加载，只是分批」，符合直觉。
 *
 * 另外 `../services/backend.ts` 的 `asset()` 也修了一处**会永久焊死空白**的缓存 bug：
 * 它曾把空载荷的 promise 一直留在 map 里，导致某次取图失败后同一个图标再也不重试。
 */

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
  const key = assetKey.value;
  // 缓存命中时**同步**就有值：卡片因身份落定而重挂时不会再闪一下首字母占位。
  nativeSource.value = key ? peekAsset(key) : "";
  if (!isTauri() || !key) return;
  void cachedAsset(key, () => backend.asset(props.kind, props.id).then((asset) => asset.dataUrl ?? ""))
    .then((url) => {
      // 空载荷不该抹掉调用方已经给好的 URL。
      if (active && url) nativeSource.value = url;
    })
    .catch(() => {
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
