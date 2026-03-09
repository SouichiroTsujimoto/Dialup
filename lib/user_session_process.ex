defmodule Dialup.UserSessionProcess do
  @moduledoc false
  use GenServer

  @session_timeout :timer.minutes(5)

  # DynamicSupervisor から起動される（引数はタプル）
  # registry_key: タブごとの一意キー（tab_id || session_id）
  # session_id: Cookie由来のセッションID（ETS永続化に使用）
  def start_link({socket_pid, app_module, session_id, registry_key}) do
    GenServer.start_link(__MODULE__, %{
      socket_pid: socket_pid,
      app_module: app_module,
      session_id: session_id,
      registry_key: registry_key
    })
  end

  def init_session(pid, path), do: GenServer.cast(pid, {:init, path})
  def navigate(pid, path), do: GenServer.cast(pid, {:navigate, path})
  def event(pid, event, value), do: GenServer.cast(pid, {:event, event, value})
  def session_id(pid), do: GenServer.call(pid, :get_session_id)
  def take_over(pid, new_socket_pid), do: GenServer.cast(pid, {:take_over, new_socket_pid})
  def reconnect(pid, path), do: GenServer.cast(pid, {:reconnect, path})

  @impl GenServer
  def init(%{socket_pid: socket_pid, app_module: app_module, session_id: session_id, registry_key: registry_key}) do
    {:ok, _} = Registry.register(Dialup.SessionRegistry, registry_key, nil)
    ref = Process.monitor(socket_pid)

    base_state = %{
      path: nil,
      socket_pid: socket_pid,
      app_module: app_module,
      session_id: session_id,
      session: %{},
      session_keys: MapSet.new(),
      assigns: %{},
      params: %{},
      subscriptions: [],
      monitor_ref: ref,
      timeout_ref: nil
    }

    state =
      if uses_ets_store?(app_module) do
        case Dialup.SessionStore.restore(session_id) do
          {:ok, %{session: session, assigns: assigns, path: path}} ->
            session_keys = MapSet.new(Map.keys(session))
            %{base_state | session: session, session_keys: session_keys, assigns: assigns, path: path}

          :error ->
            base_state
        end
      else
        base_state
      end

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:get_session_id, _from, state) do
    {:reply, state.session_id, state}
  end

  # 初回接続：layout.mount → session、page.mount → assigns
  @impl GenServer
  def handle_cast({:init, path}, state) do
    try do
      params = state.app_module.path_params(path)
      Process.put(:dialup_subscriptions, [])
      {session, session_keys} = mount_session(path, state.app_module)
      assigns = mount_page(path, params, session, session_keys, state.app_module)
      subs = Process.get(:dialup_subscriptions, [])
      {:noreply, %{state | path: path, params: params, session: session, session_keys: session_keys, assigns: assigns, subscriptions: subs}}
    rescue
      e ->
        new_state = %{state | path: path}
        send_error(new_state, e, __STACKTRACE__)
        {:noreply, new_state}
    end
  end

  # 再接続：プロセスが生存していれば現在のstateで再描画、タイムアウト済みならフルmount
  @impl GenServer
  def handle_cast({:reconnect, path}, state) do
    if state.path == nil do
      try do
        Process.put(:dialup_subscriptions, [])
        params = state.app_module.path_params(path)
        {session, session_keys} = mount_session(path, state.app_module)
        assigns = mount_page(path, params, session, session_keys, state.app_module)
        subs = Process.get(:dialup_subscriptions, [])
        new_state = update_page(%{state | path: path, params: params, session: session, session_keys: session_keys, assigns: assigns, subscriptions: subs})
        {:noreply, new_state}
      rescue
        e ->
          new_state = %{state | path: path}
          send_error(new_state, e, __STACKTRACE__)
          {:noreply, new_state}
      end
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

  @impl GenServer
  def handle_cast({:event, event, value}, state) do
    case state.app_module.page_for(state.path) do
      nil ->
        {:noreply, state}

      page_module ->
        merged = merge_for_render(state)
        start_time = Dialup.Telemetry.event_start(event, state.path)

        try do
          result =
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

              {:push_event, event_name, event_payload, new_merged} ->
                {new_session, new_assigns} = split_assigns(new_merged, state.session_keys)
                new_state = %{state | session: new_session, assigns: new_assigns}
                send_push_event(new_state, event_name, event_payload)
                {:noreply, new_state}
            end

          Dialup.Telemetry.event_stop(start_time, event, state.path)
          result
        rescue
          e ->
            Dialup.Telemetry.event_exception(start_time, event, state.path, :error, e, __STACKTRACE__)
            send_error(state, e, __STACKTRACE__)
            {:noreply, state}
        end
    end
  end

  # ページ遷移：session は保持、assigns をリセットして page.mount を呼ぶ
  @impl GenServer
  def handle_cast({:navigate, path}, state) do
    {:noreply, do_navigate(path, state)}
  end

  # ホットリロード：ファイル変更時に現在の state で再描画
  @impl GenServer
  def handle_info(:dialup_reload, state) do
    try do
      {:noreply, update_page(state)}
    rescue
      e ->
        send_error(state, e, __STACKTRACE__)
        {:noreply, state}
    end
  end

  # WebSocketプロセスが落ちたら即死せず、タイムアウトまで生存する
  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor_ref: ref} = state) do
    timeout_ref = Process.send_after(self(), :session_timeout, @session_timeout)
    {:noreply, %{state | socket_pid: nil, monitor_ref: nil, timeout_ref: timeout_ref}}
  end

  def handle_info(:session_timeout, state) do
    if uses_ets_store?(state.app_module) and state.path do
      Dialup.SessionStore.save(state.session_id, state.session, state.assigns, state.path)
    end

    {:stop, :normal, state}
  end

  # その他のメッセージは現在のページモジュールの handle_info/2 に委譲する
  def handle_info(msg, state) do
    case state.app_module.page_for(state.path) do
      nil ->
        {:noreply, state}

      page_module ->
        merged = merge_for_render(state)

        try do
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

            {:push_event, event_name, event_payload, new_merged} ->
              {new_session, new_assigns} = split_assigns(new_merged, state.session_keys)
              new_state = %{state | session: new_session, assigns: new_assigns}
              send_push_event(new_state, event_name, event_payload)
              {:noreply, new_state}
          end
        rescue
          e ->
            send_error(state, e, __STACKTRACE__)
            {:noreply, state}
        end
    end
  end

  # session を保持しつつ新しいパスに遷移する（navigate / redirect 共通）
  defp do_navigate(path, state) do
    start_time = Dialup.Telemetry.navigate_start(path)

    try do
      Enum.each(state.subscriptions, fn {pubsub, topic} ->
        Phoenix.PubSub.unsubscribe(pubsub, topic)
      end)

      Process.put(:dialup_subscriptions, [])
      params = state.app_module.path_params(path)
      assigns = mount_page(path, params, state.session, state.session_keys, state.app_module)
      subs = Process.get(:dialup_subscriptions, [])
      result = update_page(%{state | path: path, params: params, assigns: assigns, subscriptions: subs})
      Dialup.Telemetry.navigate_stop(start_time, path)
      result
    rescue
      e ->
        Dialup.Telemetry.navigate_exception(start_time, path, :error, e, __STACKTRACE__)
        new_state = %{state | path: path}
        send_error(new_state, e, __STACKTRACE__)
        new_state
    end
  end

  defp send_push_event(state, event_name, event_payload) do
    if state.socket_pid do
      html = render(state)
      payload = %{html: html, path: state.path, push_event: event_name, payload: event_payload}
      payload = put_title(payload, state)
      send(state.socket_pid, {:send_html, Jason.encode!(payload)})
    end
  end

  defp send_error(state, exception, stacktrace) do
    if state.socket_pid do
      html = render_error_page(500, state, exception, stacktrace)
      payload = Jason.encode!(%{html: html, path: state.path || "/"})
      send(state.socket_pid, {:send_html, payload})
    end
  end

  defp render_error_page(status, state, exception \\ nil, stacktrace \\ nil) do
    case state.app_module.error_page_for(state.path) do
      nil ->
        default_error_html(status, exception, stacktrace)

      error_module ->
        error_assigns = %{
          status: status,
          message: if(exception, do: Exception.message(exception), else: status_message(status))
        }

        error_assigns =
          if exception && Mix.env() == :dev do
            error_assigns
            |> Map.put(:exception, exception)
            |> Map.put(:stacktrace, Exception.format(:error, exception, stacktrace || []))
          else
            error_assigns
          end

        try do
          error_html =
            error_module.render(status, error_assigns)
            |> Phoenix.HTML.Safe.to_iodata()
            |> IO.iodata_to_binary()

          use_layout =
            if function_exported?(error_module, :__layout__, 0),
              do: error_module.__layout__(),
              else: true

          if use_layout do
            layouts = state.app_module.layouts_for(state.path || "/")
            render_assigns = merge_for_render(state)
            Dialup.Router.render_with_layouts_raw(error_html, error_module, layouts, render_assigns)
          else
            wrap_error_with_scope(error_html, error_module)
          end
        rescue
          _ ->
            default_error_html(status, exception, stacktrace)
        end
    end
  end

  defp wrap_error_with_scope(html, error_module) do
    if function_exported?(error_module, :__css_scope__, 0) do
      case error_module.__css_scope__() do
        nil -> html
        scope ->
          css = error_module.__css__() || ""
          css_tag = if css != "", do: ~s(<style data-dialup-css>#{css}</style>), else: ""
          css_tag <> ~s(<div class="#{scope}">) <> html <> "</div>"
      end
    else
      html
    end
  end

  defp status_message(404), do: "Not Found"
  defp status_message(500), do: "Internal Server Error"
  defp status_message(status), do: "Error #{status}"

  defp default_error_html(status, exception, stacktrace) do
    if exception do
      message = escape_html(Exception.message(exception))
      type = escape_html(inspect(exception.__struct__))
      trace = Exception.format(:error, exception, stacktrace || [])

      {file_line, formatted_trace} = format_stacktrace_html(trace)

      """
      <div style="all:initial;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;position:fixed;inset:0;z-index:99999;background:rgba(0,0,0,0.5);display:flex;align-items:center;justify-content:center">
        <div style="background:#1e1e2e;color:#cdd6f4;border-radius:12px;max-width:800px;width:95%;max-height:90vh;overflow:auto;box-shadow:0 25px 50px rgba(0,0,0,0.5)">
          <div style="padding:24px 28px;border-bottom:1px solid #313244">
            <div style="display:flex;align-items:center;gap:12px;margin-bottom:8px">
              <span style="background:#f38ba8;color:#1e1e2e;padding:4px 10px;border-radius:6px;font-size:13px;font-weight:700">#{status}</span>
              <span style="color:#f38ba8;font-size:14px;font-weight:600">#{type}</span>
            </div>
            <h2 style="margin:0;color:#f38ba8;font-size:18px;line-height:1.4;font-weight:500">#{message}</h2>
            #{file_line}
          </div>
          <details open style="padding:0">
            <summary style="padding:16px 28px;cursor:pointer;font-size:13px;color:#a6adc8;border-bottom:1px solid #313244;user-select:none">Stack Trace</summary>
            <pre style="margin:0;padding:20px 28px;font-size:13px;line-height:1.6;font-family:'SF Mono',Consolas,'Liberation Mono',Menlo,monospace;overflow-x:auto;white-space:pre-wrap;word-break:break-word">#{formatted_trace}</pre>
          </details>
        </div>
      </div>
      """
    else
      "<h1>#{status} #{status_message(status)}</h1>"
    end
  end

  defp format_stacktrace_html(trace) do
    lines = String.split(trace, "\n")

    file_line =
      Enum.find_value(lines, "", fn line ->
        if String.contains?(line, ".ex:") and not String.contains?(line, "(elixir") and not String.contains?(line, "(stdlib") do
          trimmed = String.trim(line)
          escaped = escape_html(trimmed)
          ~s(<p style="margin:8px 0 0;font-size:13px;color:#a6adc8;font-family:'SF Mono',Consolas,monospace">#{escaped}</p>)
        end
      end)

    formatted =
      lines
      |> Enum.map(fn line ->
        escaped = escape_html(line)

        cond do
          String.contains?(line, "(dialup") or String.contains?(line, "(elixir") or String.contains?(line, "(stdlib") ->
            ~s(<span style="color:#585b70">#{escaped}</span>)

          String.contains?(line, ".ex:") ->
            ~s(<span style="color:#89b4fa">#{escaped}</span>)

          String.starts_with?(String.trim(line), "**") ->
            ~s(<span style="color:#f38ba8;font-weight:600">#{escaped}</span>)

          true ->
            escaped
        end
      end)
      |> Enum.join("\n")

    {file_line, formatted}
  end

  defp escape_html(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
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
    |> Map.put(:current_path, state.path)
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
      {:error, :not_found} -> render_error_page(404, state)
    end
  end

  defp put_title(payload, state) do
    case state.app_module.page_for(state.path) do
      nil ->
        payload

      page_module ->
        merged = merge_for_render(state)

        case page_module.page_title(merged) do
          nil -> payload
          title -> Map.put(payload, :title, title)
        end
    end
  end

  defp uses_ets_store?(app_module) do
    function_exported?(app_module, :__session_store__, 0) and app_module.__session_store__() == :ets
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
      payload = %{html: html, path: state.path}
      payload = put_title(payload, state)
      send(state.socket_pid, {:send_html, Jason.encode!(payload)})
    end

    state
  end
end
