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
└── lib/
    ├── my_app.ex        # Applicationモジュール
    └── app/
        ├── layout.ex    # Dialup.App.Layout（ルートレイアウト）
        └── page.ex      # Dialup.App.Root（ホームページ）
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

### 3. 最初のページ作成

`lib/app/page.ex` を作成：

```elixir
defmodule Dialup.App.Root do
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

### 4. レイアウトの追加（オプション）

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

> **注意**: Layoutは `<main id="dialup-root">` の**中身**のみを生成
> `<html>`, `<head>`, `<body>` タグはDialup組み込みのShellが担当

### 5. 起動

```bash
mix run --no-halt
```

## 開発時ホットリロード

開発環境（`Mix.env() == :dev`）では自動的に `Dialup.Reloader` が起動します。`lib/` 以下の `.ex` ファイルを保存するたびに：

1. 変更を検出（ポーリング間隔: 500ms）
2. 自動でリコンパイル
3. 既存のWebSocket経由でブラウザを更新（ページリロードなし）

## プロジェクト構成

推奨ディレクトリ構造：

```
lib/
├── my_app.ex              # Applicationモジュール（use Dialup）
└── app/
    ├── layout.ex          # Dialup.App.Layout（共通レイアウト）
    ├── page.ex            # Dialup.App.Root（/ ルートページ）
    ├── about/
    │   └── page.ex        # Dialup.App.About（/about）
    └── users/
        ├── [id]/
        │   └── page.ex    # Dialup.App.Users.Id（/users/:id）
        └── layout.ex      # Dialup.App.Users.Layout（/users以下のレイアウト）
```

### 命名規則

| ファイルパス | モジュール名 | URL |
|-------------|-------------|-----|
| `app/page.ex` | `Dialup.App.Root` | `/` |
| `app/layout.ex` | `Dialup.App.Layout` | 全ページ |
| `app/about/page.ex` | `Dialup.App.About` | `/about` |
| `app/users/[id]/page.ex` | `Dialup.App.Users.Id` | `/users/:id` |
| `app/users/layout.ex` | `Dialup.App.Users.Layout` | `/users/*` |

## 基本的な動作確認

ボタンをクリックしてカウントが増えれば成功。ページ遷移はSPAとして動作し、WebSocket経由でサーバーと通信しています。

## 次のステップ

- [Routing](./routing.md) - URLとページの対応関係
- [Lifecycle](./lifecycle.md) - mount/render/handle_eventの流れ
