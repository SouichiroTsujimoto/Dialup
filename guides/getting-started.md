# Getting Started

Dialupフレームワークを使ったアプリケーションの作成方法。

## 前提条件

- Elixir 1.19以上
- 基本的なElixir/Phoenixの知識（推奨）

## インストール

### 1. 新規プロジェクト作成

```bash
mix new my_app --sup
cd my_app
```

### 2. dialupの依存追加

`mix.exs` に追加：

```elixir
defp deps do
  [
    {:dialup, path: "../dialup"}  # 開発中はpath指定
    # {:dialup, "~> 0.1.0"}        # hex公開後
  ]
end
```

```bash
mix deps.get
```

### 3. アプリケーション設定

`lib/my_app.ex` を作成：

```elixir
defmodule MyApp do
  use Application
  use Dialup, app_dir: __DIR__ <> "/app"

  @impl Application
  def start(_type, _args) do
    children = [
      {Dialup, app: __MODULE__, port: 4000}
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: __MODULE__.Supervisor
    )
  end
end
```

### 4. 最初のページ作成

`lib/app/page.ex` を作成：

```elixir
defmodule MyApp.Page do
  use Dialup.Page

  def mount(_params, assigns) do
    {:ok, assigns |> set_default(%{count: 0})}
  end

  def handle_event("increment", _value, assigns) do
    {:update, Map.update!(assigns, :count, &(&1 + 1))}
  end

  def render(assigns) do
    ~H"""
    <h1>Hello Dialup</h1>
    <p>Count: {@count}</p>
    <button ws-event="increment">+</button>
    """
  end
end
```

### 5. 起動

```bash
mix run --no-halt
```

ブラウザで `http://localhost:4000` にアクセス。

## プロジェクト構成

推奨ディレクトリ構造：

```
lib/
├── my_app.ex              # Applicationモジュール
└── app/
    ├── layout.ex          # 共通レイアウト（オプション）
    ├── page.ex            # /（ルートページ）
    ├── about/
    │   └── page.ex        # /about
    └── users/
        ├── [id]/
        │   └── page.ex    # /users/:id（動的ルート）
        └── layout.ex      # /users以下の共通レイアウト
```

## 基本的な動作確認

ボタンをクリックしてカウントが増えれば成功。ページ遷移はSPAとして動作し、WebSocket経由でサーバーと通信している。

## 次のステップ

- [Routing](./routing.md) - URLとページの対応関係
- [Lifecycle](./lifecycle.md) - mount/render/handle_eventの流れ
