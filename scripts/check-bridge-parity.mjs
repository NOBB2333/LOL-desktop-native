#!/usr/bin/env node
/**
 * 命令面一致性校验：app.json ↔ Zig 命令表 ↔ 前端调度器。
 *
 * 存在的理由：新增一个 Bridge 命令需要同时改 Zig、manifest 和前端调度器；
 * 2026-09-22 实测发现 4 个命令（lol.get_jungle_path / lol.search_summoner /
 * lol.get_player_tags / lol.update_player_tag）在 Zig 注册了但 app.json 没声明，
 * 且当时没有任何机制能发现。这个脚本就是那道防线。
 *
 * 校验三件事：
 *   1. app.json 的 bridge.commands 与 src/backend.zig 的 command_table 集合一致。
 *   2. handlers() 的注册顺序与 command_table 完全一致
 *      （main.zig 依赖 handlers() 的下标填充 async_contexts）。
 *   3. 每个非 query 通道的成员集合，在 Zig 与 frontend/src/services/native.ts
 *      之间完全一致。
 *
 * 用法：node scripts/check-bridge-parity.mjs
 */
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const backendFile = "src/backend.zig";
const manifestFile = "app.json";
const schedulerFile = "frontend/src/services/native.ts";

const read = (file) => readFileSync(resolve(root, file), "utf8");

/** 命令名不是 query 通道时才有显式登记；query 是两侧共同的兜底。 */
const EXPLICIT_LANES = ["roster", "events", "connection", "action", "state"];

function parseCommandTable() {
  const source = read(backendFile);
  const entries = [
    ...source.matchAll(/\.\{ \.name = "([a-z_.]+)", \.lane = \.([a-z]+) \}/g),
  ].map(([, name, lane]) => ({ name, lane }));

  if (entries.length === 0) {
    throw new Error(`在 ${backendFile} 中解析不到 command_table（期望 .{ .name = "...", .lane = .xxx },）`);
  }
  return entries;
}

function parseHandlerRegistry() {
  const source = read(backendFile);
  const names = [
    ...source.matchAll(/\{\s*\.name = "([a-z_.]+)",\s*\.context = self,\s*\.invoke_fn =/g),
  ].map(([, name]) => name);

  if (names.length === 0) {
    throw new Error(`在 ${backendFile} 中解析不到 handlers() 注册表`);
  }
  return names;
}

function parseManifestCommands() {
  const manifest = JSON.parse(read(manifestFile));
  const commands = manifest?.bridge?.commands;
  if (!Array.isArray(commands) || commands.length === 0) {
    throw new Error(`${manifestFile} 缺少 bridge.commands`);
  }
  return commands.map((entry) => entry.name);
}

/** 从 createCommandScheduler 里抽出「通道 -> 命令名集合」。 */
function parseScheduler() {
  const source = read(schedulerFile);
  const start = source.indexOf("export function createCommandScheduler");
  if (start < 0) throw new Error(`在 ${schedulerFile} 中找不到 createCommandScheduler`);
  const end = source.indexOf("return query(task);", start);
  if (end < 0) throw new Error(`在 ${schedulerFile} 的 createCommandScheduler 中找不到 query 兜底`);
  const body = source.slice(start, end);

  const lanes = new Map();
  const add = (lane, name) => {
    if (!lanes.has(lane)) lanes.set(lane, new Set());
    lanes.get(lane).add(name);
  };

  // 形如：if (name === "lol.x") return roster(task);
  for (const [, name, lane] of body.matchAll(/if \(name === "([a-z_.]+)"\) return ([a-z]+)\(task\);/g)) {
    add(lane, name);
  }
  // 形如：if (["lol.x", "lol.y"].includes(name)) return action(task);
  for (const [, list, lane] of body.matchAll(/if \(\[([^\]]+)\]\.includes\(name\)\) return ([a-z]+)\(task\);/g)) {
    for (const [, name] of list.matchAll(/"([a-z_.]+)"/g)) add(lane, name);
  }

  if (lanes.size === 0) {
    throw new Error(`在 ${schedulerFile} 的 createCommandScheduler 中解析不到通道分支`);
  }
  return lanes;
}

const problems = [];
const push = (title, detail) => problems.push(`  ${title}\n${detail.map((line) => `      ${line}`).join("\n")}`);

const table = parseCommandTable();
const tableNames = table.map((entry) => entry.name);
const handlers = parseHandlerRegistry();
const manifestCommands = parseManifestCommands();
const scheduler = parseScheduler();

// 1. manifest ↔ Zig 命令表
const tableSet = new Set(tableNames);
const manifestSet = new Set(manifestCommands.filter((name) => name !== "native.ping"));
const missingFromManifest = tableNames.filter((name) => !manifestSet.has(name));
const undeclaredInZig = [...manifestSet].filter((name) => !tableSet.has(name));
if (missingFromManifest.length > 0 || undeclaredInZig.length > 0) {
  const detail = [];
  if (missingFromManifest.length > 0) {
    detail.push(`已在 Zig 注册但 ${manifestFile} 未声明：${missingFromManifest.join(", ")}`);
  }
  if (undeclaredInZig.length > 0) {
    detail.push(`${manifestFile} 声明但 Zig 未注册：${undeclaredInZig.join(", ")}`);
  }
  detail.push(`请在 ${manifestFile} 的 bridge.commands 中补齐。`);
  push("命令面漂移（manifest ↔ Zig）", detail);
}

// 2. handlers() ↔ Zig 命令表
if (handlers.length !== tableNames.length) {
  push("handler 数量与命令表不一致", [
    `handlers() ${handlers.length} 个，command_table ${tableNames.length} 个`,
  ]);
} else {
  const orderMismatch = handlers
    .map((name, index) => (name === tableNames[index] ? null : `[${index}] handlers=${name}  table=${tableNames[index]}`))
    .filter(Boolean);
  if (orderMismatch.length > 0) {
    push("handlers() 顺序/成员与 command_table 不一致", orderMismatch);
  }
}

// 3. Zig 通道 ↔ 前端调度器通道
const zigLanes = new Map();
for (const lane of EXPLICIT_LANES) zigLanes.set(lane, new Set());
for (const { name, lane } of table) {
  if (!zigLanes.has(lane)) zigLanes.set(lane, new Set());
  zigLanes.get(lane).add(name);
}

for (const lane of EXPLICIT_LANES) {
  const zig = zigLanes.get(lane) ?? new Set();
  const front = scheduler.get(lane) ?? new Set();
  const onlyZig = [...zig].filter((name) => !front.has(name));
  const onlyFront = [...front].filter((name) => !zig.has(name));
  if (onlyZig.length > 0 || onlyFront.length > 0) {
    const detail = [];
    if (onlyZig.length > 0) detail.push(`${backendFile} 有、前端调度器没有：${onlyZig.join(", ")}`);
    if (onlyFront.length > 0) detail.push(`${schedulerFile} 有、${backendFile} 没有：${onlyFront.join(", ")}`);
    push(`通道 .${lane} 两端不一致`, detail);
  }
}

if (problems.length > 0) {
  console.error("命令面一致性校验失败：\n");
  for (const problem of problems) console.error(`${problem}\n`);
  process.exit(1);
}

const laneSummary = EXPLICIT_LANES.map((lane) => `${lane}:${zigLanes.get(lane).size}`).join(" ");
console.log(
  `命令面一致：manifest ${manifestSet.size} 条 + native.ping；` +
    `handlers ${handlers.length} 个顺序吻合；通道 ${laneSummary}（其余走 query）`,
);
