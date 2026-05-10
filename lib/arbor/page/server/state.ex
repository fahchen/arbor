defmodule Arbor.Page.Server.State do
  @moduledoc false

  use TypedStructor

  alias Arbor.Page.StoreRegistry
  alias Arbor.Socket

  typed_structor do
    field :root_module, module(),
      enforce: true,
      doc: "Root page store module — the user-defined module the runtime mounts on session start."

    field :root_socket, Socket.t(),
      enforce: true,
      doc:
        "Socket for the root store node. Carries assigns, hook table, and identity for the root."

    field :store_registry, StoreRegistry.t(),
      enforce: true,
      doc: "Runtime-internal table of currently mounted store nodes keyed by `store_id`."

    field :version, non_neg_integer(),
      default: 0,
      doc:
        "Monotonic counter incremented per emitted patch envelope. Resets to 0 on a fresh page server (e.g. after reconnect)."

    field :previous_wire_root, term(),
      default: nil,
      doc:
        "Wire-form root of the most recently rendered tree, cached for the next diff. `nil` between mount and the first envelope; non-nil thereafter."

    field :transport, term(),
      default: nil,
      doc:
        "Transport-adapter session info (Phoenix Channel pid + opts). Set at mount; M4 forwards patch envelopes to it after each render cycle."

    field :async_index,
          %{
            reference() => {
              StoreRegistry.identity_key(),
              Arbor.Async.tracking_name(),
              Arbor.Async.kind()
            }
          },
          default: %{},
          doc:
            "Secondary index `task_ref => {store_id, name, kind}`, rebuilt after every handler call. Lets the page server route incoming `{ref, result}` and `{:DOWN, ref, ...}` messages to the originating store entry in O(1) without scanning the registry, and lets stale-ref lazy-discard telemetry attribute the dropped task to a specific node + family."
  end
end
