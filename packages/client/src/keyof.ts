import { storeIdKey } from "./types"
import type { StoreModule, StoreProxy } from "./types"

/**
 * Returns a stable string key for a store proxy, suitable for React list keys
 * and identity comparisons. Derived from the proxy's `__musubi_store_id__`
 * so it does not collide with user-defined fields on the store shape.
 */
export function keyOf<M extends StoreModule<R>, R>(proxy: StoreProxy<M, R>): string {
  return storeIdKey(proxy.__musubi_store_id__)
}
