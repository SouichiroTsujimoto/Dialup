# Getting Started

Dialupフレームワークを使ったアプリケーションの作成方法。

## 前提条件

- Elixir 1.19以上
- 基本的なElixir/Phoenixの知識（推奨）

## インストール

### 1. 新規プロジェクト作成（推奨）

`mix dialup.new` ジェネータを使用してプロジェクトを作成：

```bash
mix dialup.new my_app
cd my_app
mix deps.get
```

これにより、以下のファイルが自動的に生成：

```
my_app/
├── README.md
├── mix.exs              # {:dialup, "~> 0.1.0"} を含む
├── .gitignore
├── priv/static/         # 静的ファイル置き場（画像・フォント・favicon など）
└── lib/
    ├── my_app.ex        # Application モジュール
    ├── root.html.heex   # HTML シェル（<head>・hooks・analytics をカスタマイズ）
    └── app/
        ├── layout.ex    # Dialup.App.Layout（ルートレイアウト）
        ├── layout.css   # レイアウト共通スタイル（コロケーション CSS）
        ├── page.ex      # Dialup.App.Page（ホームページ）
        ├── page.css     # ホームページ固有スタイル（コロケーション CSS）
        ├── error.ex     # エラーページ（404 / 500）
        └── error.css    # エラーページスタイル
```

#### ジェネレータのオプション

```bash
# アプリ名をカスタマイズ
mix dialup.new hello --app hello_world

# モジュール名もカスタマイズ
mix dialup.new my_project --app my_project --module MyAwesomeProject

# ヘルプ確認
mix help dialup.new
```

### 2. 起動

```bash
mix run --no-halt
```

ブラウザで `http://localhost:4000` にアクセス。

---

## 手動でのセットアップ（既存プロジェクトへの追加）

既存のMixプロジェクトにDialupを追加する場合：

### 1. dialupの依存追加

`mix.exs` に追加：

```elixir
defp deps do
  [
    {:dialup, "~> 0.1.0"}
  ]
end
```

```bash
mix deps.get
```

### 2. アプリケーション設定

`lib/my_app.ex` を作成：

```elixir
defmodule MyApp do
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

    opts = [
      strategy: :one_for_one,
      name: __MODULE__.Supervisor
    ]

    Supervisor.start_link(children, opts)
  end
end
```

### 3. root.html.heex の作成

`lib/root.html.heex` を作成：

```html
<!DOCTYPE html>
<html lang="{@lang}">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{@title}</title>
</head>
<body>
  <div id="dialup-root">{raw(@inner_content)}</div>
  <script src="/idiomorph.js"></script>
  <script src="/dialup.js"></script>
  <script>Dialup.connect();</script>
</body>
</html>
```

### 4. 最初のページ作成

`lib/app/page.ex` を作成：

```elixir
defmodule Dialup.App.Page do
  use Dialup.Page

  def mount(_params, assigns) do
    {:ok, Map.put(assigns, :count, 0)}
  end

  def handle_event("increment", _value, assigns) do
    {:patch, "count", render_count(assigns), 
     Map.update!(assigns, :count, &(&1 + 1))}
  end

  defp render_count(assigns) do
    ~H"""
    <p id="count">Count: {@count}</p>
    """
  end

  def render(assigns) do
    ~H"""
    <h1>Hello Dialup</h1>
    <%= render_count(assigns) %>
    <button ws-event="increment">+</button>
    """
  end
end
```

### 5. レイアウトの追加（オプション）

`lib/app/layout.ex` を作成：

```elixir
defmodule Dialup.App.Layout do
  use Dialup.Layout

  def mount(session) do
    {:ok, session}
  end

  def render(assigns) do
    ~H"""
    <nav>
      <a ws-href="/">Home</a>
    </nav>
    {raw(@inner_content)}
    """
  end
end
```

> **注意**: Layout は `#dialup-root` の**中身**のみを生成します。
> `<html>`, `<head>`, `<body>` タグは `lib/root.html.heex` が担当します。

### 6. 起動

```bash
mix run --no-halt
```

## 開発時ホットリロード

開発環境（`Mix.env() == :dev`）では自動的に `Dialup.Reloader` が起動します。`lib/` 以下の `.ex` / `.css` ファイルを保存するたびに：

