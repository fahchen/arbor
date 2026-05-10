import { describe, expectTypeOf, test } from "vitest"

import type {
  ArborStoreCommands,
  ArborStoreModule,
  ArborStoreState,
  AsyncResult,
  StreamOp,
  StoreId
} from "../src/types"
import type { BoundStore } from "../src"
import { bindStore } from "../src"
import { storeIdKey, storeKeyFromStreamStoreKey, streamStoreKey } from "../src/types"

declare module "../src/types" {
  interface ArborStoreMap {
    "Test.Store": {
      state: {
        __arbor_store_id__: readonly string[]
        count: number
      }
      commands: {
        increment: { delta: number }
      }
    }
  }
}

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
    storeKeyFromStreamStoreKey(streamStoreKey(root, "messages"))
  })

  test("exposes the module augmentation helper types", () => {
    expectTypeOf<ArborStoreModule>().toEqualTypeOf<"Test.Store">()
    expectTypeOf<ArborStoreState<"Test.Store">>().toEqualTypeOf<{
      __arbor_store_id__: readonly string[]
      count: number
    }>()
    expectTypeOf<ArborStoreCommands<"Test.Store">>().toEqualTypeOf<{
      increment: { delta: number }
    }>()
  })

  test("bindStore supports the augmented module-key overload", () => {
    type Bound = ReturnType<typeof bindStore<"Test.Store">>

    expectTypeOf<Bound>().toEqualTypeOf<
      BoundStore<
        {
          __arbor_store_id__: readonly string[]
          count: number
        },
        {
          increment: { delta: number }
        }
      >
    >()
  })
})
