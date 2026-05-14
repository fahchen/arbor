defmodule CartPageWeb.PageChannel do
  @moduledoc false

  use Arbor.Transport.Channel, stores: [CartPage.Stores.CartPageStore]
end
