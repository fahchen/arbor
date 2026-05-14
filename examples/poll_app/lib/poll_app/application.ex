defmodule PollApp.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: PollApp.PubSub},
      PollApp.Polls,
      PollAppWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: PollApp.Supervisor)
  end
end
