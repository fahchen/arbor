defmodule Musubi.Test.Fixtures.ColdVMStore do
  @moduledoc """
  Fixture for the cold-VM regression test in `Musubi.Page.ServerTest`.

  Lives under `test/support/` so its `.beam` is written to disk —
  `:code.purge/1` + `:code.delete/1` only unloads from memory; the
  `Code.ensure_loaded?/1` guard inside `Musubi.Page.Server.module_exports?/3`
  must be able to re-read the `.beam` from disk to recover.
  """

  use Musubi.Store

  state do
    field :status, String.t()
  end

  @impl Musubi.Store
  def mount(socket), do: {:ok, Musubi.Socket.assign(socket, :status, "mounted")}

  @impl Musubi.Store
  def render(socket), do: %{status: socket.assigns.status}

  @impl Musubi.Store
  def handle_command(_name, _payload, socket), do: {:noreply, socket}
end
