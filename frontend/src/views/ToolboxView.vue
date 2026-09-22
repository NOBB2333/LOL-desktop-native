<script setup lang="ts">
import { CheckCircle2, CircleAlert, Gift, PackageCheck, RefreshCw, ShieldAlert, Target, Trophy, Wrench } from "@lucide/vue";
import { NButton, NCheckbox, NPopconfirm, useMessage } from "naive-ui";
import { computed, onMounted, ref } from "vue";
import LcuAssetImage from "../components/LcuAssetImage.vue";
import PageHeader from "../components/PageHeader.vue";
import { backend } from "../services/backend";
import { useAppStore } from "../stores/app";
import type { ClaimSnapshot, ClaimSource, GameflowActionKey, GameflowActionResult } from "../types/domain";

const app = useAppStore();
const message = useMessage();

/**
 * 客户端急救动作表。
 *
 * 键名与后端 `src/backend/gameflow_ipc.zig` 的 `action_table` **逐项对应**：
 * 少一个后端会回 `InvalidRequest`，多一个点下去不会有任何反应。
 * 阶段限制故意不在这里复刻——判定的真身在客户端，界面只给一句提示。
 */
const gameflowActions: { key: GameflowActionKey; label: string; hint: string; confirm?: string }[] = [
  { key: "dodge", label: "英雄选择秒退", hint: "还在选人阶段时直接退掉这一局", confirm: "秒退会被记为一次逃跑，确定要退出这一局吗？" },
  { key: "leave-lobby", label: "退出房间", hint: "把当前房间关掉，回到大厅", confirm: "会解散当前房间，确定退出吗？" },
  { key: "play-again", label: "退出结算页面", hint: "结算页卡住出不来时用它" },
  { key: "reconnect", label: "重新连接", hint: "卡在「正在重新连接」时用它" },
  { key: "ack-failed-launch", label: "清除「启动游戏失败」", hint: "进不去游戏、界面已经点不动时用它" },
];

/**
 * 三个来源各自的图标与色相。
 *
 * 图标是**兜底**：LCU 给了 iconUrl 就显示真图（皮肤碎片、精粹、图标之类），
 * 没给（或者浏览器预览里取不到）才落到这里，这样任何情况下都不是一片空白。
 * 色相只用来区分来源，别当成奖励稀有度。
 */
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
const gameflowBusy = ref<GameflowActionKey | null>(null);
const gameflowResult = ref<GameflowActionResult | null>(null);
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
  requestAnimationFrame(() => { countPulse.value = true; });
}

