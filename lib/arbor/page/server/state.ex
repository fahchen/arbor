defmodule Arbor.Page.Server.State do
  @moduledoc false

  use TypedStructor

  alias Arbor.Page.StoreRegistry
  alias Arbor.Socket

  typed_structor do
    field(:root_module, module(), enforce: true)
    field(:root_socket, Socket.t(), enforce: true)
    field(:store_registry, StoreRegistry.t(), enforce: true)
    field(:version, non_neg_integer(), default: 0)
    field(:transport, term(), default: nil)
  end
end
