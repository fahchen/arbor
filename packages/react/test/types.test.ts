import { describe, expectTypeOf, test } from "vitest"

import { useCommand, useStore } from "../src"

type Commands = {
  checkout: {
    coupon?: string
  }
}

type CheckoutDispatcher = ReturnType<typeof useCommand<Commands, "checkout", string>>
type CounterState = {
  count: number
}
type CounterStore = ReturnType<typeof useStore<CounterState>>
type SelectedStore = ReturnType<typeof useStore<CounterState, number>>

// @ts-expect-error only declared command names are allowed
type MissingDispatcher = ReturnType<typeof useCommand<Commands, "missing">>

describe("useCommand types", () => {
  test("preserves the typed payload and command name constraints", () => {
    expectTypeOf<CheckoutDispatcher>().toEqualTypeOf<
      (payload: { coupon?: string }) => Promise<string>
    >()
    expectTypeOf<CounterStore>().toEqualTypeOf<CounterState | undefined>()
    expectTypeOf<SelectedStore>().toEqualTypeOf<number>()
  })
})
