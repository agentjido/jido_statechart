defmodule Jido.Statechart.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source_url "https://github.com/agentjido/jido_statechart"

  def project do
    [
      app: :jido_statechart,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
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
          "guides",
          "examples",
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
        extras: [
          "README.md",
          "guides/architecture.md",
          "guides/semantics.md",
          "guides/scxml.md",
          "guides/verification.md",
          "guides/runtime.md",
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

  def application, do: [extra_applications: [:crypto]]

  def cli, do: [preferred_envs: [quality: :test]]

  defp deps do
    if System.get_env("JIDO_STATECHART_HEX_GATE") == "1" do
      published_deps()
    else
      local_deps()
    end
  end

  defp local_deps do
    [
      {:jido, path: "../jido", override: true},
      {:jido_action, path: "../jido_action", override: true},
      {:jido_signal, path: "../jido_signal", override: true},
      {:zoi, path: "../zoi", override: true},
      {:saxy, "~> 1.6"},
      {:jason, "~> 1.4"},
      {:stream_data, "~> 1.4", only: :test, runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp published_deps do
    [
      {:jido, "~> 3.0.0-beta.1"},
      {:jido_action, "~> 3.0.0-beta.12"},
      {:jido_signal, "~> 3.0.0-beta.4"},
      {:zoi, "~> 0.18.11"},
      {:saxy, "~> 1.6"},
      {:jason, "~> 1.4"},
      {:stream_data, "~> 1.4", only: :test, runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
