defmodule Arbor.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/fahchen/arbor"

  def project do
    [
      app: :arbor,
      version: @version,
      description: description(),
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      consolidate_protocols: Mix.env() != :test,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      package: package(),
      dialyzer: [
        plt_local_path: "priv/plts/arbor.plt",
        plt_core_path: "priv/plts/core.plt",
        plt_add_apps: [:ex_unit, :mix],
        ignore_warnings: ".dialyzer_ignore.exs"
      ],
      aliases: aliases()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Arbor.Application, []}
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:telemetry, "~> 0.4 or ~> 1.0"},
      {:typed_structor, "~> 0.6.1"},
      {:jsonpatch, "~> 2.2"},
      {:phoenix, ">= 1.5.3 and < 2.0.0"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:ritual, github: "fahchen/ritual", only: :dev, runtime: false},
      {:benchee, "~> 1.3", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Server-authoritative, page-scoped runtime library for Elixir/Phoenix applications."
  end

  # Hex package contents. Includes the JS source under `packages/*/src`
  # so that consuming Phoenix apps can reference them via
  # `file:../deps/arbor/packages/<name>` from their JS package.json. The
  # consumer's bundler (Vite, esbuild) transpiles `.ts`/`.tsx` on demand.
  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(
          lib
          mix.exs
          README.md
          guides
          packages/client/src
          packages/client/package.json
          packages/react/src
          packages/react/package.json
        )
    ]
  end

  defp docs do
    public_modules = docs_modules()

    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      filter_modules: fn module, _metadata -> module in public_modules end,
      skip_undefined_reference_warnings_on: &skip_doc_reference?/1,
      skip_code_autolink_to: &skip_doc_reference?/1,
      extras: [
        "README.md",
        "guides/getting-started.md",
        "guides/phoenix-setup.md",
        "guides/client-and-react.md",
        "docs/client-contract.md",
        "docs/persistence-pattern.md"
      ],
      groups_for_extras: [
        Tutorials: [
          "guides/getting-started.md",
          "guides/phoenix-setup.md",
          "guides/client-and-react.md"
        ],
        Reference: [
          "docs/client-contract.md",
          "docs/persistence-pattern.md"
        ]
      ],
      groups_for_modules: [
        "Store Authoring": [
          Arbor.Store,
          Arbor.State,
          Arbor.Input,
          Arbor.Socket,
          Arbor.Child
        ],
        Runtime: [
          Arbor.Async,
          Arbor.AsyncResult,
          Arbor.Lifecycle,
          Arbor.Stream,
          Arbor.Telemetry
        ],
        Transport: [
          Arbor.Transport.Socket,
          Arbor.Transport.ConnectionChannel,
          Arbor.Transport.Channel
        ],
        Codegen: [
          Mix.Tasks.Compile.ArborTs
        ],
        Testing: [
          Arbor.Testing
        ]
      ]
    ]
  end

  defp docs_modules do
    [
      Arbor.Store,
      Arbor.State,
      Arbor.Input,
      Arbor.Socket,
      Arbor.Child,
      Arbor.Async,
      Arbor.AsyncResult,
      Arbor.Lifecycle,
      Arbor.Stream,
      Arbor.Telemetry,
      Arbor.Transport.Socket,
      Arbor.Transport.ConnectionChannel,
      Arbor.Transport.Channel,
      Mix.Tasks.Compile.ArborTs,
      Arbor.Testing
    ]
  end

  defp skip_doc_reference?(reference) when is_binary(reference) do
    Enum.any?(skipped_doc_references(), &String.starts_with?(reference, &1))
  end

  defp skip_doc_reference?(_other), do: false

  defp skipped_doc_references do
    [
      "Arbor.Application",
      "Arbor.Async.Telemetry",
      "Arbor.AsyncSupervisor",
      "Arbor.Codegen.TypeScript.Manifest",
      "Arbor.DSL.",
      "Arbor.Hooks.",
      "Arbor.Page.",
      "Arbor.Plugin.",
      "Arbor.Resolver",
      "Arbor.Socket.handle_join/2",
      "Arbor.State.__using__/1",
      "Arbor.Store.__using__/1",
      "Arbor.Stream.Slot",
      "Arbor.Type",
      "Arbor.Wire",
      "Resolver",
      "Module.__arbor_validate_state__/1"
    ]
  end

  defp aliases() do
    [
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "compile.arbor_ts --check",
        "dialyzer",
        "test"
      ],
      bench: [
        "run bench/page_runtime_bench.exs",
        "run bench/diff_bench.exs",
        "run bench/stream_bench.exs"
      ]
    ]
  end
end
