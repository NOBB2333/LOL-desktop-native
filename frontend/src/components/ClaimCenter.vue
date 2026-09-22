<script setup lang="ts">
/**
 * 一键领取。
 *
 * 从「工具箱」页搬进「自动化」页：这两件事本质都是「让程序替我做掉客户端的例行操作」，
 * 和自动接受 / 自动选人同类，没必要单开一页。搬过来时保留了原来的全部交互与动效，
 * 只把外层从页面壳（`PageHeader` + `page-shell`）换成 `.panel`，好跟自动化页的卡片对齐。
 *
 * 三个来源的图标是**兜底**：LCU 给了 iconUrl 就显示真图（皮肤碎片、精粹、图标之类），
 * 没给（或者浏览器预览里取不到）才落到这里，这样任何情况下都不是一片空白。
 * 色相只用来区分来源，别当成奖励稀有度。
 */
import { CheckCircle2, CircleAlert, Gift, PackageCheck, RefreshCw, Target, Trophy } from "@lucide/vue";
import { NButton, NCheckbox, useMessage } from "naive-ui";
import { computed, onMounted, ref } from "vue";
import { backend } from "../services/backend";
import { useAppStore } from "../stores/app";
import LcuAssetImage from "./LcuAssetImage.vue";
import type { ClaimSnapshot, ClaimSource } from "../types/domain";

const app = useAppStore();
const message = useMessage();

const sourceGlyphs = { mission: Target, reward: Gift, event: Trophy } as const;
const sourceTones: Record<ClaimSource, { tone: string; soft: string }> = {
  mission: { tone: "var(--accent)", soft: "var(--accent-soft)" },
  reward: { tone: "var(--amber)", soft: "var(--amber-soft)" },
  event: { tone: "var(--blue)", soft: "var(--blue-soft)" },
};

function sourceGlyph(source: ClaimSource) {
  return sourceGlyphs[source] ?? Gift;
}

function sourceTone(source: ClaimSource) {
  const tone = sourceTones[source] ?? sourceTones.reward;
  return { "--tone": tone.tone, "--tone-soft": tone.soft };
}

const claims = ref<ClaimSnapshot>({ items: [], sources: [], total: 0 });
const claimsLoading = ref(false);
const claiming = ref(false);
const selectedKeys = ref<string[]>([]);
/** 最近一次领取的逐条结果，成功失败都留在这儿。 */
const claimResults = ref<{ failed: boolean; text: string }[]>([]);
/** 领取成功后让「N 项可领」跳一下，给个明确的动作回执。 */
const countPulse = ref(false);

const live = computed(() => app.mode === "live");

async function loadClaims(force = false) {
  claimsLoading.value = true;
  try {
    claims.value = await backend.claims();
    // 领掉的条目不再存在，选择也要跟着收敛，否则「领取选中」会带着幽灵 key。
    selectedKeys.value = selectedKeys.value.filter((key) => claims.value.items.some((item) => item.key === key));
    if (force) message.success("已刷新可领内容");
  } catch (cause) {
    message.error(cause instanceof Error ? cause.message : String(cause));
  } finally {
    claimsLoading.value = false;
  }
}

function pulseCount() {
  countPulse.value = false;
  // 下一帧再打开，重复领取时动画才会重新播一次。
  requestAnimationFrame(() => {
    countPulse.value = true;
  });
}

async function runClaim(source: ClaimSource | "all", keys: string[]) {
  if (claiming.value) return;
  claiming.value = true;
  try {
    const outcome = await backend.claim(source, keys);
    claimResults.value = outcome.claimed.map((entry) =>
      entry.reason
        ? { failed: true, text: `失败：${entry.title} — ${entry.reason}` }
        : { failed: false, text: `已领取：${entry.title}${entry.detail ? ` · ${entry.detail}` : ""}` },
    );
    if (outcome.failedCount) message.warning(`领取结束，${outcome.failedCount} 项没领成`);
    else if (outcome.claimedCount) message.success(`已领取 ${outcome.claimedCount} 项`);
    else message.info("这次没有可领的条目");
    if (outcome.claimedCount) pulseCount();
    await loadClaims();
  } catch (cause) {
    message.error(cause instanceof Error ? cause.message : String(cause));
  } finally {
    claiming.value = false;
  }
}

function toggleClaim(key: string, checked: boolean) {
  selectedKeys.value = checked ? [...new Set([...selectedKeys.value, key])] : selectedKeys.value.filter((value) => value !== key);
}

onMounted(() => {
  void loadClaims();
});
</script>

