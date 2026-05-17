defmodule Arbor.Page.StoreTable.Entry do
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

  @type raw_state() :: :not_rendered | resolved_state()

  @type wire_state() ::
          nil
          | boolean()
          | number()
          | String.t()
          | [wire_state()]
          | %{optional(String.t()) => wire_state()}

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
        "Last resolved render output (Elixir form) for this node. Reused when memoization skips `update/2` and `render/1` (BDR-0013)."

    field :raw_state, raw_state(),
      default: :not_rendered,
      doc:
        "Last pre-resolution `render/1` return value (Elixir form before child resolution, stream normalization, store-id injection, or serialization). Reused by the root render short-circuit to re-walk descendants without re-invoking the root render callback."

    field :wire_state, wire_state() | nil,
      default: nil,
      doc:
        "Last serialized render output (wire form, after `Arbor.Wire.to_wire/1`). Stored alongside `resolved_state` so the M4 diff engine can compare wire-form trees without re-serializing."

    field :consumed_keys, [Socket.assign_key()],
      default: [],
      doc:
        "Assign keys this child consumes (the keys the parent passed via `child(Module, id: ..., key: value, ...)`). Memoization skips this child when none of these intersect the parent's `socket.assigns.__changed__`."
  end
end
