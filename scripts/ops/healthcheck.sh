#!/usr/bin/env bash
# healthcheck.sh — checks AfricAir is up, logs to journald
# Run via systemd timer every minute.
# After 3 consecutive failures: reloads nginx and logs a WARNING.
set -Eeuo pipefail

STATE_DIR="/var/lib/africair"
FAILURE_FILE="${STATE_DIR}/healthcheck-failures"
MAX_FAILURES=3
URL="http://localhost/healthz"

mkdir -p "$STATE_DIR"

# ── Check ─────────────────────────────────────────────────────────────────────
HTTP_STATUS="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$URL" || echo "000")"

if [[ "$HTTP_STATUS" == "200" ]]; then
  # Reset failure count on success
  echo "0" > "$FAILURE_FILE"
  logger -t africair-health "OK: /healthz returned 200"
  exit 0
fi

# ── Failure handling ──────────────────────────────────────────────────────────
FAILURES=0
if [[ -f "$FAILURE_FILE" ]]; then
  FAILURES="$(cat "$FAILURE_FILE")"
fi
FAILURES=$(( FAILURES + 1 ))
echo "$FAILURES" > "$FAILURE_FILE"

logger -t africair-health "FAIL: /healthz returned $HTTP_STATUS (failure $FAILURES of $MAX_FAILURES)"

if [[ "$FAILURES" -ge "$MAX_FAILURES" ]]; then
  logger -t africair-health "WARNING: $MAX_FAILURES consecutive failures — reloading nginx"
  nginx -s reload
  # Reset count after action so we don't reload on every subsequent failure
  echo "0" > "$FAILURE_FILE"
fi
