<script setup lang="ts">
import { darkTheme, dateZhCN, NConfigProvider, NMessageProvider, zhCN } from "naive-ui";
import { BarChart3, BookOpen, Bot, ChevronRight, CircleHelp, Clock3, History, Home, Moon, PanelLeftClose, PanelLeftOpen, Settings, Swords, Sun, UserRound, Wifi, WifiOff, X } from "@lucide/vue";
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { useQueryClient } from "@tanstack/vue-query";
import { RouterLink, RouterView, useRoute, useRouter } from "vue-router";
import AssetIcon from "./components/AssetIcon.vue";
import logoUrl from "./assets/lol-mark.png";
import { backend, isTauri } from "./services/backend";
import { listenNative } from "./services/native";
import { useAppStore } from "./stores/app";
import type { AccountPresence } from "./types/domain";
import { MATCH_HISTORY_QUERY_ROOT } from "./matches/query";

const PROJECT_URL = "https://github.com/NOBB2333/LOL-desktop-native";
const app = useAppStore();
const route = useRoute();
const router = useRouter();
const queryClient = useQueryClient();
const lastAutoPhase = ref<string | null>(null);
const dark = computed(() => app.config.appearance.colorMode === "dark");
const immersive = computed(() => route.path === "/game" || route.path === "/live");
const navigation = [
  { to: "/", label: "首页", icon: Home },
  { to: "/matches", label: "战绩", icon: BarChart3 },
  { to: "/champions", label: "英雄", icon: BookOpen },
  { to: "/automation", label: "自动化", icon: Bot },
  { to: "/history", label: "历史", icon: History },
  { to: "/friends", label: "好友", icon: UserRound },
  { to: "/game", label: "对局", icon: Swords, badge: "实时" },
];
// Keep every phase that can still expose the current ten-player snapshot on
// the game workspace, including reconnect, spectator, and settlement aliases.
const validGamePhases = [
  "ChampSelect",
  "GameStart",
  "InProgress",
  "Reconnect",
  "WatchInProgress",
  "Spectating",
  "Watching",
  "PreEndOfGame",
  "WaitingForStats",
  "EndOfGame",
];
const account = computed(() => app.connection);
const accountName = computed(() => account.value.gameName || account.value.summonerName || "未连接账号");
const accountTag = computed(() => account.value.tagLine ? `#${account.value.tagLine}` : "");
const presenceLabels: Record<AccountPresence, string> = {
  offline: "离线", online: "在线", away: "离开", inQueue: "正在排队", customLobby: "自定义房间", readyCheck: "准备确认", champSelect: "英雄选择", inGame: "游戏中", spectating: "观战中", endOfGame: "结算中", unknown: "状态未知",
};
const presenceLabel = computed(() => app.mode === "fixture" ? "演示预览" : presenceLabels[account.value.presence] ?? "状态未知");
const presenceClass = computed(() => account.value.presence === "offline" ? "offline" : account.value.presence === "unknown" ? "unknown" : account.value.presence);
let stopOpenGameListener: (() => void) | null = null;
let stopLcuEventListener: (() => void) | null = null;
let lcuEventPollTimer: ReturnType<typeof setInterval> | null = null;
let connectionPollTimer: ReturnType<typeof setInterval> | null = null;
let shortcutPollTimer: ReturnType<typeof setInterval> | null = null;
let lcuEventPollRunning = false;
let shortcutPollRunning = false;
let connectionPollRunning = false;
let lastConnectionRefreshAt = 0;
let automationRunning = false;
let lastLcuEventPollAt = 0;
let lastAutomationProbeAt = 0;
const matchHistoryRefreshTimers: ReturnType<typeof setTimeout>[] = [];
const normalEventPollIntervalMs = 1000;
const automationEventPollIntervalMs = 750;
const automationProbeIntervalMs = 500;
const eventDrivenConnectionMinIntervalMs = 1000;

