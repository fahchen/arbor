import { resolve } from "node:path"

import { defineConfig } from "vite"
import react from "@vitejs/plugin-react"

const workspaceRoot = resolve(__dirname, "../../..")

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      "@arbor/client": resolve(workspaceRoot, "packages/client/src/index.ts"),
      "@arbor/react": resolve(workspaceRoot, "packages/react/src/index.ts")
    }
  },
  server: {
    port: 4103,
    fs: {
      allow: [workspaceRoot]
    },
    proxy: {
      "/socket": {
        target: "http://localhost:4003",
        ws: true
      }
    }
  }
})
