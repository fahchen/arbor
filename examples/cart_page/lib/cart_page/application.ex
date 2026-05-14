defmodule CartPage.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: CartPage.PubSub},
      CartPage.Persistence,
      CartPageWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: CartPage.Supervisor)
  end
end
