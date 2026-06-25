#!/usr/bin/env bash
# UGREEN NAS VM 上で Coolify をセットアップする（Issue #4）
# Ubuntu 22.04/24.04 LTS を想定。root または sudo 可能なユーザーで実行。
set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
  echo "==> Installing Docker..."
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "${USER}" || true
  echo "Docker installed. Re-login may be required for group membership."
fi

if ! docker info >/dev/null 2>&1; then
  echo "Error: docker daemon not reachable. Start Docker or re-login after group add."
  exit 1
fi

echo "==> Installing Coolify..."
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash

echo ""
echo "Coolify install finished."
echo "Open the dashboard from your LAN (port shown by the installer, typically :8000)."
echo "After verifying the UI, take a VM snapshot for rollback."
