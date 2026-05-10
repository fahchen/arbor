defmodule MyAppWeb.PageChannel do
  @moduledoc false

  use Arbor.Transport.Channel, root: MyApp.Stores.ChatRoomStore

  @default_join_params %{room_id: "general"}

  @doc false
  @impl Phoenix.Channel
  def join(topic, _params, socket) do
    Arbor.Transport.Channel.__join__(
      MyApp.Stores.ChatRoomStore,
      topic,
      @default_join_params,
      socket
    )
  end
end
