import { act, render } from "@testing-library/react"
import { describe, expect, test } from "vitest"

import { ArborProvider, useCommand } from "../src"
import { FakeArborClient } from "./setup"

type Commands = {
  checkout: {
    coupon?: string
  }
}

const STORE_ID = ["checkout"] as const

describe("useCommand", () => {
  test("returns a stable dispatcher across rerenders", () => {
    const client = new FakeArborClient()
    const seen: Array<(payload: Commands["checkout"]) => Promise<string>> = []

    function Reader({ label }: { label: string }) {
      const dispatch = useCommand<Commands, "checkout", string>(STORE_ID, "checkout")
      seen.push(dispatch)
      return <button>{label}</button>
    }

    const rendered = render(
      <ArborProvider client={client.asProviderClient()}>
        <Reader label="first" />
      </ArborProvider>
    )

    rendered.rerender(
      <ArborProvider client={client.asProviderClient()}>
        <Reader label="second" />
      </ArborProvider>
    )

    expect(seen).toHaveLength(2)
    expect(seen[0]).toBe(seen[1])
  })

  test("invokes client.command once with the store id, name, and payload", async () => {
    const client = new FakeArborClient()
    client.onCommand(async () => "ok")
    let dispatch: ((payload: Commands["checkout"]) => Promise<string>) | undefined

    function Reader() {
      dispatch = useCommand<Commands, "checkout", string>(STORE_ID, "checkout")
      return null
    }

    render(
      <ArborProvider client={client.asProviderClient()}>
        <Reader />
      </ArborProvider>
    )

    let reply = ""

    await act(async () => {
      reply = (await dispatch?.({ coupon: "SAVE10" })) ?? ""
    })

    expect(reply).toBe("ok")
    expect(client.commandCalls).toEqual([
      {
        storeId: STORE_ID,
        name: "checkout",
        payload: { coupon: "SAVE10" }
      }
    ])
  })
})
