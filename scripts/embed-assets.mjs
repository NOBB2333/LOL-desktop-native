import { readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { join, relative, resolve } from "node:path";

const args = process.argv.slice(2);
const distArg = args[0];
const loaderArg = args[1];
// Zig appends output paths after all explicit arguments. The optional files
// between the loader and the final two paths are application resources that
// must survive a single-file package (for example the tray icon).
const bundleArg = args.at(-2);
const sourceArg = args.at(-1);
const extraArgs = args.slice(2, -2);
if (!distArg || !bundleArg || !sourceArg) {
  console.error("usage: embed-assets.mjs <dist> <loader-or-> [extra-file ...] <bundle> <zig-source>");
  process.exit(2);
}

const dist = resolve(distArg);
const files = [];
function visit(directory) {
  for (const entry of readdirSync(directory, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) visit(path);
    else if (entry.isFile()) files.push({ path: relative(dist, path).replaceAll("\\", "/"), bytes: readFileSync(path) });
  }
}
visit(dist);
if (loaderArg && loaderArg !== "-") {
  const loader = resolve(loaderArg);
  if (statSync(loader).isFile()) files.push({ path: "__native/WebView2Loader.dll", bytes: readFileSync(loader) });
}
for (const extraArg of extraArgs) {
  const extra = resolve(extraArg);
  if (!statSync(extra).isFile()) continue;
  files.push({ path: `assets/${relative(resolve("assets"), extra).replaceAll("\\", "/")}`, bytes: readFileSync(extra) });
}

const chunks = [Buffer.from("LDF1\0", "ascii")];
for (const file of files) {
  const name = Buffer.from(file.path, "utf8");
  const header = Buffer.alloc(12);
  header.writeUInt32LE(name.length, 0);
  header.writeBigUInt64LE(BigInt(file.bytes.length), 4);
  chunks.push(header, name, file.bytes);
}
writeFileSync(bundleArg, Buffer.concat(chunks));
writeFileSync(sourceArg, `pub const bytes = @embedFile("${resolve(bundleArg).replaceAll("\\", "/")}");\n`);
