# Deployment

Dialupアプリケーションの本番デプロイ方法。

## リリースビルド

### 1. releases設定

`mix.exs` に追加：

```elixir
def project do
  [
    app: :my_app,
    version: "0.1.0",
    elixir: "~> 1.19",
    start_permanent: Mix.env() == :prod,
    deps: deps(),
    releases: [
      my_app: [
        include_executables_for: [:unix],
        steps: [:assemble, :tar]
      ]
    ]
  ]
end
```

### 2. ビルド

```bash
# 依存取得とコンパイル
MIX_ENV=prod mix deps.get
MIX_ENV=prod mix compile

# リリース作成
MIX_ENV=prod mix release
```

`tar` ステップを含めている場合、`_build/prod/rel/my_app/my_app-0.1.0.tar.gz` が生成される。

### 3. サーバーでの展開

```bash
# サーバーに転送
scp _build/prod/rel/my_app/my_app-0.1.0.tar.gz user@server:/opt/

# サーバーで展開
ssh user@server
cd /opt
mkdir -p my_app
tar -xzf my_app-0.1.0.tar.gz -C my_app
```

### 4. 起動

```bash
/opt/my_app/bin/my_app start

# またはデーモン化
/opt/my_app/bin/my_app daemon

# 停止
/opt/my_app/bin/my_app stop
```

## 環境変数

`runtime.exs` で環境変数を読み込む：

```elixir
# config/runtime.exs
import Config

config :my_app, :port, String.to_integer(System.get_env("PORT", "4000"))
```

`my_app.ex` で使用：

```elixir
port = Application.get_env(:my_app, :port, 4000)
{Dialup, app: __MODULE__, port: port}
```

## systemd設定（Linux）

`/etc/systemd/system/my_app.service`：

```ini
[Unit]
Description=MyApp Dialup Server
After=network.target

[Service]
Type=simple
User=app
WorkingDirectory=/opt/my_app
ExecStart=/opt/my_app/bin/my_app start
ExecStop=/opt/my_app/bin/my_app stop
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

有効化と起動：

```bash
sudo systemctl enable my_app
sudo systemctl start my_app
sudo systemctl status my_app
```

## Docker

Dialup 公式サイト（`site/`）はリポジトリルートの [`Dockerfile`](../Dockerfile) で `mix release` ベースのマルチステージイメージをビルドする。

```bash
docker build -t dialup-site .
docker run -p 4001:4001 -e PORT=4001 dialup-site
```

ローカル検証は `docker compose up -d --build` でも可能（[`docker-compose.yml`](../docker-compose.yml)）。

ランタイムイメージには OTP release のみが含まれ、`bin/dialup_site start` で起動する。

### Dockerfile（mix release・マルチステージ）

```dockerfile
# build ステージ: モノレポ全体をコピーし site/ で mix release
FROM elixir:1.19-alpine AS build
# ... framework + site ソース ...
RUN mix release

# runtime ステージ: release のみ（build ツール・ソースなし）
FROM alpine:3.23 AS runtime
RUN apk add --no-cache libstdc++ openssl ncurses-libs
COPY --from=build /build/site/_build/prod/rel/dialup_site ./
CMD ["bin/dialup_site", "start"]
```

`site/mix.exs` の path 依存 `{:dialup, path: ".."}` はビルドステージでモノレポレイアウトを維持することで release に同梱される。

### 旧: 開発向け単一ステージ（非推奨）

```dockerfile
FROM hexpm/elixir:1.19-erlang-26-alpine-3.18

WORKDIR /app

# ビルド依存
RUN apk add --no-cache build-base git

# 依存インストール
COPY mix.exs mix.lock ./
RUN mix deps.get

# ソースコピーとビルド
COPY . .
RUN MIX_ENV=prod mix compile

EXPOSE 4000

CMD ["mix", "run", "--no-halt"]
```

ビルドと実行：

```bash
docker build -t my_app .
docker run -p 4000:4000 my_app
```

## Fly.io（推奨）

### 1. インストール

```bash
brew install flyctl
fly auth login
```

### 2. アプリ作成

```bash
cd my_app
fly launch
```

### 3. デプロイ

```bash
fly deploy
```

`fly.toml` 例：

```toml
app = "my-app"

[http_service]
  internal_port = 4000
  force_https = true

[env]
  MIX_ENV = "prod"
```

## HTTPS（リバースプロキシ）

Dialupは直接TLSを終端しないため、Nginx等のリバースプロキシでHTTPSを処理する。WebSocketの`Upgrade`ヘッダー転送が必要。

### Nginx設定例

```nginx
upstream dialup {
    server 127.0.0.1:4000;
}

server {
    listen 443 ssl http2;
    server_name example.com;

    ssl_certificate /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;

    location / {
        proxy_pass http://dialup;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 86400s;
    }
}

