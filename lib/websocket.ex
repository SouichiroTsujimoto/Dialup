defmodule Dialup.WebSocket do
  @behaviour WebSock

  # WebSocket接続確立時、GenServerを起動してPIDをstateに保存
  @impl WebSock
  def init(%{app_module: app_module}) do
    {:ok, session_pid} = Dialup.UserSessionProcess.start_link(self(), app_module)
    {:ok, %{session_pid: session_pid}}
  end

  # クライアントからのメッセージを受け取りGenServerに委譲
  @impl WebSock
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, %{"event" => "__init", "value" => path}} ->
        Dialup.UserSessionProcess.init_session(state.session_pid, path)
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
    # GenServer は Process.monitor で自動終了するため明示的なstopは不要
    _ = state
    :ok
  end
end
