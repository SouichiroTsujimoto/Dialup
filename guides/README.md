# Dialup Guides

Dialupフレームワークの使用方法について解説するガイド集です。
Dialup の二本柱は、WebSocket-first の人間向け UI と、UI 宣言から自動生成される HTTP MCP API です。

## ガイド一覧

### はじめに
- [Getting Started](./getting-started.md) - インストールから最初のアプリ作成まで
- [Fullstack Example](./fullstack-example.md) - Ecto・PubSubを使ったフルスタックアプリの作成例

### 基本概念
- [Routing](./routing.md) - ファイルベースルーティング（静的・動的・クエリパラメータ）
- [State Management](./state-management.md) - session / assigns / params の管理
- [Lifecycle](./lifecycle.md) - ライフサイクル（layout.mount / page.mount / handle_event / handle_info / render）
- [Events](./events.md) - WebSocket-first UI のイベント処理（ws-event, ws-submit, handle_info, redirect）

### AI エージェント / MCP
- **[HTTP MCP API](./mcp-api.md)** - UI 宣言から自動生成される `tools/list` / `tools/call`
- [Agent-native App Development](./agent-native-app-development.md) - エージェント対応アプリの設計・実装
- [Session tokens](./agent-handoff.md) - ライブセッションへのトークン発行と接続

### 機能別ガイド
- [File Upload](./file-upload.md) - ファイルアップロード（HTTP POST経由 / 署名付きURL経由）
- [Helpers](./helpers.md) - 便利なヘルパー関数の使い方
- [Deployment](./deployment.md) - 本番環境へのデプロイ

## 外部ライブラリとの連携

- **Ecto** - DBアクセス（[Fullstack Example](./fullstack-example.md)を参照）
- **Phoenix.PubSub** - リアルタイム通信（[Fullstack Example](./fullstack-example.md)を参照）

## APIリファレンス

```bash
cd /path/to/dialup
mix docs --open
```

## 補足資料

- [GitHub](https://github.com/SouichiroTsujimoto/Dialup) - ソースコード
- [dialup-framework.org](https://dialup-framework.org/agent_demo) - ライブ MCP デモ
