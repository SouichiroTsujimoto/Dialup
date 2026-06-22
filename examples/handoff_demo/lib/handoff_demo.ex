defmodule HandoffDemo do
  use Application

  use Dialup,
    app_dir: __DIR__ <> "/app",
    title: "Dialup Human → AI Handoff",
    lang: "en"

  @impl Application
  def start(_type, _args) do
    port = System.get_env("PORT", "4100") |> String.to_integer()

    Supervisor.start_link([{Dialup, app: __MODULE__, port: port}],
      strategy: :one_for_one,
      name: HandoffDemo.Supervisor
    )
  end
end
