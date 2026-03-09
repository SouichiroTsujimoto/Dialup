# Dialup (日本語)

WebSocket-first, file-based routing Elixir framework.

[English](./README.md)

## 概要

Dialupは、Next.jsのような開発体験でWebSocketファーストのアプリケーションを構築できるElixirフレームワークです。

### 特徴

- **ファイルベースルーティング** — ファイル配置がそのままURLになります
- **WebSocketファースト** — リアルタイム通信を標準でサポート
- **サーバーサイドステート** — クライアント側の状態管理が不要
- **シンプルなアーキテクチャ** — Phoenix/LiveViewより軽量
- **コロケーションCSS** — `.ex`ファイルの隣に`.css`を置くだけ、コンパイル時に自動スコープ化
- **静的ファイル配信** — `priv/static/`を自動で配信
- **WebSocket origin検証** — クロスオリジン接続をビルトインで保護

## クイックスタート

### 1. ジェネレータのインストール

```bash
mix archive.install hex dialup_new
```

### 2. 新規プロジェクト作成

```bash
mix dialup.new my_app
cd my_app
mix deps.get
mix run --no-halt
```

http://localhost:4000 にアクセス

### 生成されるプロジェクト構成

```
my_app/
├── mix.exs
├── lib/
│   ├── my_app.ex          # Applicationエントリポイント
│   ├── root.html.heex     # HTMLシェル（<head>・hooks・analyticsをカスタマイズ）
│   └── app/
│       ├── layout.ex / layout.css   # ルートレイアウト
│       ├── page.ex   / page.css     # ホームページ（/）
│       └── error.ex  / error.css    # エラーページ（404・500）
└── priv/static/           # 静的ファイル（画像・フォント・favicon）
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
defmodule Dialup.App.Page do
  use Dialup.Page

  def mount(_params, assigns) do
    {:ok, assigns |> set_default(%{count: 0})}
  end

  def handle_event("increment", _value, assigns) do
    {:update, assigns |> overwrite(%{count: assigns.count + 1})}
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

詳細なガイドは `mix docs --open` で参照してください。

ガイドのドキュメント本体は `guides/` にあります：

- [Getting Started](./guides/getting-started.md) — インストールと基本的な使い方
- [Routing](./guides/routing.md) — ルーティングの詳細
- [State Management](./guides/state-management.md) — 状態管理
- [Lifecycle](./guides/lifecycle.md) — ページライフサイクル
- [Events](./guides/events.md) — イベント処理
- [Helpers](./guides/helpers.md) — ヘルパー関数
- [Deployment](./guides/deployment.md) — デプロイ方法
- [Fullstack Example](./guides/fullstack-example.md) — EctoとPubSubを用いた実践的なアプリケーション例

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
