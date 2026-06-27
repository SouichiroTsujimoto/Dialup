defmodule DialupSite.MixProject do
  use Mix.Project

  def project do
    [
      app: :dialup_site,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [
        dialup_site: [
          include_executables_for: [:unix],
          steps: [:assemble, :tar]
        ]
      ]
    ]
  end

  def application do
    [
      mod: {DialupSite, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:dialup, path: ".."}
    ]
  end
end
