defmodule Dialup.Agent do
  @moduledoc """
  JSON-RPC/MCP projection for a live Dialup browser session.

  Agent tools are generated from page UI declarations and served over HTTP JSON-RPC at
  `POST /agent/:token`. See `guides/mcp-api.md` for the full reference.
  """

  alias Dialup.UserSessionProcess
  @protocol_version "2025-11-25"

  def endpoint(token), do: "/agent/#{token}"

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
      |> Enum.reject(&(&1["name"] in ["read_scene", "read_audit_log"]))
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
        "pageUrl" =>
          "The ordinary page URL exposes the tool catalog but does not authenticate an agent " <>
            "to a live browser session.",
        "sessionToken" =>
          "POST JSON-RPC to `/agent/{token}` with a bearer token issued for one live session.",
        "tokenSources" => [
          "POST `/_dialup/agent-handoff?tab_id=...` from the user's open browser tab",
          "Server-side `Dialup.Session.grant/2` for programmatic access"
        ],
        "security" =>
          "Treat session tokens as bearer credentials. They expire and can be revoked."
      },
      "connection" => %{
        "status" => "no_live_session",
        "instructions" =>
          "Obtain a session token, then POST JSON-RPC 2.0 to the HTTP MCP endpoint.",
        "httpEndpointTemplate" => "/agent/{session-token}",
        "protocolVersion" => @protocol_version
      },
      "agentQuickstart" => %{
        "goal" => "Operate the live session through HTTP request-response MCP tools.",
        "steps" => [
          "Fetch this discovery document for page concepts and the static tool catalog.",
          "Obtain a session bearer token for the target live session.",
          "POST initialize to `/agent/{token}`.",
          "POST tools/list to read generated tools from page declarations.",
          "POST tools/call read_scene to read the current semantic scene and version.",
          "POST tools/call for mutating actions with the latest `_version` in arguments.",
          "On stale version errors (-32009), call read_scene and retry."
        ],
        "jsonRpcRequestShape" => %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "TOOL_NAME", "arguments" => %{}}
        },
        "humanConfirmation" =>
          "Actions marked confirm=human are not executable via HTTP MCP. " <>
            "They require the human browser UI."
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
        "endpoint" => endpoint(token),
        "stateVersion" => version,
        "grant" => Dialup.Agent.Grant.public(grant),
        "protocolVersion" => @protocol_version,
        "instructions" =>
          "POST JSON-RPC 2.0 requests to endpoint with Content-Type: application/json."
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
      |> Enum.reject(&(&1 in ["read_scene", "read_audit_log"]))

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

      {:error, :human_confirmation_required} ->
        {:error, -32_004,
         "Action requires human confirmation and is not supported via HTTP MCP",
         %{"confirm" => "human"}}

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
        "http" => "POST #{endpoint} with Content-Type: application/json"
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
        "If the session token expires or is revoked, obtain a fresh token from the live session.",
      "humanConfirmation" =>
        "confirm=human actions return error -32004 over HTTP MCP. Use the human browser UI instead."
    }
  end
end
