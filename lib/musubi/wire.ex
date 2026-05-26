defprotocol Musubi.Wire do
  @moduledoc """
  Converts an Elixir term into its wire-form equivalent.

  Wire form is the JSON-shaped representation Musubi pushes to clients. The
  protocol normalizes:

    * atoms (other than `nil`/`true`/`false`) into strings,
    * atom map keys into string keys,
    * structs into plain maps via deriving (recursing on field values),
    * lists by recursing element-wise,
    * `DateTime`/`NaiveDateTime`/`Date`/`Time` into ISO8601 strings,
    * `URI` into its string form.

  Scalars (binaries, integers, floats, booleans, `nil`) pass through unchanged.

  Types without a `Musubi.Wire` implementation (e.g. tuples, `MapSet`,
  `Decimal`, or undecorated structs) raise `Protocol.UndefinedError`;
  convert them to a wire-safe shape before returning them from a render
  or command reply.

  Auto-derive: `Musubi.State.__using__/1` and `Musubi.Store.__using__/1` add
  `@derive Musubi.Wire`, so user-defined store and state structs serialize
  field-by-field without bespoke `defimpl`.

  ## Examples

      iex> Musubi.Wire.to_wire(:active)
      "active"
      iex> Musubi.Wire.to_wire(%{title: "Inbox", status: :paused})
      %{"title" => "Inbox", "status" => "paused"}
  """

  @doc "Returns the wire-shape representation of `value`."
  @spec to_wire(t()) :: term()
  def to_wire(value)

  @doc false
  defmacro __deriving__(module, options) do
    case Keyword.get(options, :only) do
      list when is_list(list) -> deriving_with_take(module, list)
      _other -> deriving_full(module)
    end
  end

  defp deriving_with_take(module, take) do
    quote bind_quoted: [module: module, take: take] do
      defimpl Musubi.Wire, for: module do
        def to_wire(struct) do
          stream_field_names = Musubi.Wire.Encoder.stream_field_names(unquote(module))

          struct
          |> Map.from_struct()
          |> Map.take(unquote(take))
          |> Musubi.Wire.Encoder.derive_map(stream_field_names)
        end
      end
    end
  end

  defp deriving_full(module) do
    quote bind_quoted: [module: module] do
      defimpl Musubi.Wire, for: module do
        def to_wire(struct) do
          stream_field_names = Musubi.Wire.Encoder.stream_field_names(unquote(module))

          struct
          |> Map.from_struct()
          |> Musubi.Wire.Encoder.derive_map(stream_field_names)
        end
      end
    end
  end
end

defimpl Musubi.Wire, for: Atom do
  def to_wire(nil), do: nil
  def to_wire(true), do: true
  def to_wire(false), do: false
  def to_wire(atom), do: Atom.to_string(atom)
end

defimpl Musubi.Wire, for: BitString do
  def to_wire(value) when is_binary(value), do: value
end

defimpl Musubi.Wire, for: Integer do
  def to_wire(value), do: value
end

defimpl Musubi.Wire, for: Float do
  def to_wire(value), do: value
end

defimpl Musubi.Wire, for: List do
  def to_wire(list), do: Enum.map(list, &Musubi.Wire.to_wire/1)
end

defimpl Musubi.Wire, for: Map do
  def to_wire(map) do
    Map.new(map, fn {key, value} ->
      {Musubi.Wire.Encoder.key_to_wire(key), Musubi.Wire.to_wire(value)}
    end)
  end
end

defimpl Musubi.Wire, for: DateTime do
  def to_wire(value), do: DateTime.to_iso8601(value)
end

defimpl Musubi.Wire, for: NaiveDateTime do
  def to_wire(value), do: NaiveDateTime.to_iso8601(value)
end

defimpl Musubi.Wire, for: Date do
  def to_wire(value), do: Date.to_iso8601(value)
end

defimpl Musubi.Wire, for: Time do
  def to_wire(value), do: Time.to_iso8601(value)
end

defimpl Musubi.Wire, for: URI do
  def to_wire(value), do: URI.to_string(value)
end

defimpl Musubi.Wire, for: Musubi.Child do
  def to_wire(%Musubi.Child{} = child) do
    raise ArgumentError,
          "Musubi.Wire.to_wire/1 received an unresolved child placeholder: #{inspect(child)}. " <>
            "Resolver must substitute child(...) sentinels before serialization."
  end
end

defmodule Musubi.Wire.Encoder do
  @moduledoc false

  @doc false
  @spec key_to_wire(atom() | String.t() | term()) :: String.t()
  def key_to_wire(key) when is_atom(key) and not is_nil(key) and not is_boolean(key),
    do: Atom.to_string(key)

  def key_to_wire(key) when is_binary(key), do: key

  def key_to_wire(key) do
    raise ArgumentError,
          "Musubi.Wire only supports atom or binary map keys, got: #{inspect(key)}"
  end

  @doc false
  @spec stream_field_names(module()) :: [atom()]
  def stream_field_names(module) when is_atom(module) do
    if function_exported?(module, :__musubi__, 1) do
      streams = List.wrap(module.__musubi__(:streams))
      Enum.map(streams, & &1.name)
    else
      []
    end
  end

  @doc false
  @spec derive_map(map(), [atom()]) :: map()
  def derive_map(map, stream_field_names) when is_map(map) and is_list(stream_field_names) do
    Map.new(map, fn {key, value} ->
      wire_value =
        if key in stream_field_names do
          Musubi.Wire.to_wire(Musubi.Stream.Marker.new(key))
        else
          Musubi.Wire.to_wire(value)
        end

      {key_to_wire(key), wire_value}
    end)
  end
end
