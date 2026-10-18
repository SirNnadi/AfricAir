#!/usr/bin/env bash
# deploy.sh — zero-downtime deployment for AfricAir (frontend + API)
# Usage: sudo ./scripts/ops/deploy.sh <artifact.tar.gz>
#
# What it does:
#   1. Verifies the artifact checksum
#   2. Extracts frontend to /opt/africair/releases/<id>/
#      Extracts API to /opt/africair/api/releases/<id>/ and installs prod deps
#   3. Atomically switches both current symlinks
#   4. Reloads nginx (after config test), restarts africair-api.service
#   5. Health checks frontend + API — auto-rolls back both if either fails
#   6. Keeps only the 5 most recent releases for each
set -Eeuo pipefail
trap 'echo "ERROR: deploy failed at line $LINENO" >&2' ERR

RELEASES_DIR="/opt/africair/releases"
SHARED_DIR="/opt/africair/shared"
CURRENT_LINK="/opt/africair/current"

# API release tree — separate from the frontend so each can be rolled back
# independently and the API process always has a stable WorkingDirectory.
API_RELEASES_DIR="/opt/africair/api/releases"
API_CURRENT_LINK="/opt/africair/api/current"

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

# ── 2. Extract to releases dirs ──────────────────────────────────────────────
echo "==> [2/6] Extracting artifact"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
# Pull short SHA from artifact filename: africair-<sha>.tar.gz
SHORT_SHA="$(basename "$ARTIFACT" .tar.gz | cut -d- -f2)"
RELEASE_DIR="${RELEASES_DIR}/${TIMESTAMP}-${SHORT_SHA}"
API_RELEASE_DIR="${API_RELEASES_DIR}/${TIMESTAMP}-${SHORT_SHA}"

# Frontend: the full tarball lands here; nginx serves dist/ from this path.
mkdir -p "$RELEASE_DIR"
tar -xzf "$ARTIFACT" -C "$RELEASE_DIR"
chown -R africair:africair "$RELEASE_DIR"
echo "  frontend extracted to $RELEASE_DIR"

# API: copy only the server pieces out of the already-extracted frontend dir.
# We keep them in a separate tree so the API's WorkingDirectory is clean and
# the africair-api.service ExecStart path never changes: it always points at
# /opt/africair/api/current/server/dist/index.js
mkdir -p "$API_RELEASE_DIR"
cp -r "${RELEASE_DIR}/server/dist"         "${API_RELEASE_DIR}/"
cp -r "${RELEASE_DIR}/server/migrations"   "${API_RELEASE_DIR}/"
cp    "${RELEASE_DIR}/server/package.json" "${API_RELEASE_DIR}/"
cp    "${RELEASE_DIR}/server/pnpm-lock.yaml" "${API_RELEASE_DIR}/"

# Install production-only Node dependencies inside the API release directory.
# --prod omits devDependencies; --frozen-lockfile ensures the exact versions
# from the lockfile are installed, same guarantee as the original build.
pnpm install --prod --frozen-lockfile --dir "$API_RELEASE_DIR" --silent
chown -R africair:africair "$API_RELEASE_DIR"
echo "  API extracted to $API_RELEASE_DIR"

# ── 3. Atomic symlink switch ──────────────────────────────────────────────────
echo "==> [3/6] Switching current symlinks"
PREVIOUS_RELEASE=""
if [[ -L "$CURRENT_LINK" ]]; then
  PREVIOUS_RELEASE="$(readlink "$CURRENT_LINK")"
fi

PREVIOUS_API_RELEASE=""
if [[ -L "$API_CURRENT_LINK" ]]; then
  PREVIOUS_API_RELEASE="$(readlink "$API_CURRENT_LINK")"
fi

# ln -sfn alone is not atomic: it first removes the old link then creates the
# new one, leaving a window where current does not exist. Using a temp link +
# mv -T replaces the symlink in a single rename(2) syscall — atomic.
TEMP_LINK="${CURRENT_LINK}.next"
ln -sfn "$RELEASE_DIR" "$TEMP_LINK"
mv -T "$TEMP_LINK" "$CURRENT_LINK"
echo "  frontend current -> $RELEASE_DIR"

# Same atomic swap for the API. The africair-api.service WorkingDirectory
# points at /opt/africair/api/current, so this is what makes the new code live
# for the API process after the service restarts below.
API_TEMP_LINK="${API_CURRENT_LINK}.next"
ln -sfn "$API_RELEASE_DIR" "$API_TEMP_LINK"
mv -T "$API_TEMP_LINK" "$API_CURRENT_LINK"
echo "  API current     -> $API_RELEASE_DIR"

# ── 4. Reload nginx + restart API ────────────────────────────────────────────
echo "==> [4/6] Reloading nginx and restarting API"
if nginx -t 2>/dev/null; then
  nginx -s reload
  echo "  nginx reloaded"
