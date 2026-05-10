import { act, render, screen } from "@testing-library/react"
import { describe, expect, test } from "vitest"

import type { AsyncResult } from "@arbor/client"

import { ArborProvider, useAsyncResult } from "../src"
import { FakeArborClient } from "./setup"

type CheckoutState = {
  save: AsyncResult<string> | undefined
}

const STORE_ID = ["checkout"] as const

describe("useAsyncResult", () => {
  test("tracks async result field transitions from loading to ok", () => {
    const client = new FakeArborClient()
    client.setState(STORE_ID, {
      save: { status: "loading", result: null, reason: null }
    } satisfies CheckoutState)

    function Reader() {
      const result = useAsyncResult<string>(STORE_ID, "save")
      return <div>{result?.status === "ok" ? result.result : result?.status ?? "missing"}</div>
    }

    render(
      <ArborProvider client={client.asProviderClient()}>
        <Reader />
      </ArborProvider>
    )

    expect(screen.getByText("loading")).toBeDefined()

    act(() => {
      client.setState(STORE_ID, {
        save: { status: "ok", result: "done", reason: null }
      } satisfies CheckoutState)
      client.emit(STORE_ID)
    })

    expect(screen.getByText("done")).toBeDefined()
  })
})
