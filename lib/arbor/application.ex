defmodule Arbor.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      Arbor.AsyncSupervisor
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Arbor.Supervisor)
  end
end
