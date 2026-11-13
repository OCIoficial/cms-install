import { defineConfig } from "vite";
import { svelte } from "@sveltejs/vite-plugin-svelte";

// La página se sirve en https://<admin>/import-users/. build.sh compila a
// OUT_DIR (terraform/.build/...); sin OUT_DIR, a dist/.
export default defineConfig({
  base: "/import-users/",
  plugins: [svelte()],
  build: {
    outDir: process.env.OUT_DIR ?? "dist",
    emptyOutDir: true,
  },
});
