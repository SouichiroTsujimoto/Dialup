defmodule HandoffDemo.MixProject do
  use Mix.Project

  def project do
    [
      app: :handoff_demo,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: [{:dialup, path: "../.."}]
    ]
  end

  def application do
    [mod: {HandoffDemo, []}, extra_applications: [:logger]]
  end
end
