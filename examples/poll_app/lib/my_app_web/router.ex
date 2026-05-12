defmodule MyAppWeb.Router do
  @moduledoc false

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/" do
    send_index(conn)
  end

  match _ do
    send_index(conn)
  end

  defp send_index(conn) do
    index_path = Path.join(:code.priv_dir(:poll_app), "static/index.html")

    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_file(200, index_path)
  end
end
