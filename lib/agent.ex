defmodule Dialup.Agent do
  @moduledoc """
  JSON-RPC/MCP projection for a live Dialup browser session.

  Each session receives an unguessable handoff endpoint. Calls made through that endpoint
  are serialized by the same session process that handles browser events.
  """

  alias Dialup.UserSessionProcess
  @protocol_version "2025-11-25"

  def endpoint(token), do: "/agent/#{token}"
  def websocket_endpoint(token), do: "/agent/#{token}/ws"

  def describe(token) do
    with {:ok, pid} <- lookup(token) do
      UserSessionProcess.agent_describe(pid, token)
    end
  end

  def rpc(token, request) when is_map(request) do
    id = Map.get(request, "id")

    with {:ok, pid} <- lookup(token),
         {:ok, result} <- dispatch(pid, token, request) do
      %{"jsonrpc" => "2.0", "id" => id, "result" => result}
    else
      {:error, code, message, data} ->
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{"code" => code, "message" => message, "data" => data}
        }

      {:error, code, message} ->
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{"code" => code, "message" => message}
        }

      {:error, :not_found} ->
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{"code" => -32_001, "message" => "Session is no longer available"}
        }

      {:error, :grant_expired} ->
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{"code" => -32_002, "message" => "Grant has expired or was revoked"}
        }

      {:error, :forbidden} ->
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{"code" => -32_003, "message" => "Grant does not allow this operation"}
        }
    end
  end

  def rpc(_token, _request) do
    %{
      "jsonrpc" => "2.0",
      "id" => nil,
      "error" => %{"code" => -32_600, "message" => "Invalid Request"}
    }
  end

  def tools(page_module, assigns, grant \\ nil) do
    actions =
      if function_exported?(page_module, :__dialup_actions__, 0),
        do: page_module.__dialup_actions__(),
        else: []

    builtins = [
      %{
        "name" => "read_scene",
        "description" => "Read the current semantic scene and live session state",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      },
      %{
        "name" => "focus",
        "description" =>
          "Show the human which semantic action or region the agent is targeting. " <>
            "The latest human click or rectangle selection is returned by read_scene.humanFocus.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{"target" => %{"type" => "string"}},
          "required" => ["target"]
        }
      },
      %{
        "name" => "approval_status",
        "description" => "Read the result of a pending human approval",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{"id" => %{"type" => "string"}},
          "required" => ["id"]
        }
      },
      %{
        "name" => "read_audit_log",
        "description" => "Read the ordered human and agent action log",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      }
    ]

    action_tools =
      Enum.map(actions, fn action ->
        name = action |> Map.fetch!(:name) |> to_string()

        %{
          "name" => name,
          "description" => Map.get(action, :desc, name),
          "inputSchema" =>
            input_schema(
              Map.get(action, :params, %{}),
              if(grant, do: grant.require_version, else: true)
            ),
          "_meta" => %{
            "available" => available?(page_module, action.name, assigns),
            "confirm" => Map.get(action, :confirm),
            "risk" => Map.get(action, :risk, "unspecified"),
            "effects" => Map.get(action, :effects),
            "reversible" => Map.get(action, :reversible),
            "idempotent" => Map.get(action, :idempotent),
            "examples" => Map.get(action, :examples),
            "success" => Map.get(action, :success)
          }
        }
      end)

    action_tools =
      if grant do
        Enum.filter(action_tools, &Dialup.Agent.Grant.allows?(grant, &1["name"]))
      else
        action_tools
      end

    builtins =
      if grant do
        Enum.filter(builtins, fn tool ->
          case tool["name"] do
            "read_scene" -> grant.projections != []
            "approval_status" -> true
            name -> Dialup.Agent.Grant.allows?(grant, name)
          end
        end)
      else
        builtins
      end

    builtins ++ action_tools
  end

  def scene(page_module, assigns, path, version, grant \\ nil) do
    regions =
      if function_exported?(page_module, :__dialup_regions__, 0),
        do: page_module.__dialup_regions__(),
        else: []

    actions =
      tools(page_module, assigns, grant)
      |> Enum.reject(
        &(&1["name"] in ["read_scene", "focus", "approval_status", "read_audit_log"])
      )
      |> Enum.map(fn tool ->
        %{
          "name" => tool["name"],
          "description" => tool["description"],
          "available" => tool["_meta"]["available"],
          "confirm" => tool["_meta"]["confirm"],
          "risk" => tool["_meta"]["risk"],
          "effects" => tool["_meta"]["effects"],
          "reversible" => tool["_meta"]["reversible"],
          "idempotent" => tool["_meta"]["idempotent"],
          "examples" => tool["_meta"]["examples"],
          "success" => tool["_meta"]["success"]
        }
      end)

    state =
      if function_exported?(page_module, :agent_state, 1),
        do: page_module.agent_state(assigns),
        else: %{}

    scene = %{
      "path" => path,
      "version" => version
    }

    scene
    |> maybe_put_projection(grant, :state, "state", json_safe(state))
    |> maybe_put_projection(
      grant,
      :regions,
      "regions",
      Enum.map(regions, &region_scene(&1, assigns))
    )
    |> maybe_put_projection(grant, :actions, "actions", actions)
  end

  def discovery(page_module, assigns, path) do
    message =
      if function_exported?(page_module, :agent_message, 1),
        do: page_module.agent_message(assigns),
        else: %{}

    %{
      "dialup" => "agent-discovery",
      "version" => 1,
      "url" => path,
      "message" => json_safe(message),
      "scene" => scene(page_module, assigns, path, 0),
      "accessModel" => %{
        "ordinaryUrl" =>
          "This URL describes the application, but it is not authority to access the " <>
            "user's current browser session.",
        "handoffUrl" =>
          "A URL whose path starts with /agent/ is a short-lived capability for one " <>
            "specific live browser session.",
        "sessionIsolation" =>
          "Opening the ordinary URL in the agent's own browser creates or selects that " <>
            "browser tab's session. It does not attach to work already open in the user's browser.",
        "decisionRule" =>
          "If the user asks to continue, inspect, or operate work already open in their browser " <>
            "and supplied only an ordinary URL, stop and ask them to click the site's " <>
            "\"Hand off to AI\" control and send the generated handoff URL.",
        "suggestedReply" =>
          "このURLは通常のページURLなので、現在ブラウザで開いている作業セッションには接続できません。" <>
            "ページ上の「AIに引き継ぐ」を押して発行されたセッション引き継ぎURL（/agent/ を含むURL）を送ってください。",
        "security" =>
          "Treat a handoff URL as a bearer credential. Ask the user to share it only with the " <>
            "intended agent, do not publish it, and expect it to expire."
      },
      "connection" => %{
        "status" => "no_user_session_capability",
        "instructions" =>
          "Do not claim access to the user's existing session from this ordinary URL. " <>
            "For an existing-work handoff, request a generated /agent/ URL from the user. " <>
            "Open this ordinary URL yourself only when starting a separate new session is intended.",
        "httpEndpointTemplate" => "/agent/{session-token}",
        "websocketEndpointTemplate" => "/agent/{session-token}/ws",
        "protocolVersion" => @protocol_version
      },
      "agentQuickstart" => %{
        "goal" =>
          "First determine whether the user wants their existing browser session or a new session.",
        "steps" => [
          "Classify the request: continue existing browser work, or start a separate new session.",
          "For existing work, require a generated URL containing /agent/; an ordinary URL is insufficient.",
          "If only an ordinary URL was supplied, explain the isolation and ask the user to click \"Hand off to AI\".",
          "After the user supplies the handoff URL, treat it as a sensitive short-lived capability.",
          "Use connection.endpoint as the JSON-RPC HTTP endpoint.",
          "Call initialize, tools/list, then read_scene.",
          "Use action _meta to judge risk, reversibility, approval, examples, and success.",
          "Use the current scene version in every mutating action.",
          "Call focus before a visible action when a human is present.",
          "Verify success with read_scene or the action result."
        ],
        "jsonRpcRequestShape" => %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "TOOL_NAME", "arguments" => %{}}
        },
        "sessionExpiry" =>
          "If a handoff URL expires, ask the user to issue a fresh handoff URL from the " <>
            "still-open page. Do not reload the ordinary URL and claim it is the same session.",
        "approvalSemantics" =>
          "confirm=human means the call creates a pending approval. Never bypass it. " <>
            "Wait for the human and query approval_status.",
        "spatialHandoff" =>
          "A human can click AIに場所を伝える and select one element or drag a rectangle " <>
            "across several elements. Semantic regions/actions are preferred; ordinary DOM " <>
            "elements include a selector and coordinates. Read the latest selection from " <>
            "read_scene.humanFocus; connected WebSockets also receive a focus notification."
      },
      "protocolGuide" => protocol_guide()
    }
  end

  def connected_discovery(page_module, assigns, path, version, grant, token) do
    discovery(page_module, assigns, path)
    |> Map.put("scene", scene(page_module, assigns, path, version, grant))
    |> put_in(
      ["connection"],
      %{
        "status" => "connected",
        "sessionOrigin" => "user_handoff_capability",
        "endpoint" => endpoint(token),
        "websocket" => websocket_endpoint(token),
        "stateVersion" => version,
        "grant" => Dialup.Agent.Grant.public(grant),
        "protocolVersion" => @protocol_version,
        "instructions" =>
          "POST JSON-RPC requests to endpoint. Use websocket for state_changed, focus, " <>
            "approval_resolved, and grant_revoked notifications."
      }
    )
    |> Map.put("protocolGuide", protocol_guide(token))
  end

  def available?(page_module, action, assigns) do
    if function_exported?(page_module, :__available__, 2),
      do: page_module.__available__(action, assigns),
      else: true
  end

  def action(page_module, name) do
    actions =
      if function_exported?(page_module, :__dialup_actions__, 0),
        do: page_module.__dialup_actions__(),
        else: []

    Enum.find(actions, fn action -> to_string(action.name) == to_string(name) end)
  end

  def target?(page_module, assigns, grant, target) do
    action_names =
      tools(page_module, assigns, grant)
      |> Enum.map(& &1["name"])
      |> Enum.reject(&(&1 in ["read_scene", "focus", "approval_status", "read_audit_log"]))

    region_names =
      if Dialup.Agent.Grant.projects?(grant, :regions) and
           function_exported?(page_module, :__dialup_regions__, 0) do
        Enum.map(page_module.__dialup_regions__(), &to_string(&1.name))
      else
        []
      end

    to_string(target) in (action_names ++ region_names)
  end

  def lookup(token) do
    case Registry.lookup(Dialup.SessionRegistry, {:agent_token, token}) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case :global.whereis_name({__MODULE__, token}) do
          :undefined -> {:error, :not_found}
          proxy -> {:ok, GenServer.call(proxy, :session_pid)}
        end
    end
  end

  defp dispatch(pid, token, %{"jsonrpc" => "2.0", "method" => "tools/list"}) do
    with {:ok, tools} <- UserSessionProcess.agent_tools(pid, token) do
      {:ok, %{"tools" => tools}}
    end
  end

  defp dispatch(_pid, _token, %{
         "jsonrpc" => "2.0",
         "method" => "initialize",
         "params" => _params
       }) do
    {:ok,
     %{
       "protocolVersion" => @protocol_version,
       "capabilities" => %{"tools" => %{"listChanged" => false}},
       "serverInfo" => %{"name" => "dialup-session", "version" => "0.1.0"}
     }}
  end

  defp dispatch(_pid, _token, %{"jsonrpc" => "2.0", "method" => "ping"}) do
    {:ok, %{}}
  end

  defp dispatch(_pid, _token, %{
         "jsonrpc" => "2.0",
         "method" => "notifications/initialized"
       }) do
    {:ok, %{}}
  end

  defp dispatch(pid, token, %{
         "jsonrpc" => "2.0",
         "method" => "tools/call",
         "params" => %{"name" => name} = params
       }) do
    arguments = Map.get(params, "arguments", %{})

    case UserSessionProcess.agent_call(pid, token, name, arguments) do
      {:ok, result} ->
        {:ok,
         %{
           "content" => [%{"type" => "text", "text" => Jason.encode!(result)}],
           "structuredContent" => result
         }}

      {:error, :unknown_action} ->
        {:error, -32_601, "Unknown tool: #{name}"}

      {:error, :unavailable} ->
        {:error, -32_003, "Action is not available in the current state"}

      {:error, :grant_expired} ->
        {:error, -32_002, "Grant has expired or was revoked"}

      {:error, :forbidden} ->
        {:error, -32_003, "Grant does not allow this operation"}

      {:error, :unknown_target} ->
        {:error, -32_602, "Unknown or inaccessible semantic target"}

      {:error, {:stale, current_version}} ->
        {:error, -32_009, "State version is stale", %{"currentVersion" => current_version}}

      {:error, {:invalid_arguments, errors}} ->
        {:error, -32_602, "Invalid tool arguments", %{"errors" => errors}}

      {:error, {:approval_required, approval}} ->
        {:error, -32_004, "Action requires human confirmation", approval}

      {:error, reason} ->
        {:error, -32_000, Exception.format_exit(reason)}
    end
  end

  defp dispatch(_pid, _token, %{"jsonrpc" => "2.0"}) do
    {:error, -32_601, "Method not found"}
  end

  defp dispatch(_pid, _token, _request), do: {:error, -32_600, "Invalid Request"}

  defp input_schema(params, require_version) do
    properties =
      Map.new(params, fn {name, spec} ->
        {to_string(name), schema_for(spec)}
      end)

    required =
      params
      |> Enum.reject(fn {_name, spec} ->
        {_type, opts} = normalize_spec(spec)
        Keyword.has_key?(opts, :default)
      end)
      |> Enum.map(fn {name, _spec} -> to_string(name) end)

    properties =
      if require_version,
        do: Map.put(properties, "_version", %{"type" => "integer"}),
        else: properties

    required = if require_version, do: ["_version" | required], else: required

    %{"type" => "object", "properties" => properties}
    |> then(fn schema ->
      if required == [], do: schema, else: Map.put(schema, "required", required)
    end)
  end

  defp schema_for(spec) do
    case normalize_spec(spec) do
      {:string, opts} -> schema_with_opts("string", opts)
      {:integer, opts} -> schema_with_opts("integer", opts)
      {:number, opts} -> schema_with_opts("number", opts)
      {:boolean, opts} -> schema_with_opts("boolean", opts)
      {:object, opts} -> schema_with_opts("object", opts)
      {type, opts} -> schema_with_opts(to_string(type), opts)
    end
  end

  defp normalize_spec({type, default}) when not is_list(default), do: {type, [default: default]}
  defp normalize_spec({type, opts}) when is_list(opts), do: {type, opts}
  defp normalize_spec(type), do: {type, []}

  defp schema_with_opts(type, opts) do
    Enum.reduce(opts, %{"type" => type}, fn {key, value}, schema ->
      Map.put(schema, to_string(key), value)
    end)
  end

  defp json_safe(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), json_safe(value)} end)

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)

  defp json_safe(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&json_safe/1)

  defp json_safe(nil), do: nil
  defp json_safe(true), do: true
  defp json_safe(false), do: false
  defp json_safe(value) when is_atom(value), do: to_string(value)
  defp json_safe(value), do: value

  defp maybe_put_projection(scene, nil, _projection, key, value), do: Map.put(scene, key, value)

  defp maybe_put_projection(scene, grant, projection, key, value) do
    if Dialup.Agent.Grant.projects?(grant, projection),
      do: Map.put(scene, key, value),
      else: scene
  end

  defp region_scene(region, assigns) do
    region
    |> json_safe()
    |> maybe_put_region_data(region, assigns)
  end

  defp maybe_put_region_data(scene, %{data: key}, assigns) when is_atom(key) do
    Map.put(scene, "data", json_safe(Map.get(assigns, key)))
  end

  defp maybe_put_region_data(scene, %{data: path}, assigns) when is_list(path) do
    Map.put(scene, "data", json_safe(get_in(assigns, path)))
  end

  defp maybe_put_region_data(scene, _region, _assigns), do: scene

  defp protocol_guide(token \\ "{session-token}") do
    endpoint = endpoint(token)

    %{
      "transport" => %{
        "http" => "POST #{endpoint} with Content-Type: application/json",
        "websocket" =>
          "Connect to #{websocket_endpoint(token)} for the same RPC methods plus push notifications.",
        "websocketPurpose" =>
          "Use push notifications to observe human state changes and approval results without polling."
      },
      "requests" => %{
        "initialize" => %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => @protocol_version,
            "capabilities" => %{},
            "clientInfo" => %{"name" => "ai-agent", "version" => "1"}
          }
        },
        "toolsList" => %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/list",
          "params" => %{}
        },
        "readScene" => %{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "tools/call",
          "params" => %{"name" => "read_scene", "arguments" => %{}}
        }
      },
      "versioning" => %{
        "rule" => "Every mutating action must include the latest scene version as _version.",
        "staleError" => -32_009,
        "recovery" =>
          "On stale error, do not retry blindly. Call read_scene, reconsider availability, " <>
            "then issue a new action with the returned version."
      },
      "expiryRecovery" =>
        "If this handoff endpoint returns expired/revoked, ask the user to issue a fresh " <>
          "handoff URL from their still-open page. Opening the ordinary URL creates a different session.",
      "humanFirst" =>
        "A human action shown in the UI may be an illustrative demo step. Follow the " <>
          "page-specific agent message to determine whether it is required."
    }
  end
end
