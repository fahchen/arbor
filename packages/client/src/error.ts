export type MusubiCommandErrorKind = "failed" | "timeout"

export interface MusubiCommandErrorOptions {
  kind: MusubiCommandErrorKind
  command: string
  storeId: readonly string[]
  reply?: unknown
  cause?: unknown
}

export class MusubiCommandError extends Error {
  readonly name = "MusubiCommandError"
  readonly kind: MusubiCommandErrorKind
  readonly command: string
  readonly storeId: readonly string[]
  readonly reply: unknown
  readonly code: string | undefined

  constructor(options: MusubiCommandErrorOptions) {
    super(
      MusubiCommandError.buildMessage(options),
      options.cause !== undefined ? { cause: options.cause } : undefined
    )
    this.kind = options.kind
    this.command = options.command
    this.storeId = options.storeId
    this.reply = options.reply
    this.code = MusubiCommandError.extractCode(options.reply)
  }

  static is(value: unknown): value is MusubiCommandError {
    return value instanceof Error && (value as { name?: string }).name === "MusubiCommandError"
  }

  private static buildMessage(opts: MusubiCommandErrorOptions): string {
    if (opts.kind === "timeout") return `Command "${opts.command}" timed out`
    const code = MusubiCommandError.extractCode(opts.reply)
    return `Command "${opts.command}" failed: ${code ?? MusubiCommandError.safeStringify(opts.reply)}`
  }

  private static safeStringify(value: unknown): string {
    try {
      return JSON.stringify(value) ?? String(value)
    } catch {
      return String(value)
    }
  }

  private static extractCode(reply: unknown): string | undefined {
    if (typeof reply !== "object" || reply === null) return undefined
    const record = reply as Record<string, unknown>
    for (const key of ["code", "error", "reason"]) {
      const value = record[key]
      if (typeof value === "string") return value
    }
    return undefined
  }
}
