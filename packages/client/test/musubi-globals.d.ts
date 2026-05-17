// Stand-in for the generated codegen bundle's `declare global { namespace Musubi }`
// block. The client package never declares these in global scope; the
// generated bundle does. Tests load this ambient declaration so
// `Musubi.StoreDef` / `Musubi.StoreField` / `Musubi.StreamField` /
// `Musubi.AsyncField` resolve without a codegen pass.
declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Musubi {
    declare const Type: unique symbol

    interface StoreDef<Module extends string, Shape, Commands> {
      readonly [Type]: {
        module: Module
        shape: Shape
        commands: Commands
      }
    }

    type StoreField<Module extends string> = {
      readonly [Type]: { kind: "store"; module: Module }
    }

    type StreamField<Item> = {
      readonly [Type]: { kind: "stream"; item: Item }
    }

    type AsyncField<Value> = {
      readonly [Type]: { kind: "async"; value: Value }
    }
  }
}

export {}
