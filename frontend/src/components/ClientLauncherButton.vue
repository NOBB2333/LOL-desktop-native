<script setup lang="ts">
/**
 * 一键启动客户端。
 *
 * 场景很具体：用户先打开本应用、客户端还没开，这时界面上什么都没有，只能自己去
 * 桌面找 WeGame / 英雄联盟的图标。所以这个按钮**只在没连上客户端时出现**，
 * 连上之后它就该消失——这时候再点一下「启动」没有任何意义。
 *
 * 「自动挑 + 下拉切换」：默认拿后端探测顺序里的第一条（腾讯登录器 → WeGame →
 * Riot 客户端），选过一次就记住（localStorage），下次仍然用它。入口整理与优先级
 * 全在 `src/backend/launcher_ipc.zig` 里，前端只负责展示与选择，**不猜路径**。
 *
 * 放在 topbar（`topbar-actions` 最前面）而不是设置页：客户端没开的时候人第一眼
 * 看到的就是这条顶栏，多一次跳转就少一次真正启动。
 */
import { ChevronDown, Rocket } from "@lucide/vue";
import { useMessage } from "naive-ui";
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { backend } from "../services/backend";
import { useAppStore } from "../stores/app";
import type { ClientLaunchEntry } from "../types/domain";

const LAUNCH_TARGET_KEY = "lol-desktop-launch-target";

const app = useAppStore();
const message = useMessage();

const entries = ref<ClientLaunchEntry[]>([]);
const targetId = ref("");
const busy = ref(false);
const loaded = ref(false);
const menu = ref<HTMLDetailsElement | null>(null);

/** 连上客户端之后这里就没有存在意义了；演示模式同理（那份 fixture 不是真安装）。 */
const visible = computed(() => app.initialized && app.mode === "live" && app.connection.status !== "connected");
const target = computed(() => entries.value.find((entry) => entry.id === targetId.value) ?? null);
const targetLabel = computed(() => target.value?.label ?? "自动选择");

function remember(id: string) {
  try {
    localStorage.setItem(LAUNCH_TARGET_KEY, id);
  } catch {
    // 隐私模式下 localStorage 可能直接抛错，记不住就算了，不该影响启动。
  }
}

function recalledTarget(): string {
  try {
    return localStorage.getItem(LAUNCH_TARGET_KEY) ?? "";
  } catch {
    return "";
  }
}

async function ensureEntries() {
  if (loaded.value) return;
  try {
    const result = await backend.clientInstallations();
    entries.value = Array.isArray(result?.entries) ? result.entries : [];
    loaded.value = true;
    const remembered = recalledTarget();
    // 记住的那条可能因为换了机器/卸载而消失，此时安静地退回第一优先。
    targetId.value = entries.value.some((entry) => entry.id === remembered) ? remembered : (entries.value[0]?.id ?? "");
  } catch (cause) {
    message.error(cause instanceof Error ? cause.message : String(cause));
  }
}

function pick(id: string) {
  targetId.value = id;
  remember(id);
  if (menu.value) menu.value.open = false;
  message.info(`下次启动：${entries.value.find((entry) => entry.id === id)?.label ?? id}`);
}

async function launch() {
  if (busy.value) return;
  busy.value = true;
  try {
    await ensureEntries();
    const result = await backend.launchClient(targetId.value);
    if (result.ok) message.success(`已启动 ${result.label || targetLabel.value}，客户端起来后会自动连上`);
    else message.warning(result.reason || "没能启动客户端");
  } catch (cause) {
    message.error(cause instanceof Error ? cause.message : String(cause));
  } finally {
    busy.value = false;
  }
}

// 探测放在「按钮真的会出现」之后再做，避免每次开应用都白跑一趟注册表/扫盘。
watch(visible, (value) => {
  if (value) void ensureEntries();
}, { immediate: true });

// 点击别处收起下拉：`<details>` 不会自己关。
function onDocumentPointerDown(event: PointerEvent) {
  if (!menu.value?.open) return;
  if (event.target instanceof Node && menu.value.contains(event.target)) return;
  menu.value.open = false;
}
onMounted(() => document.addEventListener("pointerdown", onDocumentPointerDown));
onBeforeUnmount(() => document.removeEventListener("pointerdown", onDocumentPointerDown));
</script>

