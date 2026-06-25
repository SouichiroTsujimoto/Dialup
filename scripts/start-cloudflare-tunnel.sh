#!/usr/bin/env bash
# Cloudflare Tunnel を Coolify アプリ（localhost:4001）へ向ける（Issue #6）
# VM 上で実行。CLOUDFLARE_TUNNEL_TOKEN は Cloudflare Zero Trust ダッシュボードから取得。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -z "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]]; then
  echo "Set CLOUDFLARE_TUNNEL_TOKEN (tunnel run token from Cloudflare Zero Trust)."
  exit 1
fi

echo "==> Starting cloudflared (host network, points at Coolify app on :4001)..."
echo "    Configure the tunnel public hostname to http://127.0.0.1:4001 in Cloudflare."
docker compose -f docker-compose.tunnel.yml up -d

echo "Tunnel container started. Verify https://dialup-framework.org and /ws."
