# @arbor/react

React bindings for Arbor stores. Provides `ArborProvider`, `useArborRoot`,
`useArborSnapshot`, and `useArborCommand` on top of `@arbor/client`.

## Install

```sh
pnpm add @arbor/react @arbor/client
```

`react` and `react-dom` are peer dependencies — install them in the consumer
app, not inside this package.

## Consuming `@arbor/react` Outside the Monorepo

When installing via `pnpm link:`, `file:`, or any path/symlink protocol,
the linked package may resolve its own `node_modules/react` and end up
with two React copies in your bundle. The symptom is `Invalid hook call.
Hooks can only be called inside of the body of a function component`
with a stack pointing deep into `@arbor/react` internals — but the bug
is the dual install, not Arbor.

### Vite

Add to `vite.config.ts`:

```ts
import path from "node:path"
import { defineConfig } from "vite"

export default defineConfig({
  resolve: {
    dedupe: ["react", "react-dom"],
    alias: {
      react: path.resolve(__dirname, "node_modules/react"),
      "react-dom": path.resolve(__dirname, "node_modules/react-dom"),
    },
  },
})
```

### Webpack / Next.js

Use `resolve.alias` with the same paths.

### Verifying the Fix

After configuring, run `pnpm why react` in the linked package and the
consumer app. Both should resolve to the same path on disk. If they
diverge, the bundler config has not deduplicated yet.
