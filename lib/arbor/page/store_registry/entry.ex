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
    field(:socket, Socket.t(), enforce: true)
    field(:module, module(), enforce: true)
    field(:resolved_state, resolved_state(), default: nil)
    field(:consumed_keys, [Socket.assign_key()], default: [])
  end
end