function isActive(to: string) {
  return to === "/" ? route.path === "/" : route.path === to || (to === "/game" && route.path === "/live");
}

function toggleTheme() {
  app.config.appearance.colorMode = dark.value ? "light" : "dark";
}

function invalidateMatchHistory() {
  void queryClient.invalidateQueries({ queryKey: [MATCH_HISTORY_QUERY_ROOT], refetchType: "active" });
}

let savedHistoryFilters = "";
watch(() => app.lastSavedAt, () => {
  const filters = JSON.stringify([app.config.providers.hideUnfinishedMatches, app.config.providers.rankedOnly]);
  if (filters === savedHistoryFilters) return;
  savedHistoryFilters = filters;
  // 自动保存完成后再刷新，避免读取到后端尚未更新的过滤口径。
  void queryClient.resetQueries({ queryKey: [MATCH_HISTORY_QUERY_ROOT] });
  void queryClient.resetQueries({ queryKey: ["lobby"] });
});

function scheduleMatchHistoryRefresh() {
  invalidateMatchHistory();
  matchHistoryRefreshTimers.push(setTimeout(invalidateMatchHistory, 3000));
  matchHistoryRefreshTimers.push(setTimeout(invalidateMatchHistory, 10_000));
}

watch(() => app.connection.phase, (phase, previous) => {
  const settlement = phase === "WaitingForStats" || phase === "PreEndOfGame" || phase === "EndOfGame";
  const previousSettlement = previous === "WaitingForStats" || previous === "PreEndOfGame" || previous === "EndOfGame";
  const leftVisibleGame = Boolean(previous && validGamePhases.includes(previous) && (!phase || !validGamePhases.includes(phase)));
  if ((settlement && !previousSettlement) || leftVisibleGame) scheduleMatchHistoryRefresh();
  if (app.mode !== "live" || !phase || !validGamePhases.includes(phase)) {
    lastAutoPhase.value = null;
    return;
  }
  if (lastAutoPhase.value === phase) return;
  lastAutoPhase.value = phase;
  if (route.path !== "/game" && route.path !== "/live") void router.push("/game");
});

function openGameView() {
  if (route.path !== "/game") void router.push("/game");
}

function publishLcuEvent(event: { uri: string; phase?: string }) {
  window.dispatchEvent(new CustomEvent("lol-lcu-event", { detail: event }));
}

function automationEnabled() {
  const config = app.config.automation;
  // Match the Rust host loop: connection status is a UI snapshot and can lag
  // the LCU process during the short ReadyCheck transition.
  return app.mode === "live" && config.enabled && !config.advisoryMode && (config.autoAccept || config.autoPick || config.autoBan);
}

async function runAutomationIfNeeded(events: { uri: string; phase?: string }[]) {
  // The native host owns a watchdog so automation continues while WebView2 is
  // throttled. Calling the bridge again from every event races that watchdog
  // and can hold the worker behind a slow LCU request, making the UI appear
  // unable to click during a delayed ReadyCheck.
  if (isTauri()) return;
  const relevant = events.some((event) => event.uri.includes("ready-check") || event.uri.includes("champ-select") || event.uri.endsWith("gameflow-phase"));
  if (!automationEnabled() || automationRunning || !relevant) return;
  automationRunning = true;
  try {
    app.reportAutomationActions(await backend.runAutomation());
  } catch (cause) {
    app.reportAutomationError(cause instanceof Error ? cause.message : String(cause));
  } finally {
    automationRunning = false;
  }
}

