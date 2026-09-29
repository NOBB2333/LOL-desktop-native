import { describe, expect, it } from "vitest";
import { fixtureConfig } from "../fixtures/data";
import { CURRENT_CONFIG_VERSION, defaultAramSwapDelaySeconds, defaultAssessmentTemplate, defaultOpenGameShortcutKey, defaultRecordingRetentionDays, migrateAppConfig, normalizeRecordingRetentionDays } from "./config";

describe("config migration", () => {
  it("adds the jungle shortcut to an existing config without changing custom shortcuts", () => {
    const config = structuredClone(fixtureConfig);
    config.version = 12;
    config.automation.shortcuts = config.automation.shortcuts.filter((shortcut) => shortcut.id !== "jungle-preference");
    config.automation.shortcuts.push({ id: "mine", label: "我的消息", key: "F8", target: "custom", template: "hello", enabled: false });

    expect(migrateAppConfig(config)).toBe(true);
    expect(config.version).toBe(CURRENT_CONFIG_VERSION);
    expect(config.automation.shortcuts.find((shortcut) => shortcut.id === "jungle-preference")).toMatchObject({ target: "jungle", key: "Ctrl+F7" });
    expect(config.automation.shortcuts.find((shortcut) => shortcut.id === "mine")?.template).toBe("hello");
    expect(config.automation.shortcuts.find((shortcut) => shortcut.id === "enemy")?.template).toBe(defaultAssessmentTemplate);
    expect(config.automation.shortcuts.find((shortcut) => shortcut.id === "ally")?.template).toBe(defaultAssessmentTemplate);
    expect(config.automation.shortcutSendIntervalMs).toBe(65);
    expect(migrateAppConfig(config)).toBe(false);
  });

  it("normalizes a legacy jungle shortcut that targeted the first ally", () => {
    const config = structuredClone(fixtureConfig);
    const shortcut = config.automation.shortcuts.find((item) => item.id === "jungle-preference")!;
    shortcut.target = "custom";

    expect(migrateAppConfig(config)).toBe(true);
    expect(shortcut.target).toBe("jungle");
  });

  it("upgrades assessment templates without in-game party context", () => {
    const config = structuredClone(fixtureConfig);
    config.version = 15;
    for (const shortcut of config.automation.shortcuts) {
      if (shortcut.id === "ally" || shortcut.id === "enemy") shortcut.template = "{team}{position}";
    }
    expect(migrateAppConfig(config)).toBe(true);
    expect(config.version).toBe(CURRENT_CONFIG_VERSION);
    expect(config.automation.shortcuts.find((item) => item.id === "ally")?.template).not.toContain("{premade}");
  });

  it("normalizes an unknown auto-pick strategy to the visible hover-first default", () => {
    const config = structuredClone(fixtureConfig);
    config.automation.autoPickStrategy = "legacy-immediate";

    expect(migrateAppConfig(config)).toBe(true);
    expect(config.automation.autoPickStrategy).toBe("show-and-lock-in");
  });

  it("moves only the legacy open-game default to Ctrl+F1", () => {
    const legacy = structuredClone(fixtureConfig);
    legacy.version = 16;
    legacy.automation.shortcuts.find((item) => item.id === "ally")!.template = "我的自定义评估";
    legacy.automation.shortcuts.find((item) => item.id === "open-game")!.key = "CommandOrControl+Shift+G";

    expect(migrateAppConfig(legacy)).toBe(true);
    expect(legacy.automation.shortcuts.find((item) => item.id === "open-game")?.key).toBe(defaultOpenGameShortcutKey);
    expect(legacy.automation.shortcuts.find((item) => item.id === "ally")?.template).toBe("我的自定义评估");

    const customized = structuredClone(fixtureConfig);
    customized.automation.shortcuts.find((item) => item.id === "open-game")!.key = "Ctrl+F2";
    expect(migrateAppConfig(customized)).toBe(false);
    expect(customized.automation.shortcuts.find((item) => item.id === "open-game")?.key).toBe("Ctrl+F2");
  });

  it("moves the legacy F8 / F10 defaults to F5 / F7 without touching custom keys", () => {
    const legacy = structuredClone(fixtureConfig);
    legacy.automation.shortcuts.find((item) => item.id === "encounter")!.key = "Ctrl+F8";
    legacy.automation.shortcuts.find((item) => item.id === "jungle-preference")!.key = "Ctrl+F10";

    expect(migrateAppConfig(legacy)).toBe(true);
    expect(legacy.automation.shortcuts.find((item) => item.id === "encounter")?.key).toBe("Ctrl+F5");
    expect(legacy.automation.shortcuts.find((item) => item.id === "jungle-preference")?.key).toBe("Ctrl+F7");

    const customized = structuredClone(fixtureConfig);
    customized.automation.shortcuts.find((item) => item.id === "encounter")!.key = "Alt+Z";
    expect(migrateAppConfig(customized)).toBe(false);
    expect(customized.automation.shortcuts.find((item) => item.id === "encounter")?.key).toBe("Alt+Z");
  });

  it("lowers only the legacy 250ms send interval to the 65ms default", () => {
    const legacy = structuredClone(fixtureConfig);
    legacy.version = 20;
    legacy.automation.shortcutSendIntervalMs = 250;

    expect(migrateAppConfig(legacy)).toBe(true);
    expect(legacy.automation.shortcutSendIntervalMs).toBe(65);

    const customized = structuredClone(fixtureConfig);
    customized.version = 20;
    customized.automation.shortcutSendIntervalMs = 120;

    expect(migrateAppConfig(customized)).toBe(true);
    expect(customized.automation.shortcutSendIntervalMs).toBe(120);
  });

  it("backfills the ARAM grab defaults without enabling it", () => {
    // v22 的新字段必须补上，但开关不能替用户打开——抢英雄要用户自己确认。
    const legacy = structuredClone(fixtureConfig);
    legacy.version = 21;
    delete (legacy.automation as Partial<typeof legacy.automation>).aramGrab;
    delete (legacy.automation as Partial<typeof legacy.automation>).aramChampionIds;
    delete (legacy.automation as Partial<typeof legacy.automation>).aramSwapDelaySeconds;

    expect(migrateAppConfig(legacy)).toBe(true);
    expect(legacy.version).toBe(CURRENT_CONFIG_VERSION);
    expect(legacy.automation.aramGrab).toBe(false);
    expect(legacy.automation.aramChampionIds).toEqual([]);
    expect(legacy.automation.aramSwapDelaySeconds).toBe(defaultAramSwapDelaySeconds);
  });

  it("给 v24 及更早的配置补上录制保留期，且不动用户已存的间隔", () => {
    // v25：录制保留期（自动清理老录制）。
    // 两条都要：①缺字段补默认的一个月；②**不能顺手改用户已存的 intervalSeconds**——
    // 那是已经落盘的真实偏好，迁移里改配置是最招人骂的一类改动。
    const legacy = structuredClone(fixtureConfig);
    legacy.version = 24;
    delete (legacy.providers.recording as Partial<typeof legacy.providers.recording>).retentionDays;
    legacy.providers.recording.intervalSeconds = 30;

    expect(migrateAppConfig(legacy)).toBe(true);
    expect(legacy.version).toBe(CURRENT_CONFIG_VERSION);
    expect(legacy.providers.recording.retentionDays).toBe(defaultRecordingRetentionDays);
    expect(legacy.providers.recording.intervalSeconds).toBe(30);
  });

  it("显式选了「永久保留」的配置不会被迁移回默认值", () => {
    // 0 是合法取值（永久），不能在迁移里被「补默认」的逻辑吃掉。
    const config = structuredClone(fixtureConfig);
    config.providers.recording.retentionDays = 0;
    migrateAppConfig(config);
    expect(config.providers.recording.retentionDays).toBe(0);
  });

  it("保留期档位归一：认不出来的值退回默认，绝不静默变成「永久」", () => {
    expect(normalizeRecordingRetentionDays(3)).toBe(3);
    expect(normalizeRecordingRetentionDays(0)).toBe(0);
    expect(normalizeRecordingRetentionDays(undefined)).toBe(defaultRecordingRetentionDays);
    expect(normalizeRecordingRetentionDays(Number.NaN)).toBe(defaultRecordingRetentionDays);
    expect(normalizeRecordingRetentionDays(17)).toBe(defaultRecordingRetentionDays);
    expect(normalizeRecordingRetentionDays(-1)).toBe(defaultRecordingRetentionDays);
  });
});
