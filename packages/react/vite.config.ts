import { defineConfig } from "vite"

// No `build` block — `@musubi/react` ships TypeScript source directly via
// the package.json `exports` map. Consumers (always Vite-based here)
// transpile on demand. This file only configures Vitest.
export default defineConfig({
  test: {
    environment: "jsdom",
    globals: false,
    include: ["test/**/*.test.ts", "test/**/*.test.tsx"],
    setupFiles: ["./test/setup.ts"],
    // `--expose-gc` lets the Suspense orphan-sweep test trigger collection
    // explicitly so the FinalizationRegistry safety net's finalizer fires
    // within the test window. Real consumers do not need this flag — the
    // browser collects on its own schedule.
    execArgv: ["--expose-gc"]
  }
})
