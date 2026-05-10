import { describe, expect, test } from "vitest"

import { applyStreamOps, getStream } from "../src/streams"
import type { StreamOp } from "../src/types"

describe("applyStreamOps", () => {
  test("appends, prepends, and splices inserts", () => {
    const ops: StreamOp[] = [
      {
        op: "insert",
        stream: "messages",
        ref: "1",
        store_id: [],
        item_key: "a",
        at: -1,
        item: "A",
        limit: null
      },
      {
        op: "insert",
        stream: "messages",
        ref: "1",
        store_id: [],
        item_key: "b",
        at: 0,
        item: "B",
        limit: null
      },
      {
        op: "insert",
        stream: "messages",
        ref: "1",
        store_id: [],
        item_key: "c",
        at: 1,
        item: "C",
        limit: null
      }
    ]

    const streams = applyStreamOps(new Map(), ops)

    expect(getStream<string>(streams, [], "messages")).toEqual([
      { itemKey: "b", item: "B" },
      { itemKey: "c", item: "C" },
      { itemKey: "a", item: "A" }
    ])
  })

  test("moves an existing item_key instead of duplicating it", () => {
    const streams = applyStreamOps(new Map(), [
      {
        op: "insert",
        stream: "messages",
        ref: "1",
        store_id: [],
        item_key: "a",
        at: -1,
        item: "A",
        limit: null
      },
      {
        op: "insert",
        stream: "messages",
        ref: "1",
        store_id: [],
        item_key: "b",
        at: -1,
        item: "B",
        limit: null
      },
      {
        op: "insert",
        stream: "messages",
        ref: "1",
        store_id: [],
        item_key: "a",
        at: -1,
        item: "A2",
        limit: null
      }
    ])

    expect(getStream<string>(streams, [], "messages")).toEqual([
      { itemKey: "b", item: "B" },
      { itemKey: "a", item: "A2" }
    ])
  })

  test("trims from the opposite end of the insert when a limit is present", () => {
    const appendTrim = applyStreamOps(new Map(), [
      {
        op: "insert",
        stream: "messages",
        ref: "1",
        store_id: [],
        item_key: "a",
        at: -1,
        item: "A",
        limit: null
      },
      {
        op: "insert",
        stream: "messages",
        ref: "1",
        store_id: [],
        item_key: "b",
        at: -1,
        item: "B",
        limit: null
      },
      {
        op: "insert",
        stream: "messages",
        ref: "1",
        store_id: [],
        item_key: "c",
        at: -1,
        item: "C",
        limit: 2
      }
    ])

    const prependTrim = applyStreamOps(new Map(), [
      {
        op: "insert",
        stream: "messages",
        ref: "1",
        store_id: [],
        item_key: "a",
        at: -1,
        item: "A",
        limit: null
      },
      {
        op: "insert",
        stream: "messages",
        ref: "1",
        store_id: [],
        item_key: "b",
        at: -1,
        item: "B",
        limit: null
      },
      {
        op: "insert",
        stream: "messages",
        ref: "1",
        store_id: [],
        item_key: "c",
        at: 0,
        item: "C",
        limit: 2
      }
    ])

    expect(getStream<string>(appendTrim, [], "messages")).toEqual([
      { itemKey: "b", item: "B" },
      { itemKey: "c", item: "C" }
    ])
    expect(getStream<string>(prependTrim, [], "messages")).toEqual([
      { itemKey: "c", item: "C" },
      { itemKey: "a", item: "A" }
    ])
  })

  test("deletes by item_key and reset clears the stream", () => {
    const streams = applyStreamOps(new Map(), [
      {
        op: "insert",
        stream: "messages",
        ref: "1",
        store_id: [],
        item_key: "a",
        at: -1,
        item: "A",
        limit: null
      },
      {
        op: "delete",
        stream: "messages",
        ref: "1",
        store_id: [],
        item_key: "a"
      },
      {
        op: "insert",
        stream: "messages",
        ref: "1",
        store_id: [],
        item_key: "b",
        at: -1,
        item: "B",
        limit: null
      },
      {
        op: "reset",
        stream: "messages",
        ref: "1",
        store_id: []
      }
    ])

    expect(getStream<string>(streams, [], "messages")).toEqual([])
  })

  test("keeps same stream names isolated across stores", () => {
    const streams = applyStreamOps(new Map(), [
      {
        op: "insert",
        stream: "messages",
        ref: "1",
        store_id: ["left"],
        item_key: "a",
        at: -1,
        item: "L",
        limit: null
      },
      {
        op: "insert",
        stream: "messages",
        ref: "2",
        store_id: ["right"],
        item_key: "a",
        at: -1,
        item: "R",
        limit: null
      }
    ])

    expect(getStream<string>(streams, ["left"], "messages")).toEqual([
      { itemKey: "a", item: "L" }
    ])
    expect(getStream<string>(streams, ["right"], "messages")).toEqual([
      { itemKey: "a", item: "R" }
    ])
  })
})