server {
    listen 80;
    server_name example.com;
    return 301 https://$host$request_uri;
}
```

`proxy_read_timeout` を長めに設定しないと、Nginx がアイドル状態のWebSocket接続を切断する。

### Caddy設定例（自動HTTPS）

```
example.com {
    reverse_proxy localhost:4000
}
```

CaddyはWebSocketの転送とLet's Encrypt証明書の自動取得をデフォルトでサポートする。

## WebSocket オリジン検証

本番環境では、悪意あるサイトからの cross-origin WebSocket 接続を防ぐために `check_origin` を明示的に設定することを推奨する。

```elixir
use Dialup,
  app_dir: __DIR__ <> "/app",
  check_origin: ["https://example.com", "https://www.example.com"]
```

| 設定値 | 動作 |
|---|---|
| `:conn`（デフォルト） | リクエストの `host` と `Origin` ヘッダのホストを比較。開発環境では自動スキップ |
| `["https://..."]` | 許可するオリジンを明示的にリストで指定（本番推奨） |
| `false` | チェックを無効化（非推奨） |

> **リバースプロキシ使用時の注意**: `:conn` モードでは `conn.host` はリバースプロキシが転送する `Host` ヘッダの値を使用する。Nginx/Caddy の設定で `proxy_set_header Host $host` が正しく設定されていることを確認すること。本番では明示的なリストを指定する方が確実。

## 静的ファイル配信

`priv/static/` に配置したファイルは `/` パスから配信される。

```
priv/static/
├── images/logo.png   → /images/logo.png
├── favicon.ico       → /favicon.ico
└── robots.txt        → /robots.txt
```

本番リリース時は `priv/static/` も含めてビルドされる。

## 注意点

- **PORT環境変数**: 多くのPaaSではPORTが動的に割り当てられる
- **WebSocket**: ロードバランサーがWebSocketをサポートしているか確認（`Upgrade`ヘッダーの転送が必要）
- **ファイルアップロード**: `/tmp` など一時ディレクトリの書き込み権限が必要
- **セッション永続化**: `session_store: :ets` はノード再起動で消える。永続化が必要な場合は外部ストアの検討を

## Dialup 公式サイト本番運用（dialup-framework.org）

モノレポ（`site/` + ルート `Dockerfile`）を UGREEN NAS 上の Coolify VM でホストし、Cloudflare Tunnel で公開する。

**現行構成:** Coolify の GitHub 連携（Deploy Key / GitHub App）は環境上うまく動かなかったため、**GitHub Actions → GHCR → Coolify（イメージ pull）** でデプロイする。VM 上での Elixir コンパイルは行わない。

### アーキテクチャ

```
GitHub (master push)
    │
    └─► GitHub Actions ──► ghcr.io/<owner>/dialup:latest
              │
              └─► Coolify (UGREEN NAS VM) ──► dialup_site :4001
                        ▲
          cloudflared (docker-compose.tunnel.yml)
                        │
               Cloudflare Tunnel
                        │
          https://dialup-framework.org
```

GitHub Actions が `master` push のたびに GHCR へイメージを publish する。Coolify は GHCR から pull してコンテナを起動する。Coolify 側に GitHub webhook はないため、**GHCR への push 後は Coolify 管理 UI から手動で再デプロイ**する（下記「再デプロイ」参照）。

### Phase 1: Coolify VM セットアップ（Issue #4）

UGREEN NAS で VM を作成し、Coolify をインストールする。NAS 本体への直載せではなく **VM 上に構築**する。

| 項目 | 推奨値 |
|------|--------|
| RAM | 3〜4 GB |
| ディスク | 20 GB 以上 |
| OS | Ubuntu 22.04 / 24.04 LTS |
| ネットワーク | ブリッジ（同一 LAN から管理 UI に到達可能） |

VM に SSH したうえで、リポジトリ付属スクリプトを実行できる:

```bash
git clone https://github.com/SouichiroTsujimoto/Dialup.git
cd Dialup
./scripts/vm-setup-coolify.sh
```

手動で行う場合:

1. [Coolify 公式インストール](https://coolify.io/docs/get-started/installation)に従い Docker + Coolify をセットアップ
2. 同一 LAN から Coolify 管理 UI にアクセスできることを確認
3. **VM スナップショットを取得**（ロールバック用）

### Phase 2: Coolify + GHCR で site/ をデプロイ（Issue #5 / #8）

GitHub Actions でイメージをビルドし GHCR に publish する。Coolify はリポジトリを clone して Dockerfile ビルドするのではなく、**既存イメージ pull** でデプロイする。

ワークフロー: [`.github/workflows/docker-publish.yml`](../.github/workflows/docker-publish.yml)

- `master` push（および `workflow_dispatch`）で `ghcr.io/<owner>/dialup` に `latest` と commit SHA タグで publish
- イメージ例: `ghcr.io/souichirotsujimoto/dialup:latest`

#### Coolify アプリ設定

| 項目 | 値 |
|------|-----|
| デプロイ方式 | **Docker Image**（既存イメージ pull） |
| Image | `ghcr.io/souichirotsujimoto/dialup:latest` |
| Port | `4001` |
| 環境変数 | `PORT=4001`, `MIX_ENV=prod` |
| GHCR 認証 | GitHub PAT（`read:packages`）または Deploy Token |

GitHub 連携（Deploy Key / GitHub App）と Auto Deploy は**使わない**。Coolify からリポジトリへ直接アクセスする必要がない。

#### 初回セットアップ手順

1. `master` に merge し、[Actions の Docker Publish](https://github.com/SouichiroTsujimoto/Dialup/actions/workflows/docker-publish.yml) が成功し GHCR にイメージがあることを確認
2. Coolify に上記のとおり Docker Image アプリを登録し、GHCR 認証を設定
3. 手動デプロイで pull・起動を確認
4. VM 内から `http://127.0.0.1:4001` で agent demo / docs ページを表示確認

