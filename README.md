# Dialup

WebSocket-first, file-based routing Elixir framework.

## 概要

Dialupは、Next.jsのような開発体験でWebSocketファーストのアプリケーションを構築できるElixirフレームワークです。

### 特徴

- **ファイルベースルーティング** - ファイル配置がそのままURLになります
- **WebSocketファースト** - リアルタイム通信を標準でサポート
- **サーバーサイドステート** - クライアント側の状態管理が不要
- **シンプルなアーキテクチャ** - Phoenix/LiveViewより軽量

## クイックスタート

### インストール

```elixir
# mix.exs
def deps do
  [
    {:dialup, "~> 0.1.0"}
  ]
end
```

### 最小構成のアプリ

```elixir
# lib/my_app.ex
defmodule MyApp do
  use Application
  use Dialup, app_dir: __DIR__ <> "/app"

  def start(_type, _args) do
    children = [
      {Dialup, app: __MODULE__, port: 4000}
    ]
    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__.Supervisor)
  end
end
```

```elixir
# lib/app/page.ex
defmodule MyApp.Page do
  use Dialup.Page

  def mount(_params, assigns) do
    {:ok, set_default(%{count: 0}, assigns)}
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

## ドキュメント

詳細なガイドは以下を参照してください：

- [Getting Started](./guides/getting-started.md) - インストールと基本的な使い方
- [Routing](./guides/routing.md) - ルーティングの詳細
- [State Management](./guides/state-management.md) - 状態管理
- [Lifecycle](./guides/lifecycle.md) - ページライフサイクル
- [Events](./guides/events.md) - イベント処理
- [Helpers](./guides/helpers.md) - ヘルパー関数
- [Deployment](./guides/deployment.md) - デプロイ方法

## アーキテクチャ

```
Browser          Elixir Server
   |                    |
dialup.js ←──WS──→ UserSessionProcess (1タブ = 1プロセス)
   |                    |
idiomorph            render/1
                        |
                     assigns (state)
```

## ライセンス

MIT
