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
    emptyOutDir: true,
    sourcemap: false,
    cssMinify: "lightningcss",
  },
  server: {
    port: nativeConfig.devServer.port,
    strictPort: true,
    host: nativeConfig.devServer.host,
  },
});
