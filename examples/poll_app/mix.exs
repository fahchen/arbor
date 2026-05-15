defmodule PollApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :poll_app,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: false,
      compilers: Mix.compilers() ++ [:arbor_ts],
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {PollApp.Application, []}
    ]
  end

  defp deps do
    [
      {:arbor, path: "../.."},
      {:phoenix, "~> 1.8"},
      {:phoenix_pubsub, "~> 2.1"},
      {:bandit, "~> 1.0"},
      {:jason, "~> 1.4"}
    ]
  end

  defp aliases do
    [
      server: ["deps.get", "run --no-halt"],
      ui: [&ui_setup/1, &ui_dev/1]
    ]
  end

  defp ui_setup(_args), do: ui_cmd!("pnpm install")
  defp ui_dev(_args), do: ui_cmd!("pnpm dev")

  defp ui_cmd!(command) do
    case Mix.shell().cmd(command, cd: "ui") do
      0 -> :ok
      status -> Mix.raise("`#{command}` exited with status #{status}")
    end
  end
end
