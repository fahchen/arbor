defmodule Arbor.Codegen.TypeScriptTest do
  use ExUnit.Case, async: true

  alias Arbor.Codegen.TypeScript
  alias Arbor.TestSupport.TypespecProbe
  alias Arbor.TestSupport.TypespecProbeChild

  describe "eligible?/1" do
    test "true for modules that opted into the TypeScript plugin" do
      assert TypeScript.eligible?(TypespecProbe)
      assert TypeScript.eligible?(TypespecProbeChild)
    end

    test "false for non-Arbor modules" do
      refute TypeScript.eligible?(Arbor.Socket)
      refute TypeScript.eligible?(__MODULE__)
    end
  end

  describe "render_type/1" do
    test "primitives" do
      assert TypeScript.render_type(quote(do: String.t())) == "string"
      assert TypeScript.render_type(quote(do: integer())) == "number"
      assert TypeScript.render_type(quote(do: float())) == "number"
      assert TypeScript.render_type(quote(do: boolean())) == "boolean"
      assert TypeScript.render_type(quote(do: atom())) == "string"
      assert TypeScript.render_type(quote(do: map())) == "Record<string, unknown>"
    end

    test "list and stream wrap as T[]" do
      assert TypeScript.render_type(quote(do: list(String.t()))) == "string[]"
      assert TypeScript.render_type(quote(do: stream(String.t()))) == "string[]"
    end

    test "literal-keyed maps emit object types" do
      ast = quote(do: %{type: :active})
      assert TypeScript.render_type(ast) =~ ~s/type: "active"/
    end

    test "unions render as T | U with array fallback to Array<T>" do
      assert TypeScript.render_type(quote(do: String.t() | nil)) == "string | null"

      list_of_union = quote(do: list(String.t() | integer()))
      assert TypeScript.render_type(list_of_union) == "Array<string | number>"
    end

    test "atom literals serialize as JSON-string literal types" do
      assert TypeScript.render_type(:active) == ~s/"active"/
    end

    test "AsyncResult.of(T) renders the generic alias" do
      assert TypeScript.render_type(quote(do: Arbor.AsyncResult.of(String.t()))) ==
               "AsyncResult<string>"

      assert TypeScript.render_type(quote(do: Arbor.AsyncResult.of(stream(String.t())))) ==
               "AsyncResult<string[]>"
    end

    test "cross-module references emit the full Elixir alias path" do
      ast = quote(do: Arbor.TestSupport.TypespecProbeChild.t())
      assert TypeScript.render_type(ast) == "Arbor.TestSupport.TypespecProbeChild"
    end
  end

  describe "render/1" do
    test "emits a single bundle with nested namespaces mirroring the module tree" do
      contents = TypeScript.render([TypespecProbe, TypespecProbeChild])

      # Top-level AsyncResult preamble lives outside any namespace
      assert contents =~ "export type AsyncResult<T>"

      # Namespace nesting follows the Elixir module path
      assert contents =~ "export namespace Arbor {"
      assert contents =~ "  export namespace TestSupport {"

      # Each Arbor module emits a type at the innermost namespace
      assert contents =~ "    export type TypespecProbe = {"
      assert contents =~ "    export type TypespecProbeChild = {"

      # Cross-module ref resolves to the full Elixir alias path
      assert contents =~ "items: Arbor.TestSupport.TypespecProbeChild[]"
      assert contents =~ "load_stream: AsyncResult<Arbor.TestSupport.TypespecProbeChild[]>"
      assert contents =~ "child: Arbor.TestSupport.TypespecProbeChild"
    end

    test "Arbor.State module emits a type without a Commands namespace" do
      contents = TypeScript.render([TypespecProbeChild])

      assert contents =~ "export type TypespecProbeChild = {"
      refute contents =~ "Commands"
    end

    test "emits AsyncResult preamble even when no modules are eligible" do
      contents = TypeScript.render([])
      assert contents =~ "export type AsyncResult<T>"
      refute contents =~ "export namespace "
    end
  end
end
