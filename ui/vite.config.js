// Vite library build for one RutOS WebUI plugin.
//
// The host WebUI already ships Vue, so vue is externalised (vite-plugin-externals)
// and the bundle is emitted as a single ES module. compile-vuci-app.sh sets
// VITE_PLUGIN_ENTRY / VITE_PLUGIN_FILENAME per component.
import { defineConfig, loadEnv } from "vite";
import { readFileSync } from "node:fs";
import vue from "@vitejs/plugin-vue";
import { viteExternalsPlugin } from "vite-plugin-externals";
import { compression } from "vite-plugin-compression2";

// Single source of truth for the WebUI build version: package.json. It is
// injected at build time as __UI_VERSION__ so the view never hardcodes a
// version that can drift from the packaged build.
const pkg = JSON.parse(readFileSync(new URL("./package.json", import.meta.url), "utf8"));

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), "");
  return {
    plugins: [
      vue({ isProduction: true }),
      viteExternalsPlugin({ vue: "Vue" }),
      compression({ deleteOriginalAssets: true }),
    ],
    define: {
      "process.env.NODE_ENV": '"production"',
      __UI_VERSION__: JSON.stringify(pkg.version),
    },
    build: {
      cssCodeSplit: false,
      lib: {
        entry: env.VITE_PLUGIN_ENTRY,
        fileName: () => `${env.VITE_PLUGIN_FILENAME}.js`,
        formats: ["es"],
      },
      rollupOptions: {
        external: ["vue"],
        output: { globals: { vue: "Vue" } },
      },
    },
  };
});
