defmodule MyAppWeb.Endpoint do
  @moduledoc false

  use Phoenix.Endpoint, otp_app: :cart_page

  socket("/socket", MyAppWeb.UserSocket,
    websocket: true,
    longpoll: false
  )

  plug(Plug.Static,
    at: "/",
    from: :cart_page,
    gzip: false,
    only: ~w(assets index.html favicon.ico)
  )

  plug(Plug.RequestId)
  plug(MyAppWeb.Router)
end
