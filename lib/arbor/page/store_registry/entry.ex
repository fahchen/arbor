defmodule Arbor.Page.StoreRegistry.Entry do
  @moduledoc "Logical store node entry tracked inside the page server."

  use TypedStructor

  alias Arbor.Socket

  typed_structor do
    field(:socket, Socket.t(), enforce: true)
    field(:module, module(), enforce: true)
  end
end
