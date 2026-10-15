#!/usr/bin/env bash
# bootstrap.sh — idempotent one-time server setup for AfricAir
# Usage: sudo ./bootstrap.sh
# Safe to run multiple times: a second run changes nothing and exits 0.
set -Eeuo pipefail
trap 'echo "ERROR: bootstrap failed at line $LINENO" >&2' ERR

# ── Guards ────────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must be run as root (use sudo)" >&2
  exit 1
fi

echo "==> [1/6] Installing system packages"
apt-get update -qq

# Node.js 22 LTS via NodeSource
if ! node --version 2>/dev/null | grep -q "^v22\|^v23\|^v24"; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
else
  echo "  node $(node --version) already installed, skipping"
fi

# corepack (ships with Node, just enable it)
corepack enable

# nginx
if ! nginx -v 2>/dev/null; then
  apt-get install -y nginx
else
  echo "  nginx already installed, skipping"
fi

# remaining tools (idempotent: apt skips already-installed packages)
apt-get install -y git ufw jq curl

echo "==> [2/6] Creating system user 'africair'"
if ! id africair &>/dev/null; then
  useradd --system --no-create-home --shell /usr/sbin/nologin africair
  echo "  user 'africair' created"
else
  echo "  user 'africair' already exists, skipping"
fi

echo "==> [3/6] Creating directory layout under /opt/africair"
mkdir -p /opt/africair/{releases,shared}
chown -R africair:africair /opt/africair

# current symlink: only create if it doesn't exist yet
if [[ ! -L /opt/africair/current ]]; then
  echo "  no current symlink yet (will be created by deploy.sh)"
fi

echo "==> [4/6] Configuring ufw"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
echo "  ufw status:"
ufw status verbose

echo "==> [5/6] Enabling and starting nginx"
systemctl enable nginx
systemctl start nginx

echo "==> [6/6] Verifying installation"
echo "  node:    $(node --version)"
echo "  npm:     $(npm --version)"
echo "  corepack: $(corepack --version)"
echo "  nginx:   $(nginx -v 2>&1)"
echo "  git:     $(git --version)"
echo "  jq:      $(jq --version)"
echo "  curl:    $(curl --version | head -1)"
echo "  ufw:     $(ufw status | head -1)"
echo "  /opt/africair layout:"
ls -la /opt/africair/

echo ""
echo "bootstrap complete."
