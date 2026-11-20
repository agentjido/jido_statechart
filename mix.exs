defmodule Jido.Statechart.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source_url "https://github.com/agentjido/jido_statechart"

  def project do
    [
      app: :jido_statechart,
      version: @version,
      elixir: "~> 1.18",
      deps: deps(),
      test_ignore_filters: [fn path -> String.starts_with?(path, "test/fixtures/") end],
      name: "Jido Statechart",
      description: "Bounded, deterministic statecharts for Jido V3 Agents",
      source_url: @source_url,
      homepage_url: "https://jido.run",
      package: [
        licenses: ["Apache-2.0", "BSD-3-Clause"],
        maintainers: ["Mike Hostetler"],
        links: %{"GitHub" => @source_url, "Website" => "https://jido.run"},
        files: [
          "lib",
          "test/fixtures/w3c",
          "mix.exs",
          ".formatter.exs",
          "README.md",
          "CHANGELOG.md",
          "CONTRIBUTING.md",
          "LICENSE"
        ]
      ],
      docs: [
        main: "readme",
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
          {"LICENSE", title: "Apache 2.0 License"}
        ]
      ],
      test_coverage: [summary: [threshold: 90], ignore_modules: [~r/^JidoStatechartTest/]],
      aliases: [
        quality: [
          "format --check-formatted",
          "compile --warnings-as-errors",
          "test --warnings-as-errors"
        ]
      ]
    ]
  end

  def application, do: [extra_applications: [:crypto, :inets, :xmerl]]

  def cli, do: [preferred_envs: [quality: :test]]

  defp deps do
    [
      {:jido, github: "agentjido/jido", ref: "aa61e26d50f8035dcffd9149515e60fcda9dcc6a"},
      {:req, "~> 0.7"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
