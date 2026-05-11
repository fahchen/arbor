defmodule MyAppWeb.PageChannel do
  @moduledoc false

  use Arbor.Transport.Channel, stores: [MyApp.Stores.CartPageStore]
end
