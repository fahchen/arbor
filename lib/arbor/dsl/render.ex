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
end
