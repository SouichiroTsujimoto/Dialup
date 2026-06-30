defmodule Dialup.AvailableIntegrationTest do
  use ExUnit.Case, async: false

  alias Dialup.Agent
  alias Dialup.AvailableTest.App
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
    assert_receive {:send_html, _initial}
    {:ok, handoff} = UserSessionProcess.issue_browser_handoff(pid)
    token = handoff["token"]

    %{pid: pid, token: token}
  end

  test "tools/list _meta.available matches derived __available__/2", %{token: token} do
    tools = rpc(token, 1, "tools/list", %{})["result"]["tools"]
    increment = Enum.find(tools, &(&1["name"] == "increment"))
    assert increment["_meta"]["available"] == true
  end

  test "tools/call returns unavailable when derived availability is false", %{pid: pid, token: token} do
    for _ <- 1..10 do
      UserSessionProcess.event(pid, "increment", %{"amount" => 1})
      assert_receive {:send_html, _}
    end

    listed = rpc(token, 1, "tools/list", %{})
    increment = Enum.find(listed["result"]["tools"], &(&1["name"] == "increment"))
    assert increment["_meta"]["available"] == false

    scene = rpc(token, 2, "tools/call", %{"name" => "read_scene", "arguments" => %{}})
    version = scene["result"]["structuredContent"]["version"]

    result =
      rpc(token, 3, "tools/call", %{
        "name" => "increment",
        "arguments" => %{"amount" => 1, "_version" => version}
      })

    assert result["result"]["isError"] == true
    assert result["result"]["structuredContent"]["reason"] == "unavailable"
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