else
  echo "ERROR: nginx config test failed — rolling back" >&2
  # Restore both symlinks before exiting so the server is left in a known state.
  if [[ -n "$PREVIOUS_RELEASE" ]]; then
    ln -sfn "$PREVIOUS_RELEASE" "$TEMP_LINK"
    mv -T "$TEMP_LINK" "$CURRENT_LINK"
  fi
  if [[ -n "$PREVIOUS_API_RELEASE" ]]; then
    ln -sfn "$PREVIOUS_API_RELEASE" "$API_TEMP_LINK"
    mv -T "$API_TEMP_LINK" "$API_CURRENT_LINK"
  fi
  exit 1
fi

# Restart the API service so it picks up the new /opt/africair/api/current.
# We use restart (not reload) because Node doesn't hot-reload code; the process
# must re-exec. The unit's Restart=on-failure means systemd will bring it back
# if this restart itself fails.
if systemctl is-enabled --quiet africair-api 2>/dev/null; then
  systemctl restart africair-api
  echo "  africair-api restarted"
else
  echo "  africair-api.service not enabled — skipping (API will not be live)"
fi

# ── 5. Health check ───────────────────────────────────────────────────────────
echo "==> [5/6] Health checking"
# Give nginx and the API process time to come up before probing.
sleep 3

HEALTHZ_STATUS="$(curl -s -o /dev/null -w '%{http_code}' http://localhost/healthz)"
VERSION_COMMIT="$(curl -s http://localhost/version.json | jq -r '.commit // empty' 2>/dev/null || true)"
EXPECTED_COMMIT="$(jq -r '.commit' "${RELEASE_DIR}/dist/version.json")"

# /api/healthz is proxied by nginx to port 4000. A 200 here means nginx is
# routing correctly AND the Node process is up and responding.
API_HEALTHZ_STATUS="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost/api/healthz || echo '000')"

ROLLBACK=false
if [[ "$HEALTHZ_STATUS" != "200" ]]; then
  echo "ERROR: /healthz returned $HEALTHZ_STATUS (expected 200)" >&2
  ROLLBACK=true
fi

if [[ "$VERSION_COMMIT" != "$EXPECTED_COMMIT" ]]; then
  echo "ERROR: commit mismatch — got '$VERSION_COMMIT', expected '$EXPECTED_COMMIT'" >&2
  ROLLBACK=true
fi

# Only fail on the API check if the service is actually enabled; if someone
# deploys without the API configured we should not block the frontend rollout.
if systemctl is-enabled --quiet africair-api 2>/dev/null; then
  if [[ "$API_HEALTHZ_STATUS" != "200" ]]; then
    echo "ERROR: /api/healthz returned $API_HEALTHZ_STATUS (expected 200)" >&2
    ROLLBACK=true
  fi
fi

if [[ "$ROLLBACK" == "true" ]]; then
  echo "==> Auto-rolling back"
  if [[ -n "$PREVIOUS_RELEASE" ]]; then
    ln -sfn "$PREVIOUS_RELEASE" "$TEMP_LINK"
    mv -T "$TEMP_LINK" "$CURRENT_LINK"
  fi
  if [[ -n "$PREVIOUS_API_RELEASE" ]]; then
    ln -sfn "$PREVIOUS_API_RELEASE" "$API_TEMP_LINK"
    mv -T "$API_TEMP_LINK" "$API_CURRENT_LINK"
  fi
  nginx -s reload
  systemctl is-enabled --quiet africair-api 2>/dev/null && systemctl restart africair-api || true
  echo "  rolled back frontend to: ${PREVIOUS_RELEASE:-none}"
  echo "  rolled back API to:      ${PREVIOUS_API_RELEASE:-none}"
  exit 1
fi

echo "  /healthz:     $HEALTHZ_STATUS"
echo "  /api/healthz: $API_HEALTHZ_STATUS"
echo "  commit:       $VERSION_COMMIT"

# ── 6. Prune old releases ─────────────────────────────────────────────────────
echo "==> [6/6] Pruning old releases (keeping $KEEP_RELEASES)"

# Frontend releases
ls -1dt "${RELEASES_DIR}"/*/  | tail -n +$((KEEP_RELEASES + 1)) | while read -r old; do
  echo "  removing frontend release: $old"
  rm -rf "$old"
done

# API releases — pruned independently so a frontend-only redeploy doesn't
# accidentally remove an API release that is still current.
ls -1dt "${API_RELEASES_DIR}"/*/  | tail -n +$((KEEP_RELEASES + 1)) | while read -r old; do
  echo "  removing API release: $old"
  rm -rf "$old"
done

echo ""
echo "deploy complete"
echo "  frontend: $RELEASE_DIR"
echo "  API:      $API_RELEASE_DIR"
