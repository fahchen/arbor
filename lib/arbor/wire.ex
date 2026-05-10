defprotocol Arbor.Wire do
  @moduledoc """
  Converts an Elixir term into its wire-form equivalent.

  Wire form is the JSON-shaped representation Arbor pushes to clients. The
  protocol normalizes:

    * atoms (other than `nil`/`true`/`false`) into strings,
    * atom map keys into string keys,
    * structs into plain maps via deriving (recursing on field values),
    * lists by recursing element-wise.

  Scalars (binaries, integers, floats, booleans, `nil`) pass through unchanged.

  Auto-derive: `Arbor.State.__using__/1` and `Arbor.Store.__using__/1` add
  `@derive Arbor.Wire`, so user-defined store and state structs serialize
  field-by-field without bespoke `defimpl`.

  ## Examples

      iex> Arbor.Wire.to_wire(:active)
      "active"
      iex> Arbor.Wire.to_wire(%{title: "Inbox", status: :paused})
      %{"title" => "Inbox", "status" => "paused"}
  """

  @doc "Returns the wire-shape representation of `value`."
  @spec to_wire(t()) :: term()
  def to_wire(value)

  @doc false
  defmacro __deriving__(module, _options) do
    quote do
      defimpl Arbor.Wire, for: unquote(module) do
        def to_wire(struct) do
          stream_field_names = Arbor.Wire.Encoder.stream_field_names(unquote(module))

          struct
          |> Map.from_struct()
          |> Map.new(fn {key, value} ->
            wire_value =
              if key in stream_field_names do
                # Per BDR-0014 + replication/json-patch-diff, stream-typed
                # field values never appear in JSON Patch ops. The diff sees
                # `[]` on both sides; stream content flows via stream_ops.
                []
              else
                Arbor.Wire.to_wire(value)
              end

            {Arbor.Wire.Encoder.key_to_wire(key), wire_value}
          end)
        end
      end
    end
  end
end

defimpl Arbor.Wire, for: Atom do
  def to_wire(nil), do: nil
  def to_wire(true), do: true
  def to_wire(false), do: false
  def to_wire(atom), do: Atom.to_string(atom)
end

defimpl Arbor.Wire, for: BitString do
  def to_wire(value) when is_binary(value), do: value
end

defimpl Arbor.Wire, for: Integer do
  def to_wire(value), do: value
end

defimpl Arbor.Wire, for: Float do
  def to_wire(value), do: value
end

defimpl Arbor.Wire, for: List do
  def to_wire(list), do: Enum.map(list, &Arbor.Wire.to_wire/1)
end

defimpl Arbor.Wire, for: Map do
  def to_wire(map) do
    Map.new(map, fn {key, value} ->
      {Arbor.Wire.Encoder.key_to_wire(key), Arbor.Wire.to_wire(value)}
    end)
  end
end

defimpl Arbor.Wire, for: Arbor.Child do
  def to_wire(%Arbor.Child{} = child) do
    raise ArgumentError,
          "Arbor.Wire.to_wire/1 received an unresolved child placeholder: #{inspect(child)}. " <>
            "Resolver must substitute child(...) sentinels before serialization."
  end
end

defmodule Arbor.Wire.Encoder do
  @moduledoc false

  @doc false
  @spec key_to_wire(atom() | String.t() | term()) :: String.t()
  def key_to_wire(key) when is_atom(key) and not is_nil(key) and not is_boolean(key),
    do: Atom.to_string(key)

  def key_to_wire(key) when is_binary(key), do: key

  def key_to_wire(key) do
    raise ArgumentError,
          "Arbor.Wire only supports atom or binary map keys, got: #{inspect(key)}"
  end

  @doc false
  @spec stream_field_names(module()) :: [atom()]
  def stream_field_names(module) when is_atom(module) do
    if function_exported?(module, :__arbor__, 1) do
      streams = List.wrap(module.__arbor__(:streams))
      Enum.map(streams, & &1.name)
    else
      []
    end
  end
end
