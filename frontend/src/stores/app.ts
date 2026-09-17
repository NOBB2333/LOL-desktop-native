import { defineStore } from "pinia";
import { computed, ref, toRaw, watch } from "vue";
import { backend, isTauri } from "../services/backend";
import { invokeNative, listenNative } from "../services/native";
import { fixtureBootstrap, fixtureConfig } from "../fixtures/data";
import type { AppBootstrap, AppConfig, ConnectionState, DataMode } from "../types/domain";
import { migrateAppConfig } from "../utils/config";

type AutomationAction = { actionType: string; actionId: number; championId: number; executed: boolean; reason: string };

export type ConfigSaveState = "idle" | "dirty" | "saving" | "saved" | "error";

export const useAppStore = defineStore("app", () => {
  const bootstrap = ref<AppBootstrap>(structuredClone(fixtureBootstrap));
  const config = ref<AppConfig>(structuredClone(fixtureConfig));
  const initialized = ref(false);
  const busy = ref(false);
  const error = ref<string | null>(null);
  const configSaveState = ref<ConfigSaveState>("idle");
  const configSaveError = ref<string | null>(null);
  const shortcutRegistrationError = ref<string | null>(null);
  const automationStatus = ref<string | null>(null);
  const automationRuntimeError = ref<string | null>(null);
  const lastSavedAt = ref<string | null>(null);
  const sidebarCollapsed = ref(typeof localStorage === "undefined" ? true : localStorage.getItem("lol-desktop-sidebar") !== "expanded");
  let persistChain = Promise.resolve();
  let persistReady = false;
  let persistTimer: ReturnType<typeof setTimeout> | null = null;
  let lastSavedSnapshot = JSON.stringify(config.value);
  let browserShortcutCleanup: (() => void) | null = null;
  let nativeShortcutCleanup: (() => void) | null = null;

  const mode = computed(() => bootstrap.value.dataMode);
  const connection = computed(() => bootstrap.value.dashboard.connection);

  function applyAppearance() {
    document.documentElement.dataset.theme = config.value.appearance.theme;
    document.documentElement.dataset.colorMode = config.value.appearance.colorMode;
    document.documentElement.dataset.compact = String(config.value.appearance.compact);
  }

  watch(config, () => {
    applyAppearance();
    if (!persistReady) return;
    schedulePersist();
  }, { deep: true });

  async function registerAssessmentShortcuts() {
    shortcutRegistrationError.value = null;
    browserShortcutCleanup?.();
    browserShortcutCleanup = null;
    const handler = (event: KeyboardEvent) => {
      const shortcut = config.value.automation.shortcuts.find((item) => item.enabled && item.key.trim() && matchesShortcut(event, item.key));
      if (!shortcut) return;
      event.preventDefault();
      void dispatchShortcut(shortcut.id);
    };
    if (!isTauri()) {
      window.addEventListener("keydown", handler);
      browserShortcutCleanup = () => window.removeEventListener("keydown", handler);
      nativeShortcutCleanup?.();
      nativeShortcutCleanup = null;
      return;
    }
    try {
      nativeShortcutCleanup?.();
      const dispatchNativeShortcut = (detail: string | { id?: string }) => {
        const shortcutId = typeof detail === "string" ? detail : detail.id;
        if (shortcutId) void dispatchShortcut(shortcutId);
      };
      const cleanup = listenNative<string | { id?: string }>("shortcut", dispatchNativeShortcut);
      const legacyCleanup = listenNative<string>("native-shortcut", dispatchNativeShortcut);
      nativeShortcutCleanup = () => { cleanup(); legacyCleanup(); };
    } catch (cause) {
      shortcutRegistrationError.value = `快捷键监听失败：${cause instanceof Error ? cause.message : String(cause)}`;
      error.value = shortcutRegistrationError.value;
    }
  }

  async function dispatchShortcut(shortcutId: string) {
    if (shortcutId === "open-game") {
      await openGameView();
      return;
    }
    try {
      await backend.sendShortcut(shortcutId);
    } catch (cause) {
      error.value = cause instanceof Error ? cause.message : String(cause);
    }
  }

  async function openGameView() {
    if (isTauri()) {
      try {
        await invokeNative("lol.open_game_view");
      } catch {
        // 前置窗口失败也要把路由切过去，否则用户按了快捷键看不到任何反馈。
      }
    }
    // The Native bridge has no implicit router access; mirror the event
    // emitted by the former Tauri command after the host accepts the action.
    window.dispatchEvent(new CustomEvent("open-game-view"));
  }

  async function initialize() {
    if (initialized.value) return;
    busy.value = true;
    try {
      const [nextBootstrap, nextConfig] = await Promise.all([backend.bootstrap(), backend.config()]);
      const configMigrated = migrateAppConfig(nextConfig);
      bootstrap.value = nextBootstrap;
      config.value = nextConfig;
      if (configMigrated) await backend.saveConfig(nextConfig);
      lastSavedSnapshot = JSON.stringify(nextConfig);
      applyAppearance();
      if (isTauri()) {
        await Promise.all([
          listenNative<ConnectionState>("connection-state", updateConnection),
          listenNative<AutomationAction[]>("automation-actions", reportAutomationActions),
          listenNative<string>("automation-error", reportAutomationError),
        ]);
        // 后台轮询的首个事件可能早于前端监听器注册，启动后主动刷新一次补上竞态。
        if (nextBootstrap.dataMode === "live") {
          void backend.refreshConnection()
            .then((connection) => updateConnection(connection))
            .catch((cause) => { error.value = cause instanceof Error ? cause.message : String(cause); });
        }
      }
      await registerAssessmentShortcuts();
      persistReady = true;
      initialized.value = true;
    } catch (cause) {
      error.value = cause instanceof Error ? cause.message : String(cause);
      persistReady = true;
      initialized.value = true;
    } finally {
      busy.value = false;
    }
  }

  async function setMode(mode: DataMode) {
    bootstrap.value.dataMode = await backend.setMode(mode);
    if (mode === "live") updateConnection(await backend.refreshConnection());
  }

  function updateConnection(connection: ConnectionState) {
    bootstrap.value.dashboard.connection = connection;
  }

  function reportAutomationActions(actions: AutomationAction[]) {
    automationRuntimeError.value = null;
    if (actions.length) automationStatus.value = actions.map((action) => action.reason).join("；");
  }

  function reportAutomationError(message: string) {
    automationRuntimeError.value = message;
    error.value = `自动化执行失败：${message}`;
  }

  function dismissError() {
    error.value = null;
  }

  function toggleSidebar() {
    sidebarCollapsed.value = !sidebarCollapsed.value;
    if (typeof localStorage !== "undefined") localStorage.setItem("lol-desktop-sidebar", sidebarCollapsed.value ? "collapsed" : "expanded");
  }

  async function persistConfig() {
    const snapshot = structuredClone(toRaw(config.value));
    const serialized = JSON.stringify(snapshot);
    if (serialized === lastSavedSnapshot) {
      configSaveState.value = "saved";
      return snapshot;
    }
    configSaveState.value = "saving";
    configSaveError.value = null;
    persistChain = persistChain.catch(() => undefined).then(async () => {
      await backend.saveConfig(snapshot);
    });
    try {
      await persistChain;
      lastSavedSnapshot = serialized;
      configSaveState.value = "saved";
      lastSavedAt.value = new Date().toISOString();
      applyAppearance();
      await registerAssessmentShortcuts();
      return snapshot;
    } catch (cause) {
      configSaveState.value = "error";
      configSaveError.value = cause instanceof Error ? cause.message : String(cause);
      throw cause;
    }
  }

  function schedulePersist() {
    configSaveState.value = "dirty";
    if (persistTimer) clearTimeout(persistTimer);
    persistTimer = setTimeout(() => {
      persistTimer = null;
      void persistConfig().catch(() => undefined);
    }, 300);
  }

  async function retryConfigSave() {
    if (persistTimer) {
      clearTimeout(persistTimer);
      persistTimer = null;
    }
    return persistConfig();
  }

  return {
    bootstrap, config, initialized, busy, error, mode, connection, sidebarCollapsed,
    configSaveState, configSaveError, shortcutRegistrationError, automationStatus, automationRuntimeError, lastSavedAt,
    initialize, setMode, updateConnection, reportAutomationActions, reportAutomationError,
    dispatchShortcut, openGameView,
    toggleSidebar, dismissError, persistConfig, retryConfigSave, applyAppearance,
  };
});

function matchesShortcut(event: KeyboardEvent, shortcutKey: string) {
  const parts = shortcutKey.split("+").map((part) => part.trim().toLowerCase()).filter(Boolean);
  const key = parts.pop();
  if (!key) return false;
  const commandOrControl = parts.includes("commandorcontrol") || parts.includes("cmdorctrl");
  if (commandOrControl && !(event.metaKey || event.ctrlKey)) return false;
  if (parts.includes("control") && !event.ctrlKey) return false;
  if (parts.includes("command") && !event.metaKey) return false;
  if (parts.includes("shift") && !event.shiftKey) return false;
  if (parts.includes("alt") && !event.altKey) return false;
  if (!parts.includes("shift") && event.shiftKey) return false;
  if (!parts.includes("alt") && event.altKey) return false;
  const expected = key.startsWith("f") && key.length > 1 ? key : key;
  return event.key.toLowerCase() === expected || event.code.toLowerCase() === `key${expected}`;
}
