import { defineConfig } from "vite"
import react from "@vitejs/plugin-react"

export default defineConfig({
  plugins: [react()],
  server: {
    port: 4101,
    proxy: {
      "/socket": {
        target: "http://localhost:4001",
        ws: true
      }
    }
  }
})
