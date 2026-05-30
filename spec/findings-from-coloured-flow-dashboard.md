---
title: Musubi 0.6 findings surfaced while integrating ColouredFlow Dashboard
date: 2026-05-30
status: open
reporter: ColouredFlow Dashboard epic (paseo-epic `cf-dashboard`)
musubi_version: 0.6.0
---

# Findings

Three concrete bugs discovered while building a real Phoenix application
(`coloured_flow/dashboard/`) on top of `musubi 0.6.0` + React 19. Each was
hit at runtime, not in unit tests, because the test suites mock `@musubi/client`
and never exercise the production code paths end-to-end. They are listed in the
order they were uncovered.

All three are reproducible against this dashboard:

- Worktree: `/Users/fahchen/.paseo/worktrees/22aafub0/feat-coloured-flow-dashboard`
- Branch: `feat-coloured-flow-dashboard`
- Commits demonstrating each fix (dashboard-side workarounds): `a7d2a29`,
  `73ad380`, `f01572b`.
- Live-runtime regression test: `dashboard/ui/scripts/smoke.mjs`. Reverting any
  of the three dashboard-side workarounds re-fails the smoke against
  `mix phx.server`.

Each finding includes a minimal reproduction, the dashboard-side workaround,
and one or more suggested upstream fix shapes.

---

## #1 — `Map.get(connect_info, :session, %{})` accepts `nil` and crashes the WS handshake

### Symptom

A Phoenix endpoint that mounts the Musubi socket with cookie-store session
options 500s the first WebSocket handshake from any browser that has not yet
established a session cookie. Server stack trace:

```
[error] ** (FunctionClauseError) no function clause matching in Musubi.Socket.put_session/2
    (musubi 0.6.0) lib/musubi/socket.ex:438: Musubi.Socket.put_session(%Musubi.Socket{...}, nil)
    (musubi 0.6.0) lib/musubi/transport/socket.ex:74: Musubi.Transport.Socket.build_connect_socket/2
    (musubi 0.6.0) lib/musubi/transport/socket.ex:83: Musubi.Transport.Socket.__connect__/4
    (phoenix 1.8.7) lib/phoenix/socket.ex:645: Phoenix.Socket.user_connect/6
```

The browser console reports the upgrade as `Error during WebSocket handshake:
Unexpected response code: 500`.

### Root cause

`lib/musubi/transport/socket.ex:71` reads the session via

```elixir
session = Map.get(connect_info, :session, %{})
```

The `Map.get/3` default only fires when the key is **missing**. Phoenix's
`Plug.Session.Cookie` produces `connect_info = %{session: nil}` on a cookieless
first visit (the cookie key is configured, just empty). So `session = nil`
falls through, and `lib/musubi/socket.ex:438` `Musubi.Socket.put_session/2`
crashes because its only clause is guarded by `is_map(session)`.

### Repro (minimal)

Phoenix endpoint mounts:

```elixir
@session_options [store: :cookie, key: "_demo_key", signing_salt: "anything"]

socket "/socket", DemoWeb.UserSocket,
  websocket: [connect_info: [session: @session_options]],
  longpoll: [connect_info: [session: @session_options]]
```

UserSocket:

```elixir
defmodule DemoWeb.UserSocket do
  use Musubi.Socket, roots: [DemoWeb.Stores.SomeStore]
end
```

A `curl` upgrade with the right Sec-WebSocket headers and **no Cookie** header
returns 500.

### Dashboard-side workaround

`a7d2a29 fix(dashboard): drop session connect_info so Musubi WS handshake
survives a cookieless first visit`. The dashboard has no auth and never
read the session, so it drops `connect_info: [session: ...]` entirely. Two
of the three arbor reference apps (`examples/poll_app`,
`examples/chat_room`) already mount the socket as plain `websocket: true`
for the same reason.

Three new ExUnit tests pin the regression at the endpoint config level
(see `dashboard/test/coloured_flow_dashboard_web/user_socket_test.exs`).

### Suggested upstream fix shapes (any one works)

1. Tighten the default at the call site to a nil-tolerant fallback:
   ```elixir
   session = connect_info |> Map.get(:session) |> Kernel.||(%{})
   ```
   No API change. Zero blast radius.
