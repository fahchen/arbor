// Stand-in for the generated codegen bundle's `declare global { namespace Arbor }`
// block. The client package never declares these in global scope; the
// generated bundle does. Tests load this ambient declaration so
// `Arbor.StoreDef` / `Arbor.StoreField` / `Arbor.StreamField` /
// `Arbor.AsyncField` resolve without a codegen pass.
declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Arbor {
    interface StoreDef<Module extends string, Shape, Commands> {
      readonly __arbor__module__?: Module
      readonly __arbor__shape__?: Shape
      readonly __arbor__commands__?: Commands
    }

    type StoreField<Module extends string> = {
      readonly __arbor__kind__?: "store"
      readonly __arbor__module__?: Module
    }

    type StreamField<Item> = {
      readonly __arbor__kind__?: "stream"
      readonly __arbor__item__?: Item
    }

    type AsyncField<Value> = {
      readonly __arbor__kind__?: "async"
      readonly __arbor__value__?: Value
    }
  }
}

export {}
