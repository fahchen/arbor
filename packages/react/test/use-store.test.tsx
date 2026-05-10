import { act, render, screen } from "@testing-library/react"
import { describe, expect, test } from "vitest"

import { ArborProvider, shallowEqual, useStore } from "../src"
import { FakeArborClient } from "./setup"

type CounterState = {
  count: number
  meta: {
    label: string
  }
}

const STORE_ID = ["checkout"] as const

describe("useStore", () => {
  test("renders the current state and re-renders when the client emits", () => {
    const client = new FakeArborClient()
    client.setState(STORE_ID, { count: 1, meta: { label: "ready" } } satisfies CounterState)

    function Reader() {
      const state = useStore<CounterState>(STORE_ID)
      return <div>{state?.count ?? "missing"}</div>
    }

    render(
      <ArborProvider client={client.asProviderClient()}>
        <Reader />
      </ArborProvider>
    )

    expect(screen.getByText("1")).toBeDefined()

    act(() => {
      client.setState(STORE_ID, { count: 2, meta: { label: "ready" } } satisfies CounterState)
      client.emit(STORE_ID)
    })

    expect(screen.getByText("2")).toBeDefined()
  })

  test("only re-renders when the selected slice changes", () => {
    const client = new FakeArborClient()
    client.setState(STORE_ID, { count: 1, meta: { label: "alpha" } } satisfies CounterState)
    let renderCount = 0

    function Reader() {
      renderCount += 1
      const count = useStore<CounterState, number>(STORE_ID, (state) => state?.count ?? 0)
      return <div>{count}</div>
    }

    render(
      <ArborProvider client={client.asProviderClient()}>
        <Reader />
      </ArborProvider>
    )

    expect(renderCount).toBe(1)

    act(() => {
      client.setState(STORE_ID, { count: 1, meta: { label: "beta" } } satisfies CounterState)
      client.emit(STORE_ID)
    })

    expect(renderCount).toBe(1)

    act(() => {
      client.setState(STORE_ID, { count: 2, meta: { label: "beta" } } satisfies CounterState)
      client.emit(STORE_ID)
    })

    expect(renderCount).toBe(2)
    expect(screen.getByText("2")).toBeDefined()
  })

  test("respects the provided equality function", () => {
    const client = new FakeArborClient()
    client.setState(STORE_ID, {
      count: 1,
      meta: { label: "same" }
    } satisfies CounterState)
    let renderCount = 0

    function Reader() {
      renderCount += 1
      const selected = useStore<CounterState, CounterState["meta"]>(
        STORE_ID,
        (state) => state?.meta ?? { label: "missing" },
        shallowEqual
      )

      return <div>{selected.label}</div>
    }

    render(
      <ArborProvider client={client.asProviderClient()}>
        <Reader />
      </ArborProvider>
    )

    expect(renderCount).toBe(1)

    act(() => {
      client.setState(STORE_ID, {
        count: 1,
        meta: { label: "same" }
      } satisfies CounterState)
      client.emit(STORE_ID)
    })

    expect(renderCount).toBe(1)

    act(() => {
      client.setState(STORE_ID, {
        count: 1,
        meta: { label: "changed" }
      } satisfies CounterState)
      client.emit(STORE_ID)
    })

    expect(renderCount).toBe(2)
    expect(screen.getByText("changed")).toBeDefined()
  })
})
