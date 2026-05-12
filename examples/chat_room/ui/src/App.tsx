import { useEffect, useState } from "react"
import type { SubmitEvent } from "react"
import { useArborCommand, useArborRoot, useArborSnapshot } from "@arbor/react"

type Registry = Arbor.Stores
type RootModule = "MyApp.Stores.ChatRoomStore"

export default function App() {
  const root = useArborRoot<Registry, RootModule>()
  const room = useArborSnapshot(root)

  const setName = useArborCommand(root, "set_name")
  const sendMessage = useArborCommand(root, "send_message")

  const [nameDraft, setNameDraft] = useState("")
  const [body, setBody] = useState("")
  const [feedback, setFeedback] = useState("")
  const [busy, setBusy] = useState<"name" | "send" | null>(null)

  const currentUser = room.current_user
  const onlineUsers = room.online_users
  const messages = room.messages

  useEffect(() => {
    setNameDraft(currentUser.name)
  }, [currentUser.name])

  async function handleSetName(event: SubmitEvent<HTMLFormElement>) {
    event.preventDefault()

    const nextName = nameDraft.trim()

    if (!nextName) {
      setFeedback("Name cannot be empty.")
      return
    }

    setBusy("name")

    try {
      const reply = await setName({ name: nextName })
      setFeedback(`Name updated to ${reply.name}.`)
    } catch (error) {
      setFeedback(error instanceof Error ? error.message : "Name update failed.")
    } finally {
      setBusy(null)
    }
  }

  async function handleSend(event: SubmitEvent<HTMLFormElement>) {
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
          <div className="badge">{messages.length} recent messages</div>
        </div>
      </section>

      <section className="grid">
        <article className="panel">
          <div className="section-header">
            <h2>Online users</h2>
            <span className={`status-pill status-${onlineUsers.status}`}>{onlineUsers.status}</span>
          </div>

          {onlineUsers.status === "ok" ? (
            <ul className="users">
              {onlineUsers.data.map((user) => (
                <li key={user.id}>
                  <strong>{user.name}</strong>
                  <span className="muted">{user.id}</span>
                </li>
              ))}
            </ul>
          ) : onlineUsers.status === "loading" ? (
            <p className="muted">Loading online users…</p>
          ) : (
            <p className="muted">Presence fetch failed.</p>
          )}
        </article>

        <article className="panel">
          <h2>Your profile</h2>
          <form className="composer" onSubmit={handleSetName}>
            <input
              value={nameDraft}
              onChange={(event) => setNameDraft(event.target.value)}
              placeholder="Display name"
            />
            <button type="submit" disabled={busy === "name"}>
              {busy === "name" ? "Saving…" : "Set name"}
            </button>
          </form>
          <p className="muted">
            Room id: <code>general</code>
          </p>
          <p className="muted">
            Signed in as <strong>{currentUser.name}</strong>
          </p>
          <p className="muted">
            Last send status: <strong>{renderSendStatus(room.last_send_status)}</strong>
          </p>
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
            {messages.map((message) => (
              <li key={message.id} className="message">
                <header>
                  <strong>{message.sender}</strong>
                  <span className="muted">{message.id}</span>
                </header>
                <p>{message.body}</p>
              </li>
            ))}
          </ul>
        )}
      </section>
    </main>
  )
}

function renderSendStatus(status: {
  type: "idle" | "ok" | "failed"
  id?: string
  reason?: string
}): string {
  switch (status.type) {
    case "idle":
      return "idle"
    case "ok":
      return `ok (${status.id ?? ""})`
    case "failed":
      return `failed (${status.reason ?? ""})`
  }
}
