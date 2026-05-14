defmodule ChatRoomWeb.Endpoint do
  @moduledoc false

  use Phoenix.Endpoint, otp_app: :chat_room

  socket("/socket", ChatRoomWeb.UserSocket,
    websocket: true,
    longpoll: false
  )

  plug(Plug.Static,
    at: "/",
    from: :chat_room,
    gzip: false,
    only: ~w(assets index.html favicon.ico)
  )

  plug(Plug.RequestId)
  plug(ChatRoomWeb.Router)
end
