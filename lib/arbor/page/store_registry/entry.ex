defmodule Arbor.Page.StoreRegistry.Entry do
  @moduledoc "Logical store node entry tracked inside the page server."

  use TypedStructor

  alias Arbor.Socket

  @type resolved_state() ::
          nil
          | boolean()
          | number()
          | String.t()
          | atom()
          | [resolved_state()]
          | %{optional(term()) => resolved_state()}

  typed_structor do
    field :socket, Socket.t(),
      enforce: true,
      doc:
        "Socket for this store node — carries assigns, hook table, identity. Preserved across identity-stable re-renders."

    field :module, module(),
      enforce: true,
      doc: "Store module backing this node. Changing the module forces a fresh mount (BDR-0011)."

    field :resolved_state, resolved_state(),
      default: nil,
      doc:
        "Last resolved render output for this node. Reused when memoization skips `update/2` and `to_state/1` (BDR-0013)."

    field :consumed_keys, [Socket.assign_key()],
      default: [],
      doc:
        "Assign keys this child consumes (the keys the parent passed via `child(Module, id: ..., key: value, ...)`). Memoization skips this child when none of these intersect the parent's `socket.assigns.__changed__`."
  end
end
