defmodule Arbor.DSL.Render do
  @moduledoc false

  @doc """
  Places a declared stream in a store's `render/1` output.

  The runtime replaces the placeholder with a wire marker and routes stream
  contents through `PatchEnvelope.stream_ops`.

      def render(socket) do
        %{messages: stream(:messages), title: socket.assigns.title}
      end
  """
  @spec stream(Arbor.Stream.stream_name()) :: Macro.t()
  defmacro stream(name) when is_atom(name) do
    quote do
      %Arbor.Stream.Placeholder{name: unquote(name)}
    end
  end

  @doc """
  Places an async-managed stream in a store's `render/1` output.

  The returned `Arbor.AsyncResult` keeps its status and reason while replacing
  `result` with the stream placeholder. The client resolves that marker into
  the materialized item array.

      def render(socket) do
        %{messages: stream(:messages, async: socket.assigns.messages)}
      end
  """
  @spec stream(Arbor.Stream.stream_name(), keyword()) :: Macro.t()
  defmacro stream(name, opts) when is_atom(name) and is_list(opts) do
    case Keyword.fetch(opts, :async) do
      {:ok, async} ->
        quote do
          Arbor.DSL.Render.async_stream(unquote(name), unquote(async))
        end

      :error ->
        raise ArgumentError, "stream/2 expects the :async option, got: #{inspect(opts)}"
    end
  end

  @doc false
  @spec async_stream(Arbor.Stream.stream_name(), Arbor.AsyncResult.t()) :: Arbor.AsyncResult.t()
  def async_stream(name, %Arbor.AsyncResult{} = async) when is_atom(name) do
    %{async | result: %Arbor.Stream.Placeholder{name: name}}
  end

  def async_stream(name, other) when is_atom(name) do
    raise ArgumentError,
          "stream(#{inspect(name)}, async: value) expects an Arbor.AsyncResult, " <>
            "got: #{inspect(other)}"
  end
end
