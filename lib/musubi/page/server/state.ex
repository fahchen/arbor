defmodule Musubi.Page.Server.State do
  @moduledoc false

  use TypedStructor

  alias Musubi.Page.StoreTable
  alias Musubi.Socket

  typed_structor do
    field :root_module, module(),
      enforce: true,
      doc: "Root page store module — the user-defined module the runtime mounts on session start."

    field :root_socket, Socket.t(),
      enforce: true,
      doc:
        "Socket for the root store node. Carries assigns, hook table, and identity for the root."

    field :store_table, StoreTable.t(),
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
              StoreTable.key(),
              Musubi.Async.tracking_name(),
              Musubi.Async.kind()
            }
          },
          default: %{},
          doc:
            "Secondary index `task_ref => {store_id, name, kind}`, rebuilt after every handler call. Lets the page server route incoming `{ref, result}` and `{:DOWN, ref, ...}` messages to the originating store entry in O(1) without scanning the registry, and lets stale-ref lazy-discard telemetry attribute the dropped task to a specific node + family."

    field :upload_progress_last_emitted,
          %{required({[String.t()], String.t(), String.t()}) => integer()},
          default: %{},
          doc:
            "Per-entry monotonic timestamp (milliseconds) of the last emitted `progress` upload op, used to enforce the 10 Hz default throttle (BDR-0025)."
  end
end
