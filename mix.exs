defmodule OCI.MixProject do
  use Mix.Project

  def project do
    [
      app: :oci,
      version: "0.0.2",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      description:
        "A Plug-based implementation of the OCI Distribution Specification (v2) registry server for Elixir applications. Provides a compliant HTTP API for container image distribution, supporting pull, push, and management operations.",
      source_url: "https://github.com/massdriver-cloud/oci",
      homepage_url: "https://github.com/massdriver-cloud/oci",
      docs: [
        main: "readme",
        logo: "logo.png",
        extras: ["README.md"]
      ],
      aliases: aliases(),
      dialyzer: dialyzer(),
      test_coverage: [
        tool: ExCoveralls,
        filter: [
          "test/support/*",
          "lib/oci/inspector.ex"
        ]
      ]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def cli do
    [
      preferred_envs: [
        "coveralls.detail": :test,
        "coveralls.html": :test,
        "coveralls.post": :test,
        coveralls: :test,
        qa: :test,
        test: :test
      ]
    ]
  end

  defp dialyzer do
    [
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
      plt_add_apps: [:mix, :iex, :ex_unit],
      ignore_warnings: ".dialyzer_ignore.exs"
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:plug, ">= 1.10.0 and < 2.0.0"},
      {:typed_struct, "~> 0.3"},
      {:jason, "~> 1.4", override: true},
      {:uuid, "~> 1.1", override: true},

      # Dev dependencies
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.29", only: [:test, :dev], runtime: false},
      {:excoveralls, "~> 0.18", only: [:test, :dev]},
      {:mix_test_watch, "~> 1.1", only: [:dev, :test], runtime: false},
      {:plug_cowboy, "~> 2.7", only: [:test, :dev]},
      {:phoenix, ">= 1.5.0 and < 2.0.0", only: [:test, :dev]},
      {:temp, "~> 0.4", only: [:test, :dev]}
    ]
  end

  defp aliases do
    [
      qa: [
        "test",
        "credo",
        "dialyzer",
        "docs"
      ]
    ]
  end

  defp package do
    [
      name: "oci",
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => "https://github.com/massdriver-cloud/oci"
      },
      files: [
        "lib",
        "mix.exs",
        "README.md",
        "logo.png"
      ]
    ]
  end
end
