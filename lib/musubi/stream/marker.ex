defmodule Musubi.Stream.Marker do
  @moduledoc false

  @key :__musubi_stream__
  @wire_key Atom.to_string(@key)

  @type marker() :: %{required(:__musubi_stream__) => String.t()}
  @type wire_marker() :: %{required(String.t()) => String.t()}
  @typep marker_candidate() ::
           marker()
           | wire_marker()
           | %{optional(String.t() | atom()) => marker_candidate()}
           | [marker_candidate()]
           | nil
           | boolean()
           | number()
           | String.t()
           | Musubi.Stream.stream_name()

  @doc false
  @spec key() :: :__musubi_stream__
  def key, do: @key

  @doc false
  @spec wire_key() :: String.t()
  def wire_key, do: @wire_key

  @doc false
  @spec new(Musubi.Stream.stream_name()) :: marker()
  def new(name) when is_atom(name), do: %{@key => Atom.to_string(name)}

  @doc false
  @spec marker?(marker_candidate()) :: boolean()
  def marker?(%{@key => name}) when is_binary(name), do: true
  def marker?(%{@wire_key => name}) when is_binary(name), do: true
  def marker?(_value), do: false
end
