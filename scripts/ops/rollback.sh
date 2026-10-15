#!/usr/bin/env bash
# rollback.sh — switch current to the previous release
# Usage: sudo ./scripts/ops/rollback.sh
set -Eeuo pipefail
trap 'echo "ERROR: rollback failed at line $LINENO" >&2' ERR

RELEASES_DIR="/opt/africair/releases"
CURRENT_LINK="/opt/africair/current"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must be run as root (use sudo)" >&2
  exit 1
fi

# Get all releases sorted newest first
mapfile -t RELEASES < <(ls -1dt "${RELEASES_DIR}"/*)

if [[ ${#RELEASES[@]} -lt 2 ]]; then
  echo "ERROR: no previous release to roll back to" >&2
  exit 1
fi

CURRENT="$(readlink "$CURRENT_LINK")"
PREVIOUS="${RELEASES[1]}"

if [[ "$CURRENT" == "$PREVIOUS" ]]; then
  echo "ERROR: already on the oldest available release" >&2
  exit 1
fi

echo "  current:  $CURRENT"
echo "  previous: $PREVIOUS"

TEMP_LINK="${CURRENT_LINK}.next"
ln -sfn "$PREVIOUS" "$TEMP_LINK"
mv -T "$TEMP_LINK" "$CURRENT_LINK"

nginx -t 2>/dev/null && nginx -s reload
echo "  nginx reloaded"

echo ""
echo "rollback complete: $PREVIOUS"
