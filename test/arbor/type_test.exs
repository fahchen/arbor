defmodule Arbor.TypeTest do
  use ExUnit.Case, async: true

  alias Arbor.Type

  defmodule LeafState do
    @moduledoc false

    use Arbor.State

    state do
      field :title, String.t()
    end
  end

  defmodule ContainerState do
    @moduledoc false

    use Arbor.State

    alias Arbor.TypeTest.LeafState

    state do
      field :leaf, LeafState.t()
    end
  end

  describe "valid_type?/1" do
    test "accepts primitives, lists, maps, unions, and module references" do
      assert Type.valid_type?(quote(do: String.t()))
      assert Type.valid_type?(quote(do: integer()))
      assert Type.valid_type?(quote(do: boolean()))
      assert Type.valid_type?(quote(do: atom()))
      assert Type.valid_type?(quote(do: nil))
      assert Type.valid_type?(quote(do: :active))
      assert Type.valid_type?(quote(do: list(String.t())))
      assert Type.valid_type?(quote(do: map()))
      assert Type.valid_type?(quote(do: %{type: :active, value: integer()}))
      assert Type.valid_type?(quote(do: String.t() | nil))
      assert Type.valid_type?(quote(do: SomeModule.t()))
      assert Type.valid_type?(quote(do: SomeModule.state()))
      assert Type.valid_type?(quote(do: stream(String.t())))
      assert Type.valid_type?(quote(do: Arbor.AsyncResult.of(stream(String.t()))))
    end

    test "rejects unknown constructors and non-literal map keys" do
      refute Type.valid_type?(quote(do: bogus_constructor()))
      refute Type.valid_type?(quote(do: %{1 => String.t()}))
      refute Type.valid_type?(quote(do: SomeModule.unknown_kind()))
    end
  end

  describe "valid?/2" do
    test "primitives" do
      assert Type.valid?("Inbox", quote(do: String.t()))
      refute Type.valid?(42, quote(do: String.t()))
      assert Type.valid?(7, quote(do: integer()))
      refute Type.valid?("7", quote(do: integer()))
      assert Type.valid?(true, quote(do: boolean()))
      refute Type.valid?("true", quote(do: boolean()))
      assert Type.valid?(nil, nil)
      refute Type.valid?("nil", nil)
    end

    test "literal atoms match wire-form strings" do
      assert Type.valid?("active", quote(do: :active))
      refute Type.valid?(:active, quote(do: :active))
      assert Type.valid?(true, quote(do: true))
      assert Type.valid?(nil, quote(do: nil))
    end

    test "lists, maps, and unions" do
      assert Type.valid?(["a", "b"], quote(do: list(String.t())))
      refute Type.valid?(["a", 1], quote(do: list(String.t())))
      assert Type.valid?(%{"a" => 1}, quote(do: map()))

      assert Type.valid?(
               %{"type" => "active"},
               quote(do: %{type: :active})
             )

      refute Type.valid?(
               %{"type" => "paused"},
               quote(do: %{type: :active})
             )

      assert Type.valid?(nil, quote(do: String.t() | nil))
      assert Type.valid?("Inbox", quote(do: String.t() | nil))
    end

    test "Module.t() resolves through host_module namespace" do
      assert Type.valid?(
               %{"title" => "Inbox"},
               quote(do: LeafState.t()),
               ContainerState
             )

      refute Type.valid?(
               %{"title" => 42},
               quote(do: LeafState.t()),
               ContainerState
             )
    end

    test "Module.state() referencing a non-store module raises at compile time" do
      defmodule Arbor.TypeTest.FakeStateRefHost do
        def __arbor__(:fields) do
          [%{name: :leaf, type: quote(do: Arbor.TypeTest.LeafState.state())}]
        end
      end

      assert_raise CompileError, ~r/is not an Arbor\.Store/, fn ->
        Type.verify_module!(Arbor.TypeTest.FakeStateRefHost)
      end
    end
  end

  describe "verify_module!/1" do
    test "loaded arbor modules pass" do
      assert :ok = Type.verify_module!(LeafState)
      assert :ok = Type.verify_module!(ContainerState)
    end

    test "raises when a referenced module does not opt into the Arbor runtime contract" do
      # The verify_module! callback walks the host module's reflection. Build
      # a fake host that exposes the same shape so we can drive the check
      # directly without depending on @after_verify firing inside the test.
      defmodule Arbor.TypeTest.FakeHost do
        def __arbor__(:fields) do
          [%{name: :payload, type: quote(do: NoSuchModule.t())}]
        end
      end

      assert_raise CompileError, ~r/NoSuchModule\.t\(\) but/, fn ->
        Type.verify_module!(Arbor.TypeTest.FakeHost)
      end
    end
  end
end
