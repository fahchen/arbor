defmodule MessagesStore.MixProject do
  use Mix.Project

  def project do
    [
      app: :messages_store,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: false,
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:arbor, path: "../.."}
    ]
  end
end
