import { act, render, screen } from "@testing-library/react"
import * as React from "react"
import { describe, expect, test, vi } from "vitest"

import {
  createMusubi,
  MusubiCommandError,
  keyOf,
  shallowEqual,
  __pendingRootMountsForTests,
  __runSuspenseOrphanSweep
} from "../src"
import * as clientModule from "@musubi/client"

import { FakeStoreProxy } from "./setup"

import type {
  MountStoreOptions,
  MountedStore,
  MusubiConnection,
  StoreModule,
  StoreProxy
} from "../src"

void React

type ReactTestStores = {
  "React.Test.Root": Musubi.StoreDef<
    "React.Test.Root",
    {
      title: string
      counter: number
    },
    {
      rename: { payload: { title: string }; reply: { ok: true } }
    }
  >
}

type Root = "React.Test.Root"

const {
  MusubiProvider,
  useMusubiCommand,
  useMusubiConnection,
  useMusubiConnectionStatus,
  useMusubiRoot,
  useMusubiRootSuspense,
  useMusubiSnapshot
} = createMusubi<ReactTestStores>()

function buildProxy(title = "Inbox", counter = 0): FakeStoreProxy<Root, ReactTestStores> {
  return new FakeStoreProxy<Root, ReactTestStores>({
    __musubi_store_id__: [],
    title,
    counter
  })
}

describe("MusubiProvider + useMusubiRoot", () => {
  test("exposes the Musubi connection to descendants", () => {
    const fake = buildProxy()
    const connection = new FakeMusubiConnection(fake.asProxy())
    let observed: unknown = null

    function Reader() {
      observed = useMusubiConnection()
      return <span>ready</span>
    }

    render(
      <MusubiProvider connection={connection}>
        <Reader />
      </MusubiProvider>
    )

    expect(screen.getByText("ready")).toBeTruthy()
    expect(observed).toBe(connection)
  })

  test("useMusubiConnection throws outside a provider", () => {
    function Reader() {
      useMusubiConnection()
      return null
    }

    const originalError = console.error
    const preventExpectedError = (event: ErrorEvent) => {
      if (
        event.error instanceof Error &&
        event.error.message.startsWith("useMusubiConnection must be used inside <MusubiProvider>")
      ) {
        event.preventDefault()
      }
    }

    console.error = () => {}
    window.addEventListener("error", preventExpectedError)

    try {
      render(
        <TestErrorBoundary>
          <Reader />
        </TestErrorBoundary>
      )

      expect(
        screen.getByText(/useMusubiConnection must be used inside <MusubiProvider>/)
      ).toBeTruthy()
    } finally {
      window.removeEventListener("error", preventExpectedError)
      console.error = originalError
    }
  })

  test("useMusubiRoot mounts and unmounts a root store", async () => {
    const fake = buildProxy()
    const connection = new FakeMusubiConnection(fake.asProxy())
    const params = { filter: "active" }

    function Reader() {
      const root = useMusubiRoot({
        module: "React.Test.Root",
        id: "dashboard-1",
        params
      })

      if (root.status !== "ready") {
        return <span>{root.status}</span>
      }

      return <span>{root.store.snapshot().title}</span>
    }

    const result = render(
      <MusubiProvider connection={connection}>
        <Reader />
      </MusubiProvider>
    )

    expect(screen.getByText("loading")).toBeTruthy()
    expect(await screen.findByText("Inbox")).toBeTruthy()
    expect(connection.mounts).toEqual([
      { module: "React.Test.Root", id: "dashboard-1", params: { filter: "active" } }
    ])

    result.unmount()

    await act(async () => {
      await flushTimers()
    })

    expect(connection.unmounts).toEqual(["dashboard-1"])
  })

  test("useMusubiRoot reuses a pending mount during StrictMode effect replay", async () => {
    const fake = buildProxy()
    const connection = new FakeMusubiConnection(fake.asProxy())
    const mount = deferred<StoreProxy<Root, ReactTestStores>>()
    connection.mountResult = mount.promise

    function Reader() {
      const root = useMusubiRoot({
        module: "React.Test.Root",
        id: "dashboard-1"
      })

      if (root.status !== "ready") {
        return <span>{root.status}</span>
      }

      return <span>{root.store.snapshot().title}</span>
    }

    const result = render(
      <React.StrictMode>
        <MusubiProvider connection={connection}>
          <Reader />
        </MusubiProvider>
      </React.StrictMode>
    )

    expect(screen.getByText("loading")).toBeTruthy()
    expect(connection.mounts).toEqual([{ module: "React.Test.Root", id: "dashboard-1" }])

    await act(async () => {
      mount.resolve(fake.asProxy())
      await mount.promise
    })

    expect(await screen.findByText("Inbox")).toBeTruthy()
    expect(connection.unmounts).toEqual([])

    result.unmount()

    await act(async () => {
      await flushTimers()
    })

    expect(connection.unmounts).toEqual(["dashboard-1"])
  })

  test("useMusubiRoot does not unmount another root when mount fails", async () => {
    const fake = buildProxy()
    const connection = new FakeMusubiConnection(fake.asProxy())
    connection.mountError = new Error("Root id is already mounted: dashboard-1")

    function Reader() {
      const root = useMusubiRoot({
        module: "React.Test.Root",
        id: "dashboard-1"
      })

      if (root.status === "error") {
        return <span>{root.error.message}</span>
      }

      return <span>{root.status}</span>
    }

    const result = render(
      <MusubiProvider connection={connection}>
        <Reader />
      </MusubiProvider>
    )

    expect(await screen.findByText("Root id is already mounted: dashboard-1")).toBeTruthy()

    result.unmount()

    expect(connection.unmounts).toEqual([])
  })
})

