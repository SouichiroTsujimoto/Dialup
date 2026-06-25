defmodule Dialup.AgentHandoffTest do
  use ExUnit.Case, async: false

  alias Dialup.Agent
  alias Dialup.AgentHandoffTest.App
  alias Dialup.UserSessionProcess

  setup_all do
    start_supervised!({Registry, keys: :unique, name: Dialup.SessionRegistry})
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
    refute Dialup.Page.navigate_action_name("/foo-bar") == Dialup.Page.navigate_action_name("/foo/bar")
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
