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

  def agent_approval(pid, approval_id, decision),
    do: GenServer.cast(pid, {:agent_approval, approval_id, decision})

  def human_focus(pid, target), do: GenServer.cast(pid, {:human_focus, target})

  def agent_attach(pid, token, socket_pid),
    do: GenServer.call(pid, {:agent_attach, token, socket_pid})

  def agent_detach(pid, socket_pid), do: GenServer.cast(pid, {:agent_detach, socket_pid})

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
      pending_approvals: %{},
      approval_results: %{},
      agent_subscribers: %{},
      human_focus: nil
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
              token
            )
          else
            nil
          end

        {:reply,
         {:ok,
          %{
            "endpoint" => Dialup.Agent.endpoint(token),
            "websocket" => Dialup.Agent.websocket_endpoint(token),
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
            nil -> []
            page_module -> Dialup.Agent.tools(page_module, merge_for_render(state), grant)
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

  def handle_call({:agent_call, token, "focus", %{"target" => target}}, _from, state) do
    case fetch_grant(state, token) do
      {:ok, grant} ->
        page_module = current_page(state)

        if (Dialup.Agent.Grant.allows?(grant, "focus") and page_module) &&
             Dialup.Agent.target?(page_module, merge_for_render(state), grant, target) do
          send_focus(state, target, "agent")

          {:reply, {:ok, %{"focused" => target, "version" => state.version}},
           audit(state, token, "focus", :ok, %{"target" => target})}
        else
          {:reply, {:error, :unknown_target}, state}
        end

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:agent_call, token, "approval_status", %{"id" => id}}, _from, state) do
    case fetch_grant(state, token) do
      {:ok, _grant} ->
        result =
          Map.get(state.approval_results, id) ||
            case Map.get(state.pending_approvals, id) do
              nil -> %{"id" => id, "status" => "not_found"}
              approval -> approval_public(approval)
            end

        {:reply, {:ok, result}, state}

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

  def handle_call({:agent_call, token, name, arguments}, _from, state) do
    {reply, new_state} = invoke_agent_action(state, token, name, arguments)
    {:reply, reply, new_state}
  end

  def handle_call({:agent_revoke, token}, _from, state) do
    case Map.fetch(state.agent_grants, token) do
      {:ok, grant} ->
        grants = Map.put(state.agent_grants, token, Dialup.Agent.Grant.revoke(grant))
        state = %{state | agent_grants: grants}
        state = disconnect_grant_subscribers(state, token)
        {:reply, :ok, state}

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

  def handle_call({:agent_attach, token, socket_pid}, _from, state) do
    case fetch_grant(state, token) do
      {:ok, _grant} ->
        ref = Process.monitor(socket_pid)
        subscribers = Map.put(state.agent_subscribers, socket_pid, %{token: token, ref: ref})
        {:reply, :ok, %{state | agent_subscribers: subscribers}}

      error ->
        {:reply, error, state}
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

  def handle_cast({:agent_approval, approval_id, decision}, state) do
    {:noreply, resolve_approval(state, approval_id, decision)}
  end

  def handle_cast({:human_focus, target}, state) do
    focus = normalize_human_focus(target, state)

    new_state =
      %{state | human_focus: focus}
      |> audit(:human, "focus", :ok, focus)
      |> notify_agents("focus", %{
        "target" => focus["target"],
        "targets" => focus["targets"],
        "selection" => focus,
        "origin" => "human",
        "version" => state.version
      })

    {:noreply, new_state}
  end

  def handle_cast({:agent_detach, socket_pid}, state) do
    {:noreply, drop_agent_subscriber(state, socket_pid)}
  end

  # ページ遷移：session は保持、assigns をリセットして page.mount を呼ぶ
  @impl GenServer
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

  def handle_info({:DOWN, ref, :process, pid, _reason} = message, state) do
    case Map.get(state.agent_subscribers, pid) do
      %{ref: ^ref} -> {:noreply, drop_agent_subscriber(state, pid)}
      _ -> delegate_info(message, state)
    end
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
              {:noreply, notify_state_changed(new_state)}

            {:update, new_merged} ->
              {new_session, new_assigns} = split_assigns(new_merged, state.session_keys)
              new_state = bump_version(%{state | session: new_session, assigns: new_assigns})
              {:noreply, update_page(new_state)}

            {:patch, target, rendered, new_merged} ->
              {new_session, new_assigns} = split_assigns(new_merged, state.session_keys)
              new_state = bump_version(%{state | session: new_session, assigns: new_assigns})
              html = to_html(rendered)
              payload = Jason.encode!(%{target: target, html: html, agent: agent_info(new_state)})
              if state.socket_pid, do: send(state.socket_pid, {:send_html, payload})
              {:noreply, notify_state_changed(new_state)}

            {:redirect, path, new_merged} ->
              {new_session, new_assigns} = split_assigns(new_merged, state.session_keys)
              new_state = bump_version(%{state | session: new_session, assigns: new_assigns})
              {:noreply, do_navigate(path, new_state)}

            {:push_event, event_name, event_payload, new_merged} ->
              {new_session, new_assigns} = split_assigns(new_merged, state.session_keys)
              new_state = bump_version(%{state | session: new_session, assigns: new_assigns})
              send_push_event(new_state, event_name, event_payload)
              {:noreply, notify_state_changed(new_state)}
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
    |> Map.put(:dialup_agent, %{
      version: state.version,
      handoff_required: true
    })
  end

  # handle_event/handle_info の返り値を session と assigns に分割する
  defp split_assigns(merged, session_keys) do
    new_session = Map.take(merged, MapSet.to_list(session_keys))

    new_assigns =
      Map.drop(merged, MapSet.to_list(session_keys) ++ [:params, :current_path, :dialup_agent])

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
    if state.socket_pid do
      html = render(state)
      payload = %{html: html, path: state.path, agent: agent_info(state)}
      payload = put_title(payload, state)
      send(state.socket_pid, {:send_html, Jason.encode!(payload)})
    end

    notify_state_changed(state)
  end

  defp apply_event(page_module, event, value, state) do
    merged = merge_for_render(state)

    try do
      case page_module.handle_event(event, value, merged) do
        {:noreply, new_merged} ->
          {new_session, new_assigns} = split_assigns(new_merged, state.session_keys)
          new_state = bump_version(%{state | session: new_session, assigns: new_assigns})
          {:ok, notify_state_changed(new_state)}

        {:update, new_merged} ->
          {new_session, new_assigns} = split_assigns(new_merged, state.session_keys)
          new_state = bump_version(%{state | session: new_session, assigns: new_assigns})
          {:ok, update_page(new_state)}

        {:patch, target, rendered, new_merged} ->
          {new_session, new_assigns} = split_assigns(new_merged, state.session_keys)
          new_state = bump_version(%{state | session: new_session, assigns: new_assigns})
          html = to_html(rendered)
          payload = Jason.encode!(%{target: target, html: html, agent: agent_info(new_state)})
          if state.socket_pid, do: send(state.socket_pid, {:send_html, payload})
          {:ok, notify_state_changed(new_state)}

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
    rescue
      exception -> {:error, {exception, __STACKTRACE__}}
    end
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
        "websocket" => Dialup.Agent.websocket_endpoint(token),
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
            grant
          )
      end

    Map.put(scene, "humanFocus", state.human_focus)
  end

  defp normalize_human_focus(target, state) when is_binary(target) do
    %{
      "mode" => "semantic",
      "target" => target,
      "targets" => [%{"id" => target}],
      "path" => state.path,
      "selectedAt" => System.system_time(:millisecond)
    }
  end

  defp normalize_human_focus(selection, state) when is_map(selection) do
    targets =
      selection
      |> Map.get("targets", [])
      |> Enum.take(50)
      |> Enum.map(fn target ->
        %{
          "id" => target |> Map.get("id", "") |> to_string() |> String.slice(0, 200),
          "kind" => target |> Map.get("kind", "unknown") |> to_string() |> String.slice(0, 40),
          "description" =>
            target |> Map.get("description", "") |> to_string() |> String.slice(0, 500),
          "text" => target |> Map.get("text", "") |> to_string() |> String.slice(0, 500),
          "selector" => target |> Map.get("selector", "") |> to_string() |> String.slice(0, 500),
          "tag" => target |> Map.get("tag", "") |> to_string() |> String.slice(0, 40),
          "role" => target |> Map.get("role", "") |> to_string() |> String.slice(0, 80),
          "rect" => normalize_rect(Map.get(target, "rect"))
        }
      end)
      |> Enum.reject(&(&1["id"] == ""))

    primary = List.first(targets)

    %{
      "mode" => selection |> Map.get("mode", "point") |> to_string() |> String.slice(0, 40),
      "target" => if(primary, do: primary["id"], else: nil),
      "targets" => targets,
      "rectangle" => normalize_rect(Map.get(selection, "rectangle")),
      "pointer" => normalize_point(Map.get(selection, "pointer")),
      "viewport" => normalize_viewport(Map.get(selection, "viewport")),
      "path" => state.path,
      "selectedAt" => System.system_time(:millisecond)
    }
  end

  defp normalize_human_focus(_selection, state), do: normalize_human_focus("", state)

  defp normalize_rect(rect) when is_map(rect) do
    Map.take(rect, ["x", "y", "width", "height", "documentX", "documentY"])
  end

  defp normalize_rect(_rect), do: nil

  defp normalize_point(point) when is_map(point), do: Map.take(point, ["x", "y"])
  defp normalize_point(_point), do: nil

  defp normalize_viewport(viewport) when is_map(viewport) do
    Map.take(viewport, ["width", "height", "scrollX", "scrollY"])
  end

  defp normalize_viewport(_viewport), do: nil

  defp resolve_event(page_module, event) do
    case Dialup.Agent.action(page_module, event) do
      nil -> event
      action -> action.name
    end
  end

  defp send_focus(state, target, origin \\ "agent") do
    if state.socket_pid do
      send(
        state.socket_pid,
        {:send_html,
         Jason.encode!(%{
           dialup: "focus",
           target: to_string(target),
           origin: origin,
           version: state.version
         })}
      )
    end

    notify_agents(state, "focus", %{
      "target" => to_string(target),
      "origin" => origin,
      "version" => state.version
    })
  end

  defp send_push_event(state, event_name, event_payload) do
    if state.socket_pid do
      html = render(state)

      payload = %{
        html: html,
        path: state.path,
        push_event: event_name,
        payload: event_payload,
        agent: agent_info(state)
      }

      payload = put_title(payload, state)
      send(state.socket_pid, {:send_html, Jason.encode!(payload)})
    end
  end

  defp agent_info(state) do
    grant = Map.fetch!(state.agent_grants, state.agent_token)

    %{
      status: "handoff_required",
      version: state.version,
      grant: Dialup.Agent.Grant.public(grant)
    }
  end

  defp bump_version(state), do: %{state | version: state.version + 1}

  defp invoke_agent_action(state, token, name, arguments) do
    with {:ok, grant} <- fetch_grant(state, token),
         true <- Dialup.Agent.Grant.allows?(grant, name) || {:error, :forbidden},
         page_module when not is_nil(page_module) <- current_page(state),
         action when not is_nil(action) <- Dialup.Agent.action(page_module, name),
         :ok <- check_version(grant, arguments, state.version),
         clean_arguments = Map.drop(arguments, ["_version", :_version]),
         {:ok, clean_arguments} <- validate_agent_arguments(action, clean_arguments),
         true <-
           Dialup.Agent.available?(page_module, action.name, merge_for_render(state)) ||
             {:error, :unavailable} do
      if Map.get(action, :confirm) == :human do
        request_approval(state, token, action, clean_arguments)
      else
        send_focus(state, name)

        case apply_event(page_module, action.name, clean_arguments, state) do
          {:ok, new_state} ->
            new_state = audit(new_state, token, name, :ok, clean_arguments)
            {{:ok, current_scene(new_state, grant)}, new_state}

          {:error, reason} ->
            {{:error, reason}, audit(state, token, name, :error)}
        end
      end
    else
      nil -> {{:error, :unknown_action}, state}
      false -> {{:error, :forbidden}, state}
      {:error, reason} -> {{:error, reason}, audit(state, token, name, :error)}
    end
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

  defp request_approval(state, token, action, arguments) do
    id = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)

    approval = %{
      id: id,
      token: token,
      action: action,
      arguments: arguments,
      requested_version: state.version,
      status: "pending",
      requested_at: System.system_time(:millisecond)
    }

    send_focus(state, action.name)
    send_approval_request(state, approval)

    new_state =
      state
      |> Map.update!(:pending_approvals, &Map.put(&1, id, approval))
      |> audit(token, to_string(action.name), :pending_approval, %{"approval_id" => id})

    {{:error, {:approval_required, approval_public(approval)}}, new_state}
  end

  defp resolve_approval(state, approval_id, decision) do
    case Map.pop(state.pending_approvals, approval_id) do
      {nil, _pending} ->
        state

      {approval, pending} ->
        state = %{state | pending_approvals: pending}

        if decision in ["approve", "approved", true] do
          execute_approved(state, approval)
        else
          result = %{"id" => approval_id, "status" => "rejected", "version" => state.version}

          state
          |> put_approval_result(approval_id, result)
          |> audit(:human, to_string(approval.action.name), :rejected, %{
            "approval_id" => approval_id
          })
          |> notify_agents("approval_resolved", result)
        end
    end
  end

  defp execute_approved(state, approval) do
    page_module = current_page(state)
    merged = merge_for_render(state)

    cond do
      approval.requested_version != state.version ->
        finish_failed_approval(state, approval, "stale")

      is_nil(page_module) ->
        finish_failed_approval(state, approval, "page_not_found")

      not Dialup.Agent.available?(page_module, approval.action.name, merged) ->
        finish_failed_approval(state, approval, "unavailable")

      true ->
        case apply_event(page_module, approval.action.name, approval.arguments, state) do
          {:ok, new_state} ->
            result = %{
              "id" => approval.id,
              "status" => "completed",
              "version" => new_state.version,
              "scene" => current_scene(new_state, Map.get(new_state.agent_grants, approval.token))
            }

            new_state
            |> put_approval_result(approval.id, result)
            |> audit(:human, to_string(approval.action.name), :approved, %{
              "approval_id" => approval.id
            })
            |> notify_agents("approval_resolved", result)

          {:error, reason} ->
            finish_failed_approval(state, approval, inspect(reason))
        end
    end
  end

  defp finish_failed_approval(state, approval, reason) do
    result = %{
      "id" => approval.id,
      "status" => "failed",
      "reason" => reason,
      "version" => state.version
    }

    state
    |> put_approval_result(approval.id, result)
    |> audit(:human, to_string(approval.action.name), :approval_failed, %{
      "approval_id" => approval.id,
      "reason" => reason
    })
    |> notify_agents("approval_resolved", result)
  end

  defp send_approval_request(state, approval) do
    if state.socket_pid do
      send(
        state.socket_pid,
        {:send_html,
         Jason.encode!(%{
           dialup: "approval_requested",
           approval: approval_public(approval),
           version: state.version
         })}
      )
    end
  end

  defp approval_public(approval) do
    %{
      "id" => approval.id,
      "status" => approval.status,
      "action" => to_string(approval.action.name),
      "description" => Map.get(approval.action, :desc, to_string(approval.action.name)),
      "arguments" => approval.arguments,
      "version" => approval.requested_version
    }
  end

  defp json_safe_audit(entry) do
    Map.new(entry, fn {key, value} -> {to_string(key), json_safe_value(value)} end)
  end

  defp json_safe_value(value) when is_atom(value), do: to_string(value)

  defp json_safe_value(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), json_safe_value(v)} end)

  defp json_safe_value(value) when is_list(value), do: Enum.map(value, &json_safe_value/1)
  defp json_safe_value(value), do: value

  defp notify_agents(state, method, params) do
    Enum.each(state.agent_subscribers, fn {pid, _subscriber} ->
      send(pid, {:agent_notification, method, params})
    end)

    state
  end

  defp put_approval_result(state, id, result) do
    results =
      state.approval_results
      |> Map.put(id, result)
      |> Enum.sort_by(fn {_id, value} -> Map.get(value, "version", 0) end, :desc)
      |> Enum.take(100)
      |> Map.new()

    %{state | approval_results: results}
  end

  defp notify_state_changed(state) do
    Enum.each(state.agent_subscribers, fn {pid, %{token: token}} ->
      case fetch_grant(state, token) do
        {:ok, grant} ->
          send(pid, {:agent_notification, "state_changed", current_scene(state, grant)})

        _ ->
          :ok
      end
    end)

    state
  end

  defp drop_agent_subscriber(state, socket_pid) do
    case Map.pop(state.agent_subscribers, socket_pid) do
      {nil, _subscribers} ->
        state

      {%{ref: ref}, subscribers} ->
        Process.demonitor(ref, [:flush])
        %{state | agent_subscribers: subscribers}
    end
  end

  defp disconnect_grant_subscribers(state, token) do
    state.agent_subscribers
    |> Enum.filter(fn {_pid, subscriber} -> subscriber.token == token end)
    |> Enum.reduce(state, fn {pid, _subscriber}, acc ->
      send(pid, {:agent_notification, "grant_revoked", %{"token" => String.slice(token, 0, 8)}})
      drop_agent_subscriber(acc, pid)
    end)
  end
end
