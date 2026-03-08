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

### Dockerfile

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

## 注意点

- **PORT環境変数**: 多くのPaaSではPORTが動的に割り当てられる
- **WebSocket**: ロードバランサーがWebSocketをサポートしているか確認（`Upgrade`ヘッダーの転送が必要）
- **ファイルアップロード**: `/tmp` など一時ディレクトリの書き込み権限が必要
- **セッション永続化**: `session_store: :ets` はノード再起動で消える。永続化が必要な場合は外部ストアの検討を
