import { act, render, screen } from "@testing-library/react"
import * as React from "react"
import { describe, expect, test, vi } from "vitest"

import {
  MusubiProvider,
  useMusubiCommand,
  useMusubiRoot,
  useMusubiConnection,
  useMusubiSnapshot
} from "../src"

import { FakeStoreProxy } from "./setup"

import type { MusubiConnection, MountStoreOptions, StoreModule, StoreProxy } from "../src"

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

function buildProxy(title = "Inbox", counter = 0): FakeStoreProxy<ReactTestStores, Root> {
  return new FakeStoreProxy<ReactTestStores, Root>({
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
      const root = useMusubiRoot<ReactTestStores, Root>({
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
    const mount = deferred<StoreProxy<unknown, never>>()
    connection.mountResult = mount.promise

    function Reader() {
      const root = useMusubiRoot<ReactTestStores, Root>({
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
      const root = useMusubiRoot<ReactTestStores, Root>({
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
  test("returns a stable dispatcher bound to the proxy", async () => {
    const fake = buildProxy()
    const handler = vi.fn(async () => ({ ok: true as const }))
    fake.onDispatch(handler)

    let dispatcher: ((payload: { title: string }) => Promise<unknown>) | undefined

    function Reader() {
      dispatcher = useMusubiCommand(fake.asProxy(), "rename")
      return null
    }

    render(<Reader />)

    await dispatcher?.({ title: "Outbox" })

    expect(handler).toHaveBeenCalledWith("rename", { title: "Outbox" })
    expect(fake.dispatchCalls).toEqual([{ name: "rename", payload: { title: "Outbox" } }])
  })
})

class FakeMusubiConnection implements MusubiConnection {
  readonly topic = "musubi:connection"
  readonly mounts: MountStoreOptions[] = []
  readonly unmounts: string[] = []
  disconnected = false
  mountError: Error | null = null
  mountResult: Promise<StoreProxy<unknown, never>> | null = null

  constructor(private readonly store: StoreProxy<unknown, never>) {}

  async mountStore<R, M extends StoreModule<R> = StoreModule<R>>(
    options: MountStoreOptions
  ): Promise<StoreProxy<R, M>> {
    this.mounts.push(options)

    if (this.mountError) {
      throw this.mountError
    }

    if (this.mountResult) {
      return (await this.mountResult) as StoreProxy<R, M>
    }

    return this.store as StoreProxy<R, M>
  }

  async unmountStore(rootId: string): Promise<void> {
    this.unmounts.push(rootId)
  }

  disconnect(): void {
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
