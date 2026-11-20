defmodule Jido.Statechart.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source_url "https://github.com/agentjido/jido_statechart"

  def project do
    [
      app: :jido_statechart,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "Jido Statechart",
      description: "Bounded, deterministic statecharts for Jido V3 Agents",
      source_url: @source_url,
      homepage_url: "https://jido.run",
      package: [
        licenses: ["Apache-2.0", "BSD-3-Clause"],
        maintainers: ["Mike Hostetler"],
        links: %{
          "Changelog" => "https://hexdocs.pm/jido_statechart/changelog.html",
          "Documentation" => "https://hexdocs.pm/jido_statechart",
          "GitHub" => @source_url,
          "Website" => "https://jido.run"
        },
        files: [
          "lib",
          "test/fixtures/w3c",
          "mix.exs",
          ".formatter.exs",
          "README.md",
          "CHANGELOG.md",
          "CONTRIBUTING.md",
          "usage-rules.md",
          "LICENSE"
        ]
      ],
      docs: [
        main: "readme",
        source_ref: "v#{@version}",
        # Jido generates these links to its hidden Extension callbacks.
        skip_undefined_reference_warnings_on: [
          "Jido.Statechart.Plugin.decode_authoring_data/2",
          "Jido.Statechart.Plugin.encode_authoring_data/2",
          "Jido.Statechart.Plugin.endpoint_kinds/0",
          "Jido.Statechart.Plugin.endpoints/1",
          "Jido.Statechart.Plugin.id/0",
          "Jido.Statechart.Plugin.lower/2",
          "Jido.Statechart.Plugin.verify/2",
          "Jido.Statechart.Plugin.verify_connection/2",
          "Jido.Statechart.Plugin.vsn/0"
        ],
        extras: [
          "README.md",
          "CHANGELOG.md",
          "CONTRIBUTING.md",
          "usage-rules.md",
          {"LICENSE", title: "Apache 2.0 License"}
        ]
      ],
      test_coverage: [tool: ExCoveralls, summary: [threshold: 90]],
      dialyzer: [plt_add_apps: [:mix]],
      aliases: [
        setup: ["deps.get"],
        install_hooks: ["git_hooks.install"],
        q: ["quality"],
        quality: [
          "format --check-formatted",
          "compile --warnings-as-errors",
          "credo --min-priority high",
          "dialyzer",
          "doctor --raise"
        ]
      ]
    ]
  end

  def application, do: [extra_applications: [:crypto, :inets, :xmerl]]

  def cli do
    [
      preferred_envs: [
        install_hooks: :dev,
        coveralls: :test,
        "coveralls.html": :test
      ]
    ]
  end

  defp deps do
    [
      {:jido, github: "agentjido/jido", branch: "release/v3"},
      {:req, "~> 0.7"},
      {:splode, "~> 0.3.0"},
      {:telemetry, "~> 1.3"},
      {:zoi, "~> 0.19.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.21", only: :dev, runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test, runtime: false},
      {:git_hooks, "~> 0.8", only: [:dev, :test], runtime: false},
      {:git_ops, "~> 2.12", only: :dev, runtime: false}
    ]
  end
end