#### 再デプロイ

`master` への merge だけでは Coolify 上のコンテナは自動更新されない。

1. `master` に merge（または [workflow_dispatch](https://github.com/SouichiroTsujimoto/Dialup/actions/workflows/docker-publish.yml) で手動実行）
2. GitHub Actions の **Docker Publish** が完了するまで待つ
3. Coolify 管理 UI で対象アプリの **Redeploy**（または **Pull latest image & restart**）を実行

特定コミットを pin したい場合は、Coolify の Image タグを SHA タグ（例: `ghcr.io/souichirotsujimoto/dialup:abc1234`）に変更してからデプロイする。

#### 代替: Coolify GitHub 連携 + Dockerfile ビルド（未採用）

Coolify の GitHub 連携を有効にし、リポジトリから Dockerfile をビルドする方式も想定していたが、本番 VM では連携が確立できなかった。NAS RAM 7.5 GB・VM 3〜4 GB 割当では VM 上での Elixir コンパイルは OOM や極端な遅延のリスクもあり、GHCR 経由を採用している。

### Phase 3: Cloudflare Tunnel 切替（Issue #6）

Coolify 上のアプリが VM 内で安定稼働していることを確認してから、トンネルの向き先を切り替える。

リポジトリにはアプリとトンネルを分離済み:

- アプリ: [`docker-compose.yml`](../docker-compose.yml)（ローカル検証用）
- トンネル: [`docker-compose.tunnel.yml`](../docker-compose.tunnel.yml)（`network_mode: host`）

**推奨: VM 上で `docker-compose.tunnel.yml` を別管理**（Coolify アプリネットワークと疎結合）。

1. Cloudflare Zero Trust でトンネルのパブリックホスト名を `http://127.0.0.1:4001` に設定
2. VM 上でトンネル起動:

```bash
export CLOUDFLARE_TUNNEL_TOKEN="<token>"
./scripts/start-cloudflare-tunnel.sh
```

3. 本番確認:
   - `https://dialup-framework.org` の表示
   - WebSocket `/ws`
   - agent MCP `POST /agent/:token`
4. **旧 NAS compose の app コンテナを停止**してもサイトが稼働することを確認

#### ロールバック

- 旧 compose は **1 週間は停止のみ**（削除しない）で保持
- Cloudflare トンネル設定のスクリーンショット / メモを残す

### Phase 4: 旧構成撤去（Issue #7）

トンネル切替完了後:

1. NAS 上の旧 2 リポジトリ clone / 旧 compose プロセスを停止
2. 1 週間経過後: 旧 compose ファイル・`.env` を削除
3. ローカルに旧 `dialup_site/` ディレクトリが残っていれば削除（任意）

ローカル再現手順:

```bash
git clone https://github.com/SouichiroTsujimoto/Dialup.git
cd Dialup
docker compose up -d --build
# トンネルは docker-compose.tunnel.yml で別管理
```

### チェックリスト（Issue 対応表）

| Issue | 完了条件 |
|-------|----------|
| #4 | Coolify ダッシュボードが VM 上で安定、LAN から管理 UI に到達可能 |
| #5 | GHCR イメージで Coolify デプロイ、VM 上でサイト表示 |
| #6 | `dialup-framework.org` が Coolify 先を指す、旧 app 停止後も稼働 |
| #7 | 旧デプロイプロセスなし、本ドキュメントだけで再デプロイ可能 |
| #8 | VM でコンパイルなし（Actions → GHCR → Coolify pull）、再デプロイ手順が明文化されている |
| #9 | ランタイムイメージに build ツール・ソースなし、`bin/dialup_site start` で起動 |
