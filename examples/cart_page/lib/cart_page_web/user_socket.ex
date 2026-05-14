defmodule CartPageWeb.UserSocket do
  @moduledoc false

  use Arbor.Socket,
    roots: [
      CartPage.Stores.CartPageStore
    ]
end
