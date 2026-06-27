defmodule Dialup.App.Demo.Page do
  use Dialup.Page

  declare_action name: :inc, desc: "Increment the counter", params: %{}
  declare_action name: :dec, desc: "Decrement the counter", params: %{}
  declare_action name: :reset_counter, desc: "Reset the counter to zero", params: %{}

  declare_action name: :submit_name,
                 desc: "Submit a name from the form",
                 params: %{name: :string},
                 agent_only: true

  declare_action name: :draft_change,
                 desc: "Sync draft text while typing",
                 params: %{value: :string},
                 agent_only: true

  declare_action name: :confirm_draft, desc: "Confirm the current draft", params: %{}

  declare_action name: :send_message,
                 desc: "Append a message to the log",
                 params: %{message: :string},
                 agent_only: true

  declare_action name: :clear_log, desc: "Clear the message log", params: %{}

  def page_title(_assigns), do: "Live Demo — Dialup"

  def mount(_params, assigns) do
    {:ok,
     assigns
     |> Map.merge(%{
       count: 0,
       name_input: "",
       submitted_name: nil,
       draft: "",
       draft_confirmed: nil,
       message_log: []
     })}
  end

  def agent_state(assigns) do
    %{
      count: assigns.count,
      submitted_name: assigns.submitted_name,
      draft: assigns.draft,
      draft_confirmed: assigns.draft_confirmed,
      message_log: assigns.message_log
    }
  end

  def agent_message(_assigns) do
    %{
      concept:
        "A showcase of Dialup's interactive UI primitives: counter with partial patch, " <>
          "form submission, real-time input sync, and a message log.",
      goal:
        "Explore each widget to verify that agent-driven mutations produce the same " <>
          "real-time results as human interaction.",
      flow: [
        "Call read_scene to see current widget states.",
        "Use inc/dec/reset_counter to test the counter.",
        "Use submit_name to test form submission.",
        "Use send_message/clear_log for the message log."
      ],
      safety: ["clear_log deletes all messages; confirm with the user first."]
    }
  end

  def agent_grant(_assigns) do
    %{
      capabilities: :all,
      projections: [:state, :regions, :actions],
      expires_in: :timer.minutes(15),
      require_version: true
    }
  end

  def handle_event(:inc, _, assigns) do
    new_assigns = Map.update!(assigns, :count, &(&1 + 1))
    {:patch, "demo-counter-value", render_counter(new_assigns), new_assigns}
  end

  def handle_event(:dec, _, assigns) do
    new_assigns = Map.update!(assigns, :count, &(&1 - 1))
    {:patch, "demo-counter-value", render_counter(new_assigns), new_assigns}
  end

  def handle_event(:reset_counter, _, assigns) do
    new_assigns = Map.put(assigns, :count, 0)
    {:patch, "demo-counter-value", render_counter(new_assigns), new_assigns}
  end

  def handle_event(:submit_name, %{"name" => name}, assigns) do
    new_assigns = assigns |> Map.merge(%{submitted_name: name, name_input: name})
    {:update, new_assigns}
  end

  def handle_event(:draft_change, value, assigns) when is_binary(value) do
    new_assigns = Map.put(assigns, :draft, value)
    {:patch, "demo-draft-preview", render_draft_preview(new_assigns), new_assigns}
  end

  def handle_event(:draft_change, params, assigns) when is_map(params) do
    value = params["value"] || params[:value] || ""
    handle_event(:draft_change, to_string(value), assigns)
  end

  def handle_event(:confirm_draft, _, assigns) do
    new_assigns = assigns |> Map.merge(%{draft_confirmed: assigns.draft, draft: ""})
    {:update, new_assigns}
  end

  def handle_event(:send_message, %{"message" => msg}, assigns) when msg != "" do
    entry = "[#{time_now()}] #{msg}"
    new_assigns = Map.update!(assigns, :message_log, &[entry | &1])
    {:update, Map.merge(new_assigns, %{message_log: Enum.take(new_assigns.message_log, 5)})}
  end

  def handle_event(:send_message, _, assigns), do: {:noreply, assigns}

  def handle_event(:clear_log, _, assigns) do
    {:update, Map.put(assigns, :message_log, [])}
  end

  defp render_counter(assigns) do
    ~H"""
    <div id="demo-counter-value" class="demo-value">{@count}</div>
    """
  end

  defp render_draft_preview(assigns) do
    ~H"""
    <p id="demo-draft-preview" class="result-line">
      <%= if @draft == "" do %>
        <span style="color: var(--muted);">入力内容がここにリアルタイム表示されます</span>
      <% else %>
        サーバーの draft: <strong>{@draft}</strong>
      <% end %>
    </p>
    """
  end

  defp time_now do
    {h, m, s} = :erlang.time()
    :io_lib.format("~2..0B:~2..0B:~2..0B", [h, m, s]) |> IO.iodata_to_binary()
  end

  def render(assigns) do
    ~H"""
    <div class="demo-container">
      <div class="demo-header">
        <h1>Live Demo</h1>
        <p>すべてのインタラクションは WebSocket 経由でサーバーの GenServer に届きます。</p>
      </div>

      <div class="demo-card">
        <div class="demo-card-header">
          <span class="demo-tag">:patch</span>
          <h3>カウンター — 部分更新</h3>
        </div>
        <p>
          <code>&#123;:patch, "demo-counter-value", rendered, assigns&#125;</code> を使用。
          カウンター部分の要素だけが更新され、ページ全体は再描画されません。
        </p>
        {render_counter(assigns)}
        <div>
          <.dialup_action name={:dec} class="btn btn-primary">ー</.dialup_action>
          <.dialup_action name={:inc} class="btn btn-primary">＋</.dialup_action>
          <.dialup_action name={:reset_counter} class="btn btn-ghost">リセット</.dialup_action>
        </div>
      </div>

      <div class="demo-card">
        <div class="demo-card-header">
          <span class="demo-tag">ws-submit</span>
          <h3>form submit</h3>
        </div>
        <p>
          自由入力フォームは <code>ws-submit</code> で送信します（入力値は動的なため
          <code>&lt;.dialup_action&gt;</code> の静的パラメータでは表現できません）。
          同じ操作は <code>declare_action</code> で AI にも公開されます。
        </p>
        <form ws-submit="submit_name">
          <div class="form-row">
            <input type="text" name="name" value={@name_input} placeholder="名前を入力..." />
            <button type="submit" class="btn btn-ghost">送信</button>
          </div>
        </form>
        <%= if @submitted_name do %>
          <p class="result-line">サーバーが受け取った名前: <strong>{@submitted_name}</strong></p>
        <% end %>
      </div>

      <div class="demo-card">
        <div class="demo-card-header">
          <span class="demo-tag">ws-change</span>
          <h3>リアルタイム入力同期</h3>
        </div>
        <p style="color: var(--muted); font-size: 0.875rem; margin: 0 0 1rem;">
          テキスト入力は <code>ws-change</code> + <code>ws-debounce</code> でサーバーへ同期します。
          確定ボタンは <code>&lt;.dialup_action&gt;</code> です。
        </p>
        <div class="form-row">
          <input type="text" ws-change="draft_change" ws-debounce="300" value={@draft} placeholder="入力中にサーバーへ同期..." />
          <.dialup_action name={:confirm_draft} class="btn btn-ghost">確定</.dialup_action>
        </div>
        {render_draft_preview(assigns)}
        <%= if @draft_confirmed do %>
          <p class="result-line">確定済み: <strong>{@draft_confirmed}</strong></p>
        <% end %>
      </div>

      <div class="demo-card">
        <div class="demo-card-header">
          <span class="demo-tag">:update</span>
          <h3>メッセージログ — 全体更新</h3>
        </div>
        <p style="color: var(--muted); font-size: 0.875rem; margin: 0 0 1rem;">
          <code>&#123;:update, assigns&#125;</code> を使用。送信のたびに <code>#dialup-root</code> 全体を idiomorph で差し替えます。
        </p>
        <form ws-submit="send_message">
          <div class="form-row">
            <input type="text" name="message" placeholder="メッセージを入力..." />
            <button type="submit" class="btn btn-ghost">送信</button>
          </div>
        </form>
        <%= if @message_log == [] do %>
          <p class="result-line" style="color: var(--muted);">まだメッセージがありません。</p>
        <% else %>
          <ul style="margin: 1rem 0 0; padding: 0; list-style: none;">
            <%= for entry <- @message_log do %>
              <li style="font-size: 0.875rem; padding: 0.3rem 0; border-bottom: 1px solid var(--border); font-family: monospace; color: #374151;">
                {entry}
              </li>
            <% end %>
          </ul>
          <.dialup_action name={:clear_log} class="btn btn-primary">クリア</.dialup_action>
        <% end %>
      </div>

      <div class="demo-card">
        <div class="demo-card-header">
          <span class="demo-tag">navigate</span>
          <h3>SPA ナビゲーション</h3>
        </div>
        <p style="color: var(--muted); font-size: 0.875rem; margin: 0 0 1rem;">
          ページ移動は <code>&lt;.dialup_action navigate="/path"&gt;</code> で宣言します。
          人間のリンクと AI のナビゲーションツールが同時に生成されます。
        </p>
        <div style="display: flex; gap: 0.75rem; flex-wrap: wrap;">
          <.dialup_action navigate="/" class="btn btn-primary">← Home</.dialup_action>
          <.dialup_action navigate="/docs" class="btn btn-primary">Get Started</.dialup_action>
          <.dialup_action navigate="/docs/concepts" class="btn btn-primary">Concepts</.dialup_action>
          <.dialup_action navigate="/docs/api" class="btn btn-primary">API Ref</.dialup_action>
        </div>
      </div>
    </div>
    """
  end
end
