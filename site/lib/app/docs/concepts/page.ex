defmodule Dialup.App.Docs.Concepts.Page do
  use Dialup.Page

  def page_title(_assigns), do: "Architecture — Dialup"

  defp code_arch, do: ~S|【ブラウザ】
  dialup.js
  ├── WebSocket 接続管理（Cookie 経由のセッション ID）
  ├── ws-event / ws-change / ws-submit / ws-href の監視
  ├── 切断検知と指数バックオフ自動再接続
  ├── ブラウザ履歴管理（history.pushState / popstate）
  └── HTML を受け取り idiomorph で DOM に適用

            ↕ WebSocket

【Elixir サーバー】
  Dialup.SessionRegistry（Registry）
  Dialup.SessionSupervisor（DynamicSupervisor）
  └── UserSessionProcess（1 タブ = 1 プロセス）
       ├── session  : layout.mount が設定。ナビゲーション間で持続
       ├── assigns  : page.mount が設定。ページ遷移でリセット
       ├── params   : URL パラメータ（自動設定）
       └── layout + page を合成して HTML を生成|

  defp code_routing, do: ~S|app/
├── layout.ex               # 全ページ共通レイアウト
├── error.ex                # 全ページ共通エラーページ
├── page.ex                 # /
├── blog/
│   ├── layout.ex           # /blog/* 共通レイアウト（ネスト可）
│   ├── error.ex            # /blog/* エラーページ（より具体的）
│   └── [slug]/
│       └── page.ex         # /blog/:slug（動的ルーティング）|

  defp code_lifecycle, do: ~S|初回接続:
  HTTP GET → Cookie にセッション ID 発行 → WebSocket 接続
  → layout.mount/1（session 確定）
  → page.mount/2（assigns 確定）
  → render → HTML 送信

ページ遷移（ws-href）:
  → page.mount/2（assigns リセット）→ render → HTML 送信

イベント（ws-event / ws-submit / ws-change）:
  → handle_event/3 → {:update, _} なら render

切断 → 再接続:
  プロセス生存中  : mount なしで現在の state で再描画
  タイムアウト済み: layout.mount + page.mount からやり直し|

  defp code_state, do: ~S|def mount(session) do
  # session: 接続全体で持続（ログインユーザーなど）
  user = Repo.get(User, get_user_id_from_cookie())
  {:ok, Map.put(session, :current_user, user)}
end|

  defp code_page_mount, do: ~S|def mount(%{"id" => id}, assigns) do
  # assigns にはすでに session の内容（current_user 等）が入っている
  post = Posts.get!(id, assigns.current_user)
  {:ok, %{post: post}}
end|

  defp code_css_scope, do: ~S|<div class="d-layout">           <!-- app/layout.css のスコープ -->
  <header>...</header>
  <div class="d-docs-page">    <!-- docs/page.css のスコープ -->
    <h1>Docs</h1>
  </div>
</div>|

  defp code_layout_false, do: ~S|defmodule Dialup.App.Login.Page do
  use Dialup.Page

  @layout false  # 全画面表示（layout.ex を無効化）

  def render(assigns) do
    ~H"""
    <div class="login-screen">
      <form ws-submit="login">
        <input name="email" />
        <input name="password" type="password" />
        <button type="submit">ログイン</button>
      </form>
    </div>
    """
  end
end|

  defp code_mcp_arch, do: ~S|【人間】 dialup.js ──WebSocket──► UserSessionProcess
