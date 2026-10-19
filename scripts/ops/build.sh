#!/usr/bin/env bash
# build.sh — reproducible build artifact for AfricAir
# Usage: ./scripts/ops/build.sh <git-ref>
#   <git-ref> can be a branch, tag, or full/short SHA
#
# Exit codes:
#   10  checkout failure (clone/fetch/checkout)
#   20  install failure  (pnpm install)
#   30  test failure     (pnpm check or pnpm test)
#   40  build failure    (pnpm build or pnpm build:api)
#
# Output: africair-<shortsha>.tar.gz + africair-<shortsha>.tar.gz.sha256
set -Eeuo pipefail
trap 'echo "ERROR: build failed at line $LINENO" >&2' ERR

REPO_URL="https://github.com/SirNnadi/AfricAir.git"
ARTIFACT_DIR="$(pwd)"

# ── Help ──────────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  sed -n '2,12p' "$0" | sed 's/^# //'
  exit 0
fi

if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <git-ref>" >&2
  exit 1
fi

GIT_REF="$1"

# ── Checkout ──────────────────────────────────────────────────────────────────
echo "==> [1/5] Checking out $GIT_REF"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

(
  git clone --quiet "$REPO_URL" "$BUILD_DIR" &&
  cd "$BUILD_DIR" &&
  git checkout "$GIT_REF"
) || { echo "ERROR: checkout failed" >&2; exit 10; }

cd "$BUILD_DIR"
SHORT_SHA="$(git rev-parse --short HEAD)"
FULL_SHA="$(git rev-parse HEAD)"
echo "  checked out $FULL_SHA"

# ── Install ───────────────────────────────────────────────────────────────────
echo "==> [2/5] Installing dependencies"
corepack enable
corepack prepare pnpm@10.23.0 --activate
pnpm install --frozen-lockfile || { echo "ERROR: pnpm install failed" >&2; exit 20; }

# ── Quality gates ─────────────────────────────────────────────────────────────
echo "==> [3/5] Running quality gates"
pnpm check || { echo "ERROR: TypeScript check failed" >&2; exit 30; }
pnpm test  || { echo "ERROR: unit tests failed" >&2; exit 30; }

# ── Build ─────────────────────────────────────────────────────────────────────
echo "==> [4/5] Building"
pnpm build     || { echo "ERROR: frontend build failed" >&2; exit 40; }
pnpm build:api || { echo "ERROR: API build failed" >&2; exit 40; }

# Write version.json into dist/
jq -n \
  --arg commit  "$FULL_SHA" \
  --arg ref     "$GIT_REF" \
  --arg builtAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg builtBy "$(whoami)@$(hostname)" \
  --arg nodeVersion "$(node --version)" \
  '{ commit: $commit, ref: $ref, builtAt: $builtAt, builtBy: $builtBy, nodeVersion: $nodeVersion }' \
  > dist/version.json

echo "  version.json: $(cat dist/version.json)"

# ── Package ───────────────────────────────────────────────────────────────────
echo "==> [5/5] Packaging artifact"
ARTIFACT_NAME="africair-${SHORT_SHA}.tar.gz"

# Bundle: frontend dist/ + API server/dist/ + server/migrations/
tar -czf "${ARTIFACT_DIR}/${ARTIFACT_NAME}" \
  dist/ \
  server/dist/ \
  server/migrations/ \
  server/package.json

# Checksum
cd "$ARTIFACT_DIR"
shasum -a 256 "$ARTIFACT_NAME" > "${ARTIFACT_NAME}.sha256"

echo ""
echo "artifact:  ${ARTIFACT_DIR}/${ARTIFACT_NAME}"
echo "checksum:  ${ARTIFACT_DIR}/${ARTIFACT_NAME}.sha256"
echo "commit:    $FULL_SHA"
echo ""
echo "build complete."
