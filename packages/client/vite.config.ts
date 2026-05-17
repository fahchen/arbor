import { defineConfig } from "vite"

// No `build` block — `@musubi/client` ships TypeScript source directly via
// the package.json `exports` map. Consumers (always bundler-based here)
// transpile on demand. This file only configures Vitest.
export default defineConfig({
  test: {
    environment: "node",
    globals: false,
    include: ["test/**/*.test.ts"]
  }
})