async function pollLcuEvents() {
  if (!app.initialized || app.mode !== "live" || lcuEventPollRunning) return;
  const now = Date.now();
  const interval = automationEnabled() ? automationEventPollIntervalMs : normalEventPollIntervalMs;
  if (now - lastLcuEventPollAt < interval) return;
  lastLcuEventPollAt = now;
  lcuEventPollRunning = true;
  try {
    const events = await backend.lcuEvents();
    if (events.length) {
      events.forEach(publishLcuEvent);
      // Chat/friend events do not change the account/gameflow snapshot. Avoid
      // putting a full connection probe behind every such event.
      if (events.some((event) => event.uri.includes("ready-check") || event.uri.includes("champ-select") || event.uri.includes("gameflow") || event.uri.includes("lobby"))) {
        void refreshLiveConnection();
      }
    }
    // ReadyCheck events can be missed while the LCU event stream reconnects.
    // Keep a lightweight phase probe running so auto-accept remains reliable.
    const nowForAutomation = Date.now();
    if (automationEnabled() && (events.length > 0 || nowForAutomation - lastAutomationProbeAt >= automationProbeIntervalMs)) {
      lastAutomationProbeAt = nowForAutomation;
      void runAutomationIfNeeded(events.length ? events : [{ uri: "/lol-gameflow/v1/gameflow-phase" }]);
    }
  } catch {
    // Connection polling owns the visible disconnected state while League is
    // closed; event polling resumes quietly on the next tick.
  } finally {
    lcuEventPollRunning = false;
  }
}

async function pollShortcutEvents() {
  if (!app.initialized || !isTauri() || shortcutPollRunning) return;
  shortcutPollRunning = true;
  try {
    const events = await backend.shortcutEvents();
    // 全部交给 store 分发：`open-game` 在那里会先调 `lol.open_game_view`
    // 把窗口显示/前置，再派发 `open-game-view`。以前这里对 open-game 只做
    // `router.push("/game")`，窗口留在游戏后面，按了等于没反应。
    for (const shortcutId of new Set(events)) {
      void app.dispatchShortcut(shortcutId);
    }
  } catch {
    // Shortcut polling is best-effort; configuration errors remain visible
    // through the normal settings diagnostics.
  } finally {
    shortcutPollRunning = false;
  }
}

async function refreshLiveConnection() {
  if (!app.initialized || app.mode !== "live" || connectionPollRunning) return;
  const now = Date.now();
  if (now - lastConnectionRefreshAt < eventDrivenConnectionMinIntervalMs) return;
  lastConnectionRefreshAt = now;
  connectionPollRunning = true;
  try {
    app.updateConnection(await backend.refreshConnection());
  } catch {
    // A later LCU event or the regular timer retries the connection probe.
  } finally {
    connectionPollRunning = false;
  }
}

function startNativeRuntimePolling() {
  if (!isTauri() || lcuEventPollTimer) return;
  void pollLcuEvents();
  void pollShortcutEvents();
  lcuEventPollTimer = setInterval(() => void pollLcuEvents(), automationEventPollIntervalMs);
  shortcutPollTimer = setInterval(() => void pollShortcutEvents(), automationEventPollIntervalMs);
  connectionPollTimer = setInterval(() => void refreshLiveConnection(), 5000);
}

onMounted(() => {
  void app.initialize().then(startNativeRuntimePolling);
  window.addEventListener("open-game-view", openGameView);
  if (isTauri()) {
    stopOpenGameListener = listenNative("open-game-view", openGameView);
    stopLcuEventListener = listenNative<{ uri: string }>("lcu-event", (event) => {
        if (!event.uri || !event.uri.startsWith("/lol-")) return;
        publishLcuEvent(event);
        void refreshLiveConnection();
        void runAutomationIfNeeded([event]);
    });
  }
});

onBeforeUnmount(() => {
  window.removeEventListener("open-game-view", openGameView);
  if (lcuEventPollTimer) clearInterval(lcuEventPollTimer);
  if (connectionPollTimer) clearInterval(connectionPollTimer);
  if (shortcutPollTimer) clearInterval(shortcutPollTimer);
  matchHistoryRefreshTimers.forEach(clearTimeout);
  stopOpenGameListener?.();
  stopLcuEventListener?.();
});
</script>

