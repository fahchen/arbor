defmodule Musubi.InputTest do
  use ExUnit.Case, async: true

  defmodule AddressInput do
    @moduledoc false
    use Musubi.Input

    input do
      field :line1, String.t()
      field :city, String.t()
    end
  end

  defmodule UserInput do
    @moduledoc false
    use Musubi.Input

    input do
      field :name, String.t()
      field :age, integer()
      field :address, AddressInput.t()
    end
  end

  describe "Scenario: struct construction" do
    test "input declaration generates a struct" do
      input = %UserInput{
        name: "Alice",
        age: 30,
        address: %AddressInput{line1: "1 Way", city: "Town"}
      }

      assert input.name == "Alice"
      assert input.address.city == "Town"
    end
  end

  describe "Scenario: reflection" do
    test "exposes :fields and singular __musubi__/2 lookup" do
      assert [
               %{name: :name},
               %{name: :age},
               %{name: :address}
             ] = UserInput.__musubi__(:fields)

      assert {:ok, %{name: :name}} = UserInput.__musubi__(:field, :name)
      assert :error = UserInput.__musubi__(:field, :unknown)
    end

    test "tags module kind as :input" do
      assert UserInput.__musubi_kind__() == :input
      assert Musubi.Input.input_module?(UserInput)
      refute Musubi.Input.input_module?(Musubi.Socket)
    end

    test "no commands or attrs are exposed" do
      assert [] = UserInput.__musubi__(:commands)
      assert [] = UserInput.__musubi__(:attrs)
    end
  end

  describe "Scenario: validation" do
    test "happy path returns :ok" do
      wire = %{
        "name" => "Alice",
        "age" => 30,
        "address" => %{"line1" => "1 Way", "city" => "Town"}
      }

      assert :ok = UserInput.__musubi_validate_input__(wire)
    end

    test "missing field returns error" do
      assert {:error, errors} =
               UserInput.__musubi_validate_input__(%{"name" => "Alice", "age" => 30})

      assert Enum.any?(errors, fn {path, msg} ->
               path == "$.address" and msg =~ "missing required field"
             end)
    end

    test "wrong type returns error" do
      assert {:error, errors} =
               UserInput.__musubi_validate_input__(%{
                 "name" => "Alice",
                 "age" => "thirty",
                 "address" => %{"line1" => "1 Way", "city" => "Town"}
               })

      assert Enum.any?(errors, fn {path, msg} ->
               path == "$.age" and msg =~ "expected integer()"
             end)
    end

    test "extra key returns error" do
      assert {:error, errors} =
               UserInput.__musubi_validate_input__(%{
                 "name" => "Alice",
                 "age" => 30,
                 "address" => %{"line1" => "1 Way", "city" => "Town"},
                 "bogus" => 1
               })

      assert Enum.any?(errors, fn {path, msg} ->
               path == "$.bogus" and msg =~ "unexpected field"
             end)
    end

    test "non-map value returns error" do
      assert {:error, [{"$", _msg}]} = UserInput.__musubi_validate_input__("not a map")
    end
  end

  describe "Scenario: nested input recurses through __musubi_validate_input__" do
    test "nested input mismatches surface from the leaf" do
      assert {:error, errors} =
               UserInput.__musubi_validate_input__(%{
                 "name" => "Alice",
                 "age" => 30,
                 "address" => %{"line1" => "1 Way", "city" => 99}
               })

      assert Enum.any?(errors, fn {path, _msg} -> path == "$.address" end)
    end
  end

  describe "Scenario: derived Musubi.Wire" do
    test "input struct serializes via Wire to a string-keyed map" do
      input = %UserInput{
        name: "Alice",
        age: 30,
        address: %AddressInput{line1: "1 Way", city: "Town"}
      }

      assert %{
               "name" => "Alice",
               "age" => 30,
               "address" => %{"line1" => "1 Way", "city" => "Town"}
             } = Musubi.Wire.to_wire(input)
    end
  end
end
