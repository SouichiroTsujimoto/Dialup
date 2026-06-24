defmodule Dialup.Server do
  @moduledoc false
  use Plug.Router

  plug(Plug.Static, at: "/", from: {:dialup, "priv/static"})
  plug(:match)
  plug(:dispatch)

  def init(opts) do
    app_module = Keyword.fetch!(opts, :app)

    user_static_opts =
      if function_exported?(app_module, :__static_dir__, 0) do
        dir = app_module.__static_dir__()
        if File.dir?(dir), do: Plug.Static.init(at: "/", from: dir), else: nil
      end

    Keyword.put(opts, :user_static_opts, user_static_opts)
  end

  def call(conn, opts) do
    app_module = Keyword.fetch!(opts, :app)

    # ユーザの静的ファイルをフレームワークより優先して配信
    conn =
      case Keyword.get(opts, :user_static_opts) do
        nil -> conn
        static_opts -> Plug.Static.call(conn, static_opts)
      end

    if conn.halted do
      conn
    else
      conn
      |> Plug.Conn.put_private(:dialup_app, app_module)
      |> run_user_plugs(app_module)
      |> then(fn conn -> if conn.halted, do: conn, else: super(conn, opts) end)
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
    conn = conn |> Plug.Conn.fetch_cookies() |> Plug.Conn.fetch_query_params()
    tab_id = conn.params["tab_id"]

    with :ok <- check_origin(conn, app_module),
         {:ok, session_id} <- fetch_dialup_session(conn) do
      conn
      |> WebSockAdapter.upgrade(
        Dialup.WebSocket,
        %{app_module: app_module, session_id: session_id, tab_id: tab_id},
        timeout: :infinity
      )
      |> halt()
    else
      {:error, reason} -> send_resp(conn, 403, reason)
    end
  end

  get "/.well-known/dialup-agent" do
    conn = Plug.Conn.fetch_query_params(conn)
    path = conn.params["path"] || "/"
    app_module = conn.private[:dialup_app]

    case discovery_for(app_module, path) do
      {:ok, discovery} ->
        send_json(conn, 200, discovery)

      {:error, :not_found} ->
        send_json(conn, 404, %{"error" => "Page is not agent-enabled or does not exist"})
    end
  end

  get "/llms.txt" do
    body = """
    # Dialup MCP API

    Dialup pages auto-generate an MCP-compatible HTTP JSON-RPC API from UI declarations.

    Discovery:
    1. Read the HTTP Link header or HTML meta `dialup-agent-discovery`.
    2. Fetch `/.well-known/dialup-agent?path=<URL-encoded-path>` for page concepts and tool catalog.
    3. Obtain a session bearer token (POST `/_dialup/agent-handoff?tab_id=...` from the live browser tab, or use a server-issued grant).
    4. POST JSON-RPC 2.0 to `/agent/{token}` with `Content-Type: application/json`.

    Standard flow:
    - initialize
    - tools/list
    - tools/call read_scene
    - tools/call <action> with the latest `_version` in arguments

    Notes:
    - Human UI uses WebSocket (`/ws`). Agent tools use HTTP request-response only.
    - Actions marked `confirm=human` are not executable via HTTP MCP.
    - On stale version errors (-32009), call read_scene and retry with the returned version.
    """

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, body)
  end

  post "/_dialup/agent-handoff" do
    app_module = conn.private[:dialup_app]
    conn = conn |> Plug.Conn.fetch_cookies() |> Plug.Conn.fetch_query_params()
    tab_id = conn.params["tab_id"]

    with :ok <- check_origin(conn, app_module),
         {:ok, session_id} <- fetch_dialup_session(conn),
         {:ok, session_pid} <- fetch_live_tab_session(tab_id, session_id),
         {:ok, handoff} <- Dialup.UserSessionProcess.issue_browser_handoff(session_pid) do
      send_json(conn, 200, handoff)
    else
      {:error, :not_ready} ->
        send_json(conn, 409, %{"error" => "Session is still connecting"})

      {:error, :session_not_found} ->
        send_json(conn, 409, %{"error" => "Live browser session was not found"})

      {:error, reason} ->
        send_json(conn, 403, %{"error" => to_string(reason)})
    end
  end

  get "/agent/:token/ws" do
    send_json(conn, 404, %{"error" => "Agent WebSocket transport is not supported. Use HTTP JSON-RPC."})
  end

  get "/agent/:token" do
    case Dialup.Agent.describe(token) do
      {:ok, descriptor} ->
        send_json(conn, 200, descriptor)

      {:error, :not_found} ->
        send_json(conn, 404, %{"error" => "Session is no longer available"})

      {:error, :grant_expired} ->
        send_json(conn, 410, %{"error" => "Grant has expired or was revoked"})
    end
  end

  post "/agent/:token" do
    case Plug.Conn.read_body(conn, length: 1_000_000) do
      {:ok, body, conn} ->
        case Jason.decode(body) do
          {:ok, request} ->
            if Map.has_key?(request, "id") do
              send_json(conn, 200, Dialup.Agent.rpc(token, request))
            else
              _ = Dialup.Agent.rpc(token, request)
              send_resp(conn, 202, "")
            end

          {:error, _reason} ->
            send_json(conn, 400, %{"error" => "Invalid JSON"})
        end

      {:more, _partial_body, conn} ->
        send_json(conn, 413, %{"error" => "Request body is too large"})

      {:error, _reason} ->
        send_json(conn, 400, %{"error" => "Could not read request body"})
    end
  end

  delete "/agent/:token" do
    with {:ok, pid} <- Dialup.Agent.lookup(token),
         :ok <- Dialup.UserSessionProcess.revoke_agent(pid, token) do
      send_json(conn, 200, %{"revoked" => true})
    else
      _ -> send_json(conn, 404, %{"error" => "Session is no longer available"})
    end
  end

  get _ do
    conn = Plug.Conn.fetch_cookies(conn)
    {conn, _session_id} = ensure_session_id(conn)
    path = conn.request_path
    app_module = conn.private[:dialup_app]

    {initial_html, page_title, discovery} =
      case app_module.page_for(path) do
        nil ->
          html = render_error_for_http(app_module, 404, path)
          {html, nil, nil}

        page_module ->
          params = app_module.path_params(path)
          {:ok, assigns} = page_module.mount(params, %{params: params, current_path: path})
          assigns = Map.put(assigns, :current_path, path)

          html =
            case app_module.dispatch(path, assigns) do
              {:ok, h} -> h
              {:error, :not_found} -> render_error_for_http(app_module, 404, path)
            end

          title = page_module.page_title(assigns)
          {html, title, Dialup.Agent.discovery(page_module, assigns, path)}
      end

    shell_opts = app_module.__shell_opts__() |> Map.merge(%{inner_content: initial_html})
    shell_opts = if page_title, do: Map.put(shell_opts, :title, page_title), else: shell_opts

    shell =
      app_module.__render_shell__(shell_opts)
      |> inject_agent_discovery(path, discovery)

    conn
    |> maybe_put_agent_link(path, discovery)
    |> put_resp_content_type("text/html")
    |> send_resp(200, shell)
  end

  defp fetch_dialup_session(conn) do
    case conn.cookies["dialup_session"] do
      nil -> {:error, "No session"}
      id -> {:ok, id}
    end
  end

  defp fetch_live_tab_session(tab_id, session_id) when is_binary(tab_id) and tab_id != "" do
    case Registry.lookup(Dialup.SessionRegistry, tab_id) do
      [{pid, _}] ->
        if Dialup.UserSessionProcess.session_id(pid) == session_id do
          {:ok, pid}
        else
          {:error, :session_not_found}
        end

      [] ->
        {:error, :session_not_found}
    end
  end

  defp fetch_live_tab_session(_tab_id, _session_id), do: {:error, :session_not_found}

  defp check_origin(conn, app_module) do
    check_origin =
      if function_exported?(app_module, :__check_origin__, 0),
        do: app_module.__check_origin__(),
        else: :conn

    cond do
      # 開発環境はデフォルトでスキップ
      Code.ensure_loaded?(Mix) and Mix.env() == :dev and check_origin == :conn ->
        :ok

      # 明示的に false が指定された場合はスキップ
      check_origin == false ->
        :ok

      # 許可オリジンリストで検証
      is_list(check_origin) ->
        origin = Plug.Conn.get_req_header(conn, "origin") |> List.first()

        if origin in check_origin do
          :ok
        else
          {:error, "Forbidden origin"}
        end

      # :conn — リクエストの host と Origin ヘッダのホストを比較
      check_origin == :conn ->
        origin = Plug.Conn.get_req_header(conn, "origin") |> List.first()

        case origin && URI.parse(origin).host do
          nil -> :ok
          host -> if host == conn.host, do: :ok, else: {:error, "Forbidden origin"}
        end
    end
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

        conn =
          Plug.Conn.put_resp_cookie(conn, "dialup_session", id, http_only: true, same_site: "Lax")

        {conn, id}

      id ->
        {conn, id}
    end
  end

  defp send_json(conn, status, payload) do
    conn
    |> put_resp_header("mcp-protocol-version", "2025-11-25")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end

  defp discovery_for(app_module, path) do
    case app_module.page_for(path) do
      nil ->
        {:error, :not_found}

      page_module ->
        params = app_module.path_params(path)
        {:ok, assigns} = page_module.mount(params, %{params: params, current_path: path})
        assigns = Map.put(assigns, :current_path, path)
        {:ok, Dialup.Agent.discovery(page_module, assigns, path)}
    end
  end

  defp inject_agent_discovery(shell, _path, nil), do: shell

  defp inject_agent_discovery(shell, path, discovery) do
    href = "/.well-known/dialup-agent?path=" <> URI.encode_www_form(path)

    tags =
      [
        ~s(<link rel="alternate" type="application/vnd.dialup.agent+json" href="#{href}">),
        ~s(<link rel="service-desc" type="application/vnd.dialup.agent+json" href="#{href}">),
        ~s(<link rel="help" type="text/plain" href="/llms.txt">),
        ~s(<meta name="dialup-agent-discovery" content="#{href}">),
        ~s(<meta name="ai-agent-instructions" content="Read #{href} for MCP tool catalog. Use POST /agent/{token} for JSON-RPC tools/list and tools/call.">),
        ~s(<script id="dialup-agent-context" type="application/json">),
        safe_json(discovery),
        "</script>"
      ]
      |> IO.iodata_to_binary()

    case String.split(shell, "</head>", parts: 2) do
      [head, tail] -> head <> tags <> "</head>" <> tail
      [_shell] -> tags <> shell
    end
  end

  defp maybe_put_agent_link(conn, _path, nil), do: conn

  defp maybe_put_agent_link(conn, path, _discovery) do
    href = "/.well-known/dialup-agent?path=" <> URI.encode_www_form(path)

    Plug.Conn.put_resp_header(
      conn,
      "link",
      ~s(<#{href}>; rel="alternate service-desc"; type="application/vnd.dialup.agent+json", </llms.txt>; rel="help"; type="text/plain")
    )
  end

  defp safe_json(value) do
    value
    |> Jason.encode!()
    |> String.replace("<", "\\u003c")
    |> String.replace(">", "\\u003e")
    |> String.replace("&", "\\u0026")
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end
end
