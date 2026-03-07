defmodule Dialup.UserSessionProcess do
  use GenServer

  @session_timeout :timer.minutes(5)

  # DynamicSupervisor から起動される（引数はタプル）
  def start_link({socket_pid, app_module, session_id}) do
    GenServer.start_link(__MODULE__, %{
      socket_pid: socket_pid,
      app_module: app_module,
      session_id: session_id
    })
  end

  def init_session(pid, path), do: GenServer.cast(pid, {:init, path})
  def navigate(pid, path), do: GenServer.cast(pid, {:navigate, path})
  def event(pid, event, value), do: GenServer.cast(pid, {:event, event, value})
  def take_over(pid, new_socket_pid), do: GenServer.cast(pid, {:take_over, new_socket_pid})
  def reconnect(pid, path), do: GenServer.cast(pid, {:reconnect, path})

  @impl GenServer
  def init(%{socket_pid: socket_pid, app_module: app_module, session_id: session_id}) do
    {:ok, _} = Registry.register(Dialup.SessionRegistry, session_id, nil)
    ref = Process.monitor(socket_pid)

    {:ok,
     %{
       path: nil,
       socket_pid: socket_pid,
       app_module: app_module,
       # layout.mount の結果。ナビゲーションをまたいで持続する
       session: %{},
       # session に属するキーのセット（handle_event の返り値を分割するために使用）
       session_keys: MapSet.new(),
       # page.mount の結果。ナビゲーションごとにリセットされる
       assigns: %{},
       # 現在のURLパラメータ（framework が自動設定）
       params: %{},
       monitor_ref: ref,
       timeout_ref: nil
     }}
  end

  # 初回接続：layout.mount → session、page.mount → assigns
  @impl GenServer
  def handle_cast({:init, path}, state) do
    params = state.app_module.path_params(path)
    {session, session_keys} = mount_session(path, state.app_module)
    assigns = mount_page(path, params, session, session_keys, state.app_module)

    {:noreply, %{state | path: path, params: params, session: session, session_keys: session_keys, assigns: assigns}}
  end

  # 再接続：プロセスが生存していれば現在のstateで再描画、タイムアウト済みならフルmount
  @impl GenServer
  def handle_cast({:reconnect, path}, state) do
    if state.path == nil do
      params = state.app_module.path_params(path)
      {session, session_keys} = mount_session(path, state.app_module)
      assigns = mount_page(path, params, session, session_keys, state.app_module)
      new_state = update_page(%{state | path: path, params: params, session: session, session_keys: session_keys, assigns: assigns})
      {:noreply, new_state}
    else
      {:noreply, update_page(state)}
    end
  end

  # 再接続時のsocket_pid引き継ぎ
  @impl GenServer
  def handle_cast({:take_over, new_socket_pid}, state) do
    if state.monitor_ref, do: Process.demonitor(state.monitor_ref, [:flush])
    if state.timeout_ref, do: Process.cancel_timer(state.timeout_ref)
    ref = Process.monitor(new_socket_pid)
    {:noreply, %{state | socket_pid: new_socket_pid, monitor_ref: ref, timeout_ref: nil}}
  end

  # イベント処理：現在のページモジュールの handle_event/3 に委譲する
  @impl GenServer
  def handle_cast({:event, event, value}, state) do
    case state.app_module.page_for(state.path) do
      nil ->
        {:noreply, state}

      page_module ->
        merged = merge_for_render(state)

        case page_module.handle_event(event, value, merged) do
          {:noreply, new_merged} ->
            {new_session, new_assigns} = split_assigns(new_merged, state.session_keys)
            {:noreply, %{state | session: new_session, assigns: new_assigns}}

          {:update, new_merged} ->
            {new_session, new_assigns} = split_assigns(new_merged, state.session_keys)
            new_state = update_page(%{state | session: new_session, assigns: new_assigns})
            {:noreply, new_state}

          {:patch, target, rendered, new_merged} ->
            {new_session, new_assigns} = split_assigns(new_merged, state.session_keys)
            html = to_html(rendered)
            payload = Jason.encode!(%{target: target, html: html})
            send(state.socket_pid, {:send_html, payload})
            {:noreply, %{state | session: new_session, assigns: new_assigns}}

          {:redirect, path, new_merged} ->
            {new_session, new_assigns} = split_assigns(new_merged, state.session_keys)
            {:noreply, do_navigate(path, %{state | session: new_session, assigns: new_assigns})}
        end
    end
  end

  # ページ遷移：session は保持、assigns をリセットして page.mount を呼ぶ
  @impl GenServer
  def handle_cast({:navigate, path}, state) do
    {:noreply, do_navigate(path, state)}
  end

  # WebSocketプロセスが落ちたら即死せず、タイムアウトまで生存する
  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor_ref: ref} = state) do
    timeout_ref = Process.send_after(self(), :session_timeout, @session_timeout)
    {:noreply, %{state | socket_pid: nil, monitor_ref: nil, timeout_ref: timeout_ref}}
  end

  def handle_info(:session_timeout, state) do
    {:stop, :normal, state}
  end

  # その他のメッセージは現在のページモジュールの handle_info/2 に委譲する
  def handle_info(msg, state) do
    case state.app_module.page_for(state.path) do
      nil ->
        {:noreply, state}

      page_module ->
        merged = merge_for_render(state)

        case page_module.handle_info(msg, merged) do
          {:noreply, new_merged} ->
            {new_session, new_assigns} = split_assigns(new_merged, state.session_keys)
            {:noreply, %{state | session: new_session, assigns: new_assigns}}

          {:update, new_merged} ->
            {new_session, new_assigns} = split_assigns(new_merged, state.session_keys)
            {:noreply, update_page(%{state | session: new_session, assigns: new_assigns})}

          {:patch, target, rendered, new_merged} ->
            {new_session, new_assigns} = split_assigns(new_merged, state.session_keys)
            html = to_html(rendered)
            payload = Jason.encode!(%{target: target, html: html})
            send(state.socket_pid, {:send_html, payload})
            {:noreply, %{state | session: new_session, assigns: new_assigns}}

          {:redirect, path, new_merged} ->
            {new_session, new_assigns} = split_assigns(new_merged, state.session_keys)
            {:noreply, do_navigate(path, %{state | session: new_session, assigns: new_assigns})}
        end
    end
  end

  # session を保持しつつ新しいパスに遷移する（navigate / redirect 共通）
  defp do_navigate(path, state) do
    params = state.app_module.path_params(path)
    assigns = mount_page(path, params, state.session, state.session_keys, state.app_module)
    update_page(%{state | path: path, params: params, assigns: assigns})
  end

  # layout.mount を順番に呼び、session と session_keys を構築する
  # 親レイアウトの結果が子レイアウトの mount に渡される
  defp mount_session(path, app_module) do
    layouts = app_module.layouts_for(path)

    Enum.reduce(layouts, {%{}, MapSet.new()}, fn layout_mod, {session, keys} ->
      {:ok, new_session} = layout_mod.mount(session)
      new_keys = MapSet.new(Map.keys(new_session))
      {new_session, MapSet.union(keys, new_keys)}
    end)
  end

  # page.mount を呼び、session キーを除いた純粋な page assigns を返す
  defp mount_page(path, params, session, session_keys, app_module) do
    case app_module.page_for(path) do
      nil ->
        %{}

      page_module ->
        # page.mount は session を reads として受け取れる（current_user 等を参照可能）
        {:ok, result} = page_module.mount(params, session)
        # session キーを除いた部分だけが page assigns
        Map.drop(result, MapSet.to_list(session_keys))
    end
  end

  # session と assigns を合成して render 用 assigns を作る
  defp merge_for_render(state) do
    state.session
    |> Map.merge(state.assigns)
    |> Map.put(:params, state.params)
  end

  # handle_event/handle_info の返り値を session と assigns に分割する
  defp split_assigns(merged, session_keys) do
    new_session = Map.take(merged, MapSet.to_list(session_keys))
    new_assigns = Map.drop(merged, MapSet.to_list(session_keys) ++ [:params])
    {new_session, new_assigns}
  end

  defp render(state) do
    render_assigns = merge_for_render(state)

    case state.app_module.dispatch(state.path, render_assigns) do
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
    if state.socket_pid do
      html = render(state)
      payload = Jason.encode!(%{html: html, path: state.path})
      send(state.socket_pid, {:send_html, payload})
    end

    state
  end
end
