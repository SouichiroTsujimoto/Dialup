defmodule Dialup.MixProject do
  use Mix.Project

  def project do
    [
      app: :dialup,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),

      # ドキュメント生成設定
      name: "Dialup",
      description: "WebSocket-first, file-based routing Elixir framework",
      source_url: "https://github.com/SouichiroTsujimoto/Dialup",
      homepage_url: "https://dialup-framework.org",
      docs: [
        main: "readme",
        extras: [
          "README.md",
          "guides/getting-started.md",
          "guides/fullstack-example.md",
          "guides/routing.md",
          "guides/state-management.md",
          "guides/lifecycle.md",
          "guides/events.md",
          "guides/helpers.md",
          "guides/testing.md",
          "guides/telemetry.md",
          "guides/deployment.md"
        ],
        groups_for_extras: [
          Guides: ~w(guides/getting-started.md guides/routing.md guides/state-management.md 
                     guides/lifecycle.md guides/events.md guides/helpers.md
                     guides/testing.md guides/telemetry.md guides/deployment.md)
        ]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      # mod: {Dialup, []},
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bandit, "~> 1.8"},
      {:websock_adapter, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.16"},
      {:phoenix_live_view, "~> 1.0"},
      {:telemetry, "~> 1.0"},

      # 開発依存
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      name: :dialup,
      description: "WebSocket-first, file-based routing Elixir framework",
      licenses: ["MIT"],
      links: %{
        "Website" => "https://dialup-framework.org",
        "GitHub" => "https://github.com/SouichiroTsujimoto/Dialup"
      },
      files: ~w(lib priv guides mix.exs README.md LICENSE)
    ]
  end
end