describe("useMusubiSnapshot", () => {
  test("re-renders on snapshot updates", () => {
    const fake = buildProxy("Inbox", 0)
    let renders = 0

    function Reader() {
      renders += 1
      const snapshot = useMusubiSnapshot(fake.asProxy())
      return <span>{snapshot.counter}</span>
    }

    render(<Reader />)
    expect(screen.getByText("0")).toBeTruthy()
    expect(renders).toBe(1)

    act(() => {
      fake.setSnapshot({ __musubi_store_id__: [], title: "Inbox", counter: 1 })
    })

    expect(screen.getByText("1")).toBeTruthy()
    expect(renders).toBe(2)
  })

  test("selector + equalityFn suppresses unrelated re-renders", () => {
    const fake = buildProxy("Inbox", 0)
    let renders = 0

    function Reader() {
      renders += 1
      const title = useMusubiSnapshot(fake.asProxy(), (s) => s.title)
      return <span>{title}</span>
    }

    render(<Reader />)
    expect(renders).toBe(1)

    act(() => {
      fake.setSnapshot({ __musubi_store_id__: [], title: "Inbox", counter: 5 })
    })

    expect(screen.getByText("Inbox")).toBeTruthy()
    expect(renders).toBe(1)
  })
})

describe("useMusubiCommand", () => {
  type Cmd = ReturnType<
    typeof useMusubiCommand<"React.Test.Root", "rename">
  >

  function CommandHarness({
    proxy,
    onResult
  }: {
    proxy: ReturnType<FakeStoreProxy<Root, ReactTestStores>["asProxy"]>
    onResult: (cmd: Cmd) => void
  }) {
    const cmd = useMusubiCommand(proxy, "rename")
    onResult(cmd)
    return (
      <span>
        {cmd.isPending ? "pending" : cmd.error ? `err:${cmd.error.kind}` : cmd.data ? "ok" : "idle"}
      </span>
    )
  }

  test("dispatch identity is stable across renders for same proxy+name", () => {
    const fake = buildProxy()
    let captured: Cmd | undefined
    function Reader() {
      captured = useMusubiCommand(fake.asProxy(), "rename")
      return null
    }
    const { rerender } = render(<Reader />)
    const first = captured!.dispatch
    rerender(<Reader />)
    expect(captured!.dispatch).toBe(first)
  })

  test("isPending + data populate on success", async () => {
    const fake = buildProxy()
    const gate = deferred<{ ok: true }>()
    fake.onDispatch(() => gate.promise)
    let cmd: Cmd | undefined
    render(<CommandHarness proxy={fake.asProxy()} onResult={(c) => (cmd = c)} />)

    let dispatchPromise: Promise<unknown> | undefined
    await act(async () => {
      dispatchPromise = cmd!.dispatch({ title: "x" })
    })
    expect(cmd!.isPending).toBe(true)

    await act(async () => {
      gate.resolve({ ok: true })
      await dispatchPromise
    })
    expect(cmd!.isPending).toBe(false)
    expect(cmd!.data).toEqual({ ok: true })
    expect(cmd!.error).toBeNull()
  })

  test("error is MusubiCommandError on failure", async () => {
    const fake = buildProxy()
    const original = new MusubiCommandError({
      kind: "failed",
      command: "rename",
      storeId: [],
      reply: { code: "boom" }
    })
    fake.onDispatch(async () => {
      throw original
    })
    let cmd: Cmd | undefined
    render(<CommandHarness proxy={fake.asProxy()} onResult={(c) => (cmd = c)} />)

    await act(async () => {
      await cmd!.dispatch({ title: "x" }).catch(() => undefined)
    })
    expect(cmd!.error).toBe(original)
    expect(cmd!.error?.code).toBe("boom")
    expect(cmd!.isPending).toBe(false)
  })

  test("non-MusubiCommandError throws are wrapped with structured fields + cause", async () => {
    const fake = buildProxy()
    const raw = new Error("network exploded")
    fake.onDispatch(async () => {
      throw raw
    })
    let cmd: Cmd | undefined
    render(<CommandHarness proxy={fake.asProxy()} onResult={(c) => (cmd = c)} />)

    await act(async () => {
      await cmd!.dispatch({ title: "x" }).catch(() => undefined)
    })
    expect(cmd!.error).toBeInstanceOf(MusubiCommandError)
    expect(cmd!.error?.kind).toBe("failed")
    expect(cmd!.error?.command).toBe("rename")
    expect(cmd!.error?.storeId).toEqual([])
    expect((cmd!.error as Error & { cause?: unknown }).cause).toBe(raw)
  })

  test("reset() clears state", async () => {
    const fake = buildProxy()
    fake.onDispatch(async () => ({ ok: true as const }))
    let cmd: Cmd | undefined
    render(<CommandHarness proxy={fake.asProxy()} onResult={(c) => (cmd = c)} />)
    await act(async () => {
      await cmd!.dispatch({ title: "x" })
    })
    expect(cmd!.data).toEqual({ ok: true })
    await act(async () => {
      cmd!.reset()
    })
    expect(cmd!.data).toBeNull()
    expect(cmd!.error).toBeNull()
    expect(cmd!.isPending).toBe(false)
  })

  test("overlapping dispatches: only latest commits state", async () => {
    const fake = buildProxy()
    const calls: Array<{ payload: unknown; gate: ReturnType<typeof deferred<{ tag: string }>> }> = []
    fake.onDispatch(async (_name, payload) => {
      const gate = deferred<{ tag: string }>()
      calls.push({ payload, gate })
      return gate.promise
    })
    let cmd: Cmd | undefined
    render(<CommandHarness proxy={fake.asProxy()} onResult={(c) => (cmd = c)} />)

    let p1: Promise<unknown> | undefined
    let p2: Promise<unknown> | undefined
    await act(async () => {
      p1 = cmd!.dispatch({ title: "a" }).catch(() => undefined)
      p2 = cmd!.dispatch({ title: "b" }).catch(() => undefined)
    })

    await act(async () => {
      calls[1]!.gate.resolve({ tag: "second" })
      await p2
    })
    expect(cmd!.data).toEqual({ tag: "second" })
    expect(cmd!.isPending).toBe(false)

    await act(async () => {
      calls[0]!.gate.resolve({ tag: "first" })
      await p1
    })
    expect(cmd!.data).toEqual({ tag: "second" })
  })

  test("reset() while in-flight invalidates the dispatch", async () => {
    const fake = buildProxy()
    const gate = deferred<{ ok: true }>()
    fake.onDispatch(() => gate.promise)
    let cmd: Cmd | undefined
    render(<CommandHarness proxy={fake.asProxy()} onResult={(c) => (cmd = c)} />)

    let p: Promise<unknown> | undefined
    await act(async () => {
      p = cmd!.dispatch({ title: "x" }).catch(() => undefined)
    })
    expect(cmd!.isPending).toBe(true)

    await act(async () => {
      cmd!.reset()
    })
    expect(cmd!.isPending).toBe(false)
    expect(cmd!.data).toBeNull()

    await act(async () => {
      gate.resolve({ ok: true })
      await p
    })
    expect(cmd!.data).toBeNull()
    expect(cmd!.isPending).toBe(false)
  })

  test("MusubiCommandError.is detects cross-module instances", async () => {
    vi.resetModules()
    const fresh = await import("@musubi/client")
    const other = new fresh.MusubiCommandError({
      kind: "failed", command: "rename", storeId: [], reply: { code: "x" }
    })
    expect(MusubiCommandError.is(other)).toBe(true)
  })
})

