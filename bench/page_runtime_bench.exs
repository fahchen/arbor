# Run with: mix run bench/page_runtime_bench.exs
#
# Measures `Arbor.Page.Server` mailbox throughput by:
#   * starting a single page
#   * dispatching N commands in sequence and consuming their replies
#
# Bench harness mounts a minimal store inline so the measurement covers the
# full command pipeline (route → before_command → handle_command →
# after_command → render → diff → envelope build) per command.

defmodule Bench.RuntimeStore do
  @moduledoc false

  use Arbor.Store

  state do
    field :counter, integer()
    field :note, String.t()
  end

  command(:bump)

  command :rename do
    payload :note, String.t()
  end

  @impl Arbor.Store
  def mount(socket) do
    {:ok,
     socket
     |> Arbor.Socket.assign(:counter, 0)
     |> Arbor.Socket.assign(:note, "init")}
  end

  @impl Arbor.Store
  def handle_command(:bump, _payload, socket) do
    {:noreply, Arbor.Socket.update_assign(socket, :counter, &(&1 + 1))}
  end

  @impl Arbor.Store
  def handle_command(:rename, %{note: note}, socket) do
    {:noreply, Arbor.Socket.assign(socket, :note, note)}
  end

  @impl Arbor.Store
  def render(socket) do
    %{counter: socket.assigns.counter, note: socket.assigns.note}
  end
end

defmodule Bench.RuntimeHelpers do
  @moduledoc false

  def start_page do
    parent = self()

    {:ok, pid} =
      Arbor.Page.Server.start_link(
        {Bench.RuntimeStore, %{}, %{transport_pid: parent}}
      )

    Process.unlink(pid)

    receive do
      {:patch, _} -> :ok
    after
      1_000 -> raise "no bootstrap envelope"
    end

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
      1_000 -> :timeout
    end
  end

  def run_n(pid, n) do
    Enum.each(1..n, fn _ ->
      {:ok, _reply} = Arbor.Page.Server.command(pid, [], :bump, %{})
      drain()
    end)

    pid
  end
end

alias Bench.RuntimeHelpers, as: H

Benchee.run(
  %{
    "single command (round-trip)" => {
      fn pid ->
        {:ok, _reply} = Arbor.Page.Server.command(pid, [], :bump, %{})
        H.drain()
        pid
      end,
      before_each: fn _ -> H.start_page() end,
      after_each: fn pid -> H.stop_page(pid) end
    },
    "100 commands serial" => {
      fn pid -> H.run_n(pid, 100) end,
      before_each: fn _ -> H.start_page() end,
      after_each: fn pid -> H.stop_page(pid) end
    },
    "1000 commands serial" => {
      fn pid -> H.run_n(pid, 1_000) end,
      before_each: fn _ -> H.start_page() end,
      after_each: fn pid -> H.stop_page(pid) end
    }
  },
  warmup: 1,
  time: 3,
  print: [fast_warning: false]
)
