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
  def agent_describe(pid, token), do: GenServer.call(pid, {:agent_describe, token})
  def agent_tools(pid, token), do: GenServer.call(pid, {:agent_tools, token})

  def agent_call(pid, token, name, arguments),
    do: GenServer.call(pid, {:agent_call, token, name, arguments})

  def revoke_agent(pid, token), do: GenServer.call(pid, {:agent_revoke, token})
  def issue_agent_grant(pid, opts), do: GenServer.call(pid, {:agent_grant, opts})
  def issue_browser_handoff(pid), do: GenServer.call(pid, :issue_browser_handoff)

  @impl GenServer
  def init(%{
        socket_pid: socket_pid,
        app_module: app_module,
        session_id: session_id,
        registry_key: registry_key
      }) do
    {:ok, _} = Registry.register(Dialup.SessionRegistry, registry_key, nil)
    agent_token = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
    {:ok, _} = Registry.register(Dialup.SessionRegistry, {:agent_token, agent_token}, nil)
    {:ok, agent_proxy} = Dialup.Agent.RegistryProxy.start_link(self(), agent_token)
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
      timeout_ref: nil,
      agent_token: agent_token,
      agent_grants: %{
        agent_token => Dialup.Agent.Grant.new(agent_token, %{expires_in: :infinity})
      },
      agent_proxies: %{agent_token => agent_proxy},
      version: 0,
      audit_log: [],
      ui_locked: false,
      lock_reason: nil,
      set_actions: %{}
    }

    state =
      if uses_ets_store?(app_module) do
        case Dialup.SessionStore.restore(session_id) do
          {:ok, %{session: session, assigns: assigns, path: path}} ->
            session_keys = MapSet.new(Map.keys(session))

            %{
              base_state
              | session: session,
                session_keys: session_keys,
                assigns: assigns,
                path: path
            }

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

  def handle_call({:agent_describe, token}, _from, state) do
    case fetch_grant(state, token) do
      {:ok, grant} ->
        page_module = current_page(state)
        assigns = merge_for_render(state)

        discovery =
          if page_module do
            Dialup.Agent.connected_discovery(
              page_module,
              assigns,
              state.path,
              state.version,
              grant,
              token,
              layout_actions(state)
            )
          else
            nil
          end

        {:reply,
         {:ok,
          %{
            "endpoint" => Dialup.Agent.endpoint(token),
            "path" => state.path,
            "version" => state.version,
            "grant" => Dialup.Agent.Grant.public(grant),
            "agentDiscovery" => discovery
          }}, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:agent_tools, token}, _from, state) do
    result =
      with {:ok, grant} <- fetch_grant(state, token) do
        tools =
          case current_page(state) do
            nil ->
              []

            page_module ->
              Dialup.Agent.tools(
                page_module,
                merge_for_render(state),
                grant,
                layout_actions(state)
              )
          end

        {:ok, tools}
      end

    {:reply, result, state}
  end

  def handle_call({:agent_call, token, "read_scene", _arguments}, _from, state) do
    case fetch_grant(state, token) do
      {:ok, grant} ->
        {:reply, {:ok, current_scene(state, grant)}, audit(state, token, "read_scene", :ok)}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:agent_call, token, "read_audit_log", _arguments}, _from, state) do
    case fetch_grant(state, token) do
      {:ok, grant} ->
        if Dialup.Agent.Grant.allows?(grant, "read_audit_log") do
          entries = state.audit_log |> Enum.reverse() |> Enum.map(&json_safe_audit/1)
          {:reply, {:ok, %{"entries" => entries}}, state}
        else
          {:reply, {:error, :forbidden}, state}
        end

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:agent_call, token, "lock_ui", arguments}, _from, state) do
    case fetch_grant(state, token) do
      {:ok, grant} ->
        if Dialup.Agent.Grant.allows?(grant, "lock_ui") do
          reason = arguments["reason"] || arguments[:reason]
          locked = %{state | ui_locked: true, lock_reason: reason}
          update_page(locked)
          locked = audit(locked, token, "lock_ui", :ok, %{"reason" => reason})
          {:reply, {:ok, lock_result(locked, grant)}, locked}
        else
          {:reply, {:error, :forbidden}, state}
        end

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:agent_call, token, "unlock_ui", _arguments}, _from, state) do
    case fetch_grant(state, token) do
      {:ok, grant} ->
        if Dialup.Agent.Grant.allows?(grant, "lock_ui") do
          unlocked = %{state | ui_locked: false, lock_reason: nil}
          update_page(unlocked)
          unlocked = audit(unlocked, token, "unlock_ui", :ok)
          {:reply, {:ok, lock_result(unlocked, grant)}, unlocked}
        else
          {:reply, {:error, :forbidden}, state}
        end

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:agent_call, token, name, arguments}, _from, state) do
    {reply, new_state} = invoke_agent_action(state, token, name, arguments)
    {:reply, reply, new_state}
  end

  def handle_call({:agent_revoke, token}, _from, state) do
    case Map.fetch(state.agent_grants, token) do
      {:ok, grant} ->
        grants = Map.put(state.agent_grants, token, Dialup.Agent.Grant.revoke(grant))
        {:reply, :ok, %{state | agent_grants: grants}}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:agent_grant, opts}, _from, state) do
    {reply, state} = create_agent_grant(state, opts)
    {:reply, reply, state}
  end

  def handle_call(:issue_browser_handoff, _from, state) do
    case current_page(state) do
      nil ->
        {:reply, {:error, :not_ready}, state}

      page_module ->
        opts = page_module.agent_grant(merge_for_render(state))
        {reply, state} = create_agent_grant(state, opts)
        {:reply, reply, audit(state, :human, "issue_agent_handoff", :ok)}
    end
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

      new_state =
        %{
          state
          | path: path,
            params: params,
            session: session,
            session_keys: session_keys,
            assigns: assigns,
            subscriptions: subs
        }
        |> configure_primary_grant()
        |> update_page()

      {:noreply, new_state}
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

        new_state =
          %{
            state
            | path: path,
              params: params,
              session: session,
              session_keys: session_keys,
              assigns: assigns,
              subscriptions: subs
          }
          |> configure_primary_grant()
          |> update_page()

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
  def handle_cast({:event, _event, _value}, %{ui_locked: true} = state) do
    # UI is locked by an agent; ignore human interactions and re-assert the
    # current view so any optimistic client state is corrected.
    {:noreply, update_page(state)}
  end

  def handle_cast({:event, event, value}, state) do
    case state.app_module.page_for(state.path) do
      nil ->
        {:noreply, state}

      page_module ->
        start_time = Dialup.Telemetry.event_start(event, state.path)

        try do
          resolved_event = resolve_event(page_module, event)

          result =
            case apply_event(page_module, resolved_event, value, state) do
              {:ok, new_state} ->
                {:noreply, audit(new_state, :human, to_string(resolved_event), :ok, value)}

              {:error, reason} ->
                raise "event failed: #{inspect(reason)}"
            end

          Dialup.Telemetry.event_stop(start_time, event, state.path)
          result
        rescue
          e ->
            Dialup.Telemetry.event_exception(
              start_time,
              event,
              state.path,
              :error,
              e,
              __STACKTRACE__
            )

            send_error(state, e, __STACKTRACE__)
            {:noreply, state}
        end
    end
  end

  # ページ遷移：session は保持、assigns をリセットして page.mount を呼ぶ
  @impl GenServer
  def handle_cast({:navigate, _path}, %{ui_locked: true} = state) do
    {:noreply, update_page(state)}
  end

  def handle_cast({:navigate, path}, state) do
    {:noreply, do_navigate(path, bump_version(state))}
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
  def handle_info(msg, state), do: delegate_info(msg, state)

  defp delegate_info(msg, state) do
    case state.app_module.page_for(state.path) do
      nil ->
        {:noreply, state}

      page_module ->
        merged = merge_for_render(state)

        try do
          case page_module.handle_info(msg, merged) do
            {:noreply, new_merged} ->
              {new_session, new_assigns} = split_assigns(new_merged, state.session_keys)
              new_state = bump_version(%{state | session: new_session, assigns: new_assigns})
              {:noreply, new_state}

            {:update, new_merged} ->
              {new_session, new_assigns} = split_assigns(new_merged, state.session_keys)
              new_state = bump_version(%{state | session: new_session, assigns: new_assigns})
              {:noreply, update_page(new_state)}

            {:patch, target, rendered, new_merged} ->
              {new_session, new_assigns} = split_assigns(new_merged, state.session_keys)
              new_state = bump_version(%{state | session: new_session, assigns: new_assigns})
              html = to_html(rendered)
              payload = Jason.encode!(%{target: target, html: html})
              if state.socket_pid, do: send(state.socket_pid, {:send_html, payload})
              {:noreply, new_state}

            {:redirect, path, new_merged} ->
              {new_session, new_assigns} = split_assigns(new_merged, state.session_keys)
              new_state = bump_version(%{state | session: new_session, assigns: new_assigns})
              {:noreply, do_navigate(path, new_state)}

            {:push_event, event_name, event_payload, new_merged} ->
              {new_session, new_assigns} = split_assigns(new_merged, state.session_keys)
              new_state = bump_version(%{state | session: new_session, assigns: new_assigns})
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

      result =
        %{state | path: path, params: params, assigns: assigns, subscriptions: subs}
        |> configure_primary_grant()
        |> update_page()

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

            Dialup.Router.render_with_layouts_raw(
              error_html,
              error_module,
              layouts,
              render_assigns
            )
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
        nil ->
          html

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
        if String.contains?(line, ".ex:") and not String.contains?(line, "(elixir") and
             not String.contains?(line, "(stdlib") do
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
          String.contains?(line, "(dialup") or String.contains?(line, "(elixir") or
              String.contains?(line, "(stdlib") ->
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
    |> Map.put(:dialup_agent, %{version: state.version, ui_locked: state.ui_locked})
  end

  # handle_event/handle_info の返り値を session と assigns に分割する
  defp split_assigns(merged, session_keys) do
    new_session = Map.take(merged, MapSet.to_list(session_keys))

    new_assigns =
      Map.drop(merged, MapSet.to_list(session_keys) ++ [:params, :current_path, :dialup_agent])

    {new_session, new_assigns}
  end

  defp render(state) do
    Dialup.SetActions.begin_collect()
    html = do_render(state)
    set_actions = Dialup.SetActions.collect()
    Dialup.SetActions.clear()
    Process.put(:dialup_last_set_actions, set_actions)
    html
  end

  defp do_render(state) do
    render_assigns = merge_for_render(state)

    case state.app_module.dispatch(state.path, render_assigns) do
      {:ok, html} -> html
      {:error, :not_found} -> render_error_page(404, state)
    end
  end

  defp capture_set_actions(state) do
    set_actions = Process.get(:dialup_last_set_actions, state.set_actions)
    Process.delete(:dialup_last_set_actions)
    %{state | set_actions: set_actions}
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
    function_exported?(app_module, :__session_store__, 0) and
      app_module.__session_store__() == :ets
  end

  defp to_html(rendered) when is_binary(rendered), do: rendered

  defp to_html(rendered) do
    rendered
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp update_page(state) do
    state =
      if state.socket_pid do
        html = render(state)
        state = capture_set_actions(state)

        payload = %{html: html, path: state.path}
        payload = put_title(payload, state)
        payload = put_ui_lock(payload, state)
        send(state.socket_pid, {:send_html, Jason.encode!(payload)})
        state
      else
        state
      end

    state
  end

  defp put_ui_lock(payload, state) do
    payload
    |> Map.put(:ui_locked, state.ui_locked)
    |> Map.put(:lock_reason, state.lock_reason)
  end

  defp lock_result(state, grant) do
    state
    |> current_scene(grant)
    |> Map.put("uiLocked", state.ui_locked)
    |> Map.put("lockReason", state.lock_reason)
  end

  defp apply_event(page_module, event, value, state) do
    merged = merge_for_render(state)
    action = Dialup.Agent.action(page_module, event, layout_actions(state))

    try do
      case action do
        %{set: _} = action ->
          apply_set_action(state, action, merged)

        %{command: _command} = action ->
          apply_command_action(state, action, value)

        _ ->
          apply_handle_event(page_module, event, value, merged, state)
      end
    rescue
      exception -> {:error, {exception, __STACKTRACE__}}
    end
  end

  defp apply_handle_event(page_module, event, value, merged, state) do
    case page_module.handle_event(event, value, merged) do
      {:noreply, new_merged} ->
        {new_session, new_assigns} = split_assigns(new_merged, state.session_keys)
        new_state = bump_version(%{state | session: new_session, assigns: new_assigns})
        {:ok, new_state}

      {:update, new_merged} ->
        {new_session, new_assigns} = split_assigns(new_merged, state.session_keys)
        new_state = bump_version(%{state | session: new_session, assigns: new_assigns})
        {:ok, update_page(new_state)}

      {:patch, target, rendered, new_merged} ->
        {new_session, new_assigns} = split_assigns(new_merged, state.session_keys)
        new_state = bump_version(%{state | session: new_session, assigns: new_assigns})
        html = to_html(rendered)
        payload = Jason.encode!(%{target: target, html: html})
        if state.socket_pid, do: send(state.socket_pid, {:send_html, payload})
        {:ok, new_state}

      {:redirect, path, new_merged} ->
        {new_session, new_assigns} = split_assigns(new_merged, state.session_keys)
        new_state = bump_version(%{state | session: new_session, assigns: new_assigns})
        {:ok, do_navigate(path, new_state)}

      {:push_event, event_name, event_payload, new_merged} ->
        {new_session, new_assigns} = split_assigns(new_merged, state.session_keys)
        new_state = bump_version(%{state | session: new_session, assigns: new_assigns})
        send_push_event(new_state, event_name, event_payload)
        {:ok, new_state}

      other ->
        {:error, {:invalid_event_return, other}}
    end
  end

  defp apply_set_action(state, action, merged) do
    key = to_string(action.name)

    case Map.fetch(state.set_actions, key) do
      {:ok, updates} ->
        new_merged = Map.merge(merged, updates)
        {new_session, new_assigns} = split_assigns(new_merged, state.session_keys)
        new_state = bump_version(%{state | session: new_session, assigns: new_assigns})
        {:ok, update_page(new_state)}

      :error ->
        {:error, :missing_set_action}
    end
  end

  defp apply_command_action(state, action, value) do
    {context_module, command_name} = action.command
    bind = Map.get(action, :bind, %{})

    with {:ok, command} <-
           Dialup.Command.build(context_module, command_name, bind, value || %{}),
         :ok <- dispatch_command(context_module, command) do
      new_state = state |> remount_page() |> update_page()
      {:ok, new_state}
    else
      {:error, reason} ->
        {:error, {:command_failed, Dialup.Command.map_error(action, reason)}}
    end
  end

  defp dispatch_command(context_module, command) do
    case Code.ensure_loaded(context_module) do
      {:module, _} ->
        dispatch_loaded_context(context_module, command)

      {:error, reason} ->
        {:error, {:invalid_context, reason}}
    end
  end

  defp dispatch_loaded_context(context_module, command) do
    cond do
      function_exported?(context_module, :dispatch, 1) ->
        normalize_dispatch_result(context_module.dispatch(command))

      function_exported?(context_module, :dispatch, 2) ->
        normalize_dispatch_result(context_module.dispatch(command, []))

      true ->
        {:error, :missing_context_dispatch}
    end
  end

  defp normalize_dispatch_result(:ok), do: :ok
  defp normalize_dispatch_result({:ok, _}), do: :ok
  defp normalize_dispatch_result({:error, reason}), do: {:error, reason}
  defp normalize_dispatch_result(other), do: {:error, other}

  defp remount_page(state) do
    params = state.app_module.path_params(state.path)

    assigns =
      mount_page(state.path, params, state.session, state.session_keys, state.app_module)

    bump_version(%{state | assigns: assigns})
  end

  defp current_page(state), do: state.app_module.page_for(state.path)

  defp create_agent_grant(state, opts) do
    token = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
    {:ok, _} = Registry.register(Dialup.SessionRegistry, {:agent_token, token}, nil)
    {:ok, proxy} = Dialup.Agent.RegistryProxy.start_link(self(), token)
    grant = Dialup.Agent.Grant.new(token, opts)
    grants = Map.put(state.agent_grants, token, grant)
    proxies = Map.put(state.agent_proxies, token, proxy)

    {{:ok,
      %{
        "token" => token,
        "endpoint" => Dialup.Agent.endpoint(token),
        "grant" => Dialup.Agent.Grant.public(grant)
      }}, %{state | agent_grants: grants, agent_proxies: proxies}}
  end

  defp current_scene(state, grant) do
    scene =
      case current_page(state) do
        nil ->
          %{
            "path" => state.path,
            "version" => state.version,
            "state" => %{},
            "regions" => [],
            "actions" => []
          }

        page_module ->
          Dialup.Agent.scene(
            page_module,
            merge_for_render(state),
            state.path,
            state.version,
            grant,
            layout_actions(state)
          )
      end

    Map.put(scene, "uiLocked", state.ui_locked)
  end

  defp layout_actions(state), do: Dialup.Agent.layout_actions(state.app_module, state.path)

  defp resolve_event(page_module, event) do
    case Dialup.Agent.action(page_module, event) do
      nil -> event
      action -> action.name
    end
  end

  defp send_push_event(state, event_name, event_payload) do
    if state.socket_pid do
      html = render(state)

      payload = %{
        html: html,
        path: state.path,
        push_event: event_name,
        payload: event_payload
      }

      payload = put_title(payload, state)
      payload = put_ui_lock(payload, state)
      send(state.socket_pid, {:send_html, Jason.encode!(payload)})
    end
  end

  defp bump_version(state), do: %{state | version: state.version + 1}

  defp invoke_agent_action(state, token, name, arguments) do
    with {:ok, grant} <- fetch_grant(state, token),
         true <- Dialup.Agent.Grant.allows?(grant, name) || {:error, :forbidden},
         page_module when not is_nil(page_module) <- current_page(state),
         action when not is_nil(action) <-
           Dialup.Agent.action(page_module, name, layout_actions(state)) do
      case Map.get(action, :navigate) do
        nil ->
          invoke_mutating_action(state, token, grant, page_module, action, name, arguments)

        path ->
          invoke_navigate_action(state, token, grant, action, name, path)
      end
    else
      nil -> {{:error, :unknown_action}, state}
      false -> {{:error, :forbidden}, state}
      {:error, reason} -> {{:error, reason}, audit(state, token, name, :error)}
    end
  end

  defp invoke_mutating_action(state, token, grant, page_module, action, name, arguments) do
    with :ok <- check_version(grant, arguments, state.version),
         clean_arguments = Map.drop(arguments, ["_version", :_version]),
         {:ok, clean_arguments} <- validate_agent_arguments(action, clean_arguments),
         true <-
           Dialup.Agent.available?(
             Map.get(action, :module, page_module),
             action.name,
             merge_for_render(state)
           ) ||
             {:error, :unavailable} do
      if Map.get(action, :confirm) == :human do
        {{:error, :human_confirmation_required},
         audit(state, token, name, :human_confirmation_required)}
      else
        clean_arguments = Map.put(clean_arguments, "_dialup_actor", "agent")

        case apply_declarative_or_legacy(page_module, action, name, clean_arguments, state) do
          {:ok, new_state} ->
            new_state = audit(new_state, token, name, :ok, clean_arguments)
            {{:ok, current_scene(new_state, grant)}, new_state}

          {:error, reason} ->
            {{:error, reason}, audit(state, token, name, :error)}
        end
      end
    else
      {:error, reason} -> {{:error, reason}, audit(state, token, name, :error)}
    end
  end

  defp invoke_navigate_action(state, token, grant, action, name, path) do
    module = Map.get(action, :module, current_page(state))
    assigns = merge_for_render(state)

    cond do
      Map.get(action, :confirm) == :human ->
        {{:error, :human_confirmation_required},
         audit(state, token, name, :human_confirmation_required)}

      not Dialup.Agent.available?(module, action.name, assigns) ->
        {{:error, :unavailable}, audit(state, token, name, :error)}

      is_nil(state.app_module.page_for(path)) ->
        {{:error, :unknown_target}, audit(state, token, name, :error)}

      true ->
        navigated = do_navigate(path, bump_version(state))
        navigated = audit(navigated, token, name, :ok, %{"path" => path})
        {{:ok, current_scene(navigated, grant)}, navigated}
    end
  end

  defp apply_declarative_or_legacy(page_module, action, _name, arguments, state) do
    apply_event(page_module, action.name, arguments, state)
  end

  defp check_version(%{require_version: false}, _arguments, _current), do: :ok

  defp check_version(_grant, arguments, current) do
    expected = Map.get(arguments, "_version", Map.get(arguments, :_version))
    if expected == current, do: :ok, else: {:error, {:stale, current}}
  end

  defp validate_agent_arguments(action, arguments) do
    case Dialup.Agent.Validator.validate(action, arguments) do
      {:ok, validated} -> {:ok, validated}
      {:error, errors} -> {:error, {:invalid_arguments, errors}}
    end
  end

  defp fetch_grant(state, token) do
    case Map.fetch(state.agent_grants, token) do
      {:ok, grant} ->
        if Dialup.Agent.Grant.active?(grant), do: {:ok, grant}, else: {:error, :grant_expired}

      :error ->
        {:error, :grant_expired}
    end
  end

  defp configure_primary_grant(state) do
    case current_page(state) do
      nil ->
        state

      page_module ->
        opts = page_module.agent_grant(merge_for_render(state))
        grant = Dialup.Agent.Grant.new(state.agent_token, opts)
        %{state | agent_grants: Map.put(state.agent_grants, state.agent_token, grant)}
    end
  end

  defp audit(state, token, action, result, details \\ %{}) do
    entry = %{
      id: System.unique_integer([:positive, :monotonic]),
      at: System.system_time(:millisecond),
      actor: if(token == :human, do: "human", else: "agent"),
      token: if(is_binary(token), do: String.slice(token, 0, 8), else: nil),
      action: action,
      result: result,
      version: state.version,
      details: details
    }

    %{state | audit_log: Enum.take([entry | state.audit_log], 100)}
  end

  defp json_safe_audit(entry) do
    Map.new(entry, fn {key, value} -> {to_string(key), json_safe_value(value)} end)
  end

  defp json_safe_value(value) when is_atom(value), do: to_string(value)

  defp json_safe_value(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), json_safe_value(v)} end)

  defp json_safe_value(value) when is_list(value), do: Enum.map(value, &json_safe_value/1)
  defp json_safe_value(value), do: value
end
