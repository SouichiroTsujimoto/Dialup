defmodule Dialup.App.AgentDemo.Page do
  use Dialup.Page

  declare_action name: :add_task,
                 desc: "Add one actionable task to the board",
                 params: %{title: :string, priority: {:string, default: "normal"}},
                 # 自由入力フォームは ws-submit で送信（動的な title は dialup_action の静的 params では表現不可）
                 agent_only: true,
                 risk: "low",
                 effects: "Appends one task to the current board.",
                 examples: [%{title: "会場を予約する", priority: "high"}],
                 success: "The task appears on the board and version increments."

  declare_action name: :complete_task,
                 desc: "Mark a task as done by its id",
                 params: %{task_id: :integer},
                 risk: "low",
                 effects: "Sets one task's done flag to true."

  declare_action name: :clear_completed,
                 desc: "Remove all completed tasks",
                 params: %{},
                 risk: "medium",
                 effects: "Deletes completed tasks from the board."

  declare_action name: :set_project,
                 desc: "Rename the project goal shown on the board",
                 params: %{value: :string},
                 agent_only: true

  def page_title(_assigns), do: "AIにバトンタッチ — Dialup MCP Demo"

  def mount(_params, assigns), do: {:ok, assigns}

  def agent_state(assigns) do
    %{
      project: assigns.project,
      tasks: Enum.map(assigns.tasks, &Map.take(&1, [:id, :title, :done, :priority, :actor]))
    }
  end

  def agent_message(assigns) do
    %{
      concept:
        "A shared task board. A human opens it in the browser and hands the live session to " <>
          "an AI agent over HTTP MCP. Both operators edit the same state.",
      project: assigns.project,
      goal: "Break the project goal into concrete, actionable tasks and add them with add_task.",
      flow: [
        "Call read_scene and note the project and version.",
        "Decide a short list of concrete tasks for the project.",
        "Call add_task once per task, always passing the latest _version.",
        "Re-read the scene to confirm the tasks were added."
      ],
      safety: ["Do not call clear_completed unless the user explicitly asked for it."]
    }
  end

  def agent_grant(_assigns) do
    # このデモは「人間にできることは AI にもできる」を体現するため全権限を渡す。
    # タスク操作・UI ロックに加え、レイアウトが宣言したサイト内ナビゲーション
    # （navigate_docs__concepts など）も自動的にツールとして利用できる。
    %{
      capabilities: :all,
      projections: [:state, :regions, :actions],
      expires_in: :timer.minutes(30),
      require_version: true
    }
  end

  def __available__(_action, _assigns), do: true

  def handle_event(:add_task, params, assigns) do
    title = (params["title"] || params[:title] || "") |> to_string() |> String.trim()
    priority = (params["priority"] || params[:priority] || "normal") |> to_string()

    if title == "" do
      {:noreply, assigns}
    else
      task = %{
        id: assigns.next_id,
        title: title,
        done: false,
        priority: priority,
        actor: actor_from(params)
      }

      {:update,
       overwrite(assigns, %{tasks: assigns.tasks ++ [task], next_id: assigns.next_id + 1})}
    end
  end

  def handle_event(:complete_task, params, assigns) do
    id = params["task_id"] || params[:task_id]
    id = if is_binary(id), do: String.to_integer(id), else: id
    tasks = Enum.map(assigns.tasks, fn t -> if t.id == id, do: %{t | done: true}, else: t end)
    {:update, overwrite(assigns, %{tasks: tasks})}
  end

  def handle_event(:clear_completed, _params, assigns) do
    {:update, overwrite(assigns, %{tasks: Enum.reject(assigns.tasks, & &1.done)})}
  end

  def handle_event(:set_project, value, assigns) when is_binary(value) do
    {:noreply, overwrite(assigns, %{project: value})}
  end

  def handle_event(:set_project, params, assigns) when is_map(params) do
    value = params["value"] || params[:value] || ""
    new_assigns = overwrite(assigns, %{project: to_string(value)})
    {:patch, "mcp-project-input", render_project_input(new_assigns), new_assigns}
  end

  def handle_event("register_handoff", %{"endpoint" => endpoint} = params, assigns) do
    {:update,
     overwrite(assigns, %{
       handoff: %{
         endpoint: endpoint,
         url: params["url"] || endpoint,
         expires_in_ms: params["expiresInMs"]
       }
     })}
  end

  defp actor_from(params) do
    case Map.get(params, "_dialup_actor") || Map.get(params, :_dialup_actor) do
      "agent" -> "ai"
      :agent -> "ai"
      _ -> "human"
    end
  end

  defp actor_label("ai"), do: "🤖 AI"
  defp actor_label(_), do: "🧑 You"

  defp prompt_text(url) do
    """
    #{url}

    この MCP エンドポイントのタスクボードに、プロジェクトの目標に合うタスクを追加して
    """
  end

  defp curl_text(url) do
    ~s(curl -X POST #{url} \\\n) <>
      ~s(  -H 'Content-Type: application/json' \\\n) <>
      ~s(  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call",) <>
      ~s("params":{"name":"read_scene","arguments":{}}}')
  end

  defp render_project_input(assigns) do
    ~H"""
    <input
      id="mcp-project-input"
      class="mcp-project-input"
      value={@project}
      ws-change="set_project"
      ws-debounce="400"
      placeholder="例: 社内勉強会の企画"
    />
    """
  end

  def render(assigns) do
    ~H"""
    <div class="mcp-demo">
      <header class="mcp-hero">
        <p class="mcp-eyebrow">Demo: TODO リスト</p>
        <h1>ブラウザで開いている画面を<br/>AI Agent にバトンタッチ</h1>
        <p class="mcp-lead">
          人間が触っているこのタスクボードを、AI Agent に渡して続きを任せられます。
          AI は <code>POST /agent/:token</code> の HTTP MCP で操作し、
          あなたのブラウザは WebSocket でリアルタイムに更新されます。
        </p>
      </header>

      <ol class="mcp-steps">
        <li><strong>①</strong> 目標を入力して、人間として数件タスクを足す</li>
        <li><strong>②</strong>「AI に渡す」を押してエンドポイントを発行</li>
        <li><strong>③</strong> お使いの AI に貼り付け（or デモ AI 実行）→ 画面が自動で埋まる</li>
      </ol>

      <div class="mcp-board-wrap">
        <.dialup_region
          name={:task_board}
          role="list"
          desc="The shared task board for the current project"
          data={:tasks}
          actions={[:add_task, :complete_task, :clear_completed]}
        >
          <div class="mcp-board">
            <div class="mcp-board-head">
              <span class="mcp-demo-tag">DEMO · TODO リスト</span>
              <label class="mcp-project-label">プロジェクトの目標</label>
              {render_project_input(assigns)}
            </div>

            <ul class="mcp-tasks">
              <li :if={@tasks == []} class="mcp-task-empty">
                まだタスクがありません。下の入力欄から、または AI に任せて追加できます。
              </li>
              <li
                :for={t <- @tasks}
                class={"mcp-task" <> if(t.done, do: " is-done", else: "") <> " mcp-by-" <> t.actor}
              >
                <span class={"mcp-actor mcp-actor-" <> t.actor}>{actor_label(t.actor)}</span>
                <span class="mcp-task-title">{t.title}</span>
                <span :if={t.priority == "high"} class="mcp-prio">優先</span>
                <.dialup_action
                  :if={not t.done}
                  name={:complete_task}
                  task_id={t.id}
                  class="btn btn-primary btn-sm"
                >
                  完了
                </.dialup_action>
                <span :if={t.done} class="mcp-check">✓</span>
              </li>
            </ul>

            <form ws-submit="add_task" class="mcp-add">
              <input name="title" placeholder="タスクを入力して Enter" autocomplete="off" />
              <button type="submit" class="btn btn-ghost btn-sm">追加</button>
            </form>

            <div :if={Enum.any?(@tasks, & &1.done)} class="mcp-board-foot">
              <span>完了 {Enum.count(@tasks, & &1.done)} 件</span>
              <.dialup_action name={:clear_completed} class="btn btn-primary btn-sm">
                完了済みを削除
              </.dialup_action>
            </div>
          </div>
        </.dialup_region>

        <aside class="mcp-handoff" data-mcp-card data-mcp-endpoint={@handoff && @handoff.endpoint}>
          <%= if @handoff do %>
            <div class="mcp-handoff-live">
              <p class="mcp-handoff-badge">セッション発行済み</p>
              <p class="mcp-handoff-note">
                このボードを操作できる一時的な MCP エンドポイントです（30分で失効）。
              </p>

              <label class="mcp-field-label">MCP エンドポイント（フル URL）</label>
              <div class="mcp-copy-row">
                <code class="mcp-endpoint" data-mcp-text="endpoint">{@handoff.url}</code>
                <button type="button" class="btn btn-primary btn-sm" data-mcp-copy="endpoint">コピー</button>
              </div>

              <label class="mcp-field-label">お使いの AI に貼り付けるプロンプト</label>
              <div class="mcp-copy-block">
                <pre data-mcp-text="prompt">{prompt_text(@handoff.url)}</pre>
                <button type="button" class="btn btn-primary btn-sm" data-mcp-copy="prompt">プロンプトをコピー</button>
              </div>

              <details class="mcp-curl">
                <summary>curl で試す</summary>
                <pre data-mcp-text="curl">{curl_text(@handoff.url)}</pre>
                <button type="button" class="btn btn-primary btn-sm" data-mcp-copy="curl">curl をコピー</button>
              </details>

              <div class="mcp-demo-run">
                <button type="button" class="btn btn-accent btn-block" data-mcp="run-demo">
                  ▶ デモ AI を実行（外部 AI 不要）
                </button>
                <p class="mcp-demo-hint">
                  実際の MCP エンドポイントに read_scene → add_task を送ります。
                  ボードがリアルタイムに埋まります。
                </p>
              </div>
            </div>
          <% else %>
            <div class="mcp-handoff-cta">
              <h2>AI Agent に渡す</h2>
              <p>
                ボタンを押すと、このライブセッションを操作できる
                MCP エンドポイントを発行します。
              </p>
              <button type="button" class="btn btn-ghost btn-block" data-mcp="handoff">
                この画面を AI に渡す →
              </button>
              <p class="mcp-handoff-status" data-mcp-status></p>
            </div>
          <% end %>

          <div class="mcp-tools">
            <p class="mcp-tools-title">UI 宣言から自動生成された MCP ツール</p>
            <ul>
              <li :for={a <- __dialup_actions__()}>
                <code>{a.name}</code>
                <span class="mcp-tool-desc">{a.desc}</span>
                <span :if={a.params != %{}} class="mcp-tool-params">
                  ({a.params |> Map.keys() |> Enum.map_join(", ", &to_string/1)})
                </span>
              </li>
              <li><code>read_scene</code><span class="mcp-tool-desc">現在の状態と version を読む</span></li>
            </ul>
          </div>
        </aside>
      </div>
    </div>
    """
  end
end
