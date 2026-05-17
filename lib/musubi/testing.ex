defmodule Musubi.Testing do
  @moduledoc """
  Test entry point for Musubi root stores, analogous to
  `Phoenix.LiveViewTest`. Wraps `Musubi.Page.Server.start_link/1` with
  test-friendly defaults and exposes the primary assertion surface
  (`render/2`).

  ## Primary surface

  Assert against the rendered wire-shape map — the same contract a
  client observes — not internal `socket.assigns`. `assigns/2` is an
  escape hatch for state not surfaced through `render/1`; prefer
  `render/2` for contract assertions.

  ## Example

      page = Musubi.Testing.mount(RoomStore, %{"room_code" => "AB12"})
      Musubi.Testing.dispatch_command(page, :ko, %{"target" => "p2"})

      assert Musubi.Testing.render(page) == %{
        winner: :p1,
        hp: %{p1: 100, p2: 0}
      }
  """

  alias Musubi.Page.Server
  alias Musubi.Socket

  defstruct [:pid, :root, :transport]

  @typedoc "Handle returned by `mount/3`; passed back into the other helpers."
  @type t :: %__MODULE__{pid: pid(), root: module(), transport: pid()}

  @doc """
  Mounts `module` as a root page. Push patches are delivered to the
  calling process; consume them with `ExUnit.Assertions.assert_receive/2`.
  Tears down on test exit via `start_supervised!`.

  ## Options

    * `:transport_pid` — pid that receives push patches. Defaults to `self()`.
  """
  @spec mount(module(), map(), keyword()) :: t()
  def mount(module, params \\ %{}, opts \\ []) when is_atom(module) and is_map(params) do
    transport = Keyword.get(opts, :transport_pid, self())

    pid =
      ExUnit.Callbacks.start_supervised!({Server, {module, params, %{transport_pid: transport}}})

    %__MODULE__{pid: pid, root: module, transport: transport}
  end

  @doc """
  Dispatches a command to a mounted store. Defaults to the root
  (`store_id: []`); pass a child path to address a nested store.

  Mirrors the client-side `proxy.dispatchCommand(name, payload)`
  contract.
  """
  @spec dispatch_command(t(), atom(), map(), Socket.store_id()) ::
          {:ok, map()} | {:error, term()}
  def dispatch_command(%__MODULE__{pid: pid}, name, payload, store_id \\ [])
      when is_atom(name) and is_map(payload) and is_list(store_id) do
    Server.command(pid, store_id, name, payload)
  end

  @doc """
  Runs the addressed store's `render/1` against its current socket and
  returns the wire-shape map. Primary assertion surface — what the
  client would observe after the next reconcile.

  Values are returned as native Elixir terms (atom literals stay atoms);
  the JSON-string transformation happens on the way out to the client,
  not inside `render/1`.
  """
  @spec render(t(), Socket.store_id()) :: map()
  def render(%__MODULE__{pid: pid}, store_id \\ []) when is_list(store_id) do
    {:ok, %{socket: socket, module: module}} = Server.peek(pid, store_id)
    module.render(socket)
  end

  @doc """
  Returns the raw `socket.assigns` for the addressed store.

  Escape hatch — prefer `render/2` for contract assertions. Use only
  when the value you need is not exposed through `render/1` (e.g. a
  private field captured for later use).
  """
  @spec assigns(t(), Socket.store_id()) :: map()
  def assigns(%__MODULE__{pid: pid}, store_id \\ []) when is_list(store_id) do
    {:ok, %{socket: socket}} = Server.peek(pid, store_id)
    socket.assigns
  end
end
