defmodule Dialup.UserSessionProcess do
  use GenServer

  def start_link(socket_pid, app_module) do
    GenServer.start_link(__MODULE__, %{socket_pid: socket_pid, app_module: app_module})
  end

  def init_session(pid, path), do: GenServer.cast(pid, {:init, path})
  def navigate(pid, path), do: GenServer.cast(pid, {:navigate, path})
  def event(pid, event, value), do: GenServer.cast(pid, {:event, event, value})

  @impl GenServer
  def init(%{socket_pid: socket_pid, app_module: app_module}) do
    Process.monitor(socket_pid)
    {:ok, %{path: nil, socket_pid: socket_pid, app_module: app_module, assigns: %{}}}
  end

  # 初回接続：クライアントが現在のパスを通知してくる
  @impl GenServer
  def handle_cast({:init, path}, state) do
    new_assigns = mount(path, state)
    {:noreply, %{state | path: path, assigns: new_assigns}}
  end

  # イベント処理：現在のページモジュールの handle_event/3 に委譲する
  @impl GenServer
  def handle_cast({:event, event, value}, state) do
    case state.app_module.page_for(state.path) do
      nil ->
        {:noreply, state}

      page_module ->
        case page_module.handle_event(event, value, state.assigns) do
          # stateのみ更新
          {:noreply, new_assigns} ->
            {:noreply, %{state | assigns: new_assigns}}

          # 全体再描画
          {:update, new_assigns} ->
            new_state = update_page(%{state | assigns: new_assigns})
            {:noreply, new_state}

          # 部分morph
          {:patch, target, rendered, new_assigns} ->
            html = to_html(rendered)
            payload = Jason.encode!(%{target: target, html: html})
            send(state.socket_pid, {:send_html, payload})
            {:noreply, %{state | assigns: new_assigns}}
        end
    end
  end

  # ページ遷移：新しいページのmount/1を呼ぶ
  @impl GenServer
  def handle_cast({:navigate, path}, state) do
    new_assigns = mount(path, state)
    new_state = update_page(%{state | path: path, assigns: new_assigns})
    {:noreply, new_state}
  end

  # WebSocketプロセスが落ちたら自分も終了
  @impl GenServer
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp mount(path, state) do
    case state.app_module.page_for(path) do
      nil ->
        state.assigns

      page_module ->
        {:ok, new_assigns} = page_module.mount(state.assigns)
        new_assigns
    end
  end

  defp render(state) do
    case state.app_module.dispatch(state.path, state.assigns) do
      {:ok, html} -> html
      {:error, :not_found} -> "<h1>404 Not Found</h1>"
    end
  end

  defp to_html(rendered) when is_binary(rendered), do: rendered

  defp to_html(rendered) do
    rendered
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp update_page(state) do
    html = render(state)
    payload = Jason.encode!(%{html: html, path: state.path})
    send(state.socket_pid, {:send_html, payload})
    state
  end
end
