defmodule Dialup.WebSocket do
  @behaviour WebSock

  # WebSocket接続確立時、既存セッションを引き継ぐか新規プロセスを起動する
  @impl WebSock
  def init(%{app_module: app_module, session_id: session_id}) do
    session_pid =
      case Registry.lookup(Dialup.SessionRegistry, session_id) do
        [{pid, _}] ->
          # 既存プロセスが生存中 → socket_pidだけ更新して引き継ぐ
          Dialup.UserSessionProcess.take_over(pid, self())
          pid

        [] ->
          # プロセスが存在しない（初回 or タイムアウト済み）→ 新規起動
          {:ok, pid} =
            DynamicSupervisor.start_child(
              Dialup.SessionSupervisor,
              {Dialup.UserSessionProcess, {self(), app_module, session_id}}
            )

          pid
      end

    Dialup.Telemetry.websocket_connect(%{session_id: session_id})
    {:ok, %{session_pid: session_pid, session_id: session_id}}
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

  def handle_info(_msg, state), do: {:ok, state}

  @impl WebSock
  def terminate(_reason, state) do
    Dialup.Telemetry.websocket_disconnect(%{session_id: state[:session_id]})
    :ok
  end
end
