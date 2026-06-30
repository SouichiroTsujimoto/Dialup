defmodule Dialup.CommandedIntegrationTest do
  use ExUnit.Case, async: false

  alias Dialup.Agent
  alias Dialup.CommandedTest.App
  alias Dialup.CommandedTest.Store
  alias Dialup.UserSessionProcess

  setup_all do
    start_supervised!({Registry, keys: :unique, name: Dialup.SessionRegistry})
    start_supervised!(Dialup.CommandedTest.Store)
    :ok
  end

  setup do
    Store.reset()

    session_id = unique("session")
    registry_key = unique("tab")

    pid =
      start_supervised!(
        {UserSessionProcess, {self(), App, session_id, registry_key}},
        id: registry_key
      )

    UserSessionProcess.init_session(pid, "/")
    assert_receive {:send_html, _initial}
    {:ok, handoff} = UserSessionProcess.issue_browser_handoff(pid)
    token = handoff["token"]

    %{pid: pid, token: token}
  end

  test "command mode dispatches through the context and remounts", %{pid: pid, token: token} do
    result =
      rpc(token, 1, "tools/call", %{
        "name" => "increment",
        "arguments" => %{"amount" => 2, "_version" => 0}
      })

    assert_receive {:send_html, _}
    assert result["result"]["structuredContent"]["state"]["count"] == 2

    UserSessionProcess.event(pid, "increment", %{"amount" => 3})
    assert_receive {:send_html, _}
    scene = rpc(token, 2, "tools/call", %{"name" => "read_scene", "arguments" => %{}})
    assert scene["result"]["structuredContent"]["state"]["count"] == 5
  end

  test "set mode updates assigns from the rendered set map", %{token: token} do
    toggled =
      rpc(token, 1, "tools/call", %{
        "name" => "toggle_sidebar",
        "arguments" => %{"_version" => 0}
      })

    assert_receive {:send_html, _}
    assert toggled["result"]["structuredContent"]["state"]["sidebar_open"] == true
  end

  test "tools/list exposes action modes", %{token: token} do
    tools = rpc(token, 1, "tools/list", %{})["result"]["tools"]

    increment = Enum.find(tools, &(&1["name"] == "increment"))
    toggle = Enum.find(tools, &(&1["name"] == "toggle_sidebar"))

    assert increment["_meta"]["mode"] == "command"
    assert toggle["_meta"]["mode"] == "set"
  end

  test "available is derived for command actions", %{pid: pid, token: token} do
    for _ <- 1..10 do
      UserSessionProcess.event(pid, "increment", %{"amount" => 1})
      assert_receive {:send_html, _}
    end

    listed = rpc(token, 1, "tools/list", %{})
    increment = Enum.find(listed["result"]["tools"], &(&1["name"] == "increment"))
    assert increment["_meta"]["available"] == false
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
