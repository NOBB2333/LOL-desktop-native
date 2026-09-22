<script setup lang="ts">
/**
 * 客户端急救。
 *
 * 从「工具箱」页搬进对局页右栏：界面卡死、进不去游戏、结算页出不来的场景，
 * 人一定正盯着对局页，不该再让人跑去另一页找按钮。所以这里刻意做成
 * 右栏那种紧凑块（`.game-quick-filter` 同一套排版），**不是**工具箱里那种大区块。
 *
 * 动作表与后端 `src/backend/gameflow_ipc.zig` 的 `action_table` **逐项对应**：
 * 少一个后端会回 `InvalidRequest`，多一个点下去不会有任何反应。
 * 阶段限制故意不在这里复刻——判定的真身在客户端，界面只给一句提示。
 *
 * 有副作用的两个（秒退、退房间）保留二次确认；其余是纯补救动作，点错也没有代价，
 * 多一步确认反而耽误时间。
 */
import { CircleAlert, ShieldAlert, Wrench } from "@lucide/vue";
import { NPopconfirm, useMessage } from "naive-ui";
import { computed, ref } from "vue";
import { backend } from "../services/backend";
import { useAppStore } from "../stores/app";
import type { GameflowActionKey, GameflowActionResult } from "../types/domain";

const app = useAppStore();
const message = useMessage();

const actions: { key: GameflowActionKey; label: string; hint: string; confirm?: string }[] = [
  { key: "dodge", label: "秒退选人", hint: "还在选人阶段时直接退掉这一局", confirm: "秒退会被记为一次逃跑，确定退出这一局吗？" },
  { key: "leave-lobby", label: "退出房间", hint: "解散当前房间回到大厅", confirm: "会解散当前房间，确定退出吗？" },
  { key: "play-again", label: "退出结算", hint: "结算页卡住出不来时用它" },
  { key: "reconnect", label: "重新连接", hint: "卡在「正在重新连接」时用它" },
  { key: "ack-failed-launch", label: "清除启动失败", hint: "进不去游戏、界面已经点不动时用它" },
];

const busy = ref<GameflowActionKey | null>(null);
const result = ref<GameflowActionResult | null>(null);
/** 非实时模式下这些动作打不到真客户端，先明说，别让人以为点了没反应是坏了。 */
const live = computed(() => app.mode === "live");

function labelOf(key: string) {
  return actions.find((action) => action.key === key)?.label ?? key;
}

async function run(key: GameflowActionKey) {
  if (busy.value) return;
  busy.value = key;
  try {
    result.value = await backend.gameflowAction(key);
    if (result.value.ok) message.success(`${labelOf(key)}已执行`);
    else message.warning(result.value.reason || "客户端没有接受这个操作");
  } catch (cause) {
    message.error(cause instanceof Error ? cause.message : String(cause));
  } finally {
    busy.value = null;
  }
}
</script>

<template>
  <div class="game-first-aid">
    <div class="game-first-aid__head">
      <span>客户端急救</span>
      <ShieldAlert :size="13" />
    </div>

    <p v-if="!live" class="game-first-aid__notice">
      <CircleAlert :size="11" />
      <span>非实时模式：这些动作不会作用到真实客户端</span>
    </p>

    <ul>
      <li v-for="action in actions" :key="action.key">
        <NPopconfirm v-if="action.confirm" positive-text="执行" negative-text="取消" @positive-click="run(action.key)">
          <template #trigger>
            <button type="button" :title="action.hint" :data-busy="busy === action.key" :disabled="Boolean(busy)">
              <Wrench :size="11" />
              <span class="game-first-aid__text">
                <strong>{{ action.label }}</strong>
                <small>{{ action.hint }}</small>
              </span>
            </button>
          </template>
          {{ action.confirm }}
        </NPopconfirm>

        <button
          v-else
          type="button"
          :title="action.hint"
          :data-busy="busy === action.key"
          :disabled="Boolean(busy)"
          @click="run(action.key)"
        >
          <Wrench :size="11" />
          <span class="game-first-aid__text">
            <strong>{{ action.label }}</strong>
            <small>{{ action.hint }}</small>
          </span>
        </button>
      </li>
    </ul>

    <p v-if="result" class="game-first-aid__result" :data-ok="result.ok">
      <strong>{{ labelOf(result.action) }}</strong>
      <span>{{ result.ok ? "已执行" : result.reason }}</span>
    </p>
  </div>
</template>

<style scoped>
/* 排版刻意与 `.game-quick-filter` / `.game-automation-quick` 完全对齐，
   这样它放进右栏时不会显得是外来的。 */
.game-first-aid {
  display: grid;
  gap: 6px;
  margin-top: 10px;
  padding-top: 8px;
  border-top: 1px solid var(--line);
}
.game-first-aid__head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 6px;
  color: var(--text-muted);
}
.game-first-aid__head > span {
  font-size: 9px;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}
.game-first-aid__notice {
  display: flex;
  align-items: center;
  gap: 5px;
  margin: 0;
  color: var(--amber);
  font-size: 9px;
}
.game-first-aid__notice span {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.game-first-aid ul {
  display: grid;
  gap: 4px;
  margin: 0;
  padding: 0;
  list-style: none;
}
.game-first-aid button {
  display: grid;
  grid-template-columns: 13px minmax(0, 1fr);
  align-items: center;
  gap: 6px;
  width: 100%;
  padding: 5px 7px;
  border: 1px solid var(--line);
  border-radius: 5px;
  color: var(--text-primary);
  background: var(--surface);
  text-align: left;
  cursor: pointer;
}
.game-first-aid button > svg {
  color: var(--text-muted);
}
.game-first-aid button:not(:disabled):hover {
  border-color: var(--accent);
  background: var(--surface-raised);
}
.game-first-aid button:not(:disabled):hover > svg {
  color: var(--accent);
}
.game-first-aid button:disabled {
  cursor: not-allowed;
  opacity: 0.5;
}
.game-first-aid__text {
  min-width: 0;
}
.game-first-aid__text strong {
  display: block;
  font-size: 10px;
  font-weight: 600;
}
.game-first-aid__text small {
  display: block;
  overflow: hidden;
  color: var(--text-muted);
  font-size: 9px;
  text-overflow: ellipsis;
  white-space: nowrap;
}
/* 执行中：图标转一下当进度，不额外占位置。 */
.game-first-aid button[data-busy="true"] > svg {
  color: var(--accent);
  animation: game-first-aid-spin 900ms linear infinite;
}
@keyframes game-first-aid-spin {
  to {
    transform: rotate(360deg);
  }
}
.game-first-aid__result {
  display: flex;
  align-items: baseline;
  gap: 6px;
  margin: 0;
  color: var(--red);
  font-size: 9px;
}
.game-first-aid__result[data-ok="true"] {
  color: var(--green);
}
.game-first-aid__result strong {
  flex: 0 0 auto;
  color: var(--text-primary);
  font-size: 10px;
}
.game-first-aid__result span {
  min-width: 0;
}

@media (prefers-reduced-motion: reduce) {
  .game-first-aid button[data-busy="true"] > svg {
    animation: none;
  }
}
</style>
