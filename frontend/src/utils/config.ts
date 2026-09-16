import type { AppConfig, ShortcutDefinition } from "../types/domain";
import { normalizePlayerTagSettings } from "../tags/settings";

export const CURRENT_CONFIG_VERSION = 20;
export const defaultOpenGameShortcutKey = "Ctrl+F1";

/**
 * `{main_position}`（主玩位置）插在段位与逐场战绩之间。旧版本存下来的默认模板
 * 会在这个版本号迁移里被替换成下面这一份；用户自己改过的模板不会被覆盖。
 */
export const defaultAssessmentTemplate =
  "{team}{position} {current_champion}：{rank} 主玩{main_position} {recent_wins}胜{recent_losses}负，{recent_games}";
const previousAssessmentTemplate =
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
  // v19：标签系统重建后新增逐标签开关；老配置缺字段时按默认值补齐。
  const normalizedTags = normalizePlayerTagSettings(config.playerTags);
  if (JSON.stringify(normalizedTags) !== JSON.stringify(config.playerTags ?? null)) {
    config.playerTags = normalizedTags;
    changed = true;
  }
  if (typeof config.providers.rankedOnly !== "boolean") {
    config.providers.rankedOnly = false;
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
  if (config.version < 20) {
    // 只替换「还是旧默认模板」的那两条，用户自定义过的模板原样保留。
    for (const shortcut of config.automation.shortcuts) {
      if (shortcut.id !== "enemy" && shortcut.id !== "ally") continue;
      if (shortcut.template.trim() !== previousAssessmentTemplate) continue;
      shortcut.template = defaultAssessmentTemplate;
      changed = true;
    }
  }
  if (config.version < CURRENT_CONFIG_VERSION) {
    config.version = CURRENT_CONFIG_VERSION;
    changed = true;
  }
  return changed;
}
