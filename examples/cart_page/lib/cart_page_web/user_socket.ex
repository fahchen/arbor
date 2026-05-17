defmodule CartPageWeb.UserSocket do
  @moduledoc false

  use Musubi.Socket,
    roots: [
      CartPage.Stores.CartPageStore
    ]
end
