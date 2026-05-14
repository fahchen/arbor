defmodule PollAppWeb.Endpoint do
  @moduledoc false

  use Phoenix.Endpoint, otp_app: :poll_app

  socket("/socket", PollAppWeb.UserSocket,
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
  plug(PollAppWeb.Router)
end
