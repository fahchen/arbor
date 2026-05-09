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

  describe "state_alias/1" do
    test "appends State to the trailing alias when missing" do
      assert TypeScript.state_alias(MyApp.Stores.ProductPageStore) == "ProductPageStoreState"
    end

    test "leaves trailing State suffix as-is" do
      assert TypeScript.state_alias(MyApp.MessageState) == "MessageState"
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

    test "cross-module references emit the TS alias" do
      ast = quote(do: Arbor.TestSupport.TypespecProbeChild.t())
      assert TypeScript.render_type(ast) == "TypespecProbeChildState"
    end
  end

  describe "render/1" do
    test "emits state + commands blocks for a Store" do
      %{path: path, contents: contents} = TypeScript.render(TypespecProbe)

      assert path == "TypespecProbeState.ts"
      assert contents =~ "export type AsyncResult<T>"
      assert contents =~ "export type TypespecProbeState = {"
      assert contents =~ "messages: string[]"
      assert contents =~ "items: TypespecProbeChildState[]"
      assert contents =~ "load_stream: AsyncResult<TypespecProbeChildState[]>"
      assert contents =~ "profile: AsyncResult<TypespecProbeChildState>"
      assert contents =~ "child: TypespecProbeChildState"
      assert contents =~ "tags: string[]"
    end

    test "returns nil for ineligible modules" do
      assert TypeScript.render(Arbor.Socket) == nil
    end

    test "Arbor.State module emits a TS alias without a Commands block" do
      %{path: path, contents: contents} = TypeScript.render(TypespecProbeChild)

      assert path == "TypespecProbeChildState.ts"
      assert contents =~ "export type TypespecProbeChildState"
      refute contents =~ "Commands"
    end
  end
end