2. Relax `Musubi.Socket.put_session/2` to accept `nil` and normalize to
   `%{}`. Adds one tiny function clause; documents the contract.
3. Document the trap. Add a `guides/phoenix-setup.md` section saying
   "Do not pass `connect_info: [session: ...]` unless your `mount/1`
   reads the session; the cookie store yields `nil` on first visit and
   crashes `put_session/2`." This is the worst of the three — every
   subsequent integrator hits the same wall — but it is at least cheap.

A test would be a one-liner against `Musubi.Transport.Socket.__connect__/4`
fed `connect_info = %{session: nil}`.

---

## #2 — `@musubi/react` workspace devDep on `react ^18.3.0` traps consumers into bundling two React copies

### Symptom

A React 19 SPA consuming `@musubi/react` via a pnpm workspace link (the
arbor packages live at `packages/{client,react}` and are linked from
consumer apps) and built with Vite ships **two** React versions in the
production bundle. Cross-version reconciliation throws the minified React
error #525 inside the Suspense subtree on the first render.

Visible to the user as: `Connect failed: Minified React error #525; visit
https://react.dev/errors/525 for the full message or use the non-minified
dev environment for full errors and additional helpful warnings.`

The dashboard's `pnpm test` (Vitest + jsdom) never saw it because
`@musubi/client` is mocked.

### Root cause

`packages/react/package.json` lists `react ^18.3.0` and
`react-dom ^18.3.0` under `devDependencies`. In a pnpm workspace consumer,
pnpm installs `react@18.3.1` into the package's own `node_modules/`. Without
explicit dedupe configuration on the consumer's bundler, Vite resolves
`import "react"` from inside `@musubi/react/src/index.tsx` to the local
copy and bundles it alongside the consumer's own `react@19.x`. Element
created by `react@18` reaches the `react-dom@19` reconciler and
`throwOnInvalidObjectTypeImpl` throws #525.

### Repro (minimal)

Consumer `package.json` declares `react: ^19.2.0` and uses
`@musubi/react` via pnpm workspace (or `file:` link). Without `resolve.dedupe`
in `vite.config.ts`, scan the production bundle:

```sh
pnpm build
grep -oE '"1[89]\.[0-9]+\.[0-9]+"' priv/static/assets/index-*.js | sort -u
# observed: "18.3.1" + "19.2.6"
```

### Dashboard-side workaround

`73ad380 fix(dashboard): dedupe React so the SPA mounts against musubi 0.6's
workspace link`. One-line Vite config addition:

```ts
// vite.config.ts
export default defineConfig({
  resolve: { dedupe: ["react", "react-dom", "react/jsx-runtime"] },
  // ...
})
```

A live-runtime smoke (`dashboard/ui/scripts/smoke.mjs`) asserts that the
built bundle contains exactly one React major. Reverting the `resolve.dedupe`
block re-fails the smoke.

### Suggested upstream fix shapes (pick any)

1. Move React out of `devDependencies` entirely — every test in
   `packages/react/` should reach the React copy hoisted at the workspace
   root anyway. If the package needs React types at build time, prefer
   `peerDependencies` only.
2. Set `peerDependencies: { react: "^18.0.0 || ^19.0.0", react-dom: "^18.0.0 || ^19.0.0" }`
   and let the consumer satisfy them.
3. Document the trap in `README.md` and the `guides/client-and-react.md`
   guide: "Consumers MUST `resolve.dedupe: ['react', 'react-dom']` in Vite
   (or the equivalent for their bundler) when linking `@musubi/react` from
   a pnpm workspace."

(1) + (2) are the durable fixes. (3) is the cheap interim band-aid.

---

## #3 — `scheduleSuspenseOrphanSweep` races React 19's passive-effect commit and wedges any root mount in an infinite loop

### Symptom

A page using `useMusubiRootSuspense` to mount a Musubi root store under
React 19 enters an infinite mount/unmount loop. Visible to the user as
the Suspense fallback never resolving — `Loading live workitems…` in
the dashboard. Server-side: ~50% sustained BEAM CPU and tens of
thousands of `mount` + `unmount` Channel messages per minute against a
single root id. Log evidence from the dashboard's smoke environment:
~82k mount + ~82k unmount cycles at ~25 ms each.

