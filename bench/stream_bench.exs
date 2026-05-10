# Run with: mix run bench/stream_bench.exs
#
# Measures stream pending-op flush per cycle as N grows. Boots a single page
# whose root store declares one stream slot, then issues a `:bulk_insert`
# command that queues N stream inserts in one handler. The page server
# flushes pending ops once per command (BDR-0018), so the bench measures the
# end-to-end queue + flush + envelope build cost for growing N.

defmodule Bench.StreamStore do
  @moduledoc false

  use Arbor.Store

  state do
    stream(:items, %{id: String.t(), body: String.t()},
      item_key: &"item-#{&1.id}",
      limit: -10_000
    )
  end

  command :bulk_insert do
    payload :n, integer()
  end

  @impl Arbor.Store
  def mount(socket), do: {:ok, socket}

  @impl Arbor.Store
  def handle_command(:bulk_insert, %{"n" => n}, socket) do
    items = for k <- 1..n, do: %{id: Integer.to_string(k), body: "row-#{k}"}
    {:noreply, Arbor.Stream.stream(socket, :items, items)}
  end

  @impl Arbor.Store
  def render(socket), do: %{items: Map.get(socket.assigns, :items, [])}
end

defmodule Bench.StreamHelpers do
  @moduledoc false

  def start_page do
    {:ok, pid} =
      Arbor.Page.Server.start_link({Bench.StreamStore, %{}, %{transport_pid: self()}})

    Process.unlink(pid)
    drain()
    pid
  end

  def stop_page(pid) when is_pid(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    :ok
  end

  def drain do
    receive do
      {:patch, _} -> :ok
    after
      2_000 -> :timeout
    end
  end

  def bulk(pid, n) do
    {:ok, _} = Arbor.Page.Server.command(pid, [], :bulk_insert, %{"n" => n})
    drain()
    pid
  end
end

alias Bench.StreamHelpers, as: H

Benchee.run(
  %{
    "queue + flush 100" => {
      fn pid -> H.bulk(pid, 100) end,
      before_each: fn _ -> H.start_page() end,
      after_each: fn pid -> H.stop_page(pid) end
    },
    "queue + flush 1_000" => {
      fn pid -> H.bulk(pid, 1_000) end,
      before_each: fn _ -> H.start_page() end,
      after_each: fn pid -> H.stop_page(pid) end
    },
    "queue + flush 5_000" => {
      fn pid -> H.bulk(pid, 5_000) end,
      before_each: fn _ -> H.start_page() end,
      after_each: fn pid -> H.stop_page(pid) end
    }
  },
  warmup: 1,
  time: 3,
  print: [fast_warning: false]
)
