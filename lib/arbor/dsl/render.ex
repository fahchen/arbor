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

  The runtime reads the current `Arbor.AsyncResult` from `socket.assigns` under
  the same stream name, falling back to `Arbor.AsyncResult.loading/0` before the
  async task has been started.

      def render(socket) do
        %{messages: async_stream(:messages)}
      end
  """
  @spec async_stream(Arbor.Stream.stream_name()) :: Macro.t()
  defmacro async_stream(name) when is_atom(name) do
    quote do
      %Arbor.Stream.AsyncPlaceholder{name: unquote(name)}
    end
  end
end
