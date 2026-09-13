import { defineConfig } from "vite";
import vue from "@vitejs/plugin-vue";
import tailwindcss from "@tailwindcss/vite";
import nativeConfig from "../config/native.json" with { type: "json" };

export default defineConfig({
  plugins: [vue(), tailwindcss()],
  // Native serves production files from zero://app, so root-relative URLs
  // such as /assets/... would resolve outside the bundled frontend tree.
  base: "./",
  build: {
    outDir: "dist",
    // 由 `npm run prebuild`（scripts/clean-dist.mjs）分批清空：某些环境会拦截
    // 单次批量删除，`emptyOutDir` 在那里会直接让构建失败。目录提前清空后，
    // Vite 也就没有必要再自己清一遍。
    emptyOutDir: false,
    sourcemap: false,
    cssMinify: "lightningcss",
  },
  server: {
    port: nativeConfig.devServer.port,
    strictPort: true,
    host: nativeConfig.devServer.host,
  },
});