class FakeMusubiConnection implements MusubiConnection<ReactTestStores> {
  readonly topic = "musubi:connection"
  readonly mounts: Array<MountStoreOptions<Root, ReactTestStores>> = []
  readonly unmounts: string[] = []
  disconnected = false
  mountError: Error | null = null
  mountErrors: Array<Error | null> = []
  mountResult: Promise<StoreProxy<Root, ReactTestStores>> | null = null
  mountResults: Array<Promise<StoreProxy<Root, ReactTestStores>>> = []

  constructor(private readonly store: StoreProxy<Root, ReactTestStores>) {}

  async mountStore<M extends StoreModule<ReactTestStores>>(
    options: MountStoreOptions<M, ReactTestStores>
  ): Promise<MountedStore<M, ReactTestStores>> {
    this.mounts.push(options as unknown as MountStoreOptions<Root, ReactTestStores>)

    const perCallError = this.mountErrors.shift()
    const err = perCallError !== undefined ? perCallError : this.mountError
    if (err) {
      throw err
    }

    const perCall = this.mountResults.shift()
    const promise = perCall ?? this.mountResult
    const proxy = promise
      ? ((await promise) as unknown as StoreProxy<M, ReactTestStores>)
      : (this.store as unknown as StoreProxy<M, ReactTestStores>)

    return {
      store: proxy,
      unmount: async () => {
        this.unmounts.push(options.id)
      }
    }
  }

