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
    join_token = conn.params["join_token"]

    with :ok <- check_origin(conn, app_module),
         {:ok, session_id, conn} <- resolve_ws_session(conn, join_token) do
      conn
      |> WebSockAdapter.upgrade(
        Dialup.WebSocket,
        %{
          app_module: app_module,
          session_id: session_id,
          tab_id: tab_id,
          join_token: join_token
        },
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
    3. Obtain a session bearer token (POST `/_dialup/agent-handoff?tab_id=...` from the live browser tab, POST `/_dialup/agent-session` for agent-first sessions, or use a server-issued grant).
    4. POST JSON-RPC 2.0 to the MCP endpoint with `Content-Type: application/json`.

    Endpoints (Streamable HTTP transport):
    - `POST /mcp` with `Authorization: Bearer <token>` (or `Mcp-Session-Id: <token>`) — canonical endpoint for standard MCP clients.
    - `POST /agent/{token}` — equivalent endpoint that carries the token in the path.
    - A GET to either endpoint returns 405 (no server-initiated SSE stream is offered).

    Standard flow:
    - initialize
    - tools/list
    - tools/call read_scene
    - tools/call <action> with the latest `_version` in arguments

    Notes:
    - Human UI uses WebSocket (`/ws`). Agent tools use HTTP request-response only.
    - Browser handoff: open `browserUrl`, WebSocket attach with `tab_id` + `join_token`, then POST `/_dialup/finalize-join` (sets cookie, consumes token). See guides/agent-handoff.md.
    - Actions marked `confirm=human` return an isError tool result over HTTP MCP.
    - On a stale `_version`, tools/call returns an isError result whose structuredContent.currentVersion is the latest; call read_scene and retry.
    """

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, body)
  end

  post "/_dialup/agent-session" do
    app_module = conn.private[:dialup_app]

    with :ok <- check_origin(conn, app_module),
         {:ok, body, conn} <- Plug.Conn.read_body(conn, length: 1_000_000),
         {:ok, path} <- decode_agent_session_path(body),
         true <- app_module.page_for(path) != nil or {:error, :not_found},
         {:ok, result} <- Dialup.Session.start(app_module, path) do
      send_json(conn, 200, result)
    else
      {:error, reason} when reason in ["Forbidden origin", "Missing origin"] ->
        send_resp(conn, 403, reason)

      {:error, :invalid_body} ->
        send_json(conn, 400, %{"error" => "Expected JSON body with a path field"})

      {:error, :not_found} ->
        send_json(conn, 404, %{"error" => "Page does not exist"})

      {:error, _reason} ->
        send_json(conn, 500, %{"error" => "Could not start agent session"})

      false ->
        send_json(conn, 500, %{"error" => "Could not start agent session"})
    end
  end

  post "/_dialup/finalize-join" do
    app_module = conn.private[:dialup_app]
    conn = conn |> Plug.Conn.fetch_query_params()
    tab_id = conn.params["tab_id"]
    nonce = conn.params["nonce"]

    with :ok <- check_origin(conn, app_module),
         {:ok, session_pid} <- fetch_joined_tab_session(tab_id),
         :ok <- Dialup.UserSessionProcess.finalize_browser_join(session_pid, tab_id, nonce) do
      session_id = Dialup.UserSessionProcess.session_id(session_pid)

      conn =
        Plug.Conn.put_resp_cookie(conn, "dialup_session", session_id,
          http_only: true,
          same_site: "Lax"
        )

      send_json(conn, 200, %{"sessionId" => session_id})
    else
      {:error, :invalid_finalize} ->
        send_json(conn, 403, %{"error" => "Invalid browser join finalize request"})

      {:error, :session_not_found} ->
        send_json(conn, 409, %{"error" => "Joined browser session was not found"})

      {:error, reason} when reason in ["Forbidden origin", "Missing origin"] ->
        send_resp(conn, 403, reason)

      {:error, reason} ->
        send_resp(conn, 403, to_string(reason))
    end
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
    send_json(conn, 404, %{
      "error" => "Agent WebSocket transport is not supported. Use HTTP JSON-RPC."
    })
  end

  # Canonical MCP endpoint for standard Streamable HTTP clients. The session token is
  # carried in the `Authorization: Bearer <token>` (or `Mcp-Session-Id`) header rather
  # than the URL, so a plain MCP client only needs the endpoint URL plus the token it
  # obtained out of band (browser handoff or server grant).
  post "/mcp" do
    case resolve_mcp_token(conn) do
      nil -> mcp_unauthorized(conn)
      token -> mcp_post(conn, token)
    end
  end

  get "/mcp" do
    # We do not offer a server-initiated SSE stream; the spec requires 405 in that case.
    conn
    |> Plug.Conn.put_resp_header("allow", "POST, DELETE")
    |> send_resp(405, "")
  end

  delete "/mcp" do
    case resolve_mcp_token(conn) do
      nil -> mcp_unauthorized(conn)
      token -> mcp_delete(conn, token)
    end
  end

  get "/agent/:token" do
    if sse_requested?(conn) do
      # A standard MCP client opening a GET SSE stream gets 405 (no SSE offered here).
      conn
      |> Plug.Conn.put_resp_header("allow", "POST, DELETE")
      |> send_resp(405, "")
    else
      case Dialup.Agent.describe(token) do
        {:ok, descriptor} ->
          send_json(conn, 200, descriptor)

        {:error, :not_found} ->
          send_json(conn, 404, %{"error" => "Session is no longer available"})

        {:error, :grant_expired} ->
          send_json(conn, 410, %{"error" => "Grant has expired or was revoked"})
      end
    end
  end

  post "/agent/:token" do
    mcp_post(conn, token)
  end

  delete "/agent/:token" do
    mcp_delete(conn, token)
  end

  get _ do
    conn = conn |> Plug.Conn.fetch_cookies() |> Plug.Conn.fetch_query_params()
    {conn, _session_id} = ensure_session_id(conn)
    path = conn.request_path
    app_module = conn.private[:dialup_app]

    {initial_html, page_title, discovery} =
      case app_module.page_for(path) do
        nil ->
          html = render_error_for_http(app_module, 404, path)
          {html, nil, nil}

        page_module ->
          assigns = Dialup.Router.mount_assigns(app_module, path)

          html =
            case app_module.dispatch(path, assigns) do
              {:ok, h} -> h
              {:error, :not_found} -> render_error_for_http(app_module, 404, path)
            end

          title = page_module.page_title(assigns)
          extra = Dialup.Agent.layout_actions(app_module, path)
          {html, title, Dialup.Agent.discovery(page_module, assigns, path, extra)}
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

  defp fetch_joined_tab_session(tab_id) when is_binary(tab_id) and tab_id != "" do
    case Registry.lookup(Dialup.SessionRegistry, tab_id) do
      [{pid, _}] ->
        if Dialup.UserSessionProcess.awaiting_browser_join?(pid) do
          {:error, :session_not_found}
        else
          {:ok, pid}
        end

      [] ->
        {:error, :session_not_found}
    end
  end

  defp fetch_joined_tab_session(_tab_id), do: {:error, :session_not_found}

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
    conn = drop_join_param(conn)

    cond do
      conn.cookies["dialup_session"] == nil ->
        id = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

        conn =
          Plug.Conn.put_resp_cookie(conn, "dialup_session", id, http_only: true, same_site: "Lax")

        {conn, id}

      true ->
        {conn, conn.cookies["dialup_session"]}
    end
  end

  defp drop_join_param(%{params: %{"_join" => _}} = conn) do
    Map.put(conn, :params, Map.delete(conn.params, "_join"))
  end

  defp drop_join_param(conn), do: conn

  defp resolve_ws_session(conn, join_token) when is_binary(join_token) and join_token != "" do
    tab_id = conn.params["tab_id"]

    if not is_binary(tab_id) or tab_id == "" do
      {:error, "Missing tab_id for browser join"}
    else
      case Registry.lookup(Dialup.SessionRegistry, {:browser_token, join_token}) do
        [{pid, _}] ->
          case Dialup.UserSessionProcess.reserve_browser_join_token(pid, join_token, tab_id) do
            {:ok, session_id} ->
              {:ok, session_id, conn}

            {:error, _} ->
              {:error, "Invalid browser join token"}
          end

        [] ->
          {:error, "Invalid browser join token"}
      end
    end
  end

  defp resolve_ws_session(conn, _join_token) do
    case fetch_dialup_session(conn) do
      {:ok, session_id} -> {:ok, session_id, conn}
      error -> error
    end
  end

  defp decode_agent_session_path(body) do
    with {:ok, %{"path" => path}} <- Jason.decode(body),
         true <- is_binary(path) and path != "" do
      {:ok, path}
    else
      _ -> {:error, :invalid_body}
    end
  end

  defp mcp_post(conn, token) do
    case validate_protocol_version(conn) do
      :ok ->
        case Plug.Conn.read_body(conn, length: 1_000_000) do
          {:ok, body, conn} ->
            decode_and_dispatch(conn, token, body)

          {:more, _partial_body, conn} ->
            send_json(conn, 413, %{"error" => "Request body is too large"})

          {:error, _reason} ->
            send_json(conn, 400, %{"error" => "Could not read request body"})
        end

      {:error, version} ->
        send_json(conn, 400, %{
          "error" => "Unsupported MCP-Protocol-Version: #{version}",
          "supportedVersions" => Dialup.Agent.supported_protocol_versions()
        })
    end
  end

  defp decode_and_dispatch(conn, token, body) do
    case Jason.decode(body) do
      {:ok, request} when is_map(request) ->
        cond do
          jsonrpc_response?(request) ->
            mcp_accepted(conn)

          Map.has_key?(request, "id") ->
            conn
            |> maybe_put_session_header(token, request)
            |> send_json(200, Dialup.Agent.rpc(token, request))

          true ->
            # JSON-RPC notification: accept it and return 202 with no body per the spec.
            _ = Dialup.Agent.rpc(token, request)
            mcp_accepted(conn)
        end

      {:ok, _batch_or_scalar} ->
        # JSON-RPC batching was removed from MCP; reject arrays/scalars cleanly
        # instead of crashing on a non-object body.
        send_json(conn, 400, jsonrpc_error(-32_600, "Invalid Request"))

      {:error, _reason} ->
        send_json(conn, 400, jsonrpc_error(-32_700, "Parse error"))
    end
  end

  defp mcp_delete(conn, token) do
    with {:ok, pid} <- Dialup.Agent.lookup(token),
         :ok <- Dialup.UserSessionProcess.revoke_agent(pid, token) do
      send_json(conn, 200, %{"revoked" => true})
    else
      _ -> send_json(conn, 404, %{"error" => "Session is no longer available"})
    end
  end

  defp mcp_unauthorized(conn) do
    conn
    |> Plug.Conn.put_resp_header("www-authenticate", "Bearer")
    |> send_json(401, %{
      "error" => "Missing session token. Provide it via Authorization: Bearer or Mcp-Session-Id."
    })
  end

  # initialize is where a stateful MCP session is established, so advertise the token as
  # the session id; standard clients echo it back via Mcp-Session-Id on later requests.
  defp maybe_put_session_header(conn, token, %{"method" => "initialize"}) do
    Plug.Conn.put_resp_header(conn, "mcp-session-id", token)
  end

  defp maybe_put_session_header(conn, _token, _request), do: conn

  defp resolve_mcp_token(conn) do
    bearer =
      conn
      |> Plug.Conn.get_req_header("authorization")
      |> Enum.find_value(&bearer_token/1)

    session_id =
      conn
      |> Plug.Conn.get_req_header("mcp-session-id")
      |> Enum.find_value(&normalize_token/1)

    bearer || session_id
  end

  defp bearer_token(header) do
    case String.split(header, " ", parts: 2, trim: true) do
      [scheme, token] ->
        if String.downcase(scheme) == "bearer", do: normalize_token(token), else: nil

      _ ->
        nil
    end
  end

  defp normalize_token(token) when is_binary(token) do
    case String.trim(token) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp validate_protocol_version(conn) do
    case Plug.Conn.get_req_header(conn, "mcp-protocol-version") do
      [] ->
        :ok

      [version | _] ->
        if version in Dialup.Agent.supported_protocol_versions(),
          do: :ok,
          else: {:error, version}
    end
  end

  defp sse_requested?(conn) do
    conn
    |> Plug.Conn.get_req_header("accept")
    |> Enum.any?(&String.contains?(&1, "text/event-stream"))
  end

  defp jsonrpc_error(code, message) do
    %{"jsonrpc" => "2.0", "id" => nil, "error" => %{"code" => code, "message" => message}}
  end

  defp jsonrpc_response?(%{"jsonrpc" => "2.0"} = message) do
    Map.has_key?(message, "id") and not Map.has_key?(message, "method") and
      (Map.has_key?(message, "result") or Map.has_key?(message, "error"))
  end

  defp jsonrpc_response?(_message), do: false

  defp mcp_accepted(conn) do
    conn
    |> put_resp_header("mcp-protocol-version", Dialup.Agent.protocol_version())
    |> send_resp(202, "")
  end

  defp send_json(conn, status, payload) do
    conn
    |> put_resp_header("mcp-protocol-version", Dialup.Agent.protocol_version())
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end

  defp discovery_for(app_module, path) do
    case app_module.page_for(path) do
      nil ->
        {:error, :not_found}

      page_module ->
        assigns = Dialup.Router.mount_assigns(app_module, path)
        extra = Dialup.Agent.layout_actions(app_module, path)
        {:ok, Dialup.Agent.discovery(page_module, assigns, path, extra)}
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
        ~s(<meta name="ai-agent-instructions" content="Read #{href} for MCP tool catalog. Use POST /mcp with a bearer token for JSON-RPC tools/list and tools/call.">),
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
