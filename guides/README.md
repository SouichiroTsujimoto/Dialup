# Dialup Guides

Dialupフレームワークの使用方法について解説するガイド集です。

## ガイド一覧

### はじめに
- [Getting Started](./getting-started.md) - インストールから最初のアプリ作成まで
  - `mix dialup.new` ジェネレータを使ったプロジェクト作成
  - 既存プロジェクトへの手動インストール
- [Fullstack Example](./fullstack-example.md) - Ecto・PubSubを使ったフルスタックアプリの作成例

### 基本概念
- [Routing](./routing.md) - ファイルベースルーティング（静的・動的・クエリパラメータ）
- [State Management](./state-management.md) - session / assigns / params の管理
- [Lifecycle](./lifecycle.md) - ライフサイクル（layout.mount / page.mount / handle_event / handle_info / render）

### 機能別ガイド
- [Events](./events.md) - イベント処理（ws-click, ws-submit, handle_info, redirect）
- [File Upload](./file-upload.md) - ファイルアップロード（HTTP POST経由 / 署名付きURL経由）
- [Helpers](./helpers.md) - 便利なヘルパー関数の使い方
- [Deployment](./deployment.md) - 本番環境へのデプロイ

## 外部ライブラリとの連携

Dialupは以下のライブラリと自然に組み合わせられます：

- **Ecto** - DBアクセス（[Fullstack Example](./fullstack-example.md)を参照）
- **Phoenix.PubSub** - リアルタイム通信（[Fullstack Example](./fullstack-example.md)を参照）

## APIリファレンス

モジュールと関数の詳細仕様はHexDocsを参照：

```bash
cd /path/to/dialup
mix docs --open
```

## 補足資料

- [GitHubリポジトリ](https://github.com/your-name/dialup) - ソースコード
