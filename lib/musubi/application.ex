defmodule Musubi.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      Musubi.AsyncSupervisor
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Musubi.Supervisor)
  end
end
