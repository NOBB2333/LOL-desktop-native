import { beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { fixtureConfig, fixtureLobby } from "../fixtures/data";

let backend: typeof import("./backend")["backend"];

beforeAll(async () => {
  const values = new Map<string, string>();
  vi.stubGlobal("localStorage", {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => values.set(key, value),
    removeItem: (key: string) => values.delete(key),
    clear: () => values.clear(),
  });
  ({ backend } = await import("./backend"));
});

describe("browser shortcut preview", () => {
  beforeEach(async () => {
    localStorage.clear();
    await backend.saveConfig(structuredClone(fixtureConfig));
  });

  it("renders the configured number of recent games", async () => {
    const config = structuredClone(fixtureConfig);
    config.automation.shortcutRecentGameCount = 3;
    const enemy = config.automation.shortcuts.find((shortcut) => shortcut.id === "enemy");
    if (!enemy) throw new Error("enemy shortcut fixture missing");
    enemy.template = "{name} {recent_games}";
    await backend.saveConfig(config);

    const lines = await backend.previewShortcut("enemy");

    expect(lines).toHaveLength(5);
    expect(lines[0]).toContain("近3场：");
    expect(lines[0].match(/；/g)).toHaveLength(2);
  });

  it("keeps the page preview compact but expands the chat text", async () => {
    const config = structuredClone(fixtureConfig);
    config.automation.shortcutRecentGameCount = 3;
    const ally = config.automation.shortcuts.find((shortcut) => shortcut.id === "ally");
    if (!ally) throw new Error("ally shortcut fixture missing");
    ally.template = "{name} {recent_games}";
    await backend.saveConfig(config);

    const preview = await backend.previewShortcut("ally");
    expect(preview).toHaveLength(5);
    expect(preview[0]).toContain("近3场：");
    // 页面预览保持「每人一行」，逐场战绩仍用「；」连在一行里。
    expect(preview[0].match(/；/g)).toHaveLength(2);

    const sent = await backend.sendShortcut("ally");
    // 聊天版本每场单独一行，并在玩家之间补一个空行（5 人 → 4 个分隔）。
    expect(sent.filter((line) => line === "")).toHaveLength(4);
    expect(sent.length).toBeGreaterThan(preview.length);
  });

  it("matches the two-line premade summary", async () => {
    const lines = await backend.previewShortcut("premade");

    expect(lines).toHaveLength(2);
    expect(lines[0]).toMatch(/^敌方开黑：/);
    expect(lines[1]).toMatch(/^我方开黑：/);
    expect(lines.join("\n")).toContain("河道观察者");
  });

  it("previews the clicked shortcut instead of falling back to enemy", async () => {
    const config = structuredClone(fixtureConfig);
    const ally = config.automation.shortcuts.find((shortcut) => shortcut.id === "ally")!;
    const enemy = config.automation.shortcuts.find((shortcut) => shortcut.id === "enemy")!;
    ally.template = "ALLY {name}";
    enemy.template = "ENEMY {name}";
    await backend.saveConfig(config);

    const allyLines = await backend.previewShortcut("ally");
    expect(allyLines).toHaveLength(5);
    expect(allyLines.every((line) => line.startsWith("ALLY "))).toBe(true);
    expect(allyLines.some((line) => line.startsWith("ENEMY "))).toBe(false);
  });

  it("builds the jungle preference shortcut for both junglers", async () => {
    const lines = await backend.previewShortcut("jungle-preference");

    expect(lines).toHaveLength(2);
    expect(lines.every((line) => line.includes("打野样本"))).toBe(true);
  });

  it("returns the complete match page for one encountered player", async () => {
    const records = await backend.encounters(fixtureLobby.ally[2].puuid, 1);

    expect(records).toHaveLength(9);
    expect(new Set(records.map((record) => record.gameId)).size).toBe(1);
    expect(records.some((record) => record.puuid === fixtureLobby.ally[2].puuid)).toBe(true);
  });
});

describe("player tags in browser preview", () => {
  it("round-trips notes per player and clears them", async () => {
    const target = fixtureLobby.ally[2].puuid;
    const other = fixtureLobby.enemy[0].puuid;

    await backend.updatePlayerTag(target, []);
    expect(await backend.playerTags([target, other])).toEqual({ [target]: [], [other]: [] });

    const saved = await backend.updatePlayerTag(target, [" 爱打野 ", "", "挂机过"]);
    expect(saved.notes).toEqual(["爱打野", "挂机过"]);
    expect(await backend.playerTags([target, other])).toEqual({
      [target]: ["爱打野", "挂机过"],
      [other]: [],
    });

    await backend.updatePlayerTag(target, []);
    expect(await backend.playerTags([target])).toEqual({ [target]: [] });
  });

  it("rejects a missing player id", async () => {
    await expect(backend.updatePlayerTag("   ", ["备注"])).rejects.toThrow("缺少玩家标识");
  });
});
