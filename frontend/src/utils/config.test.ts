import { describe, expect, it } from "vitest";
import { fixtureConfig } from "../fixtures/data";
import { CURRENT_CONFIG_VERSION, defaultAssessmentTemplate, defaultOpenGameShortcutKey, migrateAppConfig } from "./config";

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
});
