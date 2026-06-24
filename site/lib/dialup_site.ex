defmodule DialupSite do
  use Application

  use Dialup,
    app_dir: __DIR__ <> "/app",
    title: "Dialup — WebSocket-first Elixir Framework with HTTP MCP",
    lang: "en"

  @impl Application
  def start(_type, _args) do
    DialupSite.Telemetry.attach()

    port = System.get_env("PORT", "4001") |> String.to_integer()

    children = [
      {Dialup, app: __MODULE__, port: port}
    ]

    opts = [strategy: :one_for_one, name: __MODULE__.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
