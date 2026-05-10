defmodule MyApp.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children = [{Phoenix.PubSub, name: MyApp.PubSub}]
    Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
  end
end
