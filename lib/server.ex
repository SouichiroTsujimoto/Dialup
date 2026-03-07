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
    conn = Plug.Conn.fetch_cookies(conn)

    case conn.cookies["dialup_session"] do
      nil ->
        send_resp(conn, 403, "No session")

      session_id ->
        conn
        |> WebSockAdapter.upgrade(
          Dialup.WebSocket,
          %{app_module: app_module, session_id: session_id},
          timeout: :infinity
        )
        |> halt()
    end
  end

  get _ do
    conn = Plug.Conn.fetch_cookies(conn)
    {conn, _session_id} = ensure_session_id(conn)
    path = conn.request_path
    app_module = conn.private[:dialup_app]

    initial_html =
      case app_module.page_for(path) do
        nil ->
          "<h1>404 Not Found</h1>"

        page_module ->
          # 動的ルートの場合はパラメータを抽出
          params = app_module.path_params(path)
          {:ok, assigns} = page_module.mount(params, %{params: params})

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

  defp ensure_session_id(conn) do
    case conn.cookies["dialup_session"] do
      nil ->
        id = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
        conn = Plug.Conn.put_resp_cookie(conn, "dialup_session", id, http_only: true, same_site: "Lax")
        {conn, id}

      id ->
        {conn, id}
    end
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end
end