<template>
  <section class="panel claim-panel">
    <header class="panel-heading">
      <div>
        <span class="eyebrow">CLAIM ALL</span>
        <h2>一键领取</h2>
        <p class="panel-copy">
          任务奖励、待选奖励与通行证奖励轨道一次领完；已经领过的不再出现，不会重复提交。
        </p>
      </div>
      <div class="claim-panel__actions">
        <span class="claim-count" :data-pulse="countPulse" @animationend="countPulse = false">{{ claims.total }}<small>项可领</small></span>
        <span class="claim-cta">
          <NButton size="small" type="primary" :loading="claiming" :disabled="!claims.total || claiming" @click="runClaim('all', [])">
            <template #icon><Gift :size="14" /></template>全部领取
          </NButton>
          <span v-if="claiming" class="claim-cta__sweep" aria-hidden="true" />
        </span>
        <NButton size="small" secondary :loading="claimsLoading" @click="loadClaims(true)">
          <template #icon><RefreshCw :size="14" /></template>刷新
        </NButton>
      </div>
    </header>

    <p v-if="!live" class="claim-notice">
      <CircleAlert :size="14" />
      <span>当前不是<b>实时</b>模式：领取会直接作用在真实客户端上，切到「实时」之后才生效。</span>
    </p>

    <div class="claim-sources">
      <span
        v-for="source in claims.sources"
        :key="source.source"
        class="claim-source"
        :data-empty="source.count === 0"
        :style="sourceTone(source.source)"
      >
        <i class="claim-source__glyph"><component :is="sourceGlyph(source.source)" :size="13" /></i>
        <span class="claim-source__label">{{ source.label }}</span>
        <b class="claim-source__count">{{ source.count }}</b>
        <button type="button" :disabled="claiming || !source.count" @click="runClaim(source.source, [])">领取</button>
      </span>
    </div>

    <div v-if="claimsLoading && !claims.total" class="claim-empty"><strong>正在读取可领内容</strong></div>
    <div v-else-if="!claims.total" class="claim-empty">
      <PackageCheck :size="22" />
      <strong>没有可领的东西</strong>
      <span>任务奖励到账、通行证升级之后会出现在这里。</span>
    </div>
    <ul v-else class="claim-list">
      <li
        v-for="(item, index) in claims.items"
        :key="item.key"
        class="claim-item"
        :style="{ ...sourceTone(item.source), '--row': Math.min(index, 12) }"
      >
        <NCheckbox :checked="selectedKeys.includes(item.key)" @update:checked="toggleClaim(item.key, $event)" />
        <LcuAssetImage class="claim-item__icon" :path="item.iconUrl" :alt="item.title" size="md">
          <component :is="sourceGlyph(item.source)" :size="18" />
        </LcuAssetImage>
        <div class="claim-item__body">
          <strong>{{ item.title }}</strong>
          <small>
            <i class="claim-item__chip"><component :is="sourceGlyph(item.source)" :size="10" />{{ item.sourceLabel }}</i>
            <template v-if="item.detail">{{ item.detail }}</template>
          </small>
        </div>
        <span class="claim-item__count">×{{ item.count }}</span>
        <NButton size="tiny" secondary class="claim-item__claim" :disabled="claiming" @click="runClaim('all', [item.key])">领取</NButton>
      </li>
    </ul>

    <div v-if="selectedKeys.length" class="claim-selection">
      <span>已选 {{ selectedKeys.length }} 项</span>
      <NButton size="small" secondary :disabled="claiming" @click="runClaim('all', selectedKeys)">领取选中</NButton>
      <NButton size="small" quaternary @click="selectedKeys = []">清空选择</NButton>
    </div>

    <ul v-if="claimResults.length" class="claim-results">
      <li v-for="(line, index) in claimResults" :key="index" :data-failed="line.failed" :style="{ '--row': Math.min(index, 12) }">
        <CheckCircle2 v-if="!line.failed" :size="13" />
        <CircleAlert v-else :size="13" />
        <span>{{ line.text }}</span>
      </li>
    </ul>
  </section>
</template>

