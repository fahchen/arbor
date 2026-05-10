import { StrictMode } from "react"
import { createRoot } from "react-dom/client"
import { ArborProvider } from "@arbor/react"

import App from "./App"
import { client } from "./arbor"
import "./App.css"

await client.connect()

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <ArborProvider client={client}>
      <App />
    </ArborProvider>
  </StrictMode>
)
