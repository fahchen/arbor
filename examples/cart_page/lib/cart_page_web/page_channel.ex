defmodule CartPageWeb.PageChannel do
  @moduledoc false

  use Musubi.Transport.Channel, stores: [CartPage.Stores.CartPageStore]
end