  async disconnect(): Promise<void> {
    this.disconnected = true
  }
}

function deferred<T>(): {
  promise: Promise<T>
  resolve: (value: T) => void
  reject: (reason?: unknown) => void
} {
  let resolve: (value: T) => void = () => {}
  let reject: (reason?: unknown) => void = () => {}
  const promise = new Promise<T>((promiseResolve, promiseReject) => {
    resolve = promiseResolve
    reject = promiseReject
  })

  return { promise, resolve, reject }
}

function flushTimers(): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, 0)
  })
}

class TestErrorBoundary extends React.Component<
  { children: React.ReactNode },
  { message: string | null }
> {
  state: { message: string | null } = { message: null }

  static getDerivedStateFromError(error: Error): { message: string } {
    return { message: error.message }
  }

  render() {
    if (this.state.message) {
      return <span>{this.state.message}</span>
    }

    return this.props.children
  }
}

// ---------------------------------------------------------------------------
// useMusubiRootSuspense
// ---------------------------------------------------------------------------

describe("useMusubiRootSuspense", () => {
  test("loading suspends, then resolves to ready store", async () => {
    const fake = buildProxy()
    const connection = new FakeMusubiConnection(fake.asProxy())
    const gate = deferred<StoreProxy<Root, ReactTestStores>>()
    connection.mountResult = gate.promise

    function Reader() {
      const store = useMusubiRootSuspense({ module: "React.Test.Root", id: "sus-1" })
      return <span>{store.snapshot().title}</span>
    }

    render(
      <MusubiProvider connection={connection}>
        <React.Suspense fallback={<span>suspending</span>}>
          <Reader />
        </React.Suspense>
      </MusubiProvider>
    )

    expect(screen.getByText("suspending")).toBeTruthy()

    await act(async () => {
      gate.resolve(fake.asProxy())
      await gate.promise
    })

    expect(await screen.findByText("Inbox")).toBeTruthy()
  })

  test("mount failure is caught by an error boundary", async () => {
    const fake = buildProxy()
    const connection = new FakeMusubiConnection(fake.asProxy())
    connection.mountError = new Error("boom-suspense")

    function Reader() {
      const store = useMusubiRootSuspense({ module: "React.Test.Root", id: "sus-fail" })
      return <span>{store.snapshot().title}</span>
    }

    const originalError = console.error
    console.error = () => {}
    try {
      render(
        <MusubiProvider connection={connection}>
          <TestErrorBoundary>
            <React.Suspense fallback={<span>load</span>}>
              <Reader />
            </React.Suspense>
          </TestErrorBoundary>
        </MusubiProvider>
      )

      expect(await screen.findByText("boom-suspense")).toBeTruthy()
    } finally {
      console.error = originalError
    }
  })

  test("cross-variant cache: root + suspense share one server mount", async () => {
    const fake = buildProxy()
    const connection = new FakeMusubiConnection(fake.asProxy())

    function RegularReader() {
      const root = useMusubiRoot({ module: "React.Test.Root", id: "shared-1" })
      return <span>regular:{root.status}</span>
    }

    function SuspenseReader() {
      const store = useMusubiRootSuspense({ module: "React.Test.Root", id: "shared-1" })
      return <span>suspense:{store.snapshot().title}</span>
    }

    const result = render(
      <MusubiProvider connection={connection}>
        <React.Suspense fallback={<span>fallback</span>}>
          <RegularReader />
          <SuspenseReader />
        </React.Suspense>
      </MusubiProvider>
    )

    await screen.findByText("suspense:Inbox")
    expect(connection.mounts.length).toBe(1)

    result.unmount()
    await act(async () => {
      await flushTimers()
    })
    expect(connection.unmounts).toEqual(["shared-1"])
  })

  test("suspense unmount before resolve cleans up (no leak)", async () => {
    const fake = buildProxy()
    const connection = new FakeMusubiConnection(fake.asProxy())
    const gate = deferred<StoreProxy<Root, ReactTestStores>>()
    connection.mountResult = gate.promise

    function Reader() {
      const store = useMusubiRootSuspense({ module: "React.Test.Root", id: "orphan-1" })
      return <span>{store.snapshot().title}</span>
    }

    const result = render(
      <MusubiProvider connection={connection}>
        <React.Suspense fallback={<span>load</span>}>
          <Reader />
        </React.Suspense>
      </MusubiProvider>
    )

    expect(screen.getByText("load")).toBeTruthy()
    result.unmount()

    await act(async () => {
      gate.resolve(fake.asProxy())
      await gate.promise
      await flushTimers()
    })

    // The FinalizationRegistry safety net unmounts the orphaned root once
    // the discarded fiber's hook state — including the per-render token —
    // is GC'd. Real browsers collect on their own schedule; the test runs
    // with `--expose-gc` (see vite.config.ts) so we can drive it
    // deterministically here.
    const triggerGc = (globalThis as unknown as { gc?: () => void }).gc
    if (typeof triggerGc !== "function") {
      throw new Error("node --expose-gc is required to exercise the Suspense orphan sweep")
    }
    for (let i = 0; i < 20; i++) {
      triggerGc()
      // Yield to microtasks + the FinalizationRegistry queue (which runs on
      // its own task after GC).
      await new Promise((resolve) => setTimeout(resolve, 0))
      if (connection.unmounts.length > 0) break
    }

    expect(connection.unmounts).toEqual(["orphan-1"])
  })

  test("orphan sweep bails when a newer render supersedes the lease", async () => {
    // Drive the lease/generation check in `__runSuspenseOrphanSweep`
    // directly. The render is still suspended (gate never resolves), so
    // `shared.refs === 0` and the only thing that can short-circuit the
    // sweep is the lease check itself — exactly the path Codex flagged
    // as previously unexercised.
    const fake = buildProxy()
    const connection = new FakeMusubiConnection(fake.asProxy())
    const gate = deferred<StoreProxy<Root, ReactTestStores>>()
    connection.mountResult = gate.promise

    function Reader() {
      const store = useMusubiRootSuspense({ module: "React.Test.Root", id: "lease-1" })
      return <span>{store.snapshot().title}</span>
    }

    const result = render(
      <MusubiProvider connection={connection}>
        <React.Suspense fallback={<span>load</span>}>
          <Reader />
        </React.Suspense>
      </MusubiProvider>
    )

    const mounts = __pendingRootMountsForTests.get(
      connection as unknown as MusubiConnection<unknown>
    )!
    const key = "lease-1|React.Test.Root|null"
    const shared = mounts.get(key)!
    expect(shared.refs).toBe(0)

    // Seed an unrelated sibling claim — Reader's own `useId` claims
    // (however many React decides to allocate across speculative
    // renders) are not load-bearing for this test; what matters is
    // that the sibling's external claim survives the sweep.
    const siblingClaimerId = "sibling-claimer"
    shared.claimers.add(siblingClaimerId)

    result.unmount()

    // Sweep with a claimerId that is not the sibling's. Sweep removes
    // its own claimerId (idempotent if absent) and then checks
    // whether the claimers set is empty. The sibling claim keeps the
    // set non-empty so the sweep must bail before deleting the entry
    // or calling `mounted.unmount()`.
    __runSuspenseOrphanSweep({
      connection: connection as unknown as MusubiConnection<unknown>,
      key,
      unmountOnCleanup: true,
      claimerId: "phantom-claimer",
      shared
    })

    await act(async () => {
      gate.resolve(fake.asProxy())
      await gate.promise
      await flushTimers()
    })

    expect(mounts.get(key)).toBe(shared)
    expect(connection.unmounts).toEqual([])
    expect(shared.claimers.has(siblingClaimerId)).toBe(true)
  })

  test("orphan sweep bails when the entry was replaced by a fresh SharedRootMount", async () => {
    // Stale-finalizer guard: if a `SharedRootMount` is torn down and
    // a new one allocated for the same key (e.g. failed mount + retry
    // path through `ensureRootMount`), a previously-armed finalizer
    // must not mutate or unmount the replacement entry. The sweep's
    // `mounts.get(key) !== holdings.shared` identity check is what
    // closes this.
    const fake = buildProxy()
    const connection = new FakeMusubiConnection(fake.asProxy())

    function Reader() {
      const store = useMusubiRootSuspense({ module: "React.Test.Root", id: "stale-1" })
      return <span>stale:{store.snapshot().title}</span>
    }

    const result = render(
      <MusubiProvider connection={connection}>
        <React.Suspense fallback={<span>load</span>}>
          <Reader />
        </React.Suspense>
      </MusubiProvider>
    )
    expect(await screen.findByText("stale:Inbox")).toBeTruthy()

    const mounts = __pendingRootMountsForTests.get(
      connection as unknown as MusubiConnection<unknown>
    )!
    const key = "stale-1|React.Test.Root|null"
    const liveShared = mounts.get(key)!

    // Simulate a finalizer queued against a previously-torn-down
    // SharedRootMount — same connection + key, different object
    // identity. Seed a sentinel claimer so the test can prove that
    // the entry guard short-circuits BEFORE the sweep's
    // `shared.claimers.delete(claimerId)` mutation runs: if the entry
    // guard at the head of the sweep is removed, that delete will
    // strip the sentinel from `staleShared.claimers`, and the
    // assertion below will fail. Without this, removing only the
    // entry guard (and keeping the post-promise guards) would leave
    // the test silently green.
    const sentinelClaimerId = "stale-fiber"
    const staleShared = {
      refs: 0,
      promise: Promise.resolve(null as never),
      settled: true,
      failed: false,
      value: null,
      error: null,
      cleanupTimer: null,
      claimers: new Set<string>([sentinelClaimerId])
    } as unknown as Parameters<typeof __runSuspenseOrphanSweep>[0]["shared"]

    __runSuspenseOrphanSweep({
      connection: connection as unknown as MusubiConnection<unknown>,
      key,
      unmountOnCleanup: true,
      claimerId: sentinelClaimerId,
      shared: staleShared
    })
    await act(async () => { await flushTimers() })

    // The live entry must be untouched and the stale entry's own
    // state must also be untouched (the sweep bailed before the
    // entry-head `claimers.delete`).
    expect(mounts.get(key)).toBe(liveShared)
    expect(connection.unmounts).toEqual([])
    expect((staleShared as unknown as { claimers: Set<string> }).claimers.has(sentinelClaimerId)).toBe(true)

    result.unmount()
    await act(async () => { await flushTimers() })
  })

  test("StrictMode + sibling: this fiber's lifecycle does not poison a sibling's claim", async () => {
    // The original concern Codex raised about render-phase generation
    // bumps was that StrictMode (or any concurrent retry) could
    // spuriously advance the counter and orphan a sibling consumer's
    // lease. Switching to a `useId`-keyed `Set<claimerId>` removes
    // that whole class of bug: regardless of how many times React
    // re-invokes this body under StrictMode, an unrelated
    // `siblingClaimerId` we seeded into `shared.claimers` must
    // survive every render-phase and commit-cleanup mutation made by
    // Reader.
    const fake = buildProxy()
    const connection = new FakeMusubiConnection(fake.asProxy())

    function Reader() {
      const store = useMusubiRootSuspense({ module: "React.Test.Root", id: "sibling-1" })
      return <span>strict:{store.snapshot().title}</span>
    }

    const result = render(
      <React.StrictMode>
        <MusubiProvider connection={connection}>
          <React.Suspense fallback={<span>load</span>}>
            <Reader />
          </React.Suspense>
        </MusubiProvider>
      </React.StrictMode>
    )
    expect(await screen.findByText("strict:Inbox")).toBeTruthy()

    const mounts = __pendingRootMountsForTests.get(
      connection as unknown as MusubiConnection<unknown>
    )!
    const key = "sibling-1|React.Test.Root|null"
    const shared = mounts.get(key)!

    const siblingClaimerId = "external-sibling-claimer"
    shared.claimers.add(siblingClaimerId)

    result.unmount()
    await act(async () => { await flushTimers() })

    // Reader's commit-cleanup drops Reader's own `useId` claims and
    // releases its ref. The sibling's claim must still be intact, and
    // the entry should still be parked (the sibling's safety net is
    // what's responsible for tearing it down later).
    expect(shared.claimers.has(siblingClaimerId)).toBe(true)
  })

  test("orphan sweep bails when a committed consumer is holding the entry", async () => {
    const fake = buildProxy()
    const connection = new FakeMusubiConnection(fake.asProxy())

    function Reader() {
      const store = useMusubiRootSuspense({ module: "React.Test.Root", id: "committed-1" })
      return <span>commit:{store.snapshot().title}</span>
    }

    const result = render(
      <MusubiProvider connection={connection}>
        <React.Suspense fallback={<span>load</span>}>
          <Reader />
        </React.Suspense>
      </MusubiProvider>
    )
    expect(await screen.findByText("commit:Inbox")).toBeTruthy()

    const mounts = __pendingRootMountsForTests.get(
      connection as unknown as MusubiConnection<unknown>
    )!
    const key = "committed-1|React.Test.Root|null"
    const shared = mounts.get(key)!
    expect(shared.refs).toBeGreaterThan(0)

    __runSuspenseOrphanSweep({
      connection: connection as unknown as MusubiConnection<unknown>,
      key,
      unmountOnCleanup: true,
      claimerId: "stranger",
      shared
    })
    await act(async () => { await flushTimers() })

    expect(mounts.get(key)).toBe(shared)
    expect(connection.unmounts).toEqual([])

    result.unmount()
    await act(async () => { await flushTimers() })
    expect(connection.unmounts).toEqual(["committed-1"])
  })

  test("failure variant: failed mount entry is removed (no poison) and retries", async () => {
    const fake = buildProxy()
    const connection = new FakeMusubiConnection(fake.asProxy())
    connection.mountErrors = [new Error("first-fail")]

    function Reader() {
      const root = useMusubiRoot({ module: "React.Test.Root", id: "retry-1" })
      if (root.status === "error") return <span>err:{root.error.message}</span>
      if (root.status === "ready") return <span>ok:{root.store.snapshot().title}</span>
      return <span>load</span>
    }

    const first = render(
      <MusubiProvider connection={connection}>
        <Reader />
      </MusubiProvider>
    )
    expect(await screen.findByText("err:first-fail")).toBeTruthy()
    first.unmount()
    await act(async () => { await flushTimers() })

    const second = render(
      <MusubiProvider connection={connection}>
        <Reader />
      </MusubiProvider>
    )
    expect(await screen.findByText("ok:Inbox")).toBeTruthy()
    expect(connection.mounts.length).toBe(2)
    second.unmount()
    await act(async () => { await flushTimers() })
  })
})