async function runClaim(source: ClaimSource | "all", keys: string[]) {
  if (claiming.value) return;
  claiming.value = true;
  try {
    const outcome = await backend.claim(source, keys);
    claimResults.value = outcome.claimed.map((entry) => entry.reason
      ? { failed: true, text: `失败：${entry.title} — ${entry.reason}` }
      : { failed: false, text: `已领取：${entry.title}${entry.detail ? ` · ${entry.detail}` : ""}` });
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

async function runGameflow(key: GameflowActionKey) {
  if (gameflowBusy.value) return;
  gameflowBusy.value = key;
  try {
    gameflowResult.value = await backend.gameflowAction(key);
    if (gameflowResult.value.ok) message.success(`${gameflowLabel(key)}已执行`);
    else message.warning(gameflowResult.value.reason || "客户端没有接受这个操作");
  } catch (cause) {
    message.error(cause instanceof Error ? cause.message : String(cause));
  } finally {
    gameflowBusy.value = null;
  }
}

function gameflowLabel(key: string) {
  return gameflowActions.find((action) => action.key === key)?.label ?? key;
}

onMounted(() => {
  void loadClaims();
});
</script>

<template>
  <div class="page-shell toolkit-page">
    <PageHeader title="工具箱" eyebrow="TOOLKIT" meta="一键领取与客户端急救；两件都在改客户端状态，不连客户端就没法执行">
      <NButton size="small" secondary :loading="claimsLoading" @click="loadClaims(true)"><template #icon><RefreshCw :size="14" /></template>刷新</NButton>
    </PageHeader>

    <p v-if="!live" class="toolkit-notice">
      <CircleAlert :size="14" />
      <span>当前不是<b>实时</b>模式：领取与急救都会直接作用在真实客户端上，切到「实时」之后才生效。</span>
    </p>

    <!-- 一键领取 -->
    <section class="toolkit-section">
      <header class="toolkit-section__header">
        <div>
          <span class="eyebrow">CLAIM ALL</span>
          <h2>一键领取</h2>
          <p>任务奖励、待选奖励与通行证奖励轨道一次领完；已经领过的不再出现，不会重复提交。</p>
        </div>
        <div class="toolkit-section__actions">
          <span class="toolkit-count" :data-pulse="countPulse" @animationend="countPulse = false">{{ claims.total }}<small>项可领</small></span>
          <span class="toolkit-cta">
            <NButton size="small" type="primary" :loading="claiming" :disabled="!claims.total || claiming" @click="runClaim('all', [])"><template #icon><Gift :size="14" /></template>全部领取</NButton>
            <span v-if="claiming" class="toolkit-cta__sweep" aria-hidden="true" />
          </span>
        </div>
      </header>

      <div class="toolkit-sources">
        <span
          v-for="source in claims.sources"
          :key="source.source"
          class="toolkit-source"
          :data-empty="source.count === 0"
          :style="sourceTone(source.source)"
        >
          <i class="toolkit-source__glyph"><component :is="sourceGlyph(source.source)" :size="13" /></i>
          <span class="toolkit-source__label">{{ source.label }}</span>
          <b class="toolkit-source__count">{{ source.count }}</b>
          <button type="button" :disabled="claiming || !source.count" @click="runClaim(source.source, [])">领取</button>
        </span>
      </div>

      <div v-if="claimsLoading && !claims.total" class="toolkit-empty"><strong>正在读取可领内容</strong></div>
      <div v-else-if="!claims.total" class="toolkit-empty">
        <PackageCheck :size="22" />
        <strong>没有可领的东西</strong>
        <span>任务奖励到账、通行证升级之后会出现在这里。</span>
      </div>
      <ul v-else class="toolkit-list">
        <li
          v-for="(item, index) in claims.items"
          :key="item.key"
          class="toolkit-item"
          :style="{ ...sourceTone(item.source), '--row': Math.min(index, 12) }"
        >
          <NCheckbox :checked="selectedKeys.includes(item.key)" @update:checked="toggleClaim(item.key, $event)" />
          <LcuAssetImage class="toolkit-item__icon" :path="item.iconUrl" :alt="item.title" size="md">
            <component :is="sourceGlyph(item.source)" :size="18" />
          </LcuAssetImage>
          <div class="toolkit-item__body">
            <strong>{{ item.title }}</strong>
            <small>
              <i class="toolkit-item__chip"><component :is="sourceGlyph(item.source)" :size="10" />{{ item.sourceLabel }}</i>
              <template v-if="item.detail">{{ item.detail }}</template>
            </small>
          </div>
          <span class="toolkit-item__count">×{{ item.count }}</span>
          <NButton size="tiny" secondary class="toolkit-item__claim" :disabled="claiming" @click="runClaim('all', [item.key])">领取</NButton>
        </li>
      </ul>

      <div v-if="selectedKeys.length" class="toolkit-selection">
        <span>已选 {{ selectedKeys.length }} 项</span>
        <NButton size="small" secondary :disabled="claiming" @click="runClaim('all', selectedKeys)">领取选中</NButton>
        <NButton size="small" quaternary @click="selectedKeys = []">清空选择</NButton>
      </div>

      <ul v-if="claimResults.length" class="toolkit-results">
        <li v-for="(line, index) in claimResults" :key="index" :data-failed="line.failed" :style="{ '--row': Math.min(index, 12) }">
          <CheckCircle2 v-if="!line.failed" :size="13" />
          <CircleAlert v-else :size="13" />
          <span>{{ line.text }}</span>
        </li>
      </ul>
    </section>

    <!-- 客户端急救 -->
    <section class="toolkit-section">
      <header class="toolkit-section__header">
        <div>
          <span class="eyebrow">CLIENT FIRST AID</span>
          <h2>客户端急救</h2>
          <p>界面卡死、进不去游戏、结算页出不来的最后一招。阶段不对时客户端会自己拒绝，执行结果会写在下面。</p>
        </div>
        <ShieldAlert :size="20" />
      </header>

      <div class="toolkit-actions">
        <template v-for="action in gameflowActions" :key="action.key">
          <NButton v-if="!action.confirm" size="small" secondary :loading="gameflowBusy === action.key" :disabled="Boolean(gameflowBusy)" @click="runGameflow(action.key)">
            <template #icon><Wrench :size="14" /></template>{{ action.label }}
          </NButton>
          <NPopconfirm v-else positive-text="执行" negative-text="取消" @positive-click="runGameflow(action.key)">
            <template #trigger>
              <NButton size="small" secondary :loading="gameflowBusy === action.key" :disabled="Boolean(gameflowBusy)"><template #icon><Wrench :size="14" /></template>{{ action.label }}</NButton>
            </template>
            {{ action.confirm }}
          </NPopconfirm>
        </template>
      </div>

      <ul class="toolkit-hints">
        <li v-for="action in gameflowActions" :key="action.key"><strong>{{ action.label }}</strong>{{ action.hint }}</li>
      </ul>

      <p v-if="gameflowResult" class="toolkit-result" :data-ok="gameflowResult.ok">
        <strong>{{ gameflowLabel(gameflowResult.action) }}</strong>
        <em v-if="gameflowResult.phase">当前阶段 {{ gameflowResult.phase }}</em>
        <span>{{ gameflowResult.ok ? "已执行" : gameflowResult.reason }}</span>
      </p>
    </section>
  </div>
</template>

<style scoped>
.toolkit-page { max-width: 1240px; }
.toolkit-notice { display: flex; align-items: center; gap: 8px; margin: 0 0 12px; padding: 9px 12px; border: 1px solid var(--line); color: var(--text-secondary); background: var(--surface-muted); font-size: 11px; }
.toolkit-section { margin-bottom: 16px; border: 1px solid var(--line); background: var(--surface); }
.toolkit-section__header { display: flex; align-items: flex-start; justify-content: space-between; gap: 14px; padding: 14px 16px; border-bottom: 1px solid var(--line); }
.toolkit-section__header h2 { margin: 3px 0 0; font-size: 15px; }
.toolkit-section__header p { margin: 5px 0 0; max-width: 66ch; color: var(--text-muted); font-size: 11px; line-height: 1.6; }
.toolkit-section__actions { display: flex; align-items: center; gap: 10px; flex-shrink: 0; }
.toolkit-count { color: var(--text-primary); font-size: 20px; font-weight: 700; line-height: 1; }
.toolkit-count small { margin-left: 5px; color: var(--text-muted); font-size: 9px; font-weight: 400; }

/* 领取成功后让数字跳一下——纯数字没有「已完成」的语义，动一下才有回执。 */
.toolkit-count[data-pulse="true"] { animation: toolkit-count-pop 900ms ease; }
@keyframes toolkit-count-pop {
  0% { transform: scale(1); }
  35% { transform: scale(1.22); color: var(--accent); }
  100% { transform: scale(1); }
}

/* 「全部领取」进行中的扫光。挂在按钮外面的包裹层上，不去改 naive-ui 的内部结构。 */
.toolkit-cta { position: relative; display: inline-flex; }
.toolkit-cta__sweep { position: absolute; inset: 0; overflow: hidden; pointer-events: none; }
.toolkit-cta__sweep::after {
  position: absolute;
  top: 0;
  bottom: 0;
  width: 40%;
  background: linear-gradient(90deg, transparent, rgb(255 255 255 / 45%), transparent);
  content: "";
  animation: toolkit-sweep 1100ms linear infinite;
}
@keyframes toolkit-sweep {
  from { transform: translateX(-120%); }
  to { transform: translateX(320%); }
}

.toolkit-sources { display: flex; flex-wrap: wrap; gap: 8px; padding: 10px 16px; border-bottom: 1px solid var(--line); background: var(--surface-muted); }
.toolkit-source {
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
.toolkit-source[data-empty="true"] { opacity: .5; }
.toolkit-source__glyph { display: grid; place-items: center; width: 20px; height: 20px; border-radius: 4px; color: var(--tone, var(--accent)); background: var(--tone-soft, var(--accent-soft)); font-style: normal; }
.toolkit-source__label { color: var(--text-primary); }
.toolkit-source__count { min-width: 18px; padding: 1px 5px; border-radius: 8px; color: var(--tone, var(--accent)); background: var(--tone-soft, var(--accent-soft)); text-align: center; font-size: 10px; font-weight: 700; }
.toolkit-source button { padding: 3px 8px; border: 1px solid var(--line); color: var(--text-primary); background: var(--surface-raised); cursor: pointer; font-size: 10px; }
.toolkit-source button:not(:disabled):hover { border-color: var(--tone, var(--accent)); color: var(--tone, var(--accent)); background: var(--tone-soft, var(--accent-soft)); }
.toolkit-source button:disabled { cursor: not-allowed; opacity: .45; }
.toolkit-empty { display: grid; place-items: center; gap: 7px; min-height: 150px; color: var(--text-muted); font-size: 11px; }
.toolkit-list { margin: 0; padding: 0; list-style: none; }
.toolkit-item {
  display: grid;
  grid-template-columns: 22px 46px minmax(0, 1fr) 48px auto;
  align-items: center;
  gap: 11px;
  min-height: 62px;
  padding: 9px 16px;
  border-bottom: 1px solid var(--line);
  border-left: 2px solid transparent;
  animation: toolkit-row-in 240ms ease both;
  animation-delay: calc(var(--row, 0) * 22ms);
}
@keyframes toolkit-row-in {
  from { opacity: 0; transform: translateY(4px); }
  to { opacity: 1; transform: none; }
}
.toolkit-item:last-child { border-bottom: 0; }
.toolkit-item:hover { border-left-color: var(--tone, var(--accent)); background: var(--surface-raised); }
.toolkit-item__icon { border-color: var(--tone-soft, var(--accent-soft)); color: var(--tone, var(--accent)); background: var(--tone-soft, var(--accent-soft)); }
.toolkit-item__body { min-width: 0; }
.toolkit-item__body strong { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 11px; }
.toolkit-item__body small { display: flex; align-items: center; gap: 6px; min-width: 0; margin-top: 3px; overflow: hidden; color: var(--text-muted); font-size: 9px; white-space: nowrap; }
.toolkit-item__chip { display: inline-flex; flex: 0 0 auto; align-items: center; gap: 3px; padding: 1px 6px; border-radius: 8px; color: var(--tone, var(--accent)); background: var(--tone-soft, var(--accent-soft)); font-style: normal; }
.toolkit-item__count { padding: 2px 7px; border-radius: 9px; color: var(--text-secondary); background: var(--surface-muted); text-align: center; font-size: 10px; font-weight: 600; }
.toolkit-selection { display: flex; align-items: center; gap: 10px; padding: 9px 16px; border-top: 1px solid var(--line); color: var(--text-secondary); background: var(--surface-muted); font-size: 10px; }
.toolkit-results { margin: 0; padding: 9px 16px; border-top: 1px solid var(--line); list-style: none; }
.toolkit-results li {
  display: flex;
  align-items: center;
  gap: 7px;
  color: var(--green);
  font-size: 10px;
  line-height: 1.8;
  animation: toolkit-row-in 220ms ease both;
  animation-delay: calc(var(--row, 0) * 30ms);
}
.toolkit-results li[data-failed="true"] { color: var(--red); }
.toolkit-actions { display: flex; flex-wrap: wrap; gap: 8px; padding: 12px 16px 0; }
.toolkit-hints { display: grid; gap: 4px; margin: 0; padding: 12px 16px; list-style: none; }
.toolkit-hints li { display: flex; gap: 8px; color: var(--text-muted); font-size: 10px; }
.toolkit-hints strong { flex-shrink: 0; min-width: 116px; color: var(--text-secondary); font-weight: 500; }
.toolkit-result { display: flex; align-items: center; flex-wrap: wrap; gap: 8px; margin: 0; padding: 10px 16px; border-top: 1px solid var(--line); color: var(--red); background: var(--surface-muted); font-size: 10px; }
.toolkit-result[data-ok="true"] { color: var(--green); }
.toolkit-result strong { color: var(--text-primary); font-size: 11px; }
.toolkit-result em { padding: 2px 6px; color: var(--text-secondary); background: var(--surface); font-style: normal; }

@media (max-width: 820px) {
  .toolkit-section__header { flex-direction: column; }
  .toolkit-item { grid-template-columns: 22px 46px minmax(0, 1fr) auto; }
  .toolkit-item__count { display: none; }
}

/* 动画一律让位给系统设置。 */
@media (prefers-reduced-motion: reduce) {
  .toolkit-item,
  .toolkit-results li,
  .toolkit-count[data-pulse="true"],
  .toolkit-cta__sweep::after { animation: none; }
}
</style>
