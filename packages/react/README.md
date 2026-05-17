# @arbor/react

React bindings for Arbor stores. Provides `ArborProvider`, `useArborRoot`,
`useArborSnapshot`, and `useArborCommand` on top of `@arbor/client`.

## Install

`@arbor/react` ships inside the Arbor Hex package under
`deps/arbor/packages/react`. After `mix deps.get` populates `deps/arbor/`,
reference both packages by local path from the frontend project's
`package.json` (adjust the relative path so it points at
`deps/arbor/packages/<name>` from the JS app root):

```json
{
  "dependencies": {
    "@arbor/client": "file:../deps/arbor/packages/client",
    "@arbor/react": "file:../deps/arbor/packages/react"
  }
}
```

Then install once:

```sh
pnpm install   # or npm install / yarn install
```

`react` and `react-dom` are peer dependencies — install them in the
consumer app, not inside this package.

Both `@arbor/client` and `@arbor/react` ship TypeScript source directly;
the consumer bundler (Vite, Phoenix esbuild) transpiles on demand — no
build step required.

## Avoiding Duplicate React Copies

When the consumer's package manager copies the linked package into
`node_modules/@arbor/react/`, it may also bring along a second copy of
`react` via the package's own dependency tree. The symptom is
`Invalid hook call. Hooks can only be called inside of the body of a
function component` with a stack pointing deep into `@arbor/react`
internals — the bug is the dual install, not Arbor.

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

After configuring, run `pnpm why react` (or `npm ls react`) in the
consumer app. Every entry should resolve to the same path on disk. If
they diverge, the bundler config has not deduplicated yet.
