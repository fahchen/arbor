import { defineConfig } from "vite"
import react from "@vitejs/plugin-react"

export default defineConfig({
  plugins: [react()],
  server: {
    port: 4103,
    proxy: {
      "/socket": {
        target: "http://localhost:4003",
        ws: true
      }
    }
  }
})
