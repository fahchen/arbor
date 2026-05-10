import { render, screen } from "@testing-library/react"
import { describe, expect, test, vi } from "vitest"

import { ArborProvider, useArborClient } from "../src"
import { FakeArborClient } from "./setup"

describe("ArborProvider", () => {
  test("useArborClient throws outside the provider", () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => undefined)

    function Reader() {
      useArborClient()
      return null
    }

    expect(() => render(<Reader />)).toThrow("useArborClient must be used inside <ArborProvider>")
    errorSpy.mockRestore()
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
