# Dialup (日本語)

**WebSocket-first のライブ UI** と **自動生成される HTTP MCP API** を備えた、ファイルベースルーティングの Elixir フレームワーク。

[English](./README.md)

## 概要

Dialup は Next.js のような開発体験でライブアプリを構築できる Elixir フレームワークです。
中核は二つあります。人間向け UI は最初から WebSocket-first で動き、HTTP MCP API は同じページ宣言から自動生成されます。
各ページは 1 つの監視されたサーバー側アクターです。UI を `<.dialup_action>` と
`<.dialup_region>` で書くと、Dialup が `tools/list`、`tools/call`、`read_scene` を導出します。
REST API の二重実装は不要です。

```
人間ブラウザ  ──WebSocket──►  UserSessionProcess  ◄──HTTP JSON-RPC──  AI エージェント
                                      │
                               handle_event/3
                                      │
                          declare_action / dialup_action
```

### 特徴

- **WebSocket-first の人間 UI** — `/ws` と idiomorph によるライブ DOM 更新
- **自動生成される HTTP MCP API** — action / region 宣言がそのままエージェントツールになる
- **同じイベント経路** — ブラウザ操作とエージェントの `tools/call` が `handle_event/3` を共有
- **HTTP MCP** — `POST /agent/:token` で `initialize` / `tools/list` / `tools/call`
- **エージェント向け discovery** — `/.well-known/dialup-agent`、ページ埋め込み、`/llms.txt`
- **スコープ付きセッショントークン** — 有効期限・投影・ capability を細かく制御
- **ファイルベースルーティング** — ファイル配置がそのまま URL になる
- **サーバーサイドステート** — 1 タブ = 1 `UserSessionProcess`
- **コロケーション CSS** — `.ex` の隣に `.css`、コンパイル時に自動スコープ化

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

### エージェント対応ページの最小例

```elixir
defmodule Dialup.App.Page do
  use Dialup.Page

  declare_action name: :increment, desc: "カウンタを増やす", params: %{}

  def mount(_params, assigns), do: {:ok, Map.put(assigns, :count, 0)}
  def agent_state(assigns), do: %{count: assigns.count}

  def handle_event(:increment, _, assigns) do
    {:update, Map.update!(assigns, :count, &(&1 + 1))}
  end

  def render(assigns) do
    ~H"""
    <p>Count: {@count}</p>
    <.dialup_action name={:increment}>+1</.dialup_action>
    """
  end
end
```

同じ `<.dialup_action>` が、ブラウザでは WebSocket 経由のボタンになり、エージェントには生成された MCP ツールとして見えます。
ブラウザで操作することも、トークンを取得して API を呼び出すこともできます（詳細は [HTTP MCP API](./guides/mcp-api.md)）:

```bash
curl -X POST http://localhost:4000/agent/TOKEN \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"read_scene","arguments":{}}}'
```

## ドキュメント

`mix docs --open` で全文を参照できます。

- [Events](./guides/events.md) — **WebSocket-first UI のイベントと更新**
- [HTTP MCP API](./guides/mcp-api.md) — **ツール自動生成・discovery・バージョニング**
- [Agent-native アプリ開発](./guides/agent-native-app-development.md) — 実装ワークフロー
- [セッショントークン](./guides/agent-handoff.md) — ライブセッションへの接続
- [Getting Started](./guides/getting-started.md) — インストールと基本

その他は `guides/` を参照（ルーティング、状態管理、デプロイなど）。

## アーキテクチャ

```
Browser (人間)      AI agent (MCP client)
     |                      |
dialup.js ──WS──► UserSessionProcess ◄──POST /agent/:token──
     |                      |
 idiomorph              render/1 + handle_event/3
                             |
                    declare_action / dialup_region
                             │
                      tools/list (HTTP)
```

## ライセンス

MIT
