import { act, render, screen } from "@testing-library/react"
import * as React from "react"
import { describe, expect, test, vi } from "vitest"

import { createMusubi, MusubiCommandError } from "../src"

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
  useMusubiRoot,
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

    function Reader() {
      const musubiConnection = useMusubiConnection()
      return <span>{musubiConnection.topic}</span>
    }

    render(
      <MusubiProvider connection={connection}>
        <Reader />
      </MusubiProvider>
    )

    expect(screen.getByText("musubi:connection")).toBeTruthy()
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
        event.error.message === "useMusubiConnection must be used inside <MusubiProvider>"
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
        screen.getByText("useMusubiConnection must be used inside <MusubiProvider>")
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
  mountResult: Promise<StoreProxy<Root, ReactTestStores>> | null = null

  constructor(private readonly store: StoreProxy<Root, ReactTestStores>) {}

  async mountStore<M extends StoreModule<ReactTestStores>>(
    options: MountStoreOptions<M, ReactTestStores>
  ): Promise<MountedStore<M, ReactTestStores>> {
    this.mounts.push(options as unknown as MountStoreOptions<Root, ReactTestStores>)

    if (this.mountError) {
      throw this.mountError
    }

    const proxy = this.mountResult
      ? ((await this.mountResult) as unknown as StoreProxy<M, ReactTestStores>)
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
