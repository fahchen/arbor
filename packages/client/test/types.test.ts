import { describe, expectTypeOf, test } from "vitest"

import type { AsyncResult, StreamOp, StoreId } from "../src/types"
import { storeIdEquals, storeIdKey, streamStoreKey } from "../src/types"

describe("types and helpers", () => {
  test("store id helpers are stable", () => {
    const root: StoreId = []
    const child: StoreId = ["filters"]

    expectTypeOf<AsyncResult<string>>().toMatchTypeOf<
      | { status: "loading"; result: string | null; reason: null }
      | { status: "ok"; result: string; reason: null }
      | { status: "failed"; result: string | null; reason: unknown }
    >()
    expectTypeOf<StreamOp["op"]>().toEqualTypeOf<"reset" | "insert" | "delete">()

    storeIdKey(root)
    streamStoreKey(child, "messages")
    storeIdEquals(root, [])
  })
})
