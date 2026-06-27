---
name: publish-new-version
description: Dialup フレームワークの新バージョンを Hex に公開する。公開前に mix docs と dialup-site の整合確認、検証、Hex publish まで完遂する。ユーザーが新バージョン公開・Hex publish・バージョンアップを依頼したときに使う。
disable-model-invocation: true
---

# Dialup 新バージョン公開

Dialup フレームワーク（`:dialup` Hex パッケージ）の新バージョンを公開するワークフロー。
**公開前に mix docs と dialup-site の整合確認を必須ゲートとする。**

## 前提

- 対象パッケージ: `:dialup`（ルート `mix.exs`）
- 公開先: Hex（`mix hex.publish`）
- HexDocs: `mix docs` → https://dialup.hexdocs.pm
- 公式サイト docs: `site/lib/app/docs/` → https://dialup-framework.org/docs

## 停止条件（いずれかに該当したら公開しない）

- 公開バージョンが未確定、または Hex 上の既存バージョンと衝突する
- 未整理の dirty tree があり、公開対象外の変更が混在している
- **mix docs 整合ゲート** または **dialup-site 整合ゲート** が未通過
- `mix format --check-formatted` / `mix test` / `mix docs` / `site` compile が失敗
- `mix hex.build` または `mix hex.publish --dry-run` が失敗
- Hex 認証不足（`mix hex.user` / `HEX_API_KEY` 未設定）

## 手順

### 1. 事前調査

1. `git status` と変更差分を確認し、今回のリリースに含める変更を特定する
2. ルート `mix.exs` の `version` を確認し、ユーザー指定がなければ semver に沿った次バージョンを提案する
3. Hex 上の最新版と衝突しないか確認する（`mix hex.info dialup` が使えれば実行）

### 2. mix docs 整合ゲート（必須）

フレームワーク変更に対して **HexDocs（mix docs）が実態に追随しているか** を確認する。

#### 2a. `mix.exs` の docs 設定

- `version` が公開予定バージョンと一致しているか
- `package/0` の `files` に `lib`, `priv`, `guides`, `README.md`, `README.ja.md`, `LICENSE`, `AGENTS.md` が含まれているか
- `docs.extras` に公開すべき `guides/*.md` がすべて登録されているか
- `groups_for_extras` が `extras` と矛盾していないか

**既知の確認ポイント:** `guides/file-upload.md` と `guides/agent-pitfalls.md` は `guides/README.md` に掲載されているが、`docs.extras` に未登録の可能性がある。リリースに含めるべきガイドなら `mix.exs` を更新してから続行する。

#### 2b. API ドキュメント（`lib/`）

変更されたモジュールについて:

- `@moduledoc` / `@doc` が実装と一致しているか
- 新規 public API にドキュメントがあるか
- 削除・リネームした API の記述が残っていないか

#### 2c. guides（`guides/`）

フレームワーク変更に対応するガイドが更新されているか:

- Getting Started, Routing, State Management, Lifecycle, Events
- MCP 関連: `mcp-api.md`, `agent-native-app-development.md`, `agent-handoff.md`, `agent-pitfalls.md`
- その他変更に関係するガイド（`file-upload.md`, `deployment.md` など）

#### 2d. README

- `README.md` / `README.ja.md` の Quick Start、機能一覧、リンクが実態と一致しているか

#### 2e. 判定

- **PASS:** 上記が実態と一致、または今回の変更に docs 更新が不要な理由を明記できる
- **FAIL:** 不整合がある → 先に docs を修正し、ゲートを再実行する

### 3. dialup-site 整合ゲート（必須）

公式サイト（`site/`）の `/docs` は **guides や mix docs とは別ソース** である。フレームワーク変更に対して **dialup-site が実態に追随しているか** を確認する。

#### 3a. 確認対象ファイル

| ページ | ファイル |
|--------|----------|
| Getting Started (`/docs`) | `site/lib/app/docs/page.ex` |
| Architecture (`/docs/concepts`) | `site/lib/app/docs/concepts/page.ex` |
| API Reference (`/docs/api`) | `site/lib/app/docs/api/page.ex` |

関連導線:

- `site/lib/app/layout.ex` — ナビリンク
- `site/lib/app/page.ex` — トップページからの導線
- `site/lib/app/demo/`, `site/lib/app/agent_demo/` — デモが API 変更の影響を受ける場合

#### 3b. 確認内容

- インストール手順（`mix archive.install hex dialup_new`, `mix dialup.new`）が `guides/getting-started.md` と一致しているか
- `use Dialup` オプション、レイアウト/ページ API、`handle_event` 戻り値、HTML 属性の説明が `lib/` の実装と一致しているか
- アーキテクチャ図（1 タブ = 1 プロセス、WebSocket、HTTP MCP）が現行設計と一致しているか
- コード例がコンパイル可能な現行 API を反映しているか（例: `declare_action` / `<.dialup_action>` の推奨パターン）

#### 3c. 判定

- **PASS:** 3 ページと関連導線が実態と一致、または更新不要な理由を明記できる
- **FAIL:** 不整合がある → 先に `site/lib/app/docs/` を修正し、ゲートを再実行する

### 4. 公開前検証

ルートで:

```bash
mix deps.get
mix format --check-formatted
mix test
mix docs
```

サイトで:

```bash
cd site
mix deps.get
mix compile --warnings-as-errors
```

いずれかが失敗したら公開を中止し、修正する。

### 5. パッケージ内容確認

```bash
mix hex.build
mix hex.publish --dry-run
```

- tarball に意図したファイルだけが含まれているか確認する
- `package/0` の `files` と実際の tarball の差分がないか確認する

### 6. 公開

すべてのゲートと検証を通過したら:

```bash
mix hex.publish
```

- 対話プロンプトが出たら、内容を確認してから承認する
- 公開後、`mix hex.info dialup` でバージョンが反映されたか確認する（可能なら）

### 7. 公開後レポート

ユーザーに以下を報告する:

1. 公開バージョン番号
2. mix docs 整合ゲートの結果（PASS / 修正内容 / 更新不要の理由）
3. dialup-site 整合ゲートの結果（PASS / 修正内容 / 更新不要の理由）
4. 実行したコマンドとその成否
5. HexDocs URL（`https://dialup.hexdocs.pm`）と公式サイト URL（`https://dialup-framework.org/docs`）
6. 未コミットの変更や、別途デプロイが必要な作業（dialup-site 本番デプロイなど）があれば明記する

## 補足

- `dialup_new` アーカイブの公開はこの skill の対象外。フレームワーク本体（`:dialup`）のみを扱う
- dialup-site の本番デプロイ（GHCR / Coolify）は `guides/deployment.md` を参照。Hex 公開とサイトデプロイは別作業
- docs と site docs は自動同期されない。フレームワーク API や Getting Started を変えたら **両方** を確認する