1. 変更を検出（ポーリング間隔: 500ms）
2. 自動でリコンパイル（`.css` 変更は `@external_resource` 経由で対応する `.ex` も再コンパイル）
3. 既存のWebSocket経由でブラウザを更新（ページリロードなし）

## プロジェクト構成

推奨ディレクトリ構造：

```
my_app/
├── priv/static/           # 静的ファイル（/images/logo.png → /images/logo.png）
└── lib/
    ├── my_app.ex          # Application モジュール（use Dialup）
    ├── root.html.heex     # HTML シェル（<head>・Dialup.connect・analytics）
    └── app/
        ├── layout.ex      # Dialup.App.Layout（共通レイアウト）
        ├── layout.css     # 全ページ共通スタイル（オプション）
        ├── page.ex        # Dialup.App.Page（/ ルートページ）
        ├── page.css       # / 固有スタイル（オプション）
        ├── error.ex       # エラーページ（404 / 500）
        ├── about/
        │   └── page.ex    # Dialup.App.About（/about）
        └── users/
            ├── layout.ex  # Dialup.App.Users.Layout（/users 以下のレイアウト）
            ├── layout.css # /users 配下全ページのスタイル（オプション）
            └── [id]/
                └── page.ex  # Dialup.App.Users.Id（/users/:id）
```

### root.html.heex

`lib/root.html.heex` は全ページ共通の HTML シェルです。`<head>` タグへの追加、JS ライブラリの読み込み、`Dialup.connect()` のカスタマイズをここで行います。

```html
<!DOCTYPE html>
<html lang="{@lang}">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{@title}</title>
  <!-- ここに <meta>, <link>, analytics を自由に追加 -->
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
</html>
```

`id="dialup-root"` と `Dialup.connect()` は必須です。削除すると動作しません。

### 静的ファイル配信

`priv/static/` に配置したファイルは `/` パスから自動配信されます。

```html
<img src="/images/logo.png">
<link rel="icon" href="/favicon.ico">
```

### コロケーション CSS

`page.ex` / `layout.ex` と同名の `.css` ファイルをコロケーション（同ディレクトリに配置）すると、コンパイル時に自動でスコーピングされて注入される。ビルドツール不要。

```css
/* lib/app/page.css */
.hero {
  text-align: center;
  padding: 4rem 2rem;
}
h1 { font-size: 3rem; }
```

CSS はモジュール名由来の一意なクラス（`d-xxxxxxx`）でラップされ、他ページへの影響を防ぐ。`layout.css` はその layout が包む全子ページに自然にカスケードする。詳細は [Routing](./routing.md#コロケーション-css) を参照。

### 命名規則

| ファイルパス | モジュール名 | URL |
|-------------|-------------|-----|
| `app/page.ex` | `Dialup.App.Page` | `/` |
| `app/layout.ex` | `Dialup.App.Layout` | 全ページ |
| `app/about/page.ex` | `Dialup.App.About` | `/about` |
| `app/users/[id]/page.ex` | `Dialup.App.Users.Id` | `/users/:id` |
| `app/users/layout.ex` | `Dialup.App.Users.Layout` | `/users/*` |

## 基本的な動作確認

ボタンをクリックしてカウントが増えれば成功。ページ遷移はSPAとして動作し、WebSocket経由でサーバーと通信しています。

## Plug ミドルウェア

`use Dialup` に `plugs:` オプションを指定することで、HTTP リクエスト処理のパイプラインにカスタム Plug を追加できる。認証、CORS、ロギングなどに使用する。

```elixir
defmodule MyApp do
  use Application

  use Dialup,
    app_dir: __DIR__ <> "/app",
    title: "My App",
    plugs: [
      MyApp.AuthPlug,
      {Corsica, origins: "*"}
    ]

  # ...
end
```

Plug は指定した順序で実行される。Plug が `conn` を halt した場合、後続の Plug と Dialup の処理はスキップされる。

各 Plug は標準の `Plug` ビヘイビア（`init/1` と `call/2`）を実装する必要がある。

## 次のステップ

- [Routing](./routing.md) - URLとページの対応関係 / コロケーション CSS / エラーページ
- [Lifecycle](./lifecycle.md) - mount/render/handle_event/page_title の流れ
- [Testing](./testing.md) - ページのユニットテスト
- [Telemetry](./telemetry.md) - 計測とモニタリング
