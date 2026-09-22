#!/usr/bin/env node
/**
 * 以 app.json.version 为唯一来源，同步或校验所有发布版本字段。
 *
 * 与 vercel-labs/native Demo 的 scripts/version.mjs 同构，差异有三处：
 * 1. 前端目录是 frontend/（模板里叫 src_web/），并额外覆盖浏览器 preview 用的
 *    fixture 版本字段（frontend/src/fixtures/data.ts 的 appVersion）。
 * 2. 不做 JSON 重新格式化，只替换版本字段本身——避免产生与版本无关的 diff，
 *    也避免为此引入 oxfmt 依赖。根 package-lock.json 同理，只动根包那两处。
 * 3. check 额外断言 src/ 下没有残留的「当前应用版本」字面量，防止再退回硬编码。
 *
 * 用法：
 *   node scripts/version.mjs set 2.1.0   # 写入 app.json 并同步派生字段
 *   node scripts/version.mjs sync        # 按 app.json 同步派生字段
 *   node scripts/version.mjs check       # 校验全部一致
 */
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const manifestFile = "app.json";

const semverPattern =
  /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/;

/**
 * 每个派生字段的读写规则。`occurrences` 限定只改前 N 处，避免误伤嵌套字段：
 * package-lock.json 里除根包外，每个依赖条目也有 "version"。
 */
const targets = [
  { file: "package.json", kind: "json", occurrences: 1 },
  { file: "frontend/package.json", kind: "json", occurrences: 1 },
  { file: "build.zig.zon", kind: "zon", occurrences: 1 },
  { file: "frontend/src/fixtures/data.ts", kind: "fixture", occurrences: 1 },
  { file: "package-lock.json", kind: "json", occurrences: 2 },
];

const patterns = {
  json: { match: /^(\s*)"version"\s*:\s*"([^"]*)"/gm, render: (indent, version) => `${indent}"version": "${version}"` },
  zon: { match: /^([ \t]*)\.version\s*=\s*"([^"]*)",/gm, render: (indent, version) => `${indent}.version = "${version}",` },
  fixture: { match: /^(\s*)appVersion:\s*"([^"]*)",/gm, render: (indent, version) => `${indent}appVersion: "${version}",` },
};

function readManifestVersion() {
  const { version } = JSON.parse(readFileSync(resolve(root, manifestFile), "utf8"));
  if (typeof version !== "string" || !semverPattern.test(version)) {
    throw new Error(`${manifestFile} 的 version 必须是有效 SemVer，例如 2.1.0`);
  }
  return version;
}

function collectMatches(file, kind) {
  const { match } = patterns[kind];
  const source = readFileSync(resolve(root, file), "utf8");
  return { source, hits: [...source.matchAll(match)] };
}

function readDerivedVersions(target) {
  const { hits } = collectMatches(target.file, target.kind);
  if (hits.length < target.occurrences) {
    throw new Error(
      `${target.file} 里只找到 ${hits.length} 处版本字段（期望至少 ${target.occurrences} 处）；` +
        "文件结构可能已变化，请同步更新 scripts/version.mjs 的 targets。",
    );
  }
  return hits.slice(0, target.occurrences).map((hit) => hit[2]);
}

function writeDerivedVersion(target, version) {
  const { match, render } = patterns[target.kind];
  const { source, hits } = collectMatches(target.file, target.kind);

  if (hits.length < target.occurrences) {
    throw new Error(`${target.file} 里只找到 ${hits.length} 处版本字段（期望至少 ${target.occurrences} 处）`);
  }

  let remaining = target.occurrences;
  const next = source.replace(match, (whole, indent, current) => {
    if (remaining === 0) return whole;
    remaining -= 1;
    return current === version ? whole : render(indent, version);
  });

  writeFileSync(resolve(root, target.file), next, "utf8");
}

/** 找出 src/ 下把当前应用版本写成字面量的地方。 */
function findHardcodedAppVersion(version) {
  const hits = [];
  const needle = `"${version}"`;

  const walk = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const full = resolve(dir, entry.name);
      if (entry.isDirectory()) {
        walk(full);
        continue;
      }
      if (!entry.name.endsWith(".zig")) continue;
      readFileSync(full, "utf8")
        .split("\n")
        .forEach((line, index) => {
          if (line.includes(needle)) {
            hits.push(`${relative(root, full).replace(/\\/g, "/")}:${index + 1}  ${line.trim()}`);
          }
        });
    }
  };

  walk(resolve(root, "src"));
  return hits;
}

function sync(version) {
  for (const target of targets) writeDerivedVersion(target, version);
}

const [command, ...rawArgs] = process.argv.slice(2);
const [requested] = rawArgs[0] === "--" ? rawArgs.slice(1) : rawArgs;

try {
  switch (command) {
    case "set": {
      if (!requested || !semverPattern.test(requested)) {
        throw new Error("用法：node scripts/version.mjs set <SemVer>，例如 set 2.1.0");
      }
      writeDerivedVersion({ file: manifestFile, kind: "json", occurrences: 1 }, requested);
      sync(requested);
      console.log(`版本已更新为 ${requested}（已同步 ${targets.length} 个派生文件）`);
      break;
    }
    case "sync": {
      const version = readManifestVersion();
      sync(version);
      console.log(`已从 ${manifestFile} 同步派生版本 ${version}`);
      break;
    }
    case "check": {
      const expected = readManifestVersion();
      const mismatches = [];
      for (const target of targets) {
        for (const value of readDerivedVersions(target)) {
          if (value !== expected) mismatches.push([target.file, value]);
        }
      }

      if (mismatches.length > 0) {
        for (const [file, value] of mismatches) console.error(`  ${file}: ${value}（应为 ${expected}）`);
        console.error("版本不一致。运行 node scripts/version.mjs sync 修复。");
        process.exit(1);
      }

      const hardcoded = findHardcodedAppVersion(expected);
      if (hardcoded.length > 0) {
        console.error(`src/ 下仍有硬编码的应用版本 "${expected}"：`);
        for (const hit of hardcoded) console.error(`  ${hit}`);
        console.error("应用版本必须由 manifest 注入（见 src/main.zig 的 app_manifest.version）。");
        process.exit(1);
      }

      const derivedCount = targets.reduce((sum, target) => sum + target.occurrences, 0);
      console.log(`版本一致：${expected}（${targets.length} 个派生文件 / ${derivedCount} 处字段，src/ 无硬编码）`);
      break;
    }
    default:
      throw new Error("用法：node scripts/version.mjs <set|sync|check> [version]");
  }
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}
