defmodule MyAppWeb.AppSession do
  @moduledoc false

  use Arbor.Session,
    roots: [
      cart_page: MyApp.Stores.CartPageStore
    ]
end

defmodule MyAppWeb.UserSocket do
  @moduledoc false

  use Arbor.Transport.Socket, session: MyAppWeb.AppSession
end
