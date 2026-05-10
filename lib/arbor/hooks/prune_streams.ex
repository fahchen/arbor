defmodule Arbor.Hooks.PruneStreams do
  @moduledoc """
  Cycle-end stream-state pruner. Drains pending ops from each
  `Arbor.LiveStream` marked changed during the current render cycle into
  the socket-private accumulator at `Arbor.Stream.drained_key/0`, then
  prunes the struct and clears `__streams__.__changed__`.

  Attached to the `:after_serialize` lifecycle stage so it fires once per
  store, after `Arbor.Wire.to_wire/1` has produced the wire term. The page
  runtime collects from the drained accumulator after the resolver returns
  to build the patch envelope's `stream_ops` (BDR-0014, BDR-0018).

  This mirrors Phoenix.LiveView's `Phoenix.LiveView.LiveStream.prune/1`
  invoked at `:after_render` — the names differ because Arbor's cycle ends
  at the page server's flush, not at template render time.
  """

  alias Arbor.Lifecycle
  alias Arbor.Socket
  alias Arbor.Stream

  @doc """
  Drains and prunes any stream marked changed since the last render cycle.

  ## Examples

      socket = Arbor.Hooks.PruneStreams.after_serialize(%{}, socket)
      |> elem(1)
  """
  @spec after_serialize(term(), Socket.t()) :: Lifecycle.hook_result()
  def after_serialize(_wire, %Socket{} = socket) do
    {:cont, Stream.drain_and_prune(socket)}
  end
end
