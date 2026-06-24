defmodule Dialup.AgentHandoffTest.Page do
  use Dialup.Page

  declare_action(
    name: :increment,
    desc: "Increment the shared counter",
    params: %{amount: {:integer, default: 1}}
  )

  declare_action(
    name: :reset,
    desc: "Reset the counter",
    params: %{},
    confirm: :human,
    agent_only: true
  )

  declare_region(
    name: :counter,
    role: "status",
    desc: "Shared counter value",
    data: :count,
    actions: [:increment]
  )

  def mount(_params, assigns), do: {:ok, Map.put(assigns, :count, 0)}

  def __available__(:increment, assigns), do: assigns.count < 10
  def __available__(:reset, _assigns), do: true

  def agent_state(assigns), do: %{count: assigns.count}

  def agent_message(_assigns) do
    %{
      concept: "A shared counter operated by a human and an agent.",
      flow: ["Read the scene", "Increment with the current version"]
    }
  end

  def handle_event(:increment, params, assigns) do
    amount = params["amount"] || params[:amount] || 1
    {:update, Map.update!(assigns, :count, &(&1 + amount))}
  end

  def handle_event(:reset, _params, assigns), do: {:update, Map.put(assigns, :count, 0)}

  def render(assigns) do
    ~H"""
    <.dialup_region name={:counter} role="status" desc="Shared counter value">
      <span>{@count}</span>
    </.dialup_region>
    <.dialup_action name={:increment} amount="1">Increment</.dialup_action>
    """
  end
end

defmodule Dialup.AgentHandoffTest.App do
  alias Dialup.AgentHandoffTest.Page

  def page_for("/"), do: Page
  def page_for(_path), do: nil
  def path_params(_path), do: %{}
  def layouts_for(_path), do: []
  def error_page_for(_path), do: nil
  def dispatch("/", assigns), do: {:ok, Dialup.Router.render_with_layouts(Page, [], assigns)}
  def dispatch(_path, _assigns), do: {:error, :not_found}
  def __session_store__, do: :memory
  def __shell_opts__, do: %{title: "Test", lang: "en"}

  def __render_shell__(assigns) do
    "<html><head><title>Test</title></head><body>#{assigns.inner_content}</body></html>"
  end
end

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

    assert reset["error"]["code"] == -32_004
    assert reset["error"]["message"] =~ "not supported via HTTP MCP"
    assert reset["error"]["data"]["confirm"] == "human"
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

  test "stale versions and invalid arguments are rejected", %{token: token} do
    stale =
      rpc(token, 1, "tools/call", %{
        "name" => "increment",
        "arguments" => %{"amount" => 1, "_version" => 99}
      })

    assert stale["error"]["code"] == -32_009
    assert stale["error"]["data"]["currentVersion"] == 0

    invalid =
      rpc(token, 2, "tools/call", %{
        "name" => "increment",
        "arguments" => %{"amount" => "wrong", "_version" => 0}
      })

    assert invalid["error"]["code"] == -32_602
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
    assert conn.resp_body =~ "POST /agent/{token}"
    refute conn.resp_body =~ ~s(style="display)
  end

  test "live endpoint repeats page concepts and HTTP protocol guidance", %{token: token} do
    {:ok, descriptor} = Agent.describe(token)
    discovery = descriptor["agentDiscovery"]

    assert discovery["message"]["concept"] ==
             "A shared counter operated by a human and an agent."

    assert discovery["connection"]["status"] == "connected"
    assert discovery["connection"]["endpoint"] == "/agent/#{token}"
    refute Map.has_key?(discovery["connection"], "websocket")
    assert discovery["protocolGuide"]["transport"]["http"] =~ "/agent/#{token}"
    assert discovery["protocolGuide"]["versioning"]["staleError"] == -32_009
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
