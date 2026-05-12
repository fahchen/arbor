import { StrictMode } from "react"
import { createRoot } from "react-dom/client"

import App from "./App"
import { socket } from "./arbor"
import "./App.css"

// Connect the Phoenix socket before React mounts so StrictMode double-fire
// does not disrupt the WebSocket handshake (same pattern as chat_room).
socket.connect()

const root = createRoot(document.getElementById("root")!)

root.render(
  <StrictMode>
    <App />
  </StrictMode>
)
