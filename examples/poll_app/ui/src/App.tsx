import { useEffect, useState } from "react"
import type { SubmitEvent } from "react"
import { ArborProvider, useArborCommand, useArborRoot, useArborSnapshot } from "@arbor/react"

import { connectDashboard, connectPollRoom } from "./arbor"

type Registry = Arbor.Stores

// ---------------------------------------------------------------------------
// Root shell — connects the Phoenix socket once, then switches between pages
// ---------------------------------------------------------------------------

export default function App() {
  const [page, setPage] = useState<"dashboard" | { pollId: string }>("dashboard")

  // socket.connect() is called once in main.tsx before React mounts.
  // Calling it inside a useEffect causes StrictMode to double-fire
  // disconnect→connect, killing the WebSocket handshake.

  if (page === "dashboard") {
    return (
      <div className="page-enter" key="dashboard">
        <DashboardPage onEnterPoll={(pollId) => setPage({ pollId })} />
      </div>
    )
  }

  return (
    <div className="page-enter" key={page.pollId}>
      <PollRoomPage
        pollId={page.pollId}
        onBack={() => setPage("dashboard")}
      />
    </div>
  )
}

// ---------------------------------------------------------------------------
// Dashboard page — child store composition (DashboardStore + DashboardHeaderStore)
// ---------------------------------------------------------------------------

function DashboardPage({ onEnterPoll }: { onEnterPoll: (pollId: string) => void }) {
  const [store, setStore] = useState<Awaited<ReturnType<typeof connectDashboard>> | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    connectDashboard().then((s) => { if (!cancelled) setStore(s) }).catch((e) => { if (!cancelled) setError(String(e)) })
    return () => { cancelled = true }
  }, [])

  if (error) return <ConnectionError error={error} />
  if (!store) return <LoadingShell />

  return (
    <ArborProvider store={store}>
      <DashboardView onEnterPoll={onEnterPoll} />
    </ArborProvider>
  )
}

function DashboardView({ onEnterPoll }: { onEnterPoll: (pollId: string) => void }) {
  const root = useArborRoot<Registry, "MyApp.Stores.DashboardStore">()
  const page = useArborSnapshot(root)

  const header = page.header
  const polls = page.polls ?? []

  return (
    <main className="dashboard-shell">
      <header className="dash-hero">
        <div className="dash-hero-copy">
          <p className="eyebrow">Arbor Live Polling</p>
          <h1>VoteCast</h1>
          <p>Real-time polls with server-authoritative state. <span className="live-dot">Live</span> Open a second browser tab to see cross-user updates.</p>
        </div>

        {header ? (
          <div className="dash-metrics" aria-label="Poll counts">
            <MetricBadge label="Active" value={header.active_count} tone="active" />
            <MetricBadge label="Closed" value={header.closed_count} tone="closed" />
            <MetricBadge label="Total" value={header.total_count} tone="total" />
          </div>
        ) : null}
      </header>

      <section className="poll-grid" aria-label="Available polls">
        {polls.length === 0 ? (
          <div className="empty-state">
            <div className="empty-mark">?</div>
            <p>No polls available.</p>
          </div>
        ) : (
          polls.map((poll) => (
            <button
              key={poll.id}
              className="poll-card"
              onClick={() => onEnterPoll(poll.id)}
            >
              <div className="poll-card-header">
                <h2>{poll.title}</h2>
                <span className={`status-pill status-${poll.status}`}>
                  {poll.status}
                </span>
              </div>
              <div className="poll-card-meta">
                <span>{poll.option_count} options</span>
                <span>{poll.total_votes} votes</span>
              </div>
              <div className="poll-card-cta">
                {poll.status === "active" ? "Vote now →" : "View results →"}
              </div>
            </button>
          ))
        )}
      </section>
    </main>
  )
}

function MetricBadge({ label, value, tone }: { label: string; value: number; tone: string }) {
  return (
    <div className={`metric-badge metric-${tone}`}>
      <span className="metric-value">{value}</span>
      <span className="metric-label">{label}</span>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Poll room page — streams + async + PubSub
// ---------------------------------------------------------------------------

function PollRoomPage({ pollId, onBack }: { pollId: string; onBack: () => void }) {
  const [store, setStore] = useState<Awaited<ReturnType<typeof connectPollRoom>> | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    connectPollRoom(pollId).then((s) => { if (!cancelled) setStore(s) }).catch((e) => { if (!cancelled) setError(String(e)) })
    return () => { cancelled = true }
  }, [pollId])

  if (error) return <ConnectionError error={error} />
  if (!store) return <LoadingShell />

  return (
    <ArborProvider store={store}>
      <PollRoomView pollId={pollId} onBack={onBack} />
    </ArborProvider>
  )
}

