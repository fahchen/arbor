defmodule Arbor.PageServer.State do
  @moduledoc false

  use TypedStructor

  alias Arbor.Socket
  alias Arbor.StoreRegistry

  typed_structor do
    field(:root_module, module(), enforce: true)
    field(:root_socket, Socket.t(), enforce: true)
    field(:store_registry, StoreRegistry.t(), enforce: true)
    field(:version, non_neg_integer(), default: 0)
    field(:transport, term(), default: nil)
  end
end
