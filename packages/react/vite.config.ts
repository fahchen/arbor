import { resolve } from "node:path"

import { defineConfig } from "vite"
import dts from "vite-plugin-dts"

export default defineConfig({
  build: {
    lib: {
      entry: resolve(__dirname, "src/index.ts"),
      name: "ArborReact",
      formats: ["es", "cjs"],
      fileName: (format) => (format === "es" ? "index.js" : "index.cjs")
    },
    rollupOptions: {
      external: [
        "react",
        "react/jsx-runtime",
        "react-dom",
        "use-sync-external-store/shim/with-selector",
        "@arbor/client"
      ]
    },
    sourcemap: true
  },
  plugins: [dts({ insertTypesEntry: true })],
  test: {
    environment: "jsdom",
    globals: false,
    include: ["test/**/*.test.ts", "test/**/*.test.tsx"],
    setupFiles: ["./test/setup.ts"]
  }
})
