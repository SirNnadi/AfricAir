#!/usr/bin/env bash
# deploy.sh — zero-downtime deployment for AfricAir
# Usage: sudo ./scripts/ops/deploy.sh <artifact.tar.gz>
#
# What it does:
#   1. Verifies the artifact checksum
#   2. Extracts to /opt/africair/releases/<timestamp>-<sha>/
#   3. Atomically switches the current symlink
#   4. Reloads nginx (after config test)
#   5. Health checks — auto-rolls back if they fail
#   6. Keeps only the 5 most recent releases
set -Eeuo pipefail
trap 'echo "ERROR: deploy failed at line $LINENO" >&2' ERR

RELEASES_DIR="/opt/africair/releases"
SHARED_DIR="/opt/africair/shared"
CURRENT_LINK="/opt/africair/current"
KEEP_RELEASES=5

# ── Guards ────────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must be run as root (use sudo)" >&2
  exit 1
fi

if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <artifact.tar.gz>" >&2
  exit 1
fi

ARTIFACT="$(realpath "$1")"
CHECKSUM_FILE="${ARTIFACT}.sha256"

if [[ ! -f "$ARTIFACT" ]]; then
  echo "ERROR: artifact not found: $ARTIFACT" >&2
  exit 1
fi

if [[ ! -f "$CHECKSUM_FILE" ]]; then
  echo "ERROR: checksum file not found: $CHECKSUM_FILE" >&2
  exit 1
fi

# ── 1. Verify checksum ────────────────────────────────────────────────────────
echo "==> [1/6] Verifying checksum"
cd "$(dirname "$ARTIFACT")"
if ! shasum -a 256 -c "$CHECKSUM_FILE" --status; then
  echo "ERROR: checksum verification failed — aborting" >&2
  exit 1
fi
echo "  checksum OK"

# ── 2. Extract to releases dir ────────────────────────────────────────────────
echo "==> [2/6] Extracting artifact"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
# Pull short SHA from artifact filename: africair-<sha>.tar.gz
SHORT_SHA="$(basename "$ARTIFACT" .tar.gz | cut -d- -f2)"
RELEASE_DIR="${RELEASES_DIR}/${TIMESTAMP}-${SHORT_SHA}"

mkdir -p "$RELEASE_DIR"
tar -xzf "$ARTIFACT" -C "$RELEASE_DIR"
chown -R africair:africair "$RELEASE_DIR"
echo "  extracted to $RELEASE_DIR"

# ── 3. Atomic symlink switch ──────────────────────────────────────────────────
echo "==> [3/6] Switching current symlink"
PREVIOUS_RELEASE=""
if [[ -L "$CURRENT_LINK" ]]; then
  PREVIOUS_RELEASE="$(readlink "$CURRENT_LINK")"
fi

# ln -sfn alone is not atomic: it first removes the old link then creates the
# new one, leaving a window where current does not exist. Using a temp link +
# mv -T replaces the symlink in a single rename(2) syscall — atomic.
TEMP_LINK="${CURRENT_LINK}.next"
ln -sfn "$RELEASE_DIR" "$TEMP_LINK"
mv -T "$TEMP_LINK" "$CURRENT_LINK"
echo "  current -> $RELEASE_DIR"

# ── 4. Reload nginx ───────────────────────────────────────────────────────────
echo "==> [4/6] Reloading nginx"
if nginx -t 2>/dev/null; then
  nginx -s reload
  echo "  nginx reloaded"
else
  echo "ERROR: nginx config test failed — rolling back" >&2
  if [[ -n "$PREVIOUS_RELEASE" ]]; then
    ln -sfn "$PREVIOUS_RELEASE" "$TEMP_LINK"
    mv -T "$TEMP_LINK" "$CURRENT_LINK"
    echo "  rolled back to $PREVIOUS_RELEASE"
  fi
  exit 1
fi

# ── 5. Health check ───────────────────────────────────────────────────────────
echo "==> [5/6] Health checking"
sleep 2  # give nginx a moment to reload

HEALTHZ_STATUS="$(curl -s -o /dev/null -w '%{http_code}' http://localhost/healthz)"
VERSION_COMMIT="$(curl -s http://localhost/version.json | jq -r '.commit // empty' 2>/dev/null || true)"
EXPECTED_COMMIT="$(jq -r '.commit' "${RELEASE_DIR}/dist/version.json")"

ROLLBACK=false
if [[ "$HEALTHZ_STATUS" != "200" ]]; then
  echo "ERROR: /healthz returned $HEALTHZ_STATUS (expected 200)" >&2
  ROLLBACK=true
fi

if [[ "$VERSION_COMMIT" != "$EXPECTED_COMMIT" ]]; then
  echo "ERROR: commit mismatch — got '$VERSION_COMMIT', expected '$EXPECTED_COMMIT'" >&2
  ROLLBACK=true
fi

if [[ "$ROLLBACK" == "true" ]]; then
  echo "==> Auto-rolling back to $PREVIOUS_RELEASE"
  if [[ -n "$PREVIOUS_RELEASE" ]]; then
    ln -sfn "$PREVIOUS_RELEASE" "$TEMP_LINK"
    mv -T "$TEMP_LINK" "$CURRENT_LINK"
    nginx -s reload
    echo "  rolled back to $PREVIOUS_RELEASE"
  else
    echo "  no previous release to roll back to"
  fi
  exit 1
fi

echo "  /healthz: $HEALTHZ_STATUS"
echo "  commit:   $VERSION_COMMIT"

# ── 6. Prune old releases ─────────────────────────────────────────────────────
echo "==> [6/6] Pruning old releases (keeping $KEEP_RELEASES)"
ls -1dt "${RELEASES_DIR}"/*/  | tail -n +$((KEEP_RELEASES + 1)) | while read -r old; do
  echo "  removing $old"
  rm -rf "$old"
done

echo ""
echo "deploy complete: $RELEASE_DIR"