<style scoped>
.claim-panel {
  margin-top: 12px;
  overflow: hidden;
}
.claim-panel__actions {
  display: flex;
  flex: 0 0 auto;
  align-items: center;
  gap: 10px;
}
.claim-count {
  color: var(--text-primary);
  font-size: 20px;
  font-weight: 700;
  line-height: 1;
}
.claim-count small {
  margin-left: 5px;
  color: var(--text-muted);
  font-size: 9px;
  font-weight: 400;
}
/* 领取成功后让数字跳一下——纯数字没有「已完成」的语义，动一下才有回执。 */
.claim-count[data-pulse="true"] {
  animation: claim-count-pop 900ms ease;
}
@keyframes claim-count-pop {
  0% {
    transform: scale(1);
  }
  35% {
    transform: scale(1.22);
    color: var(--accent);
  }
  100% {
    transform: scale(1);
  }
}
/* 「全部领取」进行中的扫光。挂在按钮外面的包裹层上，不去改 naive-ui 的内部结构。 */
.claim-cta {
  position: relative;
  display: inline-flex;
}
.claim-cta__sweep {
  position: absolute;
  inset: 0;
  overflow: hidden;
  pointer-events: none;
}
.claim-cta__sweep::after {
  position: absolute;
  top: 0;
  bottom: 0;
  width: 40%;
  background: linear-gradient(90deg, transparent, rgb(255 255 255 / 45%), transparent);
  content: "";
  animation: claim-sweep 1100ms linear infinite;
}
@keyframes claim-sweep {
  from {
    transform: translateX(-120%);
  }
  to {
    transform: translateX(320%);
  }
}
.claim-notice {
  display: flex;
  align-items: center;
  gap: 8px;
  margin: 0;
  padding: 9px 18px;
  border-top: 1px solid var(--line);
  color: var(--text-secondary);
  background: var(--surface-muted);
  font-size: 11px;
}
.claim-sources {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  padding: 10px 18px;
  border-top: 1px solid var(--line);
  border-bottom: 1px solid var(--line);
  background: var(--surface-muted);
}
.claim-source {
  display: inline-flex;
  align-items: center;
  gap: 7px;
  padding: 4px 5px 4px 8px;
  border: 1px solid var(--line);
  border-left: 2px solid var(--tone, var(--accent));
  color: var(--text-secondary);
  background: var(--surface);
  font-size: 10px;
}
.claim-source[data-empty="true"] {
  opacity: 0.5;
}
.claim-source__glyph {
  display: grid;
  place-items: center;
  width: 20px;
  height: 20px;
  border-radius: 4px;
  color: var(--tone, var(--accent));
  background: var(--tone-soft, var(--accent-soft));
  font-style: normal;
}
.claim-source__label {
  color: var(--text-primary);
}
.claim-source__count {
  min-width: 18px;
  padding: 1px 5px;
  border-radius: 8px;
  color: var(--tone, var(--accent));
  background: var(--tone-soft, var(--accent-soft));
  text-align: center;
  font-size: 10px;
  font-weight: 700;
}
.claim-source button {
  padding: 3px 8px;
  border: 1px solid var(--line);
  color: var(--text-primary);
  background: var(--surface-raised);
  cursor: pointer;
  font-size: 10px;
}
.claim-source button:not(:disabled):hover {
  border-color: var(--tone, var(--accent));
  color: var(--tone, var(--accent));
  background: var(--tone-soft, var(--accent-soft));
}
.claim-source button:disabled {
  cursor: not-allowed;
  opacity: 0.45;
}
.claim-empty {
  display: grid;
  place-items: center;
  gap: 7px;
  min-height: 150px;
  color: var(--text-muted);
  font-size: 11px;
}
.claim-list {
  margin: 0;
  padding: 0;
  list-style: none;
}
.claim-item {
  display: grid;
  grid-template-columns: 22px 46px minmax(0, 1fr) 48px auto;
  align-items: center;
  gap: 11px;
  min-height: 62px;
  padding: 9px 18px;
  border-bottom: 1px solid var(--line);
  border-left: 2px solid transparent;
  animation: claim-row-in 240ms ease both;
  animation-delay: calc(var(--row, 0) * 22ms);
}
@keyframes claim-row-in {
  from {
    opacity: 0;
    transform: translateY(4px);
  }
  to {
    opacity: 1;
    transform: none;
  }
}
.claim-item:last-child {
  border-bottom: 0;
}
.claim-item:hover {
  border-left-color: var(--tone, var(--accent));
  background: var(--surface-raised);
}
.claim-item__icon {
  border-color: var(--tone-soft, var(--accent-soft));
  color: var(--tone, var(--accent));
  background: var(--tone-soft, var(--accent-soft));
}
.claim-item__body {
  min-width: 0;
}
.claim-item__body strong {
  display: block;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-size: 12px;
}
.claim-item__body small {
  display: flex;
  align-items: center;
  gap: 6px;
  min-width: 0;
  margin-top: 3px;
  overflow: hidden;
  color: var(--text-muted);
  font-size: 10px;
  white-space: nowrap;
}
.claim-item__chip {
  display: inline-flex;
  flex: 0 0 auto;
  align-items: center;
  gap: 3px;
  padding: 1px 6px;
  border-radius: 8px;
  color: var(--tone, var(--accent));
  background: var(--tone-soft, var(--accent-soft));
  font-style: normal;
}
.claim-item__count {
  padding: 2px 7px;
  border-radius: 9px;
  color: var(--text-secondary);
  background: var(--surface-muted);
  text-align: center;
  font-size: 10px;
  font-weight: 600;
}
.claim-selection {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 9px 18px;
  border-top: 1px solid var(--line);
  color: var(--text-secondary);
  background: var(--surface-muted);
  font-size: 10px;
}
.claim-results {
  margin: 0;
  padding: 9px 18px;
  border-top: 1px solid var(--line);
  list-style: none;
}
.claim-results li {
  display: flex;
  align-items: center;
  gap: 7px;
  color: var(--green);
  font-size: 10px;
  line-height: 1.8;
  animation: claim-row-in 220ms ease both;
  animation-delay: calc(var(--row, 0) * 30ms);
}
.claim-results li[data-failed="true"] {
  color: var(--red);
}

@media (max-width: 820px) {
  .claim-panel :deep(.panel-heading) {
    flex-direction: column;
  }
  .claim-item {
    grid-template-columns: 22px 46px minmax(0, 1fr) auto;
  }
  .claim-item__count {
    display: none;
  }
}

/* 动画一律让位给系统设置。 */
@media (prefers-reduced-motion: reduce) {
  .claim-item,
  .claim-results li,
  .claim-count[data-pulse="true"],
  .claim-cta__sweep::after {
    animation: none;
  }
}
</style>