【AI】   POST /agent/:token (JSON-RPC) ──► 同じ UserSessionProcess
                │
         declare_action / dialup_action
                │
           tools/list · tools/call|

  def render(assigns) do
    ~H"""
    <div class="docs-page">
    <h1>アーキテクチャ</h1>
    <p class="page-lead">
      Dialup の「1 タブ = 1 プロセス」モデルと、state の設計を解説します。
    </p>

    <h2>全体構造</h2>
    <p>
      Dialup は Elixir の GenServer（プロセス）を中心に据えた設計です。
      ブラウザのタブが一つ開くと、サーバー上に対応する UserSessionProcess が起動します。
      以後の操作はすべてこのプロセスを通じて行われます。
    </p>

    <pre class="arch-diagram">{code_arch()}</pre>

    <h2>ファイルベースルーティング</h2>
    <p>
      Dialup はファイルの配置を読み取り、コンパイル時にルートテーブルを生成します。
      <code>router.ex</code> への手書き登録は不要です。
      レイアウトとエラーページもディレクトリ階層で継承されます。
    </p>
    <pre><code>{code_routing()}</code></pre>

    <p>
      URL <code>/blog/my-post</code> にアクセスすると、
      <code>app/layout.ex</code> → <code>blog/layout.ex</code> → <code>blog/[slug]/page.ex</code>
      の順に組み合わされます。
      エラーページはリクエストパスに最も近い <code>error.ex</code> が選択されます。
    </p>

    <h2>ライフサイクル</h2>
    <pre><code>{code_lifecycle()}</code></pre>

    <h2>session と assigns の分離</h2>
    <p>
      Dialup の最も重要なコンセプトは、state を二層に分けることです。
    </p>

    <table class="compare-table">
      <thead>
        <tr>
          <th>フィールド</th>
          <th>設定者</th>
          <th>ライフサイクル</th>
          <th>用途例</th>
        </tr>
      </thead>
      <tbody>
        <tr>
          <td><code>session</code></td>
          <td><code>layout.mount/1</code></td>
          <td>プロセス全体で持続</td>
          <td>ログインユーザー、テーマ設定</td>
        </tr>
        <tr>
          <td><code>assigns</code></td>
          <td><code>page.mount/2</code></td>
          <td>ページ遷移でリセット</td>
          <td>記事一覧、カウンター</td>
        </tr>
        <tr>
          <td><code>params</code></td>
          <td>自動設定</td>
          <td>ナビゲーションごとに更新</td>
          <td>URL パラメータ・クエリ文字列</td>
        </tr>
      </tbody>
    </table>

    <p>
      テンプレート内では <code>session + assigns + params</code> がマージされるため、
      すべて <code>@field_name</code> でアクセスできます。
    </p>

    <pre><code>{code_state()}</code></pre>
    <pre><code>{code_page_mount()}</code></pre>

    <h2>コロケーション CSS とスコーピング</h2>
    <p>
      <code>page.ex</code> / <code>layout.ex</code> と同じディレクトリに同名の <code>.css</code> を置くと、
      コンパイル時にモジュール名由来の一意なクラス（<code>d-xxxxxxx</code>）でスコーピングされます。
      <code>layout.css</code> はその配下のディレクトリ全体に適用され、<code>page.css</code> は 同じディレクトリの <code>page.ex</code> のみに適用されます。
    </p>
    <pre><code>{code_css_scope()}</code></pre>

    <h2>@layout false — 全画面ページ</h2>
    <p>
      特定のページでレイアウト継承を無効にするには <code>@layout false</code> を指定します。
      ログイン画面・エラー画面の全画面表示に使用します。
    </p>
    <pre><code>{code_layout_false()}</code></pre>

    <h2>差分適用：なぜクライアント側か</h2>
    <p>
      Phoenix LiveView はサーバー側で差分を計算して最小限の指示を送ります。
      Dialup はシンプルさを優先し、サーバーは HTML 断片をそのまま送信します。
      クライアント側の <a href="https://github.com/bigskysoftware/idiomorph">idiomorph</a>（5KB）が
      DOM を効率的にモーフィングするため、フォームの入力値が保たれます。
    </p>

    <h2>HTTP MCP API（UI から自動生成）</h2>
    <p>
      Dialup のもう一つの中心軸は、人間向け UI 宣言からエージェント向け HTTP JSON-RPC API を
      自動生成することです。<code>&lt;.dialup_action&gt;</code> と <code>declare_action/1</code> が
      <code>tools/list</code> のカタログになり、<code>tools/call</code> は同じ
      <code>handle_event/3</code> に直列化されます。
    </p>
    <pre class="arch-diagram">{code_mcp_arch()}</pre>
    <p>
      ライブデモは <.dialup_action navigate="/agent_demo" class="inline-link">/agent_demo</.dialup_action>。
      詳細は Hex ガイド <em>HTTP MCP API</em> を参照してください。
    </p>
    </div>
    """
  end
end
