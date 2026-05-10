import type { JsonPatchOp } from "./types"

type PointerSegment = string
type JsonArray = unknown[]
type JsonObject = Record<string, unknown>
type JsonContainer = JsonArray | JsonObject

export function parsePointer(path: string): PointerSegment[] {
  if (path === "") {
    return []
  }

  if (!path.startsWith("/")) {
    throw new Error(`Invalid JSON Pointer: ${path}`)
  }

  return path
    .slice(1)
    .split("/")
    .map((segment) => segment.replaceAll("~1", "/").replaceAll("~0", "~"))
}

export function applyPatch(root: unknown, ops: readonly JsonPatchOp[]): unknown {
  return ops.reduce((current, op) => applyOperation(current, op), root)
}

function applyOperation(root: unknown, op: JsonPatchOp): unknown {
  const segments = parsePointer(op.path)

  if (segments.length === 0) {
    if (op.op !== "replace") {
      throw new Error(`Root path only supports replace, received ${op.op}`)
    }

    return op.value
  }

  return updateAtPath(root, segments, (container, segment) => {
    switch (op.op) {
      case "add":
        addValue(container, segment, op.value)
        return
      case "remove":
        removeValue(container, segment)
        return
      case "replace":
        replaceValue(container, segment, op.value)
        return
    }
  })
}

function updateAtPath(
  current: unknown,
  segments: readonly PointerSegment[],
  mutate: (container: JsonContainer, segment: PointerSegment) => void
): unknown {
  if (segments.length === 0) {
    throw new Error("Cannot update without a path segment")
  }

  const [segment, ...rest] = segments

  if (segment === undefined) {
    throw new Error("Missing JSON Pointer segment")
  }

  const container = cloneContainer(current)

  if (rest.length === 0) {
    mutate(container, segment)
    return container
  }

  const child = getChild(current, segment)
  const nextChild = updateAtPath(child, rest, mutate)

  if (Array.isArray(container)) {
    container[parseArrayIndex(segment, container.length)] = nextChild
  } else {
    container[segment] = nextChild
  }

  return container
}

function addValue(container: JsonContainer, segment: PointerSegment, value: unknown): void {
  if (Array.isArray(container)) {
    if (segment === "-") {
      container.push(value)
      return
    }

    const index = parseArrayIndex(segment, container.length, { allowEnd: true })
    container.splice(index, 0, value)
    return
  }

  container[segment] = value
}

function removeValue(container: JsonContainer, segment: PointerSegment): void {
  if (Array.isArray(container)) {
    const index = parseArrayIndex(segment, container.length - 1)
    container.splice(index, 1)
    return
  }

  delete container[segment]
}

function replaceValue(container: JsonContainer, segment: PointerSegment, value: unknown): void {
  if (Array.isArray(container)) {
    const index = parseArrayIndex(segment, container.length - 1)
    container[index] = value
    return
  }

  container[segment] = value
}

function cloneContainer(value: unknown): JsonContainer {
  if (Array.isArray(value)) {
    return value.slice()
  }

  if (isRecord(value)) {
    return { ...value }
  }

  throw new Error("JSON Patch target is not a container")
}

function getChild(container: unknown, segment: PointerSegment): unknown {
  if (Array.isArray(container)) {
    return container[parseArrayIndex(segment, container.length - 1)]
  }

  if (isRecord(container)) {
    return container[segment]
  }

  throw new Error("JSON Patch path traverses a non-container value")
}

function parseArrayIndex(
  raw: string,
  maxIndex: number,
  options: { allowEnd?: boolean } = {}
): number {
  if (!/^(0|[1-9]\d*)$/.test(raw)) {
    throw new Error(`Invalid array index: ${raw}`)
  }

  const index = Number.parseInt(raw, 10)
  const upperBound = options.allowEnd ? maxIndex + 1 : maxIndex

  if (index < 0 || index > upperBound) {
    throw new Error(`Array index out of bounds: ${raw}`)
  }

  return index
}

function isRecord(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}
