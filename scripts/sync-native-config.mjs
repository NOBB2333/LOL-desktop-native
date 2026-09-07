import { readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const configPath = resolve(root, "config/native.json");
const manifestPath = resolve(root, "app.json");
const config = JSON.parse(await readFile(configPath, "utf8"));
const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
const origin = `http://${config.devServer.host}:${config.devServer.port}`;

for (const command of manifest.bridge?.commands ?? []) {
  command.origins = ["zero://app", origin];
}
manifest.frontend.dev.url = `${origin}/`;
manifest.security.navigation.allowed_origins = ["zero://app", "zero://inline", origin];

const next = `${JSON.stringify(manifest, null, 2)}\n`;
const current = await readFile(manifestPath, "utf8");
if (current !== next) await writeFile(manifestPath, next, "utf8");
