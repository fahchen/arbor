import { act, render, screen } from "@testing-library/react"
import { describe, expect, test } from "vitest"

import type { StreamEntry } from "@arbor/client"

import { ArborProvider, useStream } from "../src"
import { FakeArborClient } from "./setup"

type Message = {
  body: string
}

const STORE_ID = ["chat"] as const
const STREAM_NAME = "messages"

describe("useStream", () => {
  test("renders and updates a materialized stream list", () => {
    const client = new FakeArborClient()
    client.setStream(STORE_ID, STREAM_NAME, [
      { itemKey: "m1", item: { body: "hello" } }
    ] satisfies readonly StreamEntry<Message>[])

    function Reader() {
      const entries = useStream<Message>(STORE_ID, STREAM_NAME)

      return (
        <ul>
          {entries.map((entry) => (
            <li key={entry.itemKey}>{entry.item.body}</li>
          ))}
        </ul>
      )
    }

    render(
      <ArborProvider client={client.asProviderClient()}>
        <Reader />
      </ArborProvider>
    )

    expect(screen.getByText("hello")).toBeDefined()

    act(() => {
      client.setStream(STORE_ID, STREAM_NAME, [
        { itemKey: "m1", item: { body: "hello" } },
        { itemKey: "m2", item: { body: "world" } }
      ] satisfies readonly StreamEntry<Message>[])
      client.emit(STORE_ID)
    })

    expect(screen.getByText("world")).toBeDefined()
  })

  test("does not re-render when the stream snapshot keeps the same array reference", () => {
    const client = new FakeArborClient()
    const entries = [{ itemKey: "m1", item: { body: "hello" } }] satisfies readonly StreamEntry<Message>[]
    client.setStream(STORE_ID, STREAM_NAME, entries)
    let renderCount = 0

    function Reader() {
      renderCount += 1
      const stream = useStream<Message>(STORE_ID, STREAM_NAME)
      return <div>{stream[0]?.item.body ?? "missing"}</div>
    }

    render(
      <ArborProvider client={client.asProviderClient()}>
        <Reader />
      </ArborProvider>
    )

    expect(renderCount).toBe(1)

    act(() => {
      client.setStream(STORE_ID, STREAM_NAME, entries)
      client.emit(STORE_ID)
    })

    expect(renderCount).toBe(1)
  })
})
