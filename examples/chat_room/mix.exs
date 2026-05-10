defmodule ChatRoom.MixProject do
  use Mix.Project

  def project do
    [
      app: :chat_room,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: false,
      compilers: Mix.compilers() ++ [:arbor_ts],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {MyApp.Application, []}
    ]
  end

  defp deps do
    [
      {:arbor, path: "../.."},
      {:phoenix, "~> 1.8"},
      {:phoenix_pubsub, "~> 2.1"},
      {:plug_cowboy, "~> 2.7"}
    ]
  end
end
