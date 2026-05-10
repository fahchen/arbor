import { describe, expect, test } from "vitest"

import { applyPatch } from "../src/patch"

describe("applyPatch", () => {
  test('replaces the root when the path is ""', () => {
    const next = applyPatch({ ok: true }, [{ op: "replace", path: "", value: { ok: false } }])

    expect(next).toEqual({ ok: false })
  })

  test("adds, replaces, and removes object keys", () => {
    const root = { value: 1 }

    const next = applyPatch(root, [
      { op: "add", path: "/extra", value: "x" },
      { op: "replace", path: "/value", value: 2 },
      { op: "remove", path: "/extra" }
    ])

    expect(next).toEqual({ value: 2 })
    expect(root).toEqual({ value: 1 })
  })

  test("supports array insert, append, remove, and replace", () => {
    const next = applyPatch(
      { list: ["a", "c", "d"] },
      [
        { op: "add", path: "/list/1", value: "b" },
        { op: "add", path: "/list/-", value: "e" },
        { op: "remove", path: "/list/2" },
        { op: "replace", path: "/list/1", value: "beta" }
      ]
    )

    expect(next).toEqual({ list: ["a", "beta", "d", "e"] })
  })

  test("unescapes JSON Pointer escape sequences", () => {
    const next = applyPatch(
      {
        "a/b": {
          "tilde~key": 1
        }
      },
      [{ op: "replace", path: "/a~1b/tilde~0key", value: 2 }]
    )

    expect(next).toEqual({
      "a/b": {
        "tilde~key": 2
      }
    })
  })

  test("applies operations in order", () => {
    const next = applyPatch(
      {
        left: { count: 1 },
        list: [1]
      },
      [
        { op: "replace", path: "/left/count", value: 2 },
        { op: "add", path: "/list/-", value: 2 },
        { op: "add", path: "/right", value: { ok: true } }
      ]
    )

    expect(next).toEqual({
      left: { count: 2 },
      list: [1, 2],
      right: { ok: true }
    })
  })
})
