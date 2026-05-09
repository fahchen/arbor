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
      doc:
        "Runtime-internal table of currently mounted store nodes keyed by `(parent_path, module, id)`."

    field :version, non_neg_integer(),
      default: 0,
      doc:
        "Monotonic counter incremented per emitted patch envelope. Resets to 0 on a fresh page server (e.g. after reconnect)."

    field :transport, term(),
      default: nil,
      doc:
        "Placeholder for transport-adapter state (Phoenix Channel session). M4 wires this; M1/M2 store opaquely."
  end
end
