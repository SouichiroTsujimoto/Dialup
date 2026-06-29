defmodule Dialup.UserSessionProcess do
  @moduledoc false
  use GenServer

  @session_timeout :timer.minutes(5)
  @headless_timeout :timer.minutes(15)
  @browser_token_ttl :timer.minutes(5)
  @browser_join_reservation_ttl :timer.seconds(30)
  @pending_finalize_ttl :timer.seconds(30)

  # Browser join state machine (single completion point):
  #   attach  -> WS join reserves token, sets pending_finalize, starts TTL timer
  #   complete -> POST finalize-join consumes token, clears pending_finalize, sets cookie
  #   rollback -> WS close or TTL before complete restores headless session
  # After complete, __reconnect only refreshes the live socket; authorization is already done.

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
  def take_over(pid, new_socket_pid, tab_id \\ nil),
    do: GenServer.call(pid, {:take_over, new_socket_pid, tab_id})
  def reconnect(pid, path), do: GenServer.cast(pid, {:reconnect, path})
  def agent_describe(pid, token), do: GenServer.call(pid, {:agent_describe, token})
  def agent_tools(pid, token), do: GenServer.call(pid, {:agent_tools, token})

  def agent_call(pid, token, name, arguments),
    do: GenServer.call(pid, {:agent_call, token, name, arguments})

  def revoke_agent(pid, token), do: GenServer.call(pid, {:agent_revoke, token})
  def issue_agent_grant(pid, opts), do: GenServer.call(pid, {:agent_grant, opts})
  def issue_browser_handoff(pid), do: GenServer.call(pid, :issue_browser_handoff)
  def browser_join(pid, new_socket_pid, tab_id \\ nil),
    do: GenServer.call(pid, {:browser_join, new_socket_pid, tab_id})

  def browser_join_with_token(pid, new_socket_pid, tab_id, token),
    do: GenServer.call(pid, {:browser_join_with_token, new_socket_pid, tab_id, token})

  def reserve_browser_join_token(pid, token, tab_id),
    do: GenServer.call(pid, {:reserve_browser_join_token, token, tab_id})

  def release_browser_join_reservation(pid, token),
    do: GenServer.call(pid, {:release_browser_join_reservation, token})

  def finalize_browser_join(pid, tab_id, nonce),
    do: GenServer.call(pid, {:finalize_browser_join, tab_id, nonce})

  def rollback_browser_join(pid),
    do: GenServer.call(pid, :rollback_browser_join)

  def issue_browser_token(pid), do: GenServer.call(pid, :issue_browser_token)

  def consume_browser_token(pid, token),
    do: GenServer.call(pid, {:consume_browser_token, token})

  def browser_token_active?(pid, token),
    do: GenServer.call(pid, {:browser_token_active?, token})

  def awaiting_browser_join?(pid), do: GenServer.call(pid, :awaiting_browser_join?)

  def start_headless(app_module, path, _opts \\ %{}) do
    session_id = random_id()
    registry_key = "headless-" <> random_id()

    {:ok, pid} =
      DynamicSupervisor.start_child(
        Dialup.SessionSupervisor,
        {__MODULE__, {nil, app_module, session_id, registry_key}}
      )

    case GenServer.call(pid, {:init_sync, path}) do
      {:ok, descriptor} ->
        {:ok, Map.put(descriptor, "sessionId", session_id)}

      error ->
        _ = DynamicSupervisor.terminate_child(Dialup.SessionSupervisor, pid)
        error
    end
  end

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

    {ref, timeout_ref} =
      if socket_pid do
        {Process.monitor(socket_pid), nil}
      else
        {nil, Process.send_after(self(), :session_timeout, @headless_timeout)}
      end

    base_state = %{
      path: nil,
      socket_pid: socket_pid,
      app_module: app_module,
      session_id: session_id,
      session: %{},
      session_keys: MapSet.new(),
      mounted_layouts: MapSet.new(),
      assigns: %{},
      params: %{},
      subscriptions: [],
      monitor_ref: ref,
      timeout_ref: timeout_ref,
      agent_token: agent_token,
      agent_grants: %{
        agent_token => Dialup.Agent.Grant.new(agent_token, %{expires_in: :infinity})
      },
      agent_proxies: %{agent_token => agent_proxy},
      browser_tokens: %{},
      headless: is_nil(socket_pid),
      pending_finalize: nil,
      pending_finalize_timeout_ref: nil,
      version: 0,
      audit_log: [],
      ui_locked: false,
      lock_reason: nil
    }

    state =
      if uses_ets_store?(app_module) do
        case Dialup.SessionStore.restore(session_id) do
          {:ok, %{session: session, assigns: assigns, path: path}} ->
            session_keys = MapSet.new(Map.keys(session))
            mounted_layouts = app_module.layouts_for(path) |> MapSet.new()

            %{
              base_state
              | session: session,
                session_keys: session_keys,
                mounted_layouts: mounted_layouts,
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

  @impl GenServer
  def handle_call({:take_over, new_socket_pid, tab_id}, _from, state) do
    if state.monitor_ref, do: Process.demonitor(state.monitor_ref, [:flush])
    if state.timeout_ref, do: Process.cancel_timer(state.timeout_ref)
    ref = Process.monitor(new_socket_pid)

    case register_tab_registry(tab_id) do
      :ok ->
        {:reply, :ok, %{state | socket_pid: new_socket_pid, monitor_ref: ref, timeout_ref: nil}}

      {:error, :tab_id_in_use} ->
        {:reply, {:error, :tab_id_in_use}, state}
    end
  end

  def handle_call({:browser_join, new_socket_pid, tab_id}, _from, state) do
    case do_browser_join(state, new_socket_pid, tab_id) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, _} -> {:reply, {:error, :invalid_token}, state}
    end
  end

  def handle_call({:browser_join_with_token, new_socket_pid, tab_id, token}, _from, state) do
    cond do
      not is_binary(tab_id) or tab_id == "" ->
        {:reply, {:error, :invalid_token}, state}

      join_blocks_token?(state, token) ->
        {:reply, {:error, :already_joined}, state}

      true ->
        with :ok <- verify_reserved_tab_id(state, token, tab_id),
             {:ok, joined_state} <- do_browser_join(state, new_socket_pid, tab_id, token) do
          {:reply, :ok, joined_state}
        else
          _ -> {:reply, {:error, :invalid_token}, state}
        end
    end
  end

  def handle_call({:finalize_browser_join, tab_id, nonce}, _from, state) do
    case state.pending_finalize do
      %{tab_id: ^tab_id, nonce: ^nonce, token: token} ->
        with {:ok, new_state} <- consume_browser_token_entry(state, token) do
          {:reply, :ok,
           new_state
           |> cancel_pending_finalize_timeout()
           |> Map.put(:pending_finalize, nil)}
        else
          _ -> {:reply, {:error, :invalid_finalize}, state}
        end

      _ ->
        {:reply, {:error, :invalid_finalize}, state}
    end
  end

  def handle_call(:rollback_browser_join, _from, %{pending_finalize: nil} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:rollback_browser_join, _from, state) do
    {:reply, :ok, rollback_pending_browser_join(state)}
  end

  def handle_call({:release_browser_join_reservation, token}, _from, state) do
    case Map.fetch(state.browser_tokens, token) do
      {:ok, %{reserved_at: _} = entry} ->
        released = entry |> Map.delete(:reserved_at) |> Map.delete(:reserved_tab_id)

        {:reply, :ok,
         %{state | browser_tokens: Map.put(state.browser_tokens, token, released)}}

      _ ->
        {:reply, {:error, :not_reserved}, state}
    end
  end

  def handle_call({:reserve_browser_join_token, token, tab_id}, _from, state) do
    if not is_binary(tab_id) or tab_id == "" do
      {:reply, {:error, :invalid_token}, state}
    else
      case Map.fetch(state.browser_tokens, token) do
      {:ok, entry} ->
        entry = clear_expired_reservation(entry)
        state = put_browser_token(state, token, entry)

        cond do
          not browser_token_active?(entry) ->
            {:reply, {:error, :invalid_token}, state}

          join_blocks_token?(state, token) ->
            {:reply, {:error, :already_joined}, state}

          reserved?(entry) ->
            {:reply, {:error, :already_reserved}, state}

          true ->
            reserved =
              entry
              |> Map.put(:reserved_at, System.monotonic_time(:millisecond))
              |> Map.put(:reserved_tab_id, tab_id)

            {:reply, {:ok, state.session_id}, put_browser_token(state, token, reserved)}
        end

      :error ->
        {:reply, {:error, :invalid_token}, state}
    end
    end
  end

  def handle_call({:agent_describe, token}, _from, state) do
    state = touch_headless_timeout(state)

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
    state = touch_headless_timeout(state)

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
    state = touch_headless_timeout(state)

    case fetch_grant(state, token) do
      {:ok, grant} ->
        {:reply, {:ok, current_scene(state, grant)}, audit(state, token, "read_scene", :ok)}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:agent_call, token, "read_audit_log", _arguments}, _from, state) do
    state = touch_headless_timeout(state)

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
    state = touch_headless_timeout(state)

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
    state = touch_headless_timeout(state)

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

  def handle_call({:agent_call, token, "issue_browser_url", _arguments}, _from, state) do
    state = touch_headless_timeout(state)

    case fetch_grant(state, token) do
      {:ok, grant} ->
        if Dialup.Agent.Grant.allows?(grant, "issue_browser_url") do
          case create_browser_token(state) do
            {:ok, result, new_state} ->
              new_state = audit(new_state, token, "issue_browser_url", :ok)
              {:reply, {:ok, result}, new_state}

            error ->
              {:reply, error, state}
          end
        else
          {:reply, {:error, :forbidden}, state}
        end

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:agent_call, token, name, arguments}, _from, state) do
    state = touch_headless_timeout(state)
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
    state = touch_headless_timeout(state)
    {reply, state} = create_agent_grant(state, opts)
    {:reply, reply, state}
  end

  def handle_call(:issue_browser_handoff, _from, state) do
    state = touch_headless_timeout(state)

    case current_page(state) do
      nil ->
        {:reply, {:error, :not_ready}, state}

      page_module ->
        opts = page_module.agent_grant(merge_for_render(state))
        {reply, state} = create_agent_grant(state, opts)
        {:reply, reply, audit(state, :human, "issue_agent_handoff", :ok)}
    end
  end

  def handle_call(:issue_browser_token, _from, state) do
    case create_browser_token(state) do
      {:ok, result, new_state} -> {:reply, {:ok, result}, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:consume_browser_token, token}, _from, state) do
    case consume_browser_token_entry(state, token) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      :error -> {:reply, {:error, :expired}, state}
    end
  end

  def handle_call(:awaiting_browser_join?, _from, state) do
    {:reply, awaiting_browser_join_state?(state), state}
  end

  def handle_call({:browser_token_active?, token}, _from, state) do
    active? =
      case Map.fetch(state.browser_tokens, token) do
        {:ok, entry} ->
          entry = clear_expired_reservation(entry)
          browser_token_active?(entry) and not reserved?(entry)

        :error ->
          false
      end

    {:reply, active?, state}
  end

  def handle_call({:init_sync, path}, _from, state) do
    case do_init(path, state) do
      {:ok, new_state} ->
        grant = Map.fetch!(new_state.agent_grants, new_state.agent_token)

        {:reply,
         {:ok,
          %{
            "token" => new_state.agent_token,
            "endpoint" => Dialup.Agent.endpoint(new_state.agent_token),
            "grant" => Dialup.Agent.Grant.public(grant),
            "path" => new_state.path
          }}, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  # 初回接続：layout.mount → session、page.mount → assigns
  @impl GenServer
  def handle_cast({:init, path}, state) do
    case do_init(path, state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, _reason, new_state} -> {:noreply, new_state}
    end
  end

  # 再接続：プロセスが生存していれば現在のstateで再描画、タイムアウト済みならフルmount
  @impl GenServer
  def handle_cast({:reconnect, path}, state) do
    if state.path == nil do
      try do
        Process.put(:dialup_subscriptions, [])
        params = state.app_module.path_params(path)
        {session, session_keys, mounted_layouts} = mount_session(path, state.app_module)
        assigns = mount_page(path, params, session, session_keys, state.app_module)
        subs = Process.get(:dialup_subscriptions, [])

        new_state =
          %{
            state
            | path: path,
              params: params,
              session: session,
              session_keys: session_keys,
              mounted_layouts: mounted_layouts,
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

  def handle_info({:pending_finalize_timeout, nonce}, state) do
    case state.pending_finalize do
      %{nonce: ^nonce} ->
        if state.socket_pid, do: send(state.socket_pid, :dialup_close_pending_join)

        {:noreply, state |> cancel_pending_finalize_timeout() |> rollback_pending_browser_join()}

      _ ->
        {:noreply, state}
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
      {session, session_keys, mounted_layouts} = merge_session_for(path, state)
      assigns = mount_page(path, params, session, session_keys, state.app_module)
      subs = Process.get(:dialup_subscriptions, [])

      result =
        %{
          state
          | path: path,
            params: params,
            session: session,
            session_keys: session_keys,
            mounted_layouts: mounted_layouts,
            assigns: assigns,
            subscriptions: subs
        }
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
    {session, session_keys} = Dialup.Router.mount_session(app_module, path)
    mounted_layouts = app_module.layouts_for(path) |> MapSet.new()
    {session, session_keys, mounted_layouts}
  end

  # 遷移先レイアウトが導入する session キーを差分マウントする。既存キーの値は上書きしない。
  defp merge_session_for(path, state) do
    layouts = state.app_module.layouts_for(path)

    Enum.reduce(layouts, {state.session, state.session_keys, state.mounted_layouts}, fn layout_mod,
                                                                                        {session,
                                                                                         keys,
                                                                                         mounted} ->
      if MapSet.member?(mounted, layout_mod) do
        {session, keys, mounted}
      else
        {:ok, fresh_session} = layout_mod.mount(session)
        new_keys = MapSet.new(Map.keys(fresh_session))
        added_keys = MapSet.difference(new_keys, keys)

        merged =
          added_keys
          |> MapSet.to_list()
          |> Enum.reduce(session, fn k, acc ->
            Map.put_new(acc, k, Map.get(fresh_session, k))
          end)

        {merged, MapSet.union(keys, new_keys), MapSet.put(mounted, layout_mod)}
      end
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

  defp verify_reserved_tab_id(state, token, tab_id) do
    case Map.fetch(state.browser_tokens, token) do
      {:ok, entry} ->
        entry = clear_expired_reservation(entry)

        case entry do
          %{reserved_tab_id: reserved_tab_id} when is_binary(reserved_tab_id) ->
            if reserved?(entry) and reserved_tab_id == tab_id, do: :ok, else: {:error, :invalid_token}

          _ ->
            :ok
        end

      :error ->
        {:error, :invalid_token}
    end
  end

  defp update_page(state) do
    if state.socket_pid do
      html = render(state)
      payload = %{html: html, path: state.path}
      payload = put_title(payload, state)
      payload = put_ui_lock(payload, state)
      payload = put_finalize_nonce(payload, state)
      send(state.socket_pid, {:send_html, Jason.encode!(payload)})
    end

    state
  end

  defp put_finalize_nonce(payload, %{pending_finalize: %{nonce: nonce}}) do
    Map.put(payload, :join_finalize_nonce, nonce)
  end

  defp put_finalize_nonce(payload, _state), do: payload

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

    try do
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

        case apply_event(page_module, action.name, clean_arguments, state) do
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

  defp do_init(path, state) do
    try do
      params = state.app_module.path_params(path)
      Process.put(:dialup_subscriptions, [])
      {session, session_keys, mounted_layouts} = mount_session(path, state.app_module)
      assigns = mount_page(path, params, session, session_keys, state.app_module)
      subs = Process.get(:dialup_subscriptions, [])

      new_state =
        %{
          state
          | path: path,
            params: params,
            session: session,
            session_keys: session_keys,
            mounted_layouts: mounted_layouts,
            assigns: assigns,
            subscriptions: subs
        }
        |> configure_primary_grant()
        |> update_page()

      {:ok, new_state}
    rescue
      e ->
        new_state = %{state | path: path}
        send_error(new_state, e, __STACKTRACE__)
        {:error, :init_failed, new_state}
    end
  end

  defp touch_headless_timeout(%{headless: true, socket_pid: nil} = state) do
    if state.timeout_ref, do: Process.cancel_timer(state.timeout_ref)
    timeout_ref = Process.send_after(self(), :session_timeout, @headless_timeout)
    %{state | timeout_ref: timeout_ref}
  end

  defp touch_headless_timeout(state), do: state

  defp create_browser_token(%{path: nil}), do: {:error, :not_ready}

  defp create_browser_token(state) do
    token = random_id()
    {:ok, _} = Registry.register(Dialup.SessionRegistry, {:browser_token, token}, nil)
    entry = browser_token_entry(token)
    browser_url = browser_join_url(state.path, token)

    {:ok,
     %{
       "browserToken" => token,
       "browserUrl" => browser_url,
       "expiresInMs" => @browser_token_ttl
     }, %{state | browser_tokens: Map.put(state.browser_tokens, token, entry)}}
  end

  defp browser_join_url(path, token) do
    separator = if String.contains?(path, "?"), do: "&", else: "?"
    path <> separator <> "_join=" <> URI.encode_www_form(token)
  end

  defp do_browser_join(state, new_socket_pid, tab_id, join_token \\ nil) do
    if is_binary(join_token) and (not is_binary(tab_id) or tab_id == "") do
      {:error, :invalid_token}
    else
      do_browser_join!(state, new_socket_pid, tab_id, join_token)
    end
  end

  defp do_browser_join!(state, new_socket_pid, tab_id, join_token) do
    with :ok <- register_tab_registry(tab_id),
         :ok <- register_registry_key(state.session_id) do
      do_browser_join_attached!(state, new_socket_pid, tab_id, join_token)
    else
      {:error, :tab_id_in_use} -> {:error, :invalid_token}
    end
  end

  defp do_browser_join_attached!(state, new_socket_pid, tab_id, join_token) do
    if state.monitor_ref, do: Process.demonitor(state.monitor_ref, [:flush])
    if state.timeout_ref, do: Process.cancel_timer(state.timeout_ref)
    ref = Process.monitor(new_socket_pid)

    pending_finalize =
      if is_binary(tab_id) and tab_id != "" and is_binary(join_token) do
        %{tab_id: tab_id, nonce: random_id(), token: join_token}
      end

    new_state =
      state
      |> Map.put(:socket_pid, new_socket_pid)
      |> Map.put(:monitor_ref, ref)
      |> Map.put(:timeout_ref, nil)
      |> Map.put(:headless, false)
      |> Map.put(:pending_finalize, pending_finalize)
      |> schedule_pending_finalize_timeout()
      |> update_page()
      |> audit(:human, "browser_join", :ok)

    {:ok, new_state}
  end

  defp register_tab_registry(tab_id) when is_binary(tab_id) and tab_id != "" do
    register_registry_key(tab_id)
  end

  defp register_tab_registry(_tab_id), do: :ok

  defp schedule_pending_finalize_timeout(%{pending_finalize: %{nonce: nonce}} = state) do
    ref = Process.send_after(self(), {:pending_finalize_timeout, nonce}, @pending_finalize_ttl)
    %{state | pending_finalize_timeout_ref: ref}
  end

  defp schedule_pending_finalize_timeout(state), do: state

  defp cancel_pending_finalize_timeout(%{pending_finalize_timeout_ref: ref} = state)
       when not is_nil(ref) do
    Process.cancel_timer(ref)
    %{state | pending_finalize_timeout_ref: nil}
  end

  defp cancel_pending_finalize_timeout(state), do: state

  defp rollback_pending_browser_join(%{pending_finalize: nil} = state), do: state

  defp rollback_pending_browser_join(%{pending_finalize: %{tab_id: tab_id, token: token}} = state) do
    state = cancel_pending_finalize_timeout(state)

    if state.monitor_ref, do: Process.demonitor(state.monitor_ref, [:flush])

    if is_binary(tab_id) and tab_id != "" do
      Registry.unregister(Dialup.SessionRegistry, tab_id)
    end

    Registry.unregister(Dialup.SessionRegistry, state.session_id)

    released =
      case Map.fetch(state.browser_tokens, token) do
        {:ok, %{reserved_at: _} = entry} ->
          entry |> Map.delete(:reserved_at) |> Map.delete(:reserved_tab_id)

        _ ->
          nil
      end

    browser_tokens =
      if released, do: Map.put(state.browser_tokens, token, released), else: state.browser_tokens

    if state.timeout_ref, do: Process.cancel_timer(state.timeout_ref)
    timeout_ref = Process.send_after(self(), :session_timeout, @headless_timeout)

    %{
      state
      | socket_pid: nil,
        monitor_ref: nil,
        timeout_ref: timeout_ref,
        headless: true,
        pending_finalize: nil,
        pending_finalize_timeout_ref: nil,
        browser_tokens: browser_tokens
    }
  end

  defp consume_browser_token_entry(state, token) do
    case Map.fetch(state.browser_tokens, token) do
      {:ok, entry} ->
        if browser_token_active?(entry) do
          Registry.unregister(Dialup.SessionRegistry, {:browser_token, token})

          consumed =
            Map.put(entry, :consumed_at, System.monotonic_time(:millisecond))

          {:ok, %{state | browser_tokens: Map.put(state.browser_tokens, token, consumed)}}
        else
          :error
        end

      :error ->
        :error
    end
  end

  defp awaiting_browser_join_state?(state) do
    state.headless and is_nil(state.socket_pid)
  end

  defp put_browser_token(state, token, entry) do
    %{state | browser_tokens: Map.put(state.browser_tokens, token, entry)}
  end

  defp clear_expired_reservation(%{reserved_at: reserved_at} = entry)
       when is_integer(reserved_at) do
    if System.monotonic_time(:millisecond) - reserved_at >= @browser_join_reservation_ttl do
      entry
      |> Map.delete(:reserved_at)
      |> Map.delete(:reserved_tab_id)
    else
      entry
    end
  end

  defp clear_expired_reservation(entry), do: entry

  defp reserved?(%{reserved_at: reserved_at}) when is_integer(reserved_at) do
    System.monotonic_time(:millisecond) - reserved_at < @browser_join_reservation_ttl
  end

  defp reserved?(_entry), do: false

  defp browser_token_entry(token) do
    now = System.monotonic_time(:millisecond)
    %{token: token, expires_at: now + @browser_token_ttl, consumed_at: nil}
  end

  defp browser_token_active?(%{consumed_at: consumed_at}) when not is_nil(consumed_at), do: false

  defp browser_token_active?(%{expires_at: expires_at}) do
    System.monotonic_time(:millisecond) < expires_at
  end

  defp join_blocks_token?(state, token) do
    not is_nil(state.socket_pid) or
      case state.pending_finalize do
        %{token: ^token} -> true
        _ -> false
      end
  end

  defp register_registry_key(key) do
    case Registry.register(Dialup.SessionRegistry, key, nil) do
      {:ok, _} ->
        :ok

      {:error, {:already_registered, pid}} when pid == self() ->
        :ok

      {:error, {:already_registered, _pid}} ->
        {:error, :tab_id_in_use}
    end
  end

  defp random_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
end
