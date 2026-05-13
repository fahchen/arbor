defmodule MyAppWeb.Endpoint do
  @moduledoc false

  use Phoenix.Endpoint, otp_app: :poll_app

  socket("/socket", MyAppWeb.UserSocket,
    websocket: true,
    longpoll: false
  )

  plug(Plug.Static,
    at: "/",
    from: :poll_app,
    gzip: false,
    only: ~w(assets index.html favicon.ico)
  )

  plug(Plug.RequestId)
  plug(MyAppWeb.Router)
end