// ---------------------------------------------------------------------------
// MusubiProvider socket form
// ---------------------------------------------------------------------------

describe("MusubiProvider socket form", () => {
  function buildFakeSocket() {
    return {} as clientModule.SocketLike
  }

  test("connecting -> ready transitions and exposes status", async () => {
    const fake = buildProxy()
    const connection = new FakeMusubiConnection(fake.asProxy())
    const socket = buildFakeSocket()
    const gate = deferred<MusubiConnection<ReactTestStores>>()
    const spy = vi.spyOn(clientModule, "connect").mockReturnValue(gate.promise as Promise<MusubiConnection<unknown>>)

    function StatusReader() {
      const status = useMusubiConnectionStatus()
      return <span>state:{status.state}</span>
    }

    try {
      render(
        <MusubiProvider socket={socket}>
          <StatusReader />
        </MusubiProvider>
      )

      expect(screen.getByText("state:connecting")).toBeTruthy()

      await act(async () => {
        gate.resolve(connection)
        await gate.promise
      })

      expect(await screen.findByText("state:ready")).toBeTruthy()
    } finally {
      spy.mockRestore()
    }
  })

  test("child useMusubiRoot mounts after ready", async () => {
    const fake = buildProxy()
    const connection = new FakeMusubiConnection(fake.asProxy())
    const gate = deferred<MusubiConnection<ReactTestStores>>()
    const spy = vi.spyOn(clientModule, "connect").mockReturnValue(gate.promise as Promise<MusubiConnection<unknown>>)

    function Reader() {
      const status = useMusubiConnectionStatus()
      if (status.state !== "ready") return <span>conn:{status.state}</span>
      return <Inner />
    }
    function Inner() {
      const root = useMusubiRoot({ module: "React.Test.Root", id: "from-socket" })
      if (root.status !== "ready") return <span>root:{root.status}</span>
      return <span>title:{root.store.snapshot().title}</span>
    }

    try {
      render(
        <MusubiProvider socket={buildFakeSocket()}>
          <Reader />
        </MusubiProvider>
      )
      expect(screen.getByText("conn:connecting")).toBeTruthy()

      await act(async () => {
        gate.resolve(connection)
        await gate.promise
      })

      expect(await screen.findByText("title:Inbox")).toBeTruthy()
      expect(connection.mounts.length).toBe(1)
    } finally {
      spy.mockRestore()
    }
  })

  test("connect failure surfaces as error state", async () => {
    const spy = vi.spyOn(clientModule, "connect").mockRejectedValue(new Error("socket-fail"))

    function Reader() {
      const status = useMusubiConnectionStatus()
      if (status.state === "error") return <span>err:{status.error.message}</span>
      return <span>{status.state}</span>
    }

    try {
      render(
        <MusubiProvider socket={{} as clientModule.SocketLike}>
          <Reader />
        </MusubiProvider>
      )
      expect(await screen.findByText("err:socket-fail")).toBeTruthy()
    } finally {
      spy.mockRestore()
    }
  })

  test("unmount during connect disconnects the resolved connection", async () => {
    const fake = buildProxy()
    const connection = new FakeMusubiConnection(fake.asProxy())
    const gate = deferred<MusubiConnection<ReactTestStores>>()
    const spy = vi.spyOn(clientModule, "connect").mockReturnValue(gate.promise as Promise<MusubiConnection<unknown>>)

    try {
      const result = render(
        <MusubiProvider socket={{} as clientModule.SocketLike}>
          <span>hi</span>
        </MusubiProvider>
      )
      result.unmount()

      await act(async () => {
        gate.resolve(connection)
        await gate.promise
        await flushTimers()
      })

      expect(connection.disconnected).toBe(true)
    } finally {
      spy.mockRestore()
    }
  })

  test("useMusubiConnection error message mentions useMusubiConnectionStatus when not ready", async () => {
    const spy = vi.spyOn(clientModule, "connect").mockReturnValue(new Promise(() => {}) as Promise<MusubiConnection<unknown>>)

    function Reader() {
      useMusubiConnection()
      return null
    }

    const originalError = console.error
    console.error = () => {}
    const onError = (e: ErrorEvent) => {
      if (e.error instanceof Error && /useMusubiConnection/.test(e.error.message)) e.preventDefault()
    }
    window.addEventListener("error", onError)
    try {
      render(
        <MusubiProvider socket={{} as clientModule.SocketLike}>
          <TestErrorBoundary>
            <Reader />
          </TestErrorBoundary>
        </MusubiProvider>
      )
      expect(await screen.findByText(/useMusubiConnectionStatus/)).toBeTruthy()
    } finally {
      window.removeEventListener("error", onError)
      console.error = originalError
      spy.mockRestore()
    }
  })

  test("rejects when both connection and socket are supplied", () => {
    const fake = buildProxy()
    const connection = new FakeMusubiConnection(fake.asProxy())
    const originalError = console.error
    console.error = () => {}
    try {
      expect(() =>
        render(
          // Type-level mutual exclusion: cast for runtime invariant check.
          <MusubiProvider {...({ connection, socket: {} } as unknown as { connection: MusubiConnection<ReactTestStores>; children: React.ReactNode })}>
            <span>x</span>
          </MusubiProvider>
        )
      ).toThrow(/either `connection` or `socket`/)
    } finally {
      console.error = originalError
    }
  })
})

