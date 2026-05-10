import { resolve } from "node:path"

import dts from "vite-plugin-dts"
import { defineConfig } from "vite"

export default defineConfig({
  build: {
    lib: {
      entry: resolve(__dirname, "src/index.ts"),
      name: "ArborClient",
      formats: ["es", "cjs"],
      fileName: (format) => (format === "es" ? "index.js" : "index.cjs")
    },
    rollupOptions: {
      external: ["phoenix"]
    },
    sourcemap: true
  },
  plugins: [dts({ insertTypesEntry: true })],
  test: {
    environment: "node",
    globals: false,
    include: ["test/**/*.test.ts"]
  }
})
