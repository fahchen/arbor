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
})
