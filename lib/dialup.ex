defmodule Dialup do
  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      {Bandit, plug: Dialup.Server, port: 8080}
    ]

    opts = [strategy: :one_for_one, name: Dialup.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
