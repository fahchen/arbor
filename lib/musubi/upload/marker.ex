defmodule Musubi.Upload.Marker do
  @moduledoc false

  @key :__musubi_upload__
  @wire_key Atom.to_string(@key)

  @type marker() :: %{required(:__musubi_upload__) => String.t()}
  @type wire_marker() :: %{required(String.t()) => String.t()}

  @doc false
  @spec key() :: :__musubi_upload__
  def key, do: @key

  @doc false
  @spec wire_key() :: String.t()
  def wire_key, do: @wire_key

  @doc false
  @spec new(atom()) :: marker()
  def new(name) when is_atom(name), do: %{@key => Atom.to_string(name)}

  @doc false
  @spec marker?(term()) :: boolean()
  def marker?(%{@key => name}) when is_binary(name), do: true
  def marker?(%{@wire_key => name}) when is_binary(name), do: true
  def marker?(_other), do: false

  @doc false
  @spec marker_name(term()) :: String.t() | nil
  def marker_name(%{@key => name}) when is_binary(name), do: name
  def marker_name(%{@wire_key => name}) when is_binary(name), do: name
  def marker_name(_other), do: nil
end
