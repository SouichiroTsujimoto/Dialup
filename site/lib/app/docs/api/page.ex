defmodule Dialup.App.Docs.Api.Page do
  use Dialup.Page

  def page_title(_assigns), do: "API Reference — Dialup"

  def agent_state(_assigns), do: %{}

  def agent_message(_assigns) do
    %{
      concept: "API reference documentation for Dialup. Read-only page with no mutable state.",
      goal:
        "Look up use Dialup options, handle_event return values, HTML attributes, and helpers."
    }
  end

  def agent_grant(_assigns) do
    %{
      capabilities: :all,
      projections: [:state, :actions],
      expires_in: :timer.minutes(15),
      require_version: false
    }
  end

  # ── コード例 ──────────────────────────────────────────────────────────────
  # """ ヒアドキュメントを使う。閉じる """ の手前の空白がトリミングされる。
  # テンプレートから {code_xxx()} で呼ぶ。

  defp code_use_dialup do
    """
    defmodule MyApp do
      use Application

      use Dialup,
        app_dir: __DIR__ <> "/app",   # 必須
        title: "My App",              # <title> のデフォルト値
        lang: "en",                   # html lang 属性
        check_origin: :conn,          # WebSocket オリジン検証
        plugs: [MyApp.AuthPlug],      # カスタム Plug（省略可）
        session_store: :memory        # :memory / :ets

      @impl Application
      def start(_type, _args) do
        children = [{Dialup, app: __MODULE__, port: 4000}]
        Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
      end
    end
    """
  end

  defp code_layout do
    """
    defmodule Dialup.App.Layout do
      use Dialup.Layout

      # 接続時に一度だけ呼ばれる（省略可）
      def mount(session) do
        user = Repo.get(User, get_user_id_from_cookie())
        {:ok, Map.put(session, :current_user, user)}
      end

      def render(assigns) do
        ~H\"""
        <nav>{@current_user.name}</nav>
        <main>{raw(@inner_content)}</main>
        \"""
      end
    end
    """
  end

  defp code_page do
    """
    defmodule Dialup.App.Users.Id.Page do
      use Dialup.Page

      def page_title(assigns), do: "\#{assigns.user.name} | MyApp"

      def mount(%{"id" => id}, assigns) do
        {:ok, %{user: Users.get!(id)}}
      end

      def handle_event("follow", _, assigns) do
        {:update, Map.update!(assigns, :user, &Users.follow/1)}
      end

      def render(assigns) do
        ~H\"""
        <h1>{@user.name}</h1>
        <button ws-event="follow">フォロー</button>
        \"""
      end
    end
    """
  end

  defp code_returns do
    """
    # 状態のみ更新、再描画なし（高頻度イベント向け）
    def handle_event("draft", value, assigns) do
      {:noreply, Map.put(assigns, :draft, value)}
    end

    # 全体を再描画
    def handle_event("submit", _value, assigns) do
      {:update, Map.put(assigns, :submitted, true)}
    end

    # 指定した id の要素のみ更新（効率的）
    defp render_counter(assigns) do
      ~H\\"<span id=\\"counter\\">{@count}</span>\\"
    end

    def handle_event("inc", _value, assigns) do
      new = Map.update!(assigns, :count, &(&1 + 1))
      {:patch, "counter", render_counter(new), new}
    end

    # 別ページへリダイレクト
    def handle_event("logout", _value, assigns) do
      {:redirect, "/login", assigns}
    end

    # JS フックを呼び出す（全体再描画も行う）
    def handle_event("save", params, assigns) do
      {:ok, item} = Items.create(params)
      {:push_event, "show_toast", %{message: "保存しました"}, Map.put(assigns, :item, item)}
    end
    """
  end

  defp code_handle_info do
    """
    def mount(_params, assigns) do
      subscribe(MyApp.PubSub, "room:lobby")  # 自動 unsubscribe 付き
      Process.send_after(self(), :tick, 1_000)
      {:ok, %{messages: [], count: 0}}
    end

    def handle_info({:new_message, msg}, assigns) do
      {:update, Map.update!(assigns, :messages, &[msg | &1])}
    end

    def handle_info(:tick, assigns) do
      Process.send_after(self(), :tick, 1_000)
      {:update, Map.update!(assigns, :count, &(&1 + 1))}
    end
    """
  end

  defp code_helpers do
    """
    def mount(params, assigns) do
      {:ok, assigns
      |> set_default(%{errors: [], page: 1})   # 未設定キーのみ初期値を設定
      |> overwrite(%{user_id: params["id"]})}  # 既存キーも含めて上書き
    end
    """
  end

  defp code_ws_hook do
    """
    # HTML 側（id 属性は必須）
    <div id="map" ws-hook="MapHook" data-lat={@lat} data-lng={@lng}></div>

    # lib/root.html.heex で登録
    Dialup.connect({
      hooks: {
        MapHook: {
          mounted(el) {
            const lat = parseFloat(el.dataset.lat);
            const lng = parseFloat(el.dataset.lng);
            el._map = L.map(el).setView([lat, lng], 13);
          },
          updated(el) {
            el._map.setView([parseFloat(el.dataset.lat), parseFloat(el.dataset.lng)]);
          },
          destroyed(el) {
            el._map?.remove();
          }
        },
        // push_event ハンドラは関数で登録
        show_toast: ({ message }) => {
          document.getElementById("toast").textContent = message;
        }
      }
    });
    """
  end

  defp code_agent_actions do
    action = "dialup_action"
    region = "dialup_region"

    """
    defmodule Dialup.App.Invoice.Page do
      use Dialup.Page

      alias MyApp.Ordering

      def mount(_params, assigns) do
        {:ok, assigns |> set_default(%{items: [], order_id: "ord-1", details_open: false})}
      end

      def agent_state(assigns), do: %{items: assigns.items, details_open: assigns.details_open}

      def render(assigns) do
        ~H\"""
        <.#{region} name={:items} role="list" desc="請求書の明細" data={@items}>
          <ul><li :for={item <- @items}>{item.sku} x {item.qty}</li></ul>
        </.#{region}>

        <.#{action}
          command={{Ordering, :add_item}}
          desc="明細を追加する"
          params={%{sku: :string, qty: {:integer, default: 1}}}
          bind={%{order_id: @order_id}}
          errors={%{too_many: "明細が多すぎます"}}
          available={length(@items) < 20}
          sku="SKU-1"
          qty="1"
        >
          追加
        </.#{action}>

        <.#{action}
          name={:toggle_details}
          desc="詳細パネルを開閉"
          params={%{}}
          set={%{details_open: !@details_open}}
        >
          詳細
        </.#{action}>
        \"""
      end
    end
    """
  end

  defp code_legacy_action do
    action = "dialup_action"

    """
    # legacy モード（handle_event/3 に委譲）
    <.#{action}
      name={:archive}
      desc="請求書をアーカイブする"
      params={%{}}
      available={@status == :draft}
    >
      アーカイブ
    </.#{action}>

    def handle_event("archive", _value, assigns) do
      {:update, Map.put(assigns, :status, :archived)}
    end
    """
  end

  defp code_mcp_endpoints do
    """
    # 既存タブから MCP token を発行
    POST /_dialup/agent-handoff?tab_id=TAB_ID
    Cookie: dialup_session=SESSION_ID

    # 人間タブなしで agent-first 開始
    POST /_dialup/agent-session
    Content-Type: application/json
    {"path":"/invoices"}

    # browser handoff 完了（dialup.js が呼ぶ）
    POST /_dialup/finalize-join?tab_id=TAB_ID&nonce=NONCE

    # MCP JSON-RPC（Bearer または path token）
    POST /mcp
    Authorization: Bearer TOKEN

    POST /agent/TOKEN
    """
  end

  # ── render ───────────────────────────────────────────────────────────────

  def render(assigns) do
    ~H"""
    <div class="docs-page">
    <h1>API リファレンス</h1>
    <p class="page-lead">
      Dialup が提供する主要な API を説明します。
      完全なリファレンスは
      <a href="https://hexdocs.pm/dialup/" class="inline-link" target="_blank" rel="noopener">HexDocs</a>
      で確認できます。
    </p>

    <h2>use Dialup オプション</h2>
    <pre><code>{code_use_dialup()}</code></pre>

    <table class="attr-table">
      <thead>
        <tr><th>オプション</th><th>説明</th></tr>
      </thead>
      <tbody>
        <tr>
          <td><code>app_dir</code></td>
          <td>page.ex / layout.ex を配置するディレクトリ（必須）</td>
        </tr>
        <tr>
          <td><code>title</code></td>
          <td><code>&lt;title&gt;</code> のデフォルト値（デフォルト: "Dialup App"）</td>
        </tr>
        <tr>
          <td><code>lang</code></td>
          <td><code>html lang</code> 属性の値（デフォルト: "en"）</td>
        </tr>
        <tr>
          <td><code>check_origin</code></td>
          <td>WebSocket オリジン検証。<code>:conn</code>（デフォルト）/ <code>false</code> / ホストのリスト</td>
        </tr>
        <tr>
          <td><code>plugs</code></td>
          <td>カスタム Plug パイプライン（認証・CORS など）</td>
        </tr>
        <tr>
          <td><code>session_store</code></td>
          <td>セッション状態の保存先。<code>:memory</code>（デフォルト）または <code>:ets</code></td>
        </tr>
      </tbody>
    </table>

    <h2>use Dialup.Layout</h2>
    <pre><code>{code_layout()}</code></pre>

    <h2>use Dialup.Page</h2>
    <pre><code>{code_page()}</code></pre>

    <div class="note">
      <strong>page_title/1</strong> は省略可能。assigns を受け取りタイトル文字列を返します。
      <code>nil</code> を返すと <code>use Dialup</code> の <code>title</code> 設定値が使われます。
    </div>

    <h2>handle_event / handle_info の返り値</h2>
    <pre><code>{code_returns()}</code></pre>

    <table class="return-table">
      <thead>
        <tr><th>返り値</th><th>説明</th></tr>
      </thead>
      <tbody>
        <tr><td><code>&#123;:noreply, assigns&#125;</code></td><td>再描画なし。状態のみ更新</td></tr>
        <tr><td><code>&#123;:update, assigns&#125;</code></td><td>全体を再描画</td></tr>
        <tr><td><code>&#123;:patch, id, html, assigns&#125;</code></td><td>指定 id の要素のみ更新</td></tr>
        <tr><td><code>&#123;:redirect, path, assigns&#125;</code></td><td>別ページへ遷移（session 保持）</td></tr>
        <tr><td><code>&#123;:push_event, name, payload, assigns&#125;</code></td><td>JS フック関数を呼び出す（全体再描画も行う）</td></tr>
      </tbody>
    </table>

    <h2>handle_info / subscribe</h2>
    <pre><code>{code_handle_info()}</code></pre>

    <h2>ヘルパー関数</h2>
    <p><code>use Dialup.Page</code> で自動的に import されます。</p>
    <pre><code>{code_helpers()}</code></pre>

    <table class="return-table">
      <thead>
        <tr><th>関数</th><th>既存キー</th><th>用途</th></tr>
      </thead>
      <tbody>
        <tr><td><code>overwrite(assigns, map)</code></td><td>上書き</td><td>新データで状態を更新</td></tr>
        <tr><td><code>set_default(assigns, map)</code></td><td>保持</td><td>初期値の設定（初回のみ）</td></tr>
      </tbody>
    </table>

    <h2>HTML 属性</h2>

    <table class="attr-table">
      <thead>
        <tr><th>属性</th><th>対象</th><th>説明</th></tr>
      </thead>
      <tbody>
        <tr>
          <td><code>ws-href="/path"</code></td>
          <td>任意</td>
          <td>クリック時に SPA ナビゲーション</td>
        </tr>
        <tr>
          <td><code>ws-event="name"</code></td>
          <td>任意</td>
          <td>クリック時に <code>handle_event/3</code> を呼ぶ</td>
        </tr>
        <tr>
          <td><code>ws-value="val"</code></td>
          <td>ws-event と組み合わせ</td>
          <td><code>handle_event</code> の第二引数として渡す値</td>
        </tr>
        <tr>
          <td><code>ws-submit="name"</code></td>
          <td>form</td>
          <td>送信時にフォームデータをオブジェクトとして渡す</td>
        </tr>
        <tr>
          <td><code>ws-change="name"</code></td>
          <td>input / textarea / select</td>
          <td>入力のたびに現在の値を送信</td>
        </tr>
        <tr>
          <td><code>ws-debounce="300"</code></td>
          <td>ws-change と組み合わせ</td>
          <td>指定 ms 間入力がなかった場合のみ送信</td>
        </tr>
        <tr>
          <td><code>ws-hook="HookName"</code></td>
          <td>任意（id 必須）</td>
          <td>外部 JS ライブラリのライフサイクル管理（mounted / updated / destroyed）</td>
        </tr>
      </tbody>
    </table>

    <h2>ws-hook と push_event</h2>
    <pre><code>{code_ws_hook()}</code></pre>

    <table class="return-table">
      <thead>
        <tr><th></th><th>push_event</th><th>ws-hook</th></tr>
      </thead>
      <tbody>
        <tr><td>起点</td><td>サーバーが能動的に呼ぶ</td><td>DOM の変化が自動で呼ぶ</td></tr>
        <tr><td>登録形式</td><td>関数 <code>name: (payload) =&gt; &#123;&#125;</code></td><td>オブジェクト <code>name: &#123; mounted, updated, destroyed &#125;</code></td></tr>
        <tr><td>用途</td><td>トースト・モーダル・スクロールなど一発イベント</td><td>地図・チャート・リッチエディタなど初期化が必要なもの</td></tr>
      </tbody>
    </table>

    <h2>HTTP MCP tools</h2>
    <p>
      エージェントに公開する操作は、通常の <code>ws-event</code> ではなく
      <code>&lt;.dialup_action&gt;</code> または <code>declare_action/1</code> で宣言します。
      人間の WebSocket イベントとエージェントの <code>tools/call</code> は同じ
      <code>UserSessionProcess</code> に直列化されます。
      ナビゲーションは <code>&lt;.dialup_action navigate="/path"&gt;</code> として宣言したリンクだけが
      tool になります。意味のある領域は <code>&lt;.dialup_region&gt;</code> /
      <code>declare_region/1</code> で安定した名前を与えます。
    </p>

    <h3>Action モード</h3>
    <p>
      <code>&lt;.dialup_action&gt;</code> は次の 4 モードのいずれか 1 つだけを指定します。
      <code>tools/list</code> の各 tool には <code>_meta.mode</code> が付きます。
    </p>

    <table class="attr-table">
      <thead>
        <tr><th>モード</th><th>属性</th><th>サーバー側ルーティング</th></tr>
      </thead>
      <tbody>
        <tr>
          <td><code>command</code></td>
          <td><code>command=&#123;&#123;Context, :cmd&#125;&#125;</code></td>
          <td>Commanded コマンドを組み立て → <code>Context.dispatch/1</code> → ページ remount</td>
        </tr>
        <tr>
          <td><code>set</code></td>
          <td><code>set=&#123;%&#123;key: value&#125;&#125;</code></td>
          <td>レンダリング時の map を assigns にマージ（UI 専用 state）</td>
        </tr>
        <tr>
          <td><code>navigate</code></td>
          <td><code>navigate="/path"</code></td>
          <td>宣言済みパスへ遷移</td>
        </tr>
        <tr>
          <td><code>action</code>（legacy）</td>
          <td><code>name=&#123;:event&#125;</code></td>
          <td><code>handle_event/3</code> に委譲</td>
        </tr>
      </tbody>
    </table>

    <p>
      Commanded / CQRS を使う場合は <code>command</code> モードを優先し、
      <code>use Dialup.CommandedContext</code> と
      <code>mix dialup.gen.aggregate</code> でスキャフォールドを生成します。
      <code>available=&#123;...&#125;</code> はコンパイル時に <code>__available__/2</code> を導出し、
      人間の UI とエージェントの <code>tools/list</code> で同じ条件を共有します。
      詳細は Hex ガイド <em>Building agent-native applications</em> を参照してください。
    </p>

    <pre><code>{code_agent_actions()}</code></pre>

    <p>フォーム送信や段階的移行が必要な操作は legacy モードで <code>handle_event/3</code> に残せます。</p>
    <pre><code>{code_legacy_action()}</code></pre>

    <h2>HTTP MCP セッション API</h2>
    <p>
      ライブセッションを操作する bearer token の取得、agent-first 起動、browser handoff の完了
      エンドポイントです。join token は <code>finalize-join</code> 成功時に消費されます
      （URL を開いただけでは完了しません）。
    </p>
    <pre><code>{code_mcp_endpoints()}</code></pre>

    <table class="attr-table">
      <thead>
        <tr><th>エンドポイント</th><th>用途</th></tr>
      </thead>
      <tbody>
        <tr>
          <td><code>POST /_dialup/agent-handoff</code></td>
          <td>開いているタブの live session に MCP token を発行</td>
        </tr>
        <tr>
          <td><code>POST /_dialup/agent-session</code></td>
          <td>headless セッションを起動（browser 未接続）</td>
        </tr>
        <tr>
          <td><code>POST /_dialup/finalize-join</code></td>
          <td>browser handoff 完了（cookie 設定 + join token 消費）</td>
        </tr>
        <tr>
          <td><code>POST /mcp</code> / <code>POST /agent/:token</code></td>
          <td>JSON-RPC（<code>tools/list</code>、<code>tools/call</code> など）</td>
        </tr>
      </tbody>
    </table>

    <h2>ページモジュールのオプション</h2>

    <table class="attr-table">
      <thead>
        <tr><th>モジュール属性</th><th>説明</th></tr>
      </thead>
      <tbody>
        <tr>
          <td><code>@layout false</code></td>
          <td>全ての <code>layout.ex</code> を無効化（全画面ページ・ログイン画面など）</td>
        </tr>
        <tr>
          <td><code>@static true</code></td>
          <td>WebSocket 接続なしで表示（純粋に静的なページ）</td>
        </tr>
      </tbody>
    </table>
    </div>
    """
  end
end
