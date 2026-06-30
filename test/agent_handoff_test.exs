defmodule Dialup.AgentHandoffTest do
  use ExUnit.Case, async: false

  alias Dialup.Agent
  alias Dialup.AgentHandoffTest.App
  alias Dialup.UserSessionProcess

  setup_all do
    start_supervised!({Registry, keys: :unique, name: Dialup.SessionRegistry})

    start_supervised!({DynamicSupervisor, name: Dialup.SessionSupervisor, strategy: :one_for_one})

    :ok
  end

  setup do
    session_id = unique("session")
    registry_key = unique("tab")

    pid =
      start_supervised!(
        {UserSessionProcess, {self(), App, session_id, registry_key}},
        id: registry_key
      )

    UserSessionProcess.init_session(pid, "/")
    assert_receive {:send_html, initial_payload}
    initial = Jason.decode!(initial_payload)
    {:ok, handoff} = UserSessionProcess.issue_browser_handoff(pid)
    token = handoff["token"]

    %{pid: pid, token: token, initial: initial, registry_key: registry_key}
  end

  test "human and agent actions share one ordered session", %{
    pid: pid,
    token: token,
    initial: initial
  } do
    refute Map.has_key?(initial, "agent")

    UserSessionProcess.event(pid, "increment", %{"amount" => 2})
    assert_receive {:send_html, _human_update}

    read = rpc(token, 1, "tools/call", %{"name" => "read_scene", "arguments" => %{}})
    assert read["result"]["structuredContent"]["state"]["count"] == 2

    assert read["result"]["structuredContent"]["regions"] == [
             %{
               "name" => "counter",
               "role" => "status",
               "desc" => "Shared counter value",
               "data" => 2,
               "actions" => ["increment"]
             }
           ]

    acted =
      rpc(token, 2, "tools/call", %{
        "name" => "increment",
        "arguments" => %{"amount" => 3, "_version" => 1}
      })

    assert_receive {:send_html, _agent_update}
    assert acted["result"]["structuredContent"]["state"]["count"] == 5
    assert acted["result"]["structuredContent"]["version"] == 2
  end

  test "tools/list exposes declarations and confirm=human is unsupported over HTTP", %{
    token: token
  } do
    listed = rpc(token, 1, "tools/list", %{})
    tools = listed["result"]["tools"]

    assert Enum.any?(tools, &(&1["name"] == "read_scene"))
    assert Enum.any?(tools, &(&1["name"] == "increment"))

    reset =
      rpc(token, 2, "tools/call", %{
        "name" => "reset",
        "arguments" => %{"_version" => 0}
      })

    assert reset["result"]["isError"] == true
    assert reset["result"]["structuredContent"]["confirm"] == "human"
    assert hd(reset["result"]["content"])["text"] =~ "human confirmation"
  end

  test "navigation is a declared action, not a free-form navigate tool", %{token: token} do
    names = rpc(token, 0, "tools/list", %{})["result"]["tools"] |> Enum.map(& &1["name"])

    refute "navigate" in names
    assert "navigate_root" in names

    moved =
      rpc(token, 1, "tools/call", %{"name" => "navigate_root", "arguments" => %{}})

    assert_receive {:send_html, payload}
    assert Jason.decode!(payload)["path"] == "/"
    assert moved["result"]["structuredContent"]["path"] == "/"
  end

  test "a layout navigation action is part of the page tool catalog", %{token: token} do
    names = rpc(token, 0, "tools/list", %{})["result"]["tools"] |> Enum.map(& &1["name"])
    assert "navigate_board" in names

    moved =
      rpc(token, 1, "tools/call", %{"name" => "navigate_board", "arguments" => %{}})

    assert_receive {:send_html, payload}
    assert Jason.decode!(payload)["path"] == "/board"
    assert moved["result"]["structuredContent"]["path"] == "/board"
  end

  test "navigating to a path that no longer exists is rejected", %{token: token} do
    missing =
      rpc(token, 1, "tools/call", %{"name" => "navigate_missing", "arguments" => %{}})

    assert missing["result"]["isError"] == true
    assert missing["result"]["structuredContent"]["reason"] == "unknown_target"
  end

  test "navigation actions are gated by capability", %{pid: pid} do
    {:ok, descriptor} =
      Dialup.Session.grant(pid, capabilities: [:increment], projections: [:state])

    token = descriptor["token"]
    names = rpc(token, 1, "tools/list", %{})["result"]["tools"] |> Enum.map(& &1["name"])
    refute "navigate_root" in names
    refute "navigate_board" in names

    forbidden =
      rpc(token, 2, "tools/call", %{"name" => "navigate_root", "arguments" => %{}})

    assert forbidden["error"]["code"] == -32_003
  end

  test "navigation availability follows __available__/2", %{pid: pid, token: token} do
    UserSessionProcess.event(pid, "increment", %{"amount" => 1})
    assert_receive {:send_html, _}

    listed = rpc(token, 1, "tools/list", %{})
    root = Enum.find(listed["result"]["tools"], &(&1["name"] == "navigate_root"))
    assert root["_meta"]["available"] == false

    blocked =
      rpc(token, 2, "tools/call", %{"name" => "navigate_root", "arguments" => %{}})

    assert blocked["result"]["isError"] == true
    assert blocked["result"]["structuredContent"]["reason"] == "unavailable"
  end

  test "confirm=human navigation is unsupported over HTTP MCP", %{token: token} do
    result =
      rpc(token, 1, "tools/call", %{"name" => "navigate_board_human", "arguments" => %{}})

    assert result["result"]["isError"] == true
    assert result["result"]["structuredContent"]["confirm"] == "human"
  end

  test "navigate_action_name distinguishes hyphenated and nested paths" do
    assert Dialup.Page.navigate_action_name("/foo-bar") == :navigate_foo_bar
    assert Dialup.Page.navigate_action_name("/foo/bar") == :navigate_foo__bar

    refute Dialup.Page.navigate_action_name("/foo-bar") ==
             Dialup.Page.navigate_action_name("/foo/bar")
  end

  test "an agent can lock and unlock the human UI", %{pid: pid, token: token} do
    names = rpc(token, 0, "tools/list", %{})["result"]["tools"] |> Enum.map(& &1["name"])
    assert "lock_ui" in names
    assert "unlock_ui" in names

    locked =
      rpc(token, 1, "tools/call", %{
        "name" => "lock_ui",
        "arguments" => %{"reason" => "AI is editing"}
      })

    assert locked["result"]["structuredContent"]["uiLocked"] == true
    assert locked["result"]["structuredContent"]["lockReason"] == "AI is editing"
    assert_receive {:send_html, lock_payload}
    assert Jason.decode!(lock_payload)["ui_locked"] == true

    # Human interaction is ignored while the UI is locked.
    UserSessionProcess.event(pid, "increment", %{"amount" => 5})
    assert_receive {:send_html, _reasserted}
    scene = rpc(token, 2, "tools/call", %{"name" => "read_scene", "arguments" => %{}})
    assert scene["result"]["structuredContent"]["state"]["count"] == 0
    assert scene["result"]["structuredContent"]["uiLocked"] == true

    # Human navigation is also blocked while locked.
    UserSessionProcess.navigate(pid, "/board")
    assert_receive {:send_html, _nav_blocked}
    locked_scene = rpc(token, 3, "tools/call", %{"name" => "read_scene", "arguments" => %{}})
    assert locked_scene["result"]["structuredContent"]["path"] == "/"

    # Unlocking restores human control.
    unlocked = rpc(token, 4, "tools/call", %{"name" => "unlock_ui", "arguments" => %{}})
    assert unlocked["result"]["structuredContent"]["uiLocked"] == false
    assert_receive {:send_html, unlock_payload}
    assert Jason.decode!(unlock_payload)["ui_locked"] == false

    UserSessionProcess.event(pid, "increment", %{"amount" => 4})
    assert_receive {:send_html, _human_update}
    after_scene = rpc(token, 5, "tools/call", %{"name" => "read_scene", "arguments" => %{}})
    assert after_scene["result"]["structuredContent"]["state"]["count"] == 4
  end

  test "lock_ui requires the lock_ui capability", %{pid: pid} do
    {:ok, descriptor} =
      Dialup.Session.grant(pid, capabilities: [:increment], projections: [:state])

    token = descriptor["token"]
    names = rpc(token, 1, "tools/list", %{})["result"]["tools"] |> Enum.map(& &1["name"])
    refute "lock_ui" in names
    refute "unlock_ui" in names

    forbidden = rpc(token, 2, "tools/call", %{"name" => "lock_ui", "arguments" => %{}})
    assert forbidden["error"]["code"] == -32_003
  end

  test "component markup carries semantic ids and serialized parameters" do
    {_assigns, html} = Dialup.Test.mount_page(Dialup.AgentHandoffTest.Page)

    assert html =~ ~s(data-dialup-id="counter")
    assert html =~ ~s(data-dialup-id="increment")
    assert html =~ ~s(data-dialup-params="{&quot;amount&quot;:&quot;1&quot;}")
  end

  test "HTTP JSON-RPC endpoint projects the live session", %{token: token} do
    request =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 7,
        "method" => "tools/call",
        "params" => %{"name" => "read_scene", "arguments" => %{}}
      })

    conn =
      Plug.Test.conn(:post, "/agent/#{token}", request)
      |> Dialup.Server.call(Dialup.Server.init(app: App))

    assert conn.status == 200
    response = Jason.decode!(conn.resp_body)
    assert response["id"] == 7
    assert response["result"]["structuredContent"]["state"]["count"] == 0
  end

  test "agent websocket endpoint is not available", %{token: token} do
    conn =
      Plug.Test.conn(:get, "/agent/#{token}/ws")
      |> Dialup.Server.call(Dialup.Server.init(app: App))

    assert conn.status == 404
  end

  test "the canonical /mcp endpoint authenticates with a bearer token", %{token: token} do
    request =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 7,
        "method" => "tools/call",
        "params" => %{"name" => "read_scene", "arguments" => %{}}
      })

    conn =
      Plug.Test.conn(:post, "/mcp", request)
      |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Dialup.Server.call(Dialup.Server.init(app: App))

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["id"] == 7
  end

  test "/mcp accepts a case-insensitive bearer auth scheme", %{token: token} do
    request =
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => %{}})

    conn =
      Plug.Test.conn(:post, "/mcp", request)
      |> Plug.Conn.put_req_header("authorization", "bearer  #{token}  ")
      |> Dialup.Server.call(Dialup.Server.init(app: App))

    assert conn.status == 200
    assert is_list(Jason.decode!(conn.resp_body)["result"]["tools"])
  end

  test "/mcp accepts the token via the Mcp-Session-Id header", %{token: token} do
    request =
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => %{}})

    conn =
      Plug.Test.conn(:post, "/mcp", request)
      |> Plug.Conn.put_req_header("mcp-session-id", token)
      |> Dialup.Server.call(Dialup.Server.init(app: App))

    assert conn.status == 200
    assert is_list(Jason.decode!(conn.resp_body)["result"]["tools"])
  end

  test "/mcp without a token is unauthorized" do
    request =
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => %{}})

    conn =
      Plug.Test.conn(:post, "/mcp", request)
      |> Dialup.Server.call(Dialup.Server.init(app: App))

    assert conn.status == 401
  end

  test "GET on the MCP endpoint returns 405 (no SSE stream offered)", %{token: token} do
    conn =
      Plug.Test.conn(:get, "/mcp")
      |> Plug.Conn.put_req_header("accept", "text/event-stream")
      |> Dialup.Server.call(Dialup.Server.init(app: App))

    assert conn.status == 405
    assert Plug.Conn.get_resp_header(conn, "allow") == ["POST, DELETE"]

    sse =
      Plug.Test.conn(:get, "/agent/#{token}")
      |> Plug.Conn.put_req_header("accept", "text/event-stream")
      |> Dialup.Server.call(Dialup.Server.init(app: App))

    assert sse.status == 405
  end

  test "initialize advertises the token as the Mcp-Session-Id", %{token: token} do
    request =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{"protocolVersion" => "2025-11-25", "capabilities" => %{}}
      })

    conn =
      Plug.Test.conn(:post, "/agent/#{token}", request)
      |> Dialup.Server.call(Dialup.Server.init(app: App))

    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "mcp-session-id") == [token]
    assert Plug.Conn.get_resp_header(conn, "mcp-protocol-version") == ["2025-11-25"]
  end

  test "an unsupported MCP-Protocol-Version header is rejected with 400", %{token: token} do
    request =
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

    conn =
      Plug.Test.conn(:post, "/agent/#{token}", request)
      |> Plug.Conn.put_req_header("mcp-protocol-version", "1999-01-01")
      |> Dialup.Server.call(Dialup.Server.init(app: App))

    assert conn.status == 400
  end

  test "malformed JSON and batch bodies are rejected as JSON-RPC errors", %{token: token} do
    parse =
      Plug.Test.conn(:post, "/agent/#{token}", "{not json")
      |> Dialup.Server.call(Dialup.Server.init(app: App))

    assert parse.status == 400
    assert Jason.decode!(parse.resp_body)["error"]["code"] == -32_700

    batch =
      Plug.Test.conn(
        :post,
        "/agent/#{token}",
        Jason.encode!([%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}])
      )
      |> Dialup.Server.call(Dialup.Server.init(app: App))

    assert batch.status == 400
    assert Jason.decode!(batch.resp_body)["error"]["code"] == -32_600
  end

  test "JSON-RPC response bodies are accepted without a response", %{token: token} do
    conn =
      Plug.Test.conn(
        :post,
        "/agent/#{token}",
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 99, "result" => %{}})
      )
      |> Dialup.Server.call(Dialup.Server.init(app: App))

    assert conn.status == 202
    assert conn.resp_body == ""
  end

  test "stale versions and invalid arguments are rejected", %{token: token} do
    stale =
      rpc(token, 1, "tools/call", %{
        "name" => "increment",
        "arguments" => %{"amount" => 1, "_version" => 99}
      })

    assert stale["result"]["isError"] == true
    assert stale["result"]["structuredContent"]["reason"] == "stale_version"
    assert stale["result"]["structuredContent"]["currentVersion"] == 0

    invalid =
      rpc(token, 2, "tools/call", %{
        "name" => "increment",
        "arguments" => %{"amount" => "wrong", "_version" => 0}
      })

    assert invalid["result"]["isError"] == true
    assert invalid["result"]["structuredContent"]["reason"] == "invalid_arguments"
  end

  test "non-object tool arguments are returned as tool errors", %{token: token} do
    invalid =
      rpc(token, 1, "tools/call", %{
        "name" => "increment",
        "arguments" => "not an object"
      })

    assert invalid["result"]["isError"] == true
    assert invalid["result"]["structuredContent"]["reason"] == "invalid_arguments"
    assert hd(invalid["result"]["structuredContent"]["errors"])["field"] == "arguments"
  end

  test "grants can be revoked", %{pid: pid, token: token} do
    assert :ok = UserSessionProcess.revoke_agent(pid, token)

    result = rpc(token, 1, "tools/call", %{"name" => "read_scene", "arguments" => %{}})
    assert result["error"]["code"] == -32_002
  end

  test "scoped grants restrict tools and projections", %{pid: pid} do
    {:ok, descriptor} =
      Dialup.Session.grant(pid,
        capabilities: [:increment],
        projections: [:state],
        expires_in: :timer.seconds(1),
        require_version: true
      )

    token = descriptor["token"]
    listed = rpc(token, 1, "tools/list", %{})
    names = Enum.map(listed["result"]["tools"], & &1["name"])

    assert "increment" in names
    refute "reset" in names
    refute "read_audit_log" in names

    scene = rpc(token, 2, "tools/call", %{"name" => "read_scene", "arguments" => %{}})
    projected = scene["result"]["structuredContent"]
    assert projected["state"] == %{"count" => 0}
    refute Map.has_key?(projected, "regions")
    refute Map.has_key?(projected, "actions")
  end

  test "audit log orders human and agent actions", %{pid: pid, token: token} do
    UserSessionProcess.event(pid, "increment", %{"amount" => 1})
    assert_receive {:send_html, _page}

    _result =
      rpc(token, 1, "tools/call", %{
        "name" => "increment",
        "arguments" => %{"amount" => 2, "_version" => 1}
      })

    assert_receive {:send_html, _page}

    log = rpc(token, 2, "tools/call", %{"name" => "read_audit_log", "arguments" => %{}})
    entries = log["result"]["structuredContent"]["entries"]

    relevant = Enum.reject(entries, &(&1["action"] == "issue_agent_handoff"))
    assert Enum.map(relevant, & &1["actor"]) == ["human", "agent"]
    assert List.last(entries)["version"] == 2
  end

  test "expired grants stop serving tools", %{pid: pid} do
    {:ok, descriptor} =
      Dialup.Session.grant(pid,
        capabilities: [:increment],
        projections: [:state],
        expires_in: 1
      )

    Process.sleep(5)
    result = rpc(descriptor["token"], 1, "tools/list", %{})
    assert result["error"]["code"] == -32_002
  end

  test "MCP initialize, ping, and initialized notification are accepted", %{token: token} do
    initialized =
      Agent.rpc(token, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1"}
        }
      })

    assert initialized["result"]["protocolVersion"] == "2025-11-25"
    assert Agent.rpc(token, %{"jsonrpc" => "2.0", "id" => 2, "method" => "ping"})["result"] == %{}

    conn =
      Plug.Test.conn(
        :post,
        "/agent/#{token}",
        Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
      )
      |> Dialup.Server.call(Dialup.Server.init(app: App))

    assert conn.status == 202
    assert conn.resp_body == ""
  end

  test "ordinary page URLs advertise MCP discovery metadata" do
    conn =
      Plug.Test.conn(:get, "/")
      |> Dialup.Server.call(Dialup.Server.init(app: App))

    assert conn.status == 200

    [link] = Plug.Conn.get_resp_header(conn, "link")
    assert link =~ ~s(</.well-known/dialup-agent?path=%2F>; rel="alternate service-desc")
    assert link =~ ~s(</llms.txt>; rel="help")

    assert conn.resp_body =~ ~s(id="dialup-agent-context")
    assert conn.resp_body =~ ~s(type="application/json")
    assert conn.resp_body =~ "A shared counter operated by a human and an agent."
    assert conn.resp_body =~ ~s(rel="service-desc")
    assert conn.resp_body =~ ~s(href="/llms.txt")
    assert conn.resp_body =~ "POST /mcp with a bearer token"
    refute conn.resp_body =~ ~s(style="display)
  end

  test "live endpoint repeats page concepts and HTTP protocol guidance", %{token: token} do
    {:ok, descriptor} = Agent.describe(token)
    discovery = descriptor["agentDiscovery"]

    assert discovery["message"]["concept"] ==
             "A shared counter operated by a human and an agent."

    assert discovery["connection"]["status"] == "connected"
    assert discovery["connection"]["endpoint"] == "/agent/#{token}"
    assert discovery["connection"]["mcpEndpoint"] == "/mcp"
    refute Map.has_key?(discovery["connection"], "websocket")
    assert discovery["protocolGuide"]["transport"]["http"] =~ "/mcp"
    assert discovery["protocolGuide"]["transport"]["pathTokenHttp"] =~ "/agent/#{token}"
    assert discovery["protocolGuide"]["versioning"]["staleResult"] =~ "isError"
    assert discovery["protocolGuide"]["versioning"]["recovery"] =~ "read_scene"
    assert discovery["protocolGuide"]["humanConfirmation"] =~ "confirm=human"
  end

  test "well-known discovery explains concepts and operations without a live token" do
    conn =
      Plug.Test.conn(:get, "/.well-known/dialup-agent?path=%2F")
      |> Dialup.Server.call(Dialup.Server.init(app: App))

    assert conn.status == 200
    discovery = Jason.decode!(conn.resp_body)

    assert discovery["message"]["concept"] ==
             "A shared counter operated by a human and an agent."

    assert discovery["connection"]["status"] == "no_live_session"
    assert discovery["connection"]["httpEndpoint"] == "/mcp"
    assert discovery["accessModel"]["pageUrl"] =~ "does not authenticate"
    assert discovery["accessModel"]["sessionToken"] =~ "/agent/"
    assert length(discovery["agentQuickstart"]["steps"]) >= 6
    assert discovery["agentQuickstart"]["humanConfirmation"] =~ "confirm=human"
    assert Enum.any?(discovery["scene"]["actions"], &(&1["name"] == "increment"))
    assert hd(discovery["scene"]["regions"])["name"] == "counter"
  end

  test "well-known discovery seeds nested layout session state" do
    conn =
      Plug.Test.conn(:get, "/.well-known/dialup-agent?path=%2Fboard")
      |> Dialup.Server.call(Dialup.Server.init(app: App))

    assert conn.status == 200
    discovery = Jason.decode!(conn.resp_body)
    assert discovery["scene"]["state"]["board_label"] == "empty"
  end

  test "llms.txt explains HTTP MCP discovery" do
    conn =
      Plug.Test.conn(:get, "/llms.txt")
      |> Dialup.Server.call(Dialup.Server.init(app: App))

    assert conn.status == 200
    assert conn.resp_body =~ "HTTP JSON-RPC"
    assert conn.resp_body =~ "tools/list"
    assert conn.resp_body =~ "tools/call"
    assert conn.resp_body =~ "_version"
    assert conn.resp_body =~ "confirm=human"
  end

  test "a human can issue a fresh session token for the current session", %{pid: pid} do
    assert {:ok, handoff} = UserSessionProcess.issue_browser_handoff(pid)
    assert handoff["endpoint"] =~ ~r{^/agent/[^/]+$}
    assert handoff["grant"]["requireVersion"]
    refute Map.has_key?(handoff, "websocket")

    token = handoff["token"]
    read = rpc(token, 1, "tools/call", %{"name" => "read_scene", "arguments" => %{}})
    assert read["result"]["structuredContent"]["state"]["count"] == 0

    log = rpc(token, 2, "tools/call", %{"name" => "read_audit_log", "arguments" => %{}})

    assert Enum.any?(log["result"]["structuredContent"]["entries"], fn entry ->
             entry["actor"] == "human" and entry["action"] == "issue_agent_handoff"
           end)
  end

  test "same-session HTTP handoff endpoint issues a capability", %{
    pid: pid,
    registry_key: registry_key
  } do
    session_id = UserSessionProcess.session_id(pid)

    conn =
      Plug.Test.conn(:post, "/_dialup/agent-handoff?tab_id=#{registry_key}")
      |> Plug.Conn.put_req_header("cookie", "dialup_session=#{session_id}")
      |> Dialup.Server.call(Dialup.Server.init(app: App))

    assert conn.status == 200
    handoff = Jason.decode!(conn.resp_body)
    assert handoff["endpoint"] =~ ~r{^/agent/[^/]+$}
    refute Map.has_key?(handoff, "websocket")
  end

  test "HTTP handoff endpoint rejects a tab from another cookie session", %{
    registry_key: registry_key
  } do
    conn =
      Plug.Test.conn(:post, "/_dialup/agent-handoff?tab_id=#{registry_key}")
      |> Plug.Conn.put_req_header("cookie", "dialup_session=another-session")
      |> Dialup.Server.call(Dialup.Server.init(app: App))

    assert conn.status == 409
    assert Jason.decode!(conn.resp_body)["error"] == "Live browser session was not found"
  end

  test "agent-first session starts headlessly and returns an MCP token" do
    {:ok, descriptor} = Dialup.Session.start(App, "/")

    assert descriptor["endpoint"] =~ ~r{^/agent/[^/]+$}
    assert is_map(descriptor["grant"])
    assert descriptor["path"] == "/"

    read =
      rpc(descriptor["token"], 1, "tools/call", %{
        "name" => "read_scene",
        "arguments" => %{}
      })

    assert read["result"]["structuredContent"]["state"]["count"] == 0
  end

  test "POST /_dialup/agent-session starts a live agent session" do
    conn =
      Plug.Test.conn(:post, "/_dialup/agent-session", Jason.encode!(%{"path" => "/"}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Dialup.Server.call(Dialup.Server.init(app: App))

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["endpoint"] =~ ~r{^/agent/[^/]+$}
    assert body["path"] == "/"
  end

  test "POST /_dialup/agent-session rejects unknown paths" do
    conn =
      Plug.Test.conn(:post, "/_dialup/agent-session", Jason.encode!(%{"path" => "/missing"}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Dialup.Server.call(Dialup.Server.init(app: App))

    assert conn.status == 404
  end

  test "POST /_dialup/agent-session rejects cross-origin requests" do
    conn =
      Plug.Test.conn(:post, "/_dialup/agent-session", Jason.encode!(%{"path" => "/"}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("origin", "https://evil.example")
      |> Dialup.Server.call(Dialup.Server.init(app: App))

    assert conn.status == 403
    assert conn.resp_body == "Forbidden origin"
  end

  test "issue_browser_url returns a one-time join URL over MCP", %{token: token} do
    result =
      rpc(token, 1, "tools/call", %{"name" => "issue_browser_url", "arguments" => %{}})

    assert result["result"]["structuredContent"]["browserUrl"] =~ "_join="
    assert result["result"]["structuredContent"]["browserToken"]
    assert result["result"]["structuredContent"]["expiresInMs"] > 0
  end

  test "issue_browser_url requires the issue_browser_url capability", %{pid: pid} do
    {:ok, descriptor} =
      Dialup.Session.grant(pid, capabilities: [:increment], projections: [:state])

    token = descriptor["token"]
    names = rpc(token, 1, "tools/list", %{})["result"]["tools"] |> Enum.map(& &1["name"])
    refute "issue_browser_url" in names

    forbidden =
      rpc(token, 2, "tools/call", %{"name" => "issue_browser_url", "arguments" => %{}})

    assert forbidden["error"]["code"] == -32_003
  end

  test "browser join attaches a websocket to an existing headless session" do
    {:ok, descriptor} = Dialup.Session.start(App, "/")
    {:ok, pid} = Agent.lookup(descriptor["token"])
    {:ok, browser} = Dialup.Session.browser_url(pid)
    join_token = browser["browserToken"]

    assert Registry.lookup(Dialup.SessionRegistry, {:browser_token, join_token}) == [{pid, nil}]

    assert :ok = UserSessionProcess.browser_join(pid, self())
    assert_receive {:send_html, payload}
    assert Jason.decode!(payload)["path"] == "/"

    assert :ok = UserSessionProcess.consume_browser_token(pid, join_token)
    assert Registry.lookup(Dialup.SessionRegistry, {:browser_token, join_token}) == []
    assert UserSessionProcess.consume_browser_token(pid, join_token) == {:error, :expired}
  end

  test "browser_join registers tab_id in the session registry" do
    {:ok, descriptor} = Dialup.Session.start(App, "/")
    {:ok, pid} = Agent.lookup(descriptor["token"])
    tab_id = unique("tab")

    assert :ok = UserSessionProcess.browser_join(pid, self(), tab_id)
    assert Registry.lookup(Dialup.SessionRegistry, tab_id) == [{pid, nil}]
  end

  test "browser_join registers session_id in the session registry" do
    {:ok, descriptor} = Dialup.Session.start(App, "/")
    {:ok, pid} = Agent.lookup(descriptor["token"])
    session_id = UserSessionProcess.session_id(pid)

    assert :ok = UserSessionProcess.browser_join(pid, self(), unique("tab"))
    assert Registry.lookup(Dialup.SessionRegistry, session_id) == [{pid, nil}]
  end

  test "headless session rejects browser attach before join token is consumed" do
    {:ok, descriptor} = Dialup.Session.start(App, "/")
    {:ok, pid} = Agent.lookup(descriptor["token"])
    session_id = UserSessionProcess.session_id(pid)

    assert UserSessionProcess.awaiting_browser_join?(pid)

    assert {:ok, state} =
             Dialup.WebSocket.init(%{
               app_module: App,
               session_id: session_id,
               tab_id: unique("tab")
             })

    refute state.session_pid == pid
  end

  test "finalize-join atomically consumes the join token and clears pending handoff" do
    {:ok, descriptor} = Dialup.Session.start(App, "/")
    {:ok, pid} = Agent.lookup(descriptor["token"])
    {:ok, browser} = Dialup.Session.browser_url(pid)
    join_token = browser["browserToken"]
    tab_id = unique("tab")

    assert {:ok, _} = UserSessionProcess.reserve_browser_join_token(pid, join_token, tab_id)
    assert :ok = UserSessionProcess.browser_join_with_token(pid, self(), tab_id, join_token)
    nonce = :sys.get_state(pid).pending_finalize.nonce

    conn =
      Plug.Test.conn(:post, "/_dialup/finalize-join?tab_id=#{tab_id}&nonce=#{nonce}")
      |> Dialup.Server.call(Dialup.Server.init(app: App))

    assert conn.status == 200
    refute UserSessionProcess.browser_token_active?(pid, join_token)
    assert is_nil(:sys.get_state(pid).pending_finalize)
  end

  test "a newly issued join token works after finalize when the browser disconnects" do
    {:ok, descriptor} = Dialup.Session.start(App, "/")
    {:ok, pid} = Agent.lookup(descriptor["token"])
    {:ok, browser} = Dialup.Session.browser_url(pid)
    join_token = browser["browserToken"]
    tab_a = unique("tab-a")
    tab_b = unique("tab-b")
    socket = spawn(fn -> Process.sleep(:infinity) end)

    assert {:ok, _} = UserSessionProcess.reserve_browser_join_token(pid, join_token, tab_a)
    assert :ok = UserSessionProcess.browser_join_with_token(pid, socket, tab_a, join_token)
    nonce = :sys.get_state(pid).pending_finalize.nonce

    conn =
      Plug.Test.conn(:post, "/_dialup/finalize-join?tab_id=#{tab_a}&nonce=#{nonce}")
      |> Dialup.Server.call(Dialup.Server.init(app: App))

    assert conn.status == 200
    refute UserSessionProcess.browser_token_active?(pid, join_token)
    Process.exit(socket, :kill)
    Process.sleep(20)

    {:ok, fresh_browser} = Dialup.Session.browser_url(pid)
    fresh_token = fresh_browser["browserToken"]
    refute fresh_token == join_token

    assert {:ok, _} = UserSessionProcess.reserve_browser_join_token(pid, fresh_token, tab_b)
  end

  test "finalize-join sets the session cookie after browser join" do
    {:ok, descriptor} = Dialup.Session.start(App, "/")
    {:ok, pid} = Agent.lookup(descriptor["token"])
    {:ok, browser} = Dialup.Session.browser_url(pid)
    join_token = browser["browserToken"]
    tab_id = unique("tab")

    assert {:ok, _} = UserSessionProcess.reserve_browser_join_token(pid, join_token, tab_id)
    assert :ok = UserSessionProcess.browser_join_with_token(pid, self(), tab_id, join_token)
    nonce = :sys.get_state(pid).pending_finalize.nonce

    conn =
      Plug.Test.conn(:post, "/_dialup/finalize-join?tab_id=#{tab_id}&nonce=#{nonce}")
      |> Dialup.Server.call(Dialup.Server.init(app: App))

    assert conn.status == 200
    assert ["dialup_session=" <> _] = Plug.Conn.get_resp_header(conn, "set-cookie")
  end

  test "reload reconnects to a joined headless session by session_id" do
    {:ok, descriptor} = Dialup.Session.start(App, "/")
    {:ok, pid} = Agent.lookup(descriptor["token"])
    session_id = UserSessionProcess.session_id(pid)
    tab_id = unique("tab")

    assert :ok = UserSessionProcess.browser_join(pid, self(), tab_id)

    new_tab = unique("tab")

    assert {:ok, state} =
             Dialup.WebSocket.init(%{
               app_module: App,
               session_id: session_id,
               tab_id: new_tab
             })

    assert state.session_pid == pid
    assert Registry.lookup(Dialup.SessionRegistry, new_tab) == [{pid, nil}]
  end

  test "GET with consumed _join does not attach the headless session cookie" do
    {:ok, descriptor} = Dialup.Session.start(App, "/")
    {:ok, pid} = Agent.lookup(descriptor["token"])
    {:ok, browser} = Dialup.Session.browser_url(pid)
    join_url = browser["browserUrl"]
    join_token = browser["browserToken"]
    headless_session_id = UserSessionProcess.session_id(pid)

    assert :ok = UserSessionProcess.consume_browser_token(pid, join_token)

    conn =
      Plug.Test.conn(:get, join_url)
      |> Dialup.Server.call(Dialup.Server.init(app: App))

    assert conn.status == 200
    ["dialup_session=" <> cookie_value] = Plug.Conn.get_resp_header(conn, "set-cookie")
    refute String.starts_with?(cookie_value, headless_session_id)
  end

  test "invalid browser join token stops websocket init" do
    {:ok, descriptor} = Dialup.Session.start(App, "/")
    {:ok, pid} = Agent.lookup(descriptor["token"])
    session_id = UserSessionProcess.session_id(pid)

    assert {:stop, :invalid_browser_join} =
             Dialup.WebSocket.init(%{
               app_module: App,
               session_id: session_id,
               tab_id: unique("tab"),
               join_token: "invalid-token"
             })
  end

  test "consumed browser join token stops websocket init" do
    {:ok, descriptor} = Dialup.Session.start(App, "/")
    {:ok, pid} = Agent.lookup(descriptor["token"])
    {:ok, browser} = Dialup.Session.browser_url(pid)
    join_token = browser["browserToken"]
    session_id = UserSessionProcess.session_id(pid)

    assert :ok = UserSessionProcess.consume_browser_token(pid, join_token)

    assert {:stop, :invalid_browser_join} =
             Dialup.WebSocket.init(%{
               app_module: App,
               session_id: session_id,
               tab_id: unique("tab"),
               join_token: join_token
             })
  end

  test "consumed browser join token is rejected before websocket upgrade" do
    {:ok, descriptor} = Dialup.Session.start(App, "/")
    {:ok, pid} = Agent.lookup(descriptor["token"])
    {:ok, browser} = Dialup.Session.browser_url(pid)
    join_token = browser["browserToken"]

    assert :ok = UserSessionProcess.consume_browser_token(pid, join_token)

    conn =
      Plug.Test.conn(:get, "/ws?tab_id=test-tab&join_token=#{join_token}")
      |> Plug.Conn.put_req_header("cookie", "dialup_session=placeholder")
      |> Dialup.Server.call(Dialup.Server.init(app: App))

    assert conn.status == 403
  end

  test "browser_join_with_token allows only one reserved tab to attach" do
    {:ok, descriptor} = Dialup.Session.start(App, "/")
    {:ok, pid} = Agent.lookup(descriptor["token"])
    {:ok, browser} = Dialup.Session.browser_url(pid)
    join_token = browser["browserToken"]
    tab_a = unique("tab-a")
    tab_b = unique("tab-b")

    assert {:ok, _} = UserSessionProcess.reserve_browser_join_token(pid, join_token, tab_a)

    assert :ok = UserSessionProcess.browser_join_with_token(pid, self(), tab_a, join_token)

    assert {:error, :already_joined} =
             UserSessionProcess.browser_join_with_token(pid, self(), tab_b, join_token)
  end

  test "reserve_browser_join_token rejects after browser has attached" do
    {:ok, descriptor} = Dialup.Session.start(App, "/")
    {:ok, pid} = Agent.lookup(descriptor["token"])
    {:ok, browser} = Dialup.Session.browser_url(pid)
    join_token = browser["browserToken"]
    tab_a = unique("tab-a")
    tab_b = unique("tab-b")

    assert {:ok, _} = UserSessionProcess.reserve_browser_join_token(pid, join_token, tab_a)
    assert :ok = UserSessionProcess.browser_join_with_token(pid, self(), tab_a, join_token)

    assert {:error, :already_joined} =
             UserSessionProcess.reserve_browser_join_token(pid, join_token, tab_b)
  end

  test "pending browser join rolls back when finalize is not completed in time" do
    {:ok, descriptor} = Dialup.Session.start(App, "/")
    {:ok, pid} = Agent.lookup(descriptor["token"])
    {:ok, browser} = Dialup.Session.browser_url(pid)
    join_token = browser["browserToken"]
    tab_a = unique("tab-a")
    tab_b = unique("tab-b")

    assert {:ok, _} = UserSessionProcess.reserve_browser_join_token(pid, join_token, tab_a)
    assert :ok = UserSessionProcess.browser_join_with_token(pid, self(), tab_a, join_token)

    %{pending_finalize: %{nonce: nonce}} = :sys.get_state(pid)
    send(pid, {:pending_finalize_timeout, nonce})

    assert Process.alive?(pid)
    assert UserSessionProcess.awaiting_browser_join?(pid)
    assert {:ok, _} = UserSessionProcess.reserve_browser_join_token(pid, join_token, tab_b)
  end

  test "reserve_browser_join_token requires tab_id" do
    {:ok, descriptor} = Dialup.Session.start(App, "/")
    {:ok, pid} = Agent.lookup(descriptor["token"])
    {:ok, browser} = Dialup.Session.browser_url(pid)
    join_token = browser["browserToken"]

    assert {:error, :invalid_token} =
             UserSessionProcess.reserve_browser_join_token(pid, join_token, "")
  end

  test "reserve_browser_join_token allows only one concurrent reservation" do
    {:ok, descriptor} = Dialup.Session.start(App, "/")
    {:ok, pid} = Agent.lookup(descriptor["token"])
    {:ok, browser} = Dialup.Session.browser_url(pid)
    join_token = browser["browserToken"]

    results =
      1..2
      |> Task.async_stream(
        fn i ->
          UserSessionProcess.reserve_browser_join_token(pid, join_token, unique("tab-#{i}"))
        end,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.count(results, fn
             {:error, :already_reserved} -> true
             {:error, :invalid_token} -> true
             _ -> false
           end) == 1
  end

  test "failed headless start terminates the session process" do
    before = DynamicSupervisor.count_children(Dialup.SessionSupervisor).active

    assert {:error, :init_failed} = UserSessionProcess.start_headless(App, "/boom")

    Process.sleep(50)

    assert DynamicSupervisor.count_children(Dialup.SessionSupervisor).active == before
  end

  test "GET with _join does not set the headless session cookie before websocket join" do
    {:ok, descriptor} = Dialup.Session.start(App, "/")
    {:ok, pid} = Agent.lookup(descriptor["token"])
    {:ok, browser} = Dialup.Session.browser_url(pid)
    join_url = browser["browserUrl"]
    headless_session_id = UserSessionProcess.session_id(pid)

    conn =
      Plug.Test.conn(:get, join_url)
      |> Dialup.Server.call(Dialup.Server.init(app: App))

    assert conn.status == 200

    for cookie <- Plug.Conn.get_resp_header(conn, "set-cookie") do
      refute String.contains?(cookie, headless_session_id)
    end
  end

  test "websocket rejects an invalid join token before upgrade" do
    conn =
      Plug.Test.conn(:get, "/ws?tab_id=test-tab&join_token=invalid")
      |> Plug.Conn.put_req_header("cookie", "dialup_session=placeholder")
      |> Dialup.Server.call(Dialup.Server.init(app: App))

    assert conn.status == 403
  end

  test "HTTP GET seeds nested layout session for SSR" do
    conn =
      Plug.Test.conn(:get, "/board")
      |> Dialup.Server.call(Dialup.Server.init(app: App))

    assert conn.status == 200
    assert conn.resp_body =~ "data-board-label>empty</h1>"
  end

  test "navigating to a page merges nested layout session keys", %{pid: pid, token: token} do
    UserSessionProcess.navigate(pid, "/board")
    assert_receive {:send_html, payload}
    assert Jason.decode!(payload)["path"] == "/board"

    scene =
      rpc(token, 1, "tools/call", %{"name" => "read_scene", "arguments" => %{}})

    assert scene["result"]["structuredContent"]["state"]["board_label"] == "empty"
  end

  test "nested layout session survives navigation away and back", %{pid: pid, token: token} do
    UserSessionProcess.navigate(pid, "/board")
    assert_receive {:send_html, _to_board}

    board_scene =
      rpc(token, 1, "tools/call", %{"name" => "read_scene", "arguments" => %{}})

    version = board_scene["result"]["structuredContent"]["version"]

    updated =
      rpc(token, 2, "tools/call", %{
        "name" => "set_board_label",
        "arguments" => %{"value" => "kept", "_version" => version}
      })

    assert_receive {:send_html, _board_update}
    assert updated["result"]["structuredContent"]["state"]["board_label"] == "kept"

    UserSessionProcess.navigate(pid, "/")
    assert_receive {:send_html, _to_home}

    UserSessionProcess.navigate(pid, "/board")
    assert_receive {:send_html, _back_to_board}

    scene =
      rpc(token, 3, "tools/call", %{"name" => "read_scene", "arguments" => %{}})

    assert scene["result"]["structuredContent"]["state"]["board_label"] == "kept"
  end

  test "opening the root page first still seeds nested layout session on navigate", %{
    pid: pid,
    token: token
  } do
    scene =
      rpc(token, 1, "tools/call", %{"name" => "read_scene", "arguments" => %{}})

    refute Map.has_key?(scene["result"]["structuredContent"]["state"], "board_label")

    UserSessionProcess.navigate(pid, "/board")
    assert_receive {:send_html, _}

    board =
      rpc(token, 2, "tools/call", %{"name" => "read_scene", "arguments" => %{}})

    assert board["result"]["structuredContent"]["state"]["board_label"] == "empty"
  end

  defp rpc(token, id, method, params) do
    Agent.rpc(token, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    })
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
end
