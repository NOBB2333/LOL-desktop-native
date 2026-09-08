import type { AppConfig, ShortcutDefinition } from "../types/domain";

export const CURRENT_CONFIG_VERSION = 18;
export const defaultOpenGameShortcutKey = "Ctrl+F1";

export const defaultAssessmentTemplate =
  "{team}{position} {current_champion}：{rank} {recent_wins}胜{recent_losses}负，{recent_games}";

export const junglePreferenceShortcut: ShortcutDefinition = {
  id: "jungle-preference",
  label: "发送打野偏好",
  key: "Ctrl+F10",
  target: "jungle",
  template: "{name}：{jungle_preference}",
  enabled: true,
};

export const encounterShortcut: ShortcutDefinition = {
  id: "encounter",
  label: "发送遇到记录",
  key: "Ctrl+F8",
  target: "encounter",
  template: "{encounter}",
  enabled: true,
};

export function migrateAppConfig(config: AppConfig) {
  let changed = false;
  if (typeof config.providers.rankedOnly !== "boolean") {
    config.providers.rankedOnly = false;
    changed = true;
  }
  if (typeof config.automation.protectChatInput !== "boolean") {
    config.automation.protectChatInput = true;
    changed = true;
  }
  if (!Number.isFinite(config.automation.autoAcceptDelaySeconds)) {
    config.automation.autoAcceptDelaySeconds = 0;
    changed = true;
  }
  if (!Number.isFinite(config.automation.autoPickDelaySeconds)) {
    config.automation.autoPickDelaySeconds = 1;
    changed = true;
  }
  if (!Number.isFinite(config.automation.shortcutSendIntervalMs)) {
    config.automation.shortcutSendIntervalMs = 250;
    changed = true;
  }
  if (!Number.isFinite(config.automation.shortcutRecentGameCount)) {
    config.automation.shortcutRecentGameCount = 5;
    changed = true;
  }
  if (!['just-show', 'show-and-lock-in', 'lock-in-immediately'].includes(config.automation.autoPickStrategy)) {
    config.automation.autoPickStrategy = "show-and-lock-in";
    changed = true;
  }
  if (!config.automation.shortcuts.some((shortcut) => shortcut.id === junglePreferenceShortcut.id)) {
    const premadeIndex = config.automation.shortcuts.findIndex((shortcut) => shortcut.id === "premade");
    config.automation.shortcuts.splice(premadeIndex >= 0 ? premadeIndex + 1 : 0, 0, structuredClone(junglePreferenceShortcut));
    changed = true;
  } else {
    // Configs created before the native shortcut target existed may still
    // point this id at `custom`, whose legacy behavior is "first ally".
    // Normalize the reserved shortcut so both preview and live sending use
    // the player identified as jungle (position or Smite), including old
    // persisted configs that already contain the shortcut.
    const jungleShortcut = config.automation.shortcuts.find((shortcut) => shortcut.id === junglePreferenceShortcut.id);
    if (jungleShortcut && jungleShortcut.target !== junglePreferenceShortcut.target) {
      jungleShortcut.target = junglePreferenceShortcut.target;
      changed = true;
    }
  }
  if (!config.automation.shortcuts.some((shortcut) => shortcut.id === encounterShortcut.id)) {
    const premadeIndex = config.automation.shortcuts.findIndex((shortcut) => shortcut.id === "premade");
    config.automation.shortcuts.splice(premadeIndex >= 0 ? premadeIndex : 0, 0, structuredClone(encounterShortcut));
    changed = true;
  }
  const openGameShortcut = config.automation.shortcuts.find((shortcut) => shortcut.id === "open-game");
  if (openGameShortcut?.key === "CommandOrControl+Shift+G") {
    openGameShortcut.key = defaultOpenGameShortcutKey;
    changed = true;
  }
  // Party context is sent as a separate ally-only line during champ-select;
  // keeping it in ally/enemy templates would leak it into in-game chat.
  for (const shortcut of config.automation.shortcuts) {
    if ((shortcut.id === "ally" || shortcut.id === "enemy") && shortcut.template.includes("{premade}")) {
      shortcut.template = defaultAssessmentTemplate;
      changed = true;
    }
  }
  if (config.version < 16) {
    config.automation.shortcutSendIntervalMs = 250;
    for (const shortcut of config.automation.shortcuts) {
      if (shortcut.id === "enemy" || shortcut.id === "ally") shortcut.template = defaultAssessmentTemplate;
    }
    changed = true;
  }
  if (config.version < CURRENT_CONFIG_VERSION) {
    config.version = CURRENT_CONFIG_VERSION;
    changed = true;
  }
  return changed;
}
