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
    assert initial["agent"]["status"] == "handoff_required"
    refute Map.has_key?(initial["agent"], "endpoint")

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

    assert_receive {:send_html, focus_payload}

    assert Jason.decode!(focus_payload) == %{
             "dialup" => "focus",
             "origin" => "agent",
             "target" => "increment",
             "version" => 1
           }

    assert_receive {:send_html, _agent_update}
    assert acted["result"]["structuredContent"]["state"]["count"] == 5
    assert acted["result"]["structuredContent"]["version"] == 2
  end

  test "tools/list exposes declarations and human approval resumes the action", %{
    pid: pid,
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
    assert_receive {:send_html, focus_payload}
    assert Jason.decode!(focus_payload)["target"] == "reset"
    assert_receive {:send_html, approval_payload}
    approval = Jason.decode!(approval_payload)["approval"]

    UserSessionProcess.agent_approval(pid, approval["id"], "approve")
    assert_receive {:send_html, _updated_page}

    status =
      rpc(token, 3, "tools/call", %{
        "name" => "approval_status",
        "arguments" => %{"id" => approval["id"]}
      })

    assert status["result"]["structuredContent"]["status"] == "completed"
    assert status["result"]["structuredContent"]["version"] == 1
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

  test "agent subscribers receive human state changes and focus", %{pid: pid, token: token} do
    assert :ok = UserSessionProcess.agent_attach(pid, token, self())

    UserSessionProcess.human_focus(pid, "counter")
    assert_receive {:agent_notification, "focus", %{"origin" => "human", "target" => "counter"}}

    UserSessionProcess.event(pid, "increment", %{"amount" => 2})
    assert_receive {:send_html, _page}
    assert_receive {:agent_notification, "state_changed", scene}
    assert scene["state"]["count"] == 2
  end

  test "human rectangle selections persist in read_scene and notify agents", %{
    pid: pid,
    token: token
  } do
    assert :ok = UserSessionProcess.agent_attach(pid, token, self())

    selection = %{
      "mode" => "rectangle",
      "targets" => [
        %{
          "id" => "dom:#summary",
          "kind" => "dom",
          "selector" => "#summary",
          "tag" => "p",
          "role" => "",
          "description" => "Counter summary",
          "text" => "0",
          "rect" => %{"x" => 20, "y" => 30, "width" => 240, "height" => 100}
        }
      ],
      "rectangle" => %{"x" => 10, "y" => 20, "width" => 280, "height" => 140},
      "pointer" => %{"x" => 290, "y" => 160},
      "viewport" => %{"width" => 1280, "height" => 720, "scrollX" => 0, "scrollY" => 0}
    }

    UserSessionProcess.human_focus(pid, selection)

    assert_receive {:agent_notification, "focus",
                    %{
                      "origin" => "human",
                      "target" => "dom:#summary",
                      "selection" => %{"mode" => "rectangle"}
                    }}

    scene = rpc(token, 9, "tools/call", %{"name" => "read_scene", "arguments" => %{}})
    human_focus = scene["result"]["structuredContent"]["humanFocus"]

    assert human_focus["target"] == "dom:#summary"

    assert human_focus["targets"]
           |> hd()
           |> Map.take(["id", "kind", "selector", "tag", "description"]) == %{
             "id" => "dom:#summary",
             "kind" => "dom",
             "selector" => "#summary",
             "tag" => "p",
             "description" => "Counter summary"
           }

    assert human_focus["rectangle"]["width"] == 280
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
    refute "focus" in names
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

    assert_receive {:send_html, _focus}
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

  test "ordinary page URLs advertise invisible agent discovery metadata" do
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
    assert conn.resp_body =~ "This ordinary URL is not the user"
    refute conn.resp_body =~ ~s(style="display)
  end

  test "live endpoint repeats page concepts and complete protocol recovery guidance", %{
    token: token
  } do
    {:ok, descriptor} = Agent.describe(token)
    discovery = descriptor["agentDiscovery"]

    assert discovery["message"]["concept"] ==
             "A shared counter operated by a human and an agent."

    assert discovery["connection"]["status"] == "connected"
    assert discovery["connection"]["sessionOrigin"] == "user_handoff_capability"
    assert discovery["connection"]["endpoint"] == "/agent/#{token}"
    assert discovery["protocolGuide"]["transport"]["http"] =~ "/agent/#{token}"
    assert discovery["protocolGuide"]["versioning"]["staleError"] == -32_009
    assert discovery["protocolGuide"]["versioning"]["recovery"] =~ "read_scene"
    assert discovery["protocolGuide"]["expiryRecovery"] =~ "ask the user"
    assert discovery["protocolGuide"]["humanFirst"] =~ "illustrative"
  end

  test "well-known discovery explains concepts and operations without a live token" do
    conn =
      Plug.Test.conn(:get, "/.well-known/dialup-agent?path=%2F")
      |> Dialup.Server.call(Dialup.Server.init(app: App))

    assert conn.status == 200
    discovery = Jason.decode!(conn.resp_body)

    assert discovery["message"]["concept"] ==
             "A shared counter operated by a human and an agent."

    assert discovery["connection"]["status"] == "no_user_session_capability"
    assert discovery["accessModel"]["ordinaryUrl"] =~ "not authority"
    assert discovery["accessModel"]["decisionRule"] =~ "Hand off to AI"
    assert discovery["accessModel"]["suggestedReply"] =~ "セッション引き継ぎURL"
    assert discovery["accessModel"]["sessionIsolation"] =~ "does not attach"
    assert length(discovery["agentQuickstart"]["steps"]) >= 6
    assert discovery["agentQuickstart"]["approvalSemantics"] =~ "confirm=human"
    assert Enum.any?(discovery["scene"]["actions"], &(&1["name"] == "increment"))
    assert hd(discovery["scene"]["regions"])["name"] == "counter"
  end

  test "llms.txt explains URL-only discovery" do
    conn =
      Plug.Test.conn(:get, "/llms.txt")
      |> Dialup.Server.call(Dialup.Server.init(app: App))

    assert conn.status == 200
    assert conn.resp_body =~ "does NOT grant access"
    assert conn.resp_body =~ "Hand off to AI"
    assert conn.resp_body =~ "/agent/"
    assert conn.resp_body =~ "tools/list"
    assert conn.resp_body =~ "_version"
  end

  test "a human can issue a fresh handoff capability for the current session", %{pid: pid} do
    assert {:ok, handoff} = UserSessionProcess.issue_browser_handoff(pid)
    assert handoff["endpoint"] =~ ~r{^/agent/[^/]+$}
    assert handoff["grant"]["requireVersion"]

    token = handoff["token"]
    read = rpc(token, 1, "tools/call", %{"name" => "read_scene", "arguments" => %{}})
    assert read["result"]["structuredContent"]["state"]["count"] == 0

    log = rpc(token, 2, "tools/call", %{"name" => "read_audit_log", "arguments" => %{}})

    assert Enum.any?(log["result"]["structuredContent"]["entries"], fn entry ->
             entry["actor"] == "human" and entry["action"] == "issue_agent_handoff"
           end)
  end

  test "browser websocket returns a newly issued handoff URL", %{pid: pid} do
    message = Jason.encode!(%{"event" => "__issue_agent_handoff", "value" => %{}})

    assert {:reply, :ok, {:text, payload}, _state} =
             Dialup.WebSocket.handle_in(
               {message, [opcode: :text]},
               %{session_pid: pid, session_id: "test"}
             )

    response = Jason.decode!(payload)
    assert response["dialup"] == "handoff_issued"
    assert response["handoff"]["endpoint"] =~ ~r{^/agent/[^/]+$}
    assert response["handoff"]["grant"]["expiresInMs"] > 0
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
