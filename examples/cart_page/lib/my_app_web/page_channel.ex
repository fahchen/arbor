defmodule MyAppWeb.PageChannel do
  @moduledoc false

  use Arbor.Transport.Channel, root: MyApp.Stores.CartPageStore

  @default_join_params %{
    cart_id: "demo-cart",
    current_user: %{id: "u1", name: "Ada"}
  }

  @doc false
  @impl Phoenix.Channel
  def join(topic, _params, socket) do
    Arbor.Transport.Channel.__join__(
      MyApp.Stores.CartPageStore,
      topic,
      @default_join_params,
      socket
    )
  end
end
