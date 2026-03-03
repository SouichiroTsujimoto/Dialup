defmodule Dialup.Server do
  use Plug.Router

  plug(Plug.Static, at: "/", from: {:dialup, "priv/static"})
  plug(:match)
  plug(:dispatch)

  def init(opts), do: opts

  def call(conn, opts) do
    app_module = Keyword.fetch!(opts, :app)

    conn
    |> Plug.Conn.put_private(:dialup_app, app_module)
    |> super(opts)
  end

  # WebSocket upgrade endpoint
  get "/ws" do
    app_module = conn.private[:dialup_app]

    conn
    |> WebSockAdapter.upgrade(Dialup.WebSocket, %{app_module: app_module}, timeout: :infinity)
    |> halt()
  end

  get _ do
    path = conn.request_path
    app_module = conn.private[:dialup_app]

    initial_html =
      case app_module.page_for(path) do
        nil ->
          "<h1>404 Not Found</h1>"

        page_module ->
          {:ok, assigns} = page_module.mount(%{})

          case app_module.dispatch(path, assigns) do
            {:ok, html} -> html
            {:error, :not_found} -> "<h1>404 Not Found</h1>"
          end
      end

    shell =
      app_module.__shell_opts__()
      |> Map.merge(%{inner_content: initial_html})
      |> Dialup.Shell.render()

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, shell)
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end
end
