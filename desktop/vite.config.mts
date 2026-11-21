import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

export default defineConfig({
  root: "src/renderer",
  base: "./",
  plugins: [react()],
  build: {
    outDir: "../../dist/renderer",
    emptyOutDir: true,
    target: "esnext", // noVNC 1.7 uses top-level await; Electron's Chromium runs it natively
    chunkSizeWarningLimit: 2000,
  },
});
