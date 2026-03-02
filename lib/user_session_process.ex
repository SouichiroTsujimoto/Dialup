defmodule Dialup.UserSessionProcess do
  use GenServer

  def start_link(socket_pid) do
    GenServer.start_link(__MODULE__, %{socket_pid: socket_pid})
  end

  def init_session(pid, path), do: GenServer.cast(pid, {:init, path})
  def navigate(pid, path), do: GenServer.cast(pid, {:navigate, path})
  def event(pid, event, value), do: GenServer.cast(pid, {:event, event, value})

  @impl GenServer
  def init(%{socket_pid: socket_pid}) do
    Process.monitor(socket_pid)
    {:ok, %{path: nil, socket_pid: socket_pid, assigns: %{}}}
  end

  # 初回接続：クライアントが現在のパスを通知してくる
  @impl GenServer
  def handle_cast({:init, path}, state) do
    {:noreply, %{state | path: path}}
  end

  # イベント処理：現在のページモジュールの handle_event/3 に委譲する
  @impl GenServer
  def handle_cast({:event, event, value}, state) do
    case Dialup.Router.page_for(state.path) do
      nil ->
        {:noreply, state}

      page_module ->
        case page_module.handle_event(event, value, state.assigns) do
          # 全体再描画
          {:noreply, new_assigns} ->
            new_state = update_page(%{state | assigns: new_assigns})
            {:noreply, new_state}

          # 部分morph
          {:patch, target, html, new_assigns} ->
            payload = Jason.encode!(%{target: target, html: html})
            send(state.socket_pid, {:send_html, payload})
            {:noreply, %{state | assigns: new_assigns}}
        end
    end
  end

  # ページ遷移：新しいページのmount/1を呼ぶ
  @impl GenServer
  def handle_cast({:navigate, path}, state) do
    new_assigns = mount(path, state.assigns)
    new_state = update_page(%{state | path: path, assigns: new_assigns})
    {:noreply, new_state}
  end

  # WebSocketプロセスが落ちたら自分も終了
  @impl GenServer
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ページのmount/1を呼んで初期assignsを取得する
  defp mount(path, assigns) do
    case Dialup.Router.page_for(path) do
      nil ->
        assigns

      page_module ->
        if function_exported?(page_module, :mount, 1) do
          case page_module.mount(assigns) do
            {:ok, new_assigns} -> new_assigns
          end
        else
          assigns
        end
    end
  end

  defp render(path, assigns) do
    case Dialup.Router.dispatch(path, assigns) do
      {:ok, html} -> html
      {:error, :not_found} -> "<h1>404 Not Found</h1>"
    end
  end

  defp update_page(state) do
    html = render(state.path, state.assigns)
    payload = Jason.encode!(%{html: html, path: state.path})
    send(state.socket_pid, {:send_html, payload})
    state
  end
end
