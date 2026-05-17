defmodule Musubi.Codegen.TypeScript.TypeRendererTest do
  use ExUnit.Case, async: true

  alias Musubi.Codegen.TypeScript.TypeRenderer

  describe "primitives" do
    test "String.t()" do
      assert TypeRenderer.render(quote(do: String.t())) == "string"
    end

    test "binary()" do
      assert TypeRenderer.render(quote(do: binary())) == "string"
    end

    test "integer()" do
      assert TypeRenderer.render(quote(do: integer())) == "number"
    end

    test "float()" do
      assert TypeRenderer.render(quote(do: float())) == "number"
    end

    test "boolean()" do
      assert TypeRenderer.render(quote(do: boolean())) == "boolean"
    end

    test "atom() (atoms serialize as strings)" do
      assert TypeRenderer.render(quote(do: atom())) == "string"
    end

    test "map() (untyped)" do
      assert TypeRenderer.render(quote(do: map())) == "Record<string, unknown>"
    end
  end

  describe "literals" do
    test "nil" do
      assert TypeRenderer.render(nil) == "null"
    end

    test "true" do
      assert TypeRenderer.render(true) == "true"
    end

    test "false" do
      assert TypeRenderer.render(false) == "false"
    end

    test "atom literal" do
      assert TypeRenderer.render(:active) == ~s/"active"/
    end

    test "atom literal with embedded characters preserves JSON-string escaping" do
      assert TypeRenderer.render(:"with-dash") == ~s/"with-dash"/
    end

    test "binary literal" do
      assert TypeRenderer.render("hello") == ~s/"hello"/
    end

    test "integer literal" do
      assert TypeRenderer.render(42) == "42"
    end

    test "float literal" do
      assert TypeRenderer.render(3.14) == "3.14"
    end
  end

  describe "containers" do
    test "list(T)" do
      assert TypeRenderer.render(quote(do: list(String.t()))) == "string[]"
    end

    test "stream(T) renders as Musubi.StreamField<T> phantom marker" do
      assert TypeRenderer.render(quote(do: stream(String.t()))) ==
               "Musubi.StreamField<string>"
    end

    test "list of nested list" do
      assert TypeRenderer.render(quote(do: list(list(integer())))) == "number[][]"
    end

    test "literal-keyed map with single atom key" do
      assert TypeRenderer.render(quote(do: %{type: :active})) == ~s/{ type: "active" }/
    end

    test "literal-keyed map with multiple keys" do
      ast = quote(do: %{a: String.t(), b: integer()})
      assert TypeRenderer.render(ast) == "{ a: string; b: number }"
    end

    test "string-key map" do
      ast = quote(do: %{"key" => String.t()})
      assert TypeRenderer.render(ast) == ~s/{ "key": string }/
    end

    test "nested map" do
      ast = quote(do: %{outer: %{inner: integer()}})
      assert TypeRenderer.render(ast) == "{ outer: { inner: number } }"
    end

    test "nested map with stream field" do
      ast = quote(do: %{feed: %{messages: stream(String.t())}})

      assert TypeRenderer.render(ast) ==
               "{ feed: { messages: Musubi.StreamField<string> } }"
    end
  end

  describe "unions" do
    test "T | nil" do
      assert TypeRenderer.render(quote(do: String.t() | nil)) == "string | null"
    end

    test "three-way union (left-associative)" do
      ast = quote(do: String.t() | integer() | boolean())
      assert TypeRenderer.render(ast) == "string | number | boolean"
    end

    test "atom-literal union" do
      ast = quote(do: :ok | :err)
      assert TypeRenderer.render(ast) == ~s/"ok" | "err"/
    end

    test "list of union falls back to Array<...>" do
      ast = quote(do: list(String.t() | integer()))
      assert TypeRenderer.render(ast) == "Array<string | number>"
    end

    test "stream of union renders as Musubi.StreamField<union>" do
      ast = quote(do: stream(String.t() | integer()))
      assert TypeRenderer.render(ast) == "Musubi.StreamField<string | number>"
    end

    test "union of literal maps" do
      ast = quote(do: %{type: :a} | %{type: :b, value: integer()})
      assert TypeRenderer.render(ast) == ~s/{ type: "a" } | { type: "b"; value: number }/
    end
  end

  describe "module references" do
    test "Module.t() emits the full Elixir alias path" do
      ast = quote(do: Musubi.TestSupport.TypespecProbeChild.t())
      assert TypeRenderer.render(ast) == "Musubi.TestSupport.TypespecProbeChild"
    end

    test "Module.state() emits Musubi.StoreField<\"...\"> phantom marker" do
      ast = quote(do: Musubi.TestSupport.TypespecProbeChild.state())

      assert TypeRenderer.render(ast) ==
               ~s|Musubi.StoreField<"Musubi.TestSupport.TypespecProbeChild">|
    end

    test "Musubi.AsyncResult.of(T) renders as Musubi.AsyncField<T>" do
      ast = quote(do: Musubi.AsyncResult.of(String.t()))
      assert TypeRenderer.render(ast) == "Musubi.AsyncField<string>"
    end

    test "AsyncResult.of(stream(T)) renders as Musubi.AsyncField<Musubi.StreamField<T>>" do
      ast = quote(do: Musubi.AsyncResult.of(stream(String.t())))
      assert TypeRenderer.render(ast) == "Musubi.AsyncField<Musubi.StreamField<string>>"
    end

    test "AsyncResult.of with cross-module ref" do
      ast = quote(do: Musubi.AsyncResult.of(Musubi.TestSupport.TypespecProbeChild.t()))

      assert TypeRenderer.render(ast) ==
               "Musubi.AsyncField<Musubi.TestSupport.TypespecProbeChild>"
    end

    test "non-AsyncResult `.of/1` falls back to unknown" do
      ast = quote(do: Some.Other.Module.of(String.t()))
      assert TypeRenderer.render(ast) == "unknown"
    end
  end

  describe "fallback" do
    test "unknown AST shape renders as \"unknown\"" do
      assert TypeRenderer.render({:weird_node, [], [:nope]}) == "unknown"
    end
  end
end
