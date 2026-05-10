import { describe, expectTypeOf, test } from "vitest"

import { useCommand, useStore } from "../src"
import type { ArborStoreCommands, ArborStoreState } from "@arbor/client"

type Commands = {
  checkout: {
    coupon?: string
  }
}

declare module "@arbor/client" {
  interface ArborStoreMap {
    "Test.Store": {
      state: {
        __arbor_store_id__: readonly string[]
        count: number
      }
      commands: {
        checkout: {
          coupon?: string
        }
      }
    }
  }
}

type CheckoutDispatcher = ReturnType<typeof useCommand<Commands, "checkout", string>>
type CounterState = {
  count: number
}
type CounterStore = ReturnType<typeof useStore<CounterState>>
type SelectedStore = ReturnType<typeof useStore<CounterState, number>>
type AugmentedStore = ReturnType<typeof useStore<"Test.Store">>
type AugmentedSelectedStore = ReturnType<typeof useStore<"Test.Store", number>>
type AugmentedDispatcher = ReturnType<typeof useCommand<"Test.Store", "checkout", string>>

// @ts-expect-error only declared command names are allowed
type MissingDispatcher = ReturnType<typeof useCommand<Commands, "missing">>
// @ts-expect-error only declared command names are allowed on the module-key path
type MissingAugmentedDispatcher = ReturnType<typeof useCommand<"Test.Store", "missing">>

describe("useCommand types", () => {
  test("preserves the typed payload and command name constraints", () => {
    expectTypeOf<CheckoutDispatcher>().toEqualTypeOf<
      (payload: { coupon?: string }) => Promise<string>
    >()
    expectTypeOf<CounterStore>().toEqualTypeOf<CounterState | undefined>()
    expectTypeOf<SelectedStore>().toEqualTypeOf<number>()
    expectTypeOf<ArborStoreState<"Test.Store">>().toEqualTypeOf<{
      __arbor_store_id__: readonly string[]
      count: number
    }>()
    expectTypeOf<ArborStoreCommands<"Test.Store">>().toEqualTypeOf<{
      checkout: {
        coupon?: string
      }
    }>()
    expectTypeOf<AugmentedStore>().toEqualTypeOf<
      { __arbor_store_id__: readonly string[]; count: number } | undefined
    >()
    expectTypeOf<AugmentedSelectedStore>().toEqualTypeOf<number>()
    expectTypeOf<AugmentedDispatcher>().toEqualTypeOf<
      (payload: { coupon?: string }) => Promise<string>
    >()
  })
})