<template>
  <NConfigProvider :locale="zhCN" :date-locale="dateZhCN" :theme="dark ? darkTheme : null" :theme-overrides="{ common: { primaryColor: '#0f8a75', primaryColorHover: '#08745f', borderRadius: '5px' } }">
    <NMessageProvider>
      <div class="app-frame" :class="{ 'app-frame--collapsed': app.sidebarCollapsed, 'app-frame--immersive': immersive }">
        <aside class="sidebar" :class="{ 'sidebar--collapsed': app.sidebarCollapsed }">
          <div class="brand-lockup">
            <div class="brand-mark"><img :src="logoUrl" alt="" /></div>
            <div class="brand-copy"><strong>桌上英雄联盟</strong><span>LCU / BP 工作台</span></div>
          </div>
          <button class="sidebar-toggle sidebar-toggle--top" type="button" :aria-label="app.sidebarCollapsed ? '展开侧栏' : '收起侧栏'" @click="app.toggleSidebar()">
            <PanelLeftOpen v-if="app.sidebarCollapsed" :size="17" /><PanelLeftClose v-else :size="17" /><span>{{ app.sidebarCollapsed ? "展开导航" : "收起导航" }}</span>
          </button>
          <nav class="primary-nav" aria-label="主导航">
            <RouterLink v-for="item in navigation" :key="item.to" :to="item.to" class="nav-item" :class="{ active: isActive(item.to) }" :aria-label="item.label">
              <component :is="item.icon" :size="17" /><span>{{ item.label }}</span><em v-if="item.badge">{{ item.badge }}</em><ChevronRight v-if="isActive(item.to)" :size="14" class="nav-arrow" />
            </RouterLink>
          </nav>
          <div class="sidebar-foot">
            <RouterLink to="/settings" class="nav-item" :class="{ active: route.path === '/settings' }" aria-label="设置"><Settings :size="17" /><span>设置</span></RouterLink>
            <a :href="PROJECT_URL" target="_blank" rel="noreferrer" class="nav-item muted" aria-label="项目地址"><CircleHelp :size="17" /><span>项目地址</span></a>
          </div>
        </aside>
        <main class="main-area">
          <header class="topbar" :class="{ 'topbar--immersive': immersive }">
            <div class="breadcrumb"><span>桌上英雄联盟</span><ChevronRight :size="14" /><strong>{{ String(route.meta.title) }}</strong></div>
            <div class="topbar-actions">
              <button class="topbar-icon-button" type="button" :aria-label="dark ? '切换浅色模式' : '切换深色模式'" :title="dark ? '浅色模式' : '深色模式'" @click="toggleTheme"><Moon v-if="dark" :size="16" /><Sun v-else :size="16" /></button>
              <RouterLink to="/settings" class="topbar-account" title="打开设置">
                <AssetIcon kind="profile" :id="account.profileIconId ?? 0" :name="accountName" fallback-url="./fixtures/champions/Ahri.png" size="sm" />
                <span class="topbar-account__copy"><strong>{{ accountName }}<small>{{ accountTag }}</small></strong><em :data-presence="presenceClass"><i />{{ presenceLabel }}</em></span>
              </RouterLink>
              <span class="connection-pill" :data-status="app.connection.status"><i />{{ app.connection.status === "connected" ? "LCU" : app.mode === "fixture" ? "本地" : "未连接" }}<Wifi v-if="app.connection.status === 'connected'" :size="14" /><WifiOff v-else :size="14" /></span>
              <Clock3 v-if="account.queueLabel" :size="15" class="topbar-queue" :title="account.queueLabel" />
            </div>
          </header>
          <div v-if="app.error" class="runtime-error-banner" role="alert"><span>{{ app.error }}</span><button type="button" title="关闭错误提示" aria-label="关闭错误提示" @click="app.dismissError"><X :size="14" /></button></div>
          <div class="content-scroll"><RouterView /></div>
        </main>
      </div>
    </NMessageProvider>
  </NConfigProvider>
</template>
