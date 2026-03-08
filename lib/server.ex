defmodule Dialup.Server do
  use Plug.Router

  plug(Plug.Static, at: "/", from: {:dialup, "priv/static"})
  plug(:match)
  plug(:dispatch)

  def init(opts), do: opts

  def call(conn, opts) do
    app_module = Keyword.fetch!(opts, :app)

    conn =
      conn
      |> Plug.Conn.put_private(:dialup_app, app_module)
      |> run_user_plugs(app_module)

    if conn.halted do
      conn
    else
      super(conn, opts)
    end
  end

  defp run_user_plugs(conn, app_module) do
    if function_exported?(app_module, :__plugs__, 0) do
      Enum.reduce_while(app_module.__plugs__(), conn, fn plug_spec, conn ->
        {plug_mod, plug_opts} = normalize_plug(plug_spec)
        conn = plug_mod.call(conn, plug_mod.init(plug_opts))
        if conn.halted, do: {:halt, conn}, else: {:cont, conn}
      end)
    else
      conn
    end
  end

  defp normalize_plug({mod, opts}) when is_atom(mod), do: {mod, opts}
  defp normalize_plug(mod) when is_atom(mod), do: {mod, []}

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

    {initial_html, page_title} =
      case app_module.page_for(path) do
        nil ->
          html = render_error_for_http(app_module, 404, path)
          {html, nil}

        page_module ->
          params = app_module.path_params(path)
          {:ok, assigns} = page_module.mount(params, %{params: params})

          html =
            case app_module.dispatch(path, assigns) do
              {:ok, h} -> h
              {:error, :not_found} -> render_error_for_http(app_module, 404, path)
            end

          title = page_module.page_title(assigns)
          {html, title}
      end

    shell_opts = app_module.__shell_opts__() |> Map.merge(%{inner_content: initial_html})
    shell_opts = if page_title, do: Map.put(shell_opts, :title, page_title), else: shell_opts
    shell = Dialup.Shell.render(shell_opts)

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, shell)
  end

  defp render_error_for_http(app_module, status, path) do
    case app_module.error_page_for(path) do
      nil ->
        "<h1>#{status} #{status_text(status)}</h1>"

      error_module ->
        assigns = %{status: status, message: status_text(status)}

        try do
          error_html =
            error_module.render(status, assigns)
            |> Phoenix.HTML.Safe.to_iodata()
            |> IO.iodata_to_binary()

          use_layout =
            if function_exported?(error_module, :__layout__, 0),
              do: error_module.__layout__(),
              else: true

          if use_layout do
            layouts = app_module.layouts_for(path)
            Dialup.Router.render_with_layouts_raw(error_html, error_module, layouts, assigns)
          else
            error_html
          end
        rescue
          _ -> "<h1>#{status} #{status_text(status)}</h1>"
        end
    end
  end

  defp status_text(404), do: "Not Found"
  defp status_text(500), do: "Internal Server Error"
  defp status_text(status), do: "Error #{status}"

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
