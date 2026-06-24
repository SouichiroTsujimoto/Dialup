defmodule Dialup.App.Docs.Page do
  use Dialup.Page

  def page_title(_assigns), do: "Getting Started — Dialup"

  defp code_new, do: ~S|# `dialup_new`コマンドをインストール(初回のみ)
mix archive.install hex dialup_new

# 新規プロジェクト作成
mix dialup.new my_app
cd my_app
mix deps.get
mix run --no-halt|

  defp code_file_tree, do: ~S|my_app/
├── priv/static/         # 静的ファイル置き場（画像・favicon など）
└── lib/
    ├── my_app.ex        # Application モジュール
    ├── root.html.heex   # HTML シェル（<head> / hooks / analytics）
    └── app/
        ├── layout.ex    # ルートレイアウト
        ├── layout.css   # 全ページ共通スタイル（コロケーション CSS）
        ├── page.ex      # ホームページ /
        ├── page.css     # / 固有スタイル（コロケーション CSS）
        ├── error.ex     # エラーページ（404 / 500）
        └── error.css    # エラーページスタイル|

  defp code_app_module, do: ~S|defmodule MyApp do
  use Application

  use Dialup,
    app_dir: __DIR__ <> "/app",
    title: "My App",
    lang: "en"

  @impl Application
  def start(_type, _args) do
    children = [
      {Dialup, app: __MODULE__, port: 4000}
    ]
    Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
  end
end|

  defp code_root_shell, do: ~S|<!DOCTYPE html>
<html lang="{@lang}">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{@title}</title>
  <!-- ここに <meta>, <link>, analytics を追加 -->
</head>
<body>
  <div id="dialup-root">{raw(@inner_content)}</div>
  <script src="/idiomorph.js"></script>
  <script src="/dialup.js"></script>
  <script>
    Dialup.connect({
      /* hooks: { MyHook: { mounted(el) {}, destroyed(el) {} } } */
    });
  </script>
</body>
</html>|

  defp code_first_page, do: ~S|defmodule Dialup.App.Page do
  use Dialup.Page

  def mount(_params, assigns) do
    {:ok, Map.put(assigns, :count, 0)}
  end

  def handle_event("increment", _, assigns) do
    {:update, Map.update!(assigns, :count, &(&1 + 1))}
  end

  def render(assigns) do
    ~H"""
    <h1>Hello, Dialup!</h1>
    <p>Count: {@count}</p>
    <button ws-event="increment">+1</button>
    """
  end
end|

  defp code_routing, do: ~S|lib/app/
├── page.ex              # /
├── about/
│   └── page.ex          # /about
├── blog/
│   ├── layout.ex        # /blog/* 共通レイアウト
│   └── [slug]/
│       └── page.ex      # /blog/:slug（動的ルート）
└── users/
    └── [id]/
        └── page.ex      # /users/:id|

  defp code_colocation, do: ~S|/* lib/app/page.css — page.ex と同じディレクトリに置く */
.hero {
  text-align: center;
  padding: 4rem 2rem;
}
h1 { font-size: 3rem; }|

  def render(assigns) do
    ~H"""
    <div class="docs-page">
    <h1>Getting Started</h1>
    <p class="page-lead">
      Dialup を使って最初のリアルタイムページを動かすまでのガイドです。
    </p>

    <h2>インストール</h2>
    <p><code>mix dialup.new</code> ジェネレータで新規プロジェクトを作成します（推奨）。</p>

    <pre><code>{code_new()}</code></pre>

    <p>ブラウザで <code>http://localhost:4000</code> にアクセスして動作を確認してください。</p>

    <h2>生成されるファイル構成</h2>
    <pre><code>{code_file_tree()}</code></pre>

    <h2>Application モジュール</h2>
    <p><code>lib/my_app.ex</code> が Dialup の起点です。<code>use Dialup</code> で設定を行い、Supervision Tree に <code>{"{Dialup, app: __MODULE__, port: 4000}"}</code> を追加するだけです。</p>
    <pre><code>{code_app_module()}</code></pre>

    <div class="note">
      <strong>app_dir</strong> に指定したディレクトリのファイル配置が自動的にルートになります。
      <code>router.ex</code> への手書き登録は不要です。
    </div>

    <h2>root.html.heex — HTML シェル</h2>
    <p>
      <code>lib/root.html.heex</code> は全ページ共通の HTML シェルです。
      <code>&lt;head&gt;</code> へのタグ追加・分析スクリプト・JS フックの登録はここで行います。
      <code>id="dialup-root"</code> と <code>Dialup.connect()</code> は必須です。
    </p>
    <pre><code>{code_root_shell()}</code></pre>

    <h2>最初のページを作る</h2>
    <p><code>lib/app/page.ex</code> がルートページ <code>/</code> になります。</p>
    <pre><code>{code_first_page()}</code></pre>

    <h2>ページの追加とルーティング</h2>
    <p>ファイルを置くだけでルートが追加されます。動的ルートは <code>[パラメータ名]</code> ディレクトリで表現します。</p>
    <pre><code>{code_routing()}</code></pre>

    <h2>コロケーション CSS</h2>
    <p>
      <code>page.ex</code> と同名の <code>page.css</code> を同じディレクトリに置くと、
      コンパイル時に自動スコーピングされて注入されます。ビルドツール不要。
    </p>
    <pre><code>{code_colocation()}</code></pre>

    <div class="note">
      <strong>静的ファイル配信：</strong>
      <code>priv/static/</code> に配置したファイルは <code>/</code> パスから自動配信されます。
      例: <code>priv/static/images/logo.png</code> → <code>&lt;img src="/images/logo.png"&gt;</code>
    </div>

    <h2>次のステップ</h2>
    <ul>
      <li><.dialup_action navigate="/agent_demo" class="inline-link">MCP Live Demo</.dialup_action> — UI から自動生成される HTTP JSON-RPC を体験</li>
      <li><.dialup_action navigate="/docs/concepts" class="inline-link">アーキテクチャとライフサイクル</.dialup_action>を理解する</li>
      <li><.dialup_action navigate="/docs/api" class="inline-link">API リファレンス</.dialup_action>で使える機能を確認する</li>
      <li><.dialup_action navigate="/demo" class="inline-link">UI Demo</.dialup_action> でリアルタイム UI を確認する</li>
    </ul>
    </div>
    """
  end
end
