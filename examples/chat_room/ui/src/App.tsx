import { useState } from "react"
import type { FormEvent } from "react"
import { useAsyncResult, useCommand, useStore, useStream } from "@arbor/react"

import type { ChatRoomCommands, ChatRoomState, MessageState, OnlineUser } from "./types"

const ROOT_STORE_ID = [] as const

export default function App() {
  const room = useStore<ChatRoomState>(ROOT_STORE_ID)
  const messages = useStream<MessageState>(ROOT_STORE_ID, "messages")
  const onlineUsers = useAsyncResult<OnlineUser[]>(ROOT_STORE_ID, "online_users")
  const reload = useCommand<ChatRoomCommands, "reload", Record<string, never>>(ROOT_STORE_ID, "reload")
  const refresh = useCommand<ChatRoomCommands, "refresh", Record<string, never>>(
    ROOT_STORE_ID,
    "refresh"
  )
  const sendMessage = useCommand<ChatRoomCommands, "send_message", { queued: boolean }>(
    ROOT_STORE_ID,
    "send_message"
  )

  const [body, setBody] = useState("")
  const [feedback, setFeedback] = useState("")
  const [busy, setBusy] = useState<"send" | "reload" | "refresh" | null>(null)

  if (!room) {
    return (
      <main className="shell">
        <section className="panel loading">Waiting for the chat room bootstrap patch…</section>
      </main>
    )
  }

  async function handleSend(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()

    const nextBody = body.trim()

    if (!nextBody) {
      setFeedback("Message body cannot be empty.")
      return
    }

    setBusy("send")

    try {
      const reply = await sendMessage({ body: nextBody })
      setFeedback(reply.queued ? "Message queued for async delivery." : "Send request returned.")
      setBody("")
    } catch (error) {
      setFeedback(error instanceof Error ? error.message : "Message send failed.")
    } finally {
      setBusy(null)
    }
  }

  async function runAction(
    action: "reload" | "refresh",
    command: (payload: Record<string, never>) => Promise<Record<string, never>>
  ) {
    setBusy(action)

    try {
      await command({})
      setFeedback(action === "reload" ? "Silent stream reload sent." : "Refresh command sent.")
    } catch (error) {
      setFeedback(error instanceof Error ? error.message : `${action} failed.`)
    } finally {
      setBusy(null)
    }
  }

  return (
    <main className="shell">
      <section className="hero">
        <p className="eyebrow">Arbor Example</p>
        <div className="hero-row">
          <div>
            <h1>Chat room</h1>
            <p className="hero-copy">
              Stream updates, async assigns, and async command replies over the same channel.
            </p>
          </div>
          <div className="badge">{messages.length} streamed messages</div>
        </div>
      </section>

      <section className="grid">
        <article className="panel">
          <div className="section-header">
            <h2>Online users</h2>
            <span className={`status-pill status-${onlineUsers?.status ?? "loading"}`}>
              {onlineUsers?.status ?? "loading"}
            </span>
          </div>

          {onlineUsers?.status === "ok" ? (
            <ul className="users">
              {onlineUsers.result.map((user) => (
                <li key={user.id}>
                  <strong>{user.name}</strong>
                  <span className="muted">{user.id}</span>
                </li>
              ))}
            </ul>
          ) : onlineUsers?.status === "loading" || !onlineUsers ? (
            <p className="muted">Loading online users…</p>
          ) : (
            <p className="muted">
              Presence fetch failed.
            </p>
          )}
        </article>

        <article className="panel">
          <h2>Controls</h2>
          <div className="actions">
            <button type="button" onClick={() => void runAction("reload", reload)} disabled={busy !== null}>
              {busy === "reload" ? "Reloading…" : "Reload stream"}
            </button>
            <button type="button" className="ghost" onClick={() => void runAction("refresh", refresh)} disabled={busy !== null}>
              {busy === "refresh" ? "Refreshing…" : "Refresh with async"}
            </button>
          </div>
          <p className="muted">Room id: <code>general</code></p>
          <p className="muted">Last send status: <strong>{renderSendStatus(room.last_send_status)}</strong></p>
        </article>
      </section>

      <section className="panel">
        <h2>Send message</h2>
        <form className="composer" onSubmit={handleSend}>
          <input
            value={body}
            onChange={(event) => setBody(event.target.value)}
            placeholder="Type a message"
          />
          <button type="submit" disabled={busy === "send"}>
            {busy === "send" ? "Sending…" : "Send"}
          </button>
        </form>

        {feedback ? <p className="notice">{feedback}</p> : null}
      </section>

      <section className="panel">
        <h2>Message stream</h2>

        {messages.length === 0 ? (
          <p className="empty">No messages have been materialized yet.</p>
        ) : (
          <ul className="messages">
            {messages.map((entry) => (
              <li key={entry.itemKey} className="message">
                <header>
                  <strong>{entry.item.sender}</strong>
                  <span className="muted">{entry.item.id}</span>
                </header>
                <p>{entry.item.body}</p>
              </li>
            ))}
          </ul>
        )}
      </section>
    </main>
  )
}

function renderSendStatus(status: ChatRoomState["last_send_status"]): string {
  switch (status.type) {
    case "idle":
      return "idle"
    case "ok":
      return `ok (${status.id})`
    case "failed":
      return `failed (${status.reason})`
  }
}
