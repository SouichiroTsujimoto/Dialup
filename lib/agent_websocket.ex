defmodule Dialup.AgentWebSocket do
  @moduledoc false
  @behaviour WebSock

  @impl WebSock
  def init(%{token: token}) do
    with {:ok, session_pid} <- Dialup.Agent.lookup(token),
         :ok <- Dialup.UserSessionProcess.agent_attach(session_pid, token, self()) do
      {:ok, %{token: token, session_pid: session_pid}}
    else
      _ -> {:stop, :normal}
    end
  end

  @impl WebSock
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, request} ->
        if Map.has_key?(request, "id") do
          response = Dialup.Agent.rpc(state.token, request)
          {:reply, :ok, {:text, Jason.encode!(response)}, state}
        else
          {:ok, state}
        end

      {:error, _reason} ->
        {:ok, state}
    end
  end

  @impl WebSock
  def handle_info({:agent_notification, method, params}, state) do
    payload = %{"jsonrpc" => "2.0", "method" => method, "params" => params}
    {:reply, :ok, {:text, Jason.encode!(payload)}, state}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl WebSock
  def terminate(_reason, state) do
    Dialup.UserSessionProcess.agent_detach(state.session_pid, self())
    :ok
  end
end
