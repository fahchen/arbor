import { render, screen } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest"

import { ArborProvider, useArborClient } from "../src"
import { FakeArborClient } from "./setup"

describe("ArborProvider", () => {
  beforeEach(() => {
    vi.spyOn(console, "error").mockImplementation(() => undefined)
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  test("useArborClient throws outside the provider", () => {
    function Reader() {
      useArborClient()
      return null
    }

    expect(() => render(<Reader />)).toThrow("useArborClient must be used inside <ArborProvider>")
  })

  test("useArborClient returns the provider client", () => {
    const client = new FakeArborClient()

    function Reader() {
      const resolved = useArborClient()
      return <div>{resolved === client.asProviderClient() ? "same" : "different"}</div>
    }

    render(
      <ArborProvider client={client.asProviderClient()}>
        <Reader />
      </ArborProvider>
    )

    expect(screen.getByText("same")).toBeDefined()
  })
})
