import { act, render, screen } from "@testing-library/react"
import * as React from "react"
import { describe, expect, test, vi } from "vitest"

import { ArborProvider, useArborCommand, useArborRoot, useArborSnapshot } from "../src"

import { FakeStoreProxy } from "./setup"

void React

type ReactTestStores = {
  "React.Test.Root": Arbor.StoreDef<
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
    __arbor_store_id__: [],
    title,
    counter
  })
}

describe("ArborProvider + useArborRoot", () => {
  test("exposes the root proxy to descendants", () => {
    const fake = buildProxy()

    function Reader() {
      const root = useArborRoot<ReactTestStores, Root>()
      return <span>{root.snapshot().title}</span>
    }

    render(
      <ArborProvider proxy={fake.asProxy()}>
        <Reader />
      </ArborProvider>
    )

    expect(screen.getByText("Inbox")).toBeTruthy()
  })

  test("useArborRoot throws outside a provider", () => {
    function Reader() {
      useArborRoot<ReactTestStores, Root>()
      return null
    }

    const originalError = console.error
    console.error = () => {}

    expect(() => render(<Reader />)).toThrow(
      /useArborRoot must be used inside <ArborProvider>/
    )

    console.error = originalError
  })
})

describe("useArborSnapshot", () => {
  test("re-renders on snapshot updates", () => {
    const fake = buildProxy("Inbox", 0)
    let renders = 0

    function Reader() {
      renders += 1
      const snapshot = useArborSnapshot(fake.asProxy())
      return <span>{snapshot.counter}</span>
    }

    render(<Reader />)
    expect(screen.getByText("0")).toBeTruthy()
    expect(renders).toBe(1)

    act(() => {
      fake.setSnapshot({ __arbor_store_id__: [], title: "Inbox", counter: 1 })
    })

    expect(screen.getByText("1")).toBeTruthy()
    expect(renders).toBe(2)
  })

  test("selector + equalityFn suppresses unrelated re-renders", () => {
    const fake = buildProxy("Inbox", 0)
    let renders = 0

    function Reader() {
      renders += 1
      const title = useArborSnapshot(fake.asProxy(), (s) => s.title)
      return <span>{title}</span>
    }

    render(<Reader />)
    expect(renders).toBe(1)

    act(() => {
      fake.setSnapshot({ __arbor_store_id__: [], title: "Inbox", counter: 5 })
    })

    expect(screen.getByText("Inbox")).toBeTruthy()
    expect(renders).toBe(1)
  })
})

describe("useArborCommand", () => {
  test("returns a stable dispatcher bound to the proxy", async () => {
    const fake = buildProxy()
    const handler = vi.fn(async () => ({ ok: true as const }))
    fake.onDispatch(handler)

    let dispatcher: ((payload: { title: string }) => Promise<unknown>) | undefined

    function Reader() {
      dispatcher = useArborCommand(fake.asProxy(), "rename")
      return null
    }

    render(<Reader />)

    await dispatcher?.({ title: "Outbox" })

    expect(handler).toHaveBeenCalledWith("rename", { title: "Outbox" })
    expect(fake.dispatchCalls).toEqual([{ name: "rename", payload: { title: "Outbox" } }])
  })
})