// ---------------------------------------------------------------------------
// useMusubiSnapshot default equalityFn
// ---------------------------------------------------------------------------

describe("useMusubiSnapshot default shallowEqual", () => {
  test("fresh-literal selector with same content does not re-render", () => {
    const fake = buildProxy("Inbox", 0)
    let renders = 0

    function Reader() {
      renders += 1
      // Selector returns a fresh tuple every call; default shallowEqual
      // should treat (0, "Inbox") === (0, "Inbox") as equal.
      const view = useMusubiSnapshot(fake.asProxy(), (s) => ({
        counter: s.counter,
        title: s.title
      }))
      return <span>{view.title}:{view.counter}</span>
    }

    render(<Reader />)
    expect(renders).toBe(1)

    act(() => {
      // Notify with same content
      fake.setSnapshot({ __musubi_store_id__: [], title: "Inbox", counter: 0 })
    })
    expect(renders).toBe(1)
  })

  test("shallowEqual default is overridable", () => {
    expect(shallowEqual({ a: 1 }, { a: 1 })).toBe(true)
  })
})

// ---------------------------------------------------------------------------
// useMusubiRoot canonical params
// ---------------------------------------------------------------------------

describe("useMusubiRoot canonical params", () => {
  test("logically-equal params share a single mount", async () => {
    const fake = buildProxy()
    const connection = new FakeMusubiConnection(fake.asProxy())

    function A() {
      const r = useMusubiRoot({ module: "React.Test.Root", id: "p-1", params: { a: 1, b: 2 } })
      return <span>A:{r.status}</span>
    }
    function B() {
      const r = useMusubiRoot({ module: "React.Test.Root", id: "p-1", params: { b: 2, a: 1 } })
      return <span>B:{r.status}</span>
    }

    const result = render(
      <MusubiProvider connection={connection}>
        <A />
        <B />
      </MusubiProvider>
    )

    await screen.findByText("A:ready")
    await screen.findByText("B:ready")
    expect(connection.mounts.length).toBe(1)

    result.unmount()
    await act(async () => { await flushTimers() })
  })
})

// ---------------------------------------------------------------------------
// keyOf
// ---------------------------------------------------------------------------

describe("keyOf", () => {
  test("returns stable string from proxy id", () => {
    const fake = new FakeStoreProxy<Root, ReactTestStores>({
      __musubi_store_id__: ["root", "abc"] as unknown as string[],
      title: "x",
      counter: 0
    })
    Object.assign(fake, { __musubi_store_id__: ["root", "abc"] })
    const proxy = fake.asProxy()
    expect(keyOf(proxy)).toBe(JSON.stringify(["root", "abc"]))
  })
})
