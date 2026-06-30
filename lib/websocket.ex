defmodule Dialup.WebSocket do
  @moduledoc false
  @behaviour WebSock

  # WebSocket接続確立時、既存セッションを引き継ぐか新規プロセスを起動する
  # tab_id (sessionStorage) をregistry keyとして使うことで、
  # 同一ブラウザの複数タブが互いのセッションプロセスを上書きしない
  @impl WebSock
  def init(%{app_module: app_module, session_id: session_id, tab_id: tab_id} = args) do
    join_token = Map.get(args, :join_token)

    if is_binary(join_token) and join_token != "" do
      init_with_join_token(tab_id, join_token)
    else
      init_normal(app_module, session_id, tab_id)
    end
  end

  defp init_with_join_token(tab_id, join_token) do
    result =
      case Registry.lookup(Dialup.SessionRegistry, {:browser_token, join_token}) do
        [{pid, _}] ->
          case Dialup.UserSessionProcess.browser_join_with_token(pid, self(), tab_id, join_token) do
            :ok -> {:ok, pid}
            _ ->
              _ = Dialup.UserSessionProcess.release_browser_join_reservation(pid, join_token)
              :error
          end

        [] ->
          :error
      end

    case result do
      {:ok, pid} ->
        session_id = Dialup.UserSessionProcess.session_id(pid)
        Dialup.Telemetry.websocket_connect(%{session_id: session_id})

        {:ok,
         %{
           session_pid: pid,
           session_id: session_id,
           joined: true
         }}

      _ ->
        {:stop, :invalid_browser_join}
    end
  end

  defp init_normal(app_module, session_id, tab_id) do
    session_pid =
      case lookup_live_session(session_id, tab_id) do
        {:ok, pid} ->
          case Dialup.UserSessionProcess.take_over(pid, self(), tab_id) do
            :ok ->
              pid

            {:error, :tab_id_in_use} ->
              :ok = Dialup.UserSessionProcess.take_over(pid, self(), nil)
              pid
          end

        :not_found ->
          registry_key = tab_id || session_id
          start_session(app_module, session_id, registry_key)
      end

    Dialup.Telemetry.websocket_connect(%{session_id: session_id})
    {:ok, %{session_pid: session_pid, session_id: session_id, joined: false}}
  end

  defp lookup_live_session(session_id, tab_id) do
    pid =
      cond do
        is_binary(tab_id) and tab_id != "" ->
          case Registry.lookup(Dialup.SessionRegistry, tab_id) do
            [{found, _}] -> found
            [] -> lookup_pid_by_session_id(session_id)
          end

        true ->
          lookup_pid_by_session_id(session_id)
      end

    case pid do
      nil ->
        :not_found

      found ->
        if Dialup.UserSessionProcess.session_id(found) == session_id and
             not Dialup.UserSessionProcess.awaiting_browser_join?(found) do
          {:ok, found}
        else
          :not_found
        end
    end
  end

  defp lookup_pid_by_session_id(session_id) do
    case Registry.lookup(Dialup.SessionRegistry, session_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp start_session(app_module, session_id, registry_key) do
    {:ok, pid} =
      DynamicSupervisor.start_child(
        Dialup.SessionSupervisor,
        {Dialup.UserSessionProcess, {self(), app_module, session_id, registry_key}}
      )

    pid
  end

  # クライアントからのメッセージを受け取りGenServerに委譲
  @impl WebSock
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, %{"event" => "__init", "value" => path}} ->
        Dialup.UserSessionProcess.init_session(state.session_pid, path)
        {:ok, state}

      {:ok, %{"event" => "__reconnect", "value" => path}} ->
        Dialup.UserSessionProcess.reconnect(state.session_pid, path)
        {:ok, state}

      {:ok, %{"event" => "__navigate", "value" => path}} ->
        Dialup.UserSessionProcess.navigate(state.session_pid, path)
        {:ok, state}

      {:ok, %{"event" => event, "value" => value}} ->
        Dialup.UserSessionProcess.event(state.session_pid, event, value)
        {:ok, state}

      {:error, _} ->
        {:ok, state}
    end
  end

  # GenServerからのHTMLをWebSocket経由でブラウザへ転送
  @impl WebSock
  def handle_info({:send_html, payload}, state) do
    {:reply, :ok, {:text, payload}, state}
  end

  def handle_info(:dialup_close_pending_join, state) do
    {:stop, :pending_finalize_timeout, state}
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl WebSock
  def terminate(_reason, %{joined: true, session_pid: pid} = state) when is_pid(pid) do
    _ = Dialup.UserSessionProcess.rollback_browser_join(pid)
    Dialup.Telemetry.websocket_disconnect(%{session_id: state[:session_id]})
    :ok
  end

  def terminate(_reason, state) do
    Dialup.Telemetry.websocket_disconnect(%{session_id: state[:session_id]})
    :ok
  end
end
