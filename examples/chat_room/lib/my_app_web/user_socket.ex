defmodule MyAppWeb.UserSocket do
  @moduledoc false

  use Phoenix.Socket

  channel("page:*", MyAppWeb.PageChannel)

  @doc false
  @impl Phoenix.Socket
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @doc false
  @impl Phoenix.Socket
  def id(_socket), do: nil
end
