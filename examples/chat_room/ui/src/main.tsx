import { StrictMode } from "react"
import { createRoot } from "react-dom/client"
import { ArborProvider } from "@arbor/react"

import App from "./App"
import { connectArbor } from "./arbor"
import "./App.css"

const root = createRoot(document.getElementById("root")!)

try {
  const connection = await connectArbor()

  root.render(
    <StrictMode>
      <ArborProvider connection={connection}>
        <App />
      </ArborProvider>
    </StrictMode>
  )
} catch (error) {
  root.render(
    <div style={{ padding: 24, fontFamily: "system-ui" }}>
      <h1>Connect failed</h1>
      <p>
        The Arbor demo backend isn&apos;t reachable. Start the Phoenix endpoint with{" "}
        <code>mix run --no-halt</code> and reload.
      </p>
      <pre style={{ whiteSpace: "pre-wrap", color: "#a00" }}>{String(error)}</pre>
    </div>
  )
}
