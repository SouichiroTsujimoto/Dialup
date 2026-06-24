defmodule Dialup.App.Docs.Api.Page do
  use Dialup.Page

  def page_title(_assigns), do: "API Reference — Dialup"

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
        plugs: [MyApp.AuthPlug]       # カスタム Plug（省略可）

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

  # ── render ───────────────────────────────────────────────────────────────

  def render(assigns) do
    ~H"""
    <div class="docs-page">
    <h1>API リファレンス</h1>
    <p class="page-lead">
      Dialup が提供する主要な API を説明します。
      完全なリファレンスは <code>mix docs</code> で生成される HexDocs で確認できます。
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