function PollRoomView({ pollId, onBack }: { pollId: string; onBack: () => void }) {
  const root = useArborRoot<Registry, "MyApp.Stores.PollRoomStore">()
  const page = useArborSnapshot(root)

  const voteCmd = useArborCommand(root, "vote")
  const resetVoteCmd = useArborCommand(root, "reset_vote")
  const toggleStatusCmd = useArborCommand(root, "toggle_status")

  const [feedback, setFeedback] = useState("")
  const [busy, setBusy] = useState(false)

  const poll = page.poll
  const options = page.options ?? []
  const userVote = page.user_vote
  const hasVoted = userVote?.status === "ok" && userVote.data != null
  const userVotedOptionId = hasVoted ? userVote.data : null
  const isClosed = poll?.status === "closed"
  const totalVotes = poll?.total_votes ?? 0

  function spawnParticles(element: HTMLElement) {
    const rect = element.getBoundingClientRect()
    const cx = rect.left + rect.width / 2
    const cy = rect.top + rect.height / 2
    const count = 10

    for (let i = 0; i < count; i++) {
      const particle = document.createElement("div")
      particle.className = "vote-particle"
      const angle = (Math.PI * 2 * i) / count + Math.random() * 0.4
      const distance = 30 + Math.random() * 50
      particle.style.cssText = `
        left: ${cx}px;
        top: ${cy}px;
        --px: ${Math.cos(angle) * distance}px;
        --py: ${Math.sin(angle) * distance}px;
      `
      document.body.appendChild(particle)
      particle.addEventListener("animationend", () => particle.remove())
    }
  }

  async function handleVote(optionId: string, target: HTMLElement) {
    if (isClosed || busy) return
    setBusy(true)

    try {
      const reply = await voteCmd({ option_id: optionId }) as { status: string }
      if (reply.status === "closed") setFeedback("Poll is closed.")
      else if (reply.status === "voted") {
        setFeedback("Vote cast.")
        spawnParticles(target)
      }
    } catch (e) {
      setFeedback(e instanceof Error ? e.message : "Vote failed.")
    } finally {
      setBusy(false)
    }
  }

  async function handleResetVote() {
    if (busy) return
    setBusy(true)

    try {
      await resetVoteCmd({})
      setFeedback("Vote removed.")
    } catch (e) {
      setFeedback(e instanceof Error ? e.message : "Reset failed.")
    } finally {
      setBusy(false)
    }
  }

  async function handleToggleStatus() {
    try {
      await toggleStatusCmd({})
    } catch (e) {
      setFeedback(e instanceof Error ? e.message : "Toggle failed.")
    }
  }

  return (
    <main className="room-shell">
      <header className="room-header">
        <button type="button" className="back-btn" onClick={onBack}>
          ← Back
        </button>

        <div className="room-title-block">
          <div className="room-title-row">
            <h1>{poll?.title ?? "Loading..."}</h1>
            {poll ? (
              <span className={`status-pill status-${poll.status}`}>
                {poll.status}
              </span>
            ) : null}
          </div>
          <div className="room-meta">
            <span>{options.length} options</span>
            <span>{totalVotes} total votes</span>
          </div>
        </div>

        <button
          type="button"
          className="toggle-btn"
          onClick={() => void handleToggleStatus()}
        >
          {isClosed ? "Reopen poll" : "Close poll"}
        </button>
      </header>

      <section className="options-panel" aria-label="Poll options">
        {options.length === 0 ? (
          <div className="empty-state">
            <div className="empty-mark">+</div>
            <p>No options yet.</p>
          </div>
        ) : (
          <ul className="options-list">
            {options.map((option) => {
              const pct = totalVotes > 0 ? (option.vote_count / totalVotes) * 100 : 0
              const isMine = option.id === userVotedOptionId

              return (
                <li key={option.id} className={`option-item ${isMine ? "option-mine" : ""}`}>
                  <button
                    type="button"
                    className="option-vote-area"
                    onClick={(e) => void handleVote(option.id, e.currentTarget)}
                    disabled={isClosed || busy}
                  >
                    <div className="option-info">
                      <span className="option-label">{option.label}</span>
                      <span className="option-count">
                        {option.vote_count} {option.vote_count === 1 ? "vote" : "votes"}
                      </span>
                    </div>

                    <div className="option-bar-track">
                      <div
                        className="option-bar-fill"
                        style={{ width: `${pct}%` }}
                      />
                    </div>

                    <span className="option-pct">{pct.toFixed(1)}%</span>
                  </button>

                  {isMine ? (
                    <span className="voted-badge" aria-label="Your vote">✓</span>
                  ) : null}
                </li>
              )
            })}
          </ul>
        )}
      </section>

      <footer className="vote-footer">
        <div className="vote-actions">
          {userVote?.status === "loading" ? (
            <p className="vote-state">Checking your vote...</p>
          ) : hasVoted ? (
            <>
              <p className="vote-state">
                You voted for{" "}
                <strong>
                  {options.find((o) => o.id === userVotedOptionId)?.label ?? "an option"}
                </strong>
              </p>
              <button
                type="button"
                className="reset-btn"
                onClick={() => void handleResetVote()}
                disabled={busy || isClosed}
              >
                Remove my vote
              </button>
            </>
          ) : (
            <p className="vote-state">
              {isClosed ? "Poll closed" : "Cast your vote by clicking an option above"}
            </p>
          )}

          {userVote?.status === "failed" ? (
            <p className="vote-error">
              Could not load your vote. {String(userVote.reason ?? "")}
            </p>
          ) : null}
        </div>

        {feedback ? (
          <p className="feedback" role="status" aria-live="polite">
            {feedback}
          </p>
        ) : null}
      </footer>
    </main>
  )
}

// ---------------------------------------------------------------------------
// Shared shell components
// ---------------------------------------------------------------------------

function ConnectionError({ error }: { error: string }) {
  return (
    <div className="connect-error">
      <h1>Connect failed</h1>
      <p>
        The VoteCast backend isn&apos;t reachable. Start it with{" "}
        <code>cd examples/poll_app && mix run --no-halt</code> and reload.
      </p>
      <pre>{error}</pre>
    </div>
  )
}

function LoadingShell() {
  return (
    <div className="loading-shell">
      <div className="loading-spinner" />
      <p>Connecting to VoteCast...</p>
    </div>
  )
}
