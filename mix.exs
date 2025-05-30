defmodule OCI.MixProject do
  use Mix.Project

  def project do
    [
      app: :oci,
      version: "0.0.1",
      elixir: "~> 1.15",
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
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def cli do
    [
      preferred_envs: [
        "coveralls.detail": :test,
        "coveralls.html": :test,
        "coveralls.post": :test,
        coveralls: :test,
        credo: :dev,
        dialyzer: :dev,
        docs: :dev,
        qa: :test,
        test: :test
      ]
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
      {:excoveralls, "~> 0.18", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.29", only: :dev, runtime: false},
      {:jason, "~> 1.4", override: true},
      {:mix_test_watch, "~> 1.1", only: [:dev, :test], runtime: false},
      {:phoenix, ">= 1.5.0 and < 2.0.0", optional: true},
      {:plug, ">= 1.10.0 and < 2.0.0"},
      {:plug_cowboy, "~> 2.7", only: :test},
      {:temp, "~> 0.4", only: [:test, :dev]},
      {:typed_struct, "~> 0.3"},
      {:uuid, "~> 1.1", override: true}
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
