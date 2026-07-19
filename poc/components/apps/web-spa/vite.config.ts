// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  // safari11: transpile ES2020+ syntax for iPhone X-era Safari and old
  // Android WebView without adding @vitejs/plugin-legacy.
  build: { target: "safari11" },
});