This is reliably broken on React 19. It is not a flake.

### Root cause

`packages/react/src/index.tsx:598-620` — `scheduleSuspenseOrphanSweep`:

```ts
function scheduleSuspenseOrphanSweep(/* ... */) {
  shared.promise.then(sweep, sweep)
  // ... eventually setTimeout(fn, 0)
}
```

The sweep schedules `mounts.delete(key)` + `shared.value.unmount()` via
`setTimeout(0)` — a **macrotask**. React 19 schedules its passive-effect
commit (where `bumpMountRef` runs) via `MessageChannel`, also a macrotask
but with different priority. On Chrome/V8 the `setTimeout(0)` task is
consistently ordered ahead of the `MessageChannel` commit task. So the
sweep tears the entry down BEFORE the commit effect can bump the
refcount.

On the next render `ensureRootMount` (`packages/react/src/index.tsx:496-542`)
sees no entry, calls `connection.mountStore(...)`, and returns a fresh
unsettled `shared`. Suspense replays the render. The sweep schedules
again. Loop.

The only thing that keeps the cycle off the BEAM is the consumer never
loading the page.

### Repro (minimal)

A page that calls

```tsx
const { proxy, snapshot } = useMusubiRootSuspense({
  module: "DemoWeb.Stores.SomeRoot",
  id: "default",
})
```

under React 19 (`react@19.2.x`, `react-dom@19.2.x`) inside a single
Suspense boundary will spin forever. The server-side Page.Server logs
will show alternating `mount` and `unmount` messages at ~25 ms intervals.

### Dashboard-side workaround

`f01572b fix(dashboard): use useMusubiRoot to dodge musubi/react Suspense
sweep race`. Switch from `useMusubiRootSuspense` to `useMusubiRoot` and
render the loading state off `root.status === "loading"` instead of
through Suspense. `useMusubiRoot` mounts in a commit-phase `useEffect`,
calls `bumpMountRef` synchronously after the entry is created, and
never invokes the sweep helper.

The dashboard added live-runtime smoke coverage in
`dashboard/ui/scripts/smoke.mjs`: it opens a real Phoenix Socket, joins
`musubi:connection`, mounts `InboxStore`/`default`, waits for the
initial patch envelope, sends a SECOND mount on the same id, and asserts
the server rejects it with `"root already mounted"`. The broken Suspense
path would let the second mount succeed because the first never settled.

### Suggested upstream fix shapes (any one works)

1. Schedule the sweep behind a `requestAnimationFrame` so it lands AFTER
   the next paint, well after React's commit effects:
   ```ts
   requestAnimationFrame(() => setTimeout(sweep, 0))
   ```
   Same intent; correct ordering on every browser.
2. Mark the shared mount as consumed synchronously inside
   `useMusubiRootSuspense` once `sharedMount.settled` is true, and
   short-circuit the sweep on that flag.
3. Drop the sweep helper entirely and rely on `connection.mountStore`'s
   server-side timeout to garbage-collect orphaned mounts from Suspense
   renders that never commit.

None of these require an API change for consumers — `useMusubiRootSuspense`
stays the public hook.

A live-runtime regression test would mirror the dashboard's smoke: a
Node script that mounts a root twice and expects the second to be
rejected. The current `packages/react` unit suite cannot reproduce this
because it does not exercise a real Phoenix Channel.

---

## Cross-cutting observation

All three findings share one root cause: the existing test suites for
`@musubi/client` and `@musubi/react` mock the Phoenix Socket boundary,
so the production paths above were never exercised end-to-end. The
arbor reference apps under `examples/` work around #1 and #2
implicitly by configuring their endpoints and bundlers in the
narrow shapes that happen to dodge each trap, but no test pins those
shapes as required.

A small set of live-runtime smoke tests — mirroring
`dashboard/ui/scripts/smoke.mjs`, but living in arbor and run against a
known-good example app — would catch all three on the next regression.
The dashboard team is happy to upstream the script as a starting point.

## Contact

Findings raised from the ColouredFlow Dashboard epic.  Reach out via
the dashboard worktree for repros and timing traces.