<template>
  <div v-if="visible" class="client-launcher">
    <button
      type="button"
      class="client-launcher__go"
      :data-busy="busy"
      :disabled="busy"
      :title="target ? `启动 ${target.label}（${target.path}）` : '启动本机的英雄联盟客户端'"
      @click="launch"
    >
      <Rocket :size="13" />
      <span>{{ busy ? "启动中…" : "启动客户端" }}</span>
    </button>

    <details ref="menu" class="client-launcher__menu">
      <summary :title="`选择启动入口（当前：${targetLabel}）`" aria-label="选择启动入口">
        <ChevronDown :size="12" />
      </summary>
      <div class="client-launcher__popover">
        <p>从哪个入口启动</p>
        <ul v-if="entries.length">
          <li v-for="entry in entries" :key="entry.id">
            <button type="button" :data-active="entry.id === targetId" :title="entry.path" @click="pick(entry.id)">
              <strong>{{ entry.label }}</strong>
              <small>{{ entry.detail }}</small>
            </button>
          </li>
        </ul>
        <p v-else class="client-launcher__empty">没在本机找到客户端安装位置</p>
      </div>
    </details>
  </div>
</template>

<style scoped>
.client-launcher {
  display: inline-flex;
  align-items: stretch;
  gap: 0;
  position: relative;
}
/* 主按钮刻意用强调色描边：这是「客户端没开」时顶栏上唯一该被看见的东西。 */
.client-launcher__go {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  min-height: 29px;
  padding: 0 9px;
  border: 1px solid var(--accent);
  border-right: 0;
  border-radius: 5px 0 0 5px;
  color: var(--accent);
  background: var(--accent-soft, var(--surface));
  cursor: pointer;
  font-size: 10px;
  font-weight: 600;
  white-space: nowrap;
}
.client-launcher__go:not(:disabled):hover {
  background: var(--surface-raised);
}
.client-launcher__go:disabled {
  cursor: progress;
  opacity: 0.7;
}
.client-launcher__go[data-busy="true"] > svg {
  animation: client-launcher-lift 900ms ease-in-out infinite;
}
@keyframes client-launcher-lift {
  50% {
    transform: translateY(-2px);
  }
}
.client-launcher__menu {
  position: relative;
  display: inline-flex;
}
.client-launcher__menu > summary {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 20px;
  min-height: 29px;
  border: 1px solid var(--accent);
  border-radius: 0 5px 5px 0;
  color: var(--accent);
  background: var(--accent-soft, var(--surface));
  cursor: pointer;
  list-style: none;
}
.client-launcher__menu > summary::-webkit-details-marker {
  display: none;
}
.client-launcher__menu[open] > summary,
.client-launcher__menu > summary:hover {
  background: var(--surface-raised);
}
.client-launcher__popover {
  position: absolute;
  z-index: 30;
  top: calc(100% + 8px);
  right: 0;
  width: 244px;
  padding: 10px;
  border: 1px solid var(--line-strong);
  border-radius: 6px;
  background: var(--surface);
  box-shadow: 0 14px 32px #1a342b24;
}
.client-launcher__popover p {
  margin: 0 0 8px;
  color: var(--muted);
  font-size: 10px;
  font-weight: 700;
}
.client-launcher__popover ul {
  display: grid;
  gap: 4px;
  margin: 0;
  padding: 0;
  list-style: none;
}
.client-launcher__popover button {
  display: grid;
  gap: 1px;
  width: 100%;
  padding: 6px 8px;
  border: 1px solid var(--line);
  border-radius: 5px;
  color: var(--text-primary);
  background: var(--surface);
  text-align: left;
  cursor: pointer;
}
.client-launcher__popover button:hover {
  border-color: var(--accent);
  background: var(--surface-raised);
}
.client-launcher__popover button[data-active="true"] {
  border-color: var(--accent);
  background: var(--surface-raised);
}
.client-launcher__popover strong {
  font-size: 10px;
  font-weight: 700;
}
.client-launcher__popover small {
  overflow: hidden;
  color: var(--text-muted);
  font-size: 9px;
  text-overflow: ellipsis;
  white-space: nowrap;
}
/* 路径可能很长，用省略号而不是把 popover 撑宽。 */
.client-launcher__popover button[title] small {
  max-width: 220px;
}
.client-launcher__empty {
  margin: 0;
  color: var(--amber);
  font-size: 9px;
  font-weight: 600;
}
@media (max-width: 720px) {
  /* 窄屏顶栏要腾位置给账号与连接状态，这里只留图标。 */
  .client-launcher__go > span {
    display: none;
  }
  .client-launcher__go {
    padding: 0 7px;
  }
}
@media (prefers-reduced-motion: reduce) {
  .client-launcher__go[data-busy="true"] > svg {
    animation: none;
  }
}
</style>
