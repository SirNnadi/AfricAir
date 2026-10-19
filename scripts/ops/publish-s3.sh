#!/usr/bin/env bash
# publish-s3.sh — publish AfricAir dist/ to S3 + invalidate CloudFront
# Usage: ./scripts/ops/publish-s3.sh <dist-dir> <bucket> <distribution-id>
#
# Upload order matters:
#   1. assets/  (hashed filenames, immutable cache) — new JS/CSS is live before index.html
#   2. index.html + version.json (no-cache) — only points at already-uploaded assets
#   3. --delete stale files — only after new index.html is live, so no 404 window
#   4. Invalidate /index.html and /version.json only — assets are content-addressed
#      so their URLs never collide; invalidating /* wastes money and busts the CDN cache
#      for files that haven't changed.
set -Eeuo pipefail
trap 'echo "ERROR: publish failed at line $LINENO" >&2' ERR

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  sed -n '2,4p' "$0" | sed 's/^# //'
  exit 0
fi

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <dist-dir> <bucket> <distribution-id>" >&2
  exit 1
fi

DIST_DIR="$(realpath "$1")"
BUCKET="$2"
DISTRIBUTION_ID="$3"

if [[ ! -d "$DIST_DIR" ]]; then
  echo "ERROR: dist dir not found: $DIST_DIR" >&2
  exit 1
fi

# ── 1. Upload assets/ (immutable, long-lived cache) ──────────────────────────
# These files have content hashes in their names (e.g. index-Bx3kP9aQ.js).
# A new deploy produces new filenames, so old and new assets coexist safely.
# Upload these FIRST so they exist before index.html references them.
echo "==> [1/4] Uploading assets/ (immutable)"
aws s3 sync "${DIST_DIR}/assets/" "s3://${BUCKET}/assets/" \
  --cache-control "public,max-age=31536000,immutable" \
  --no-progress

# ── 2. Upload index.html + version.json (no-cache) ───────────────────────────
# Upload AFTER assets so the new index.html only goes live once all the JS/CSS
# it references is already in S3. Browsers and CloudFront must revalidate these
# on every request so users always get the latest entry point.
echo "==> [2/4] Uploading index.html and version.json (no-cache)"
aws s3 cp "${DIST_DIR}/index.html" "s3://${BUCKET}/index.html" \
  --cache-control "no-cache" \
  --content-type "text/html"

aws s3 cp "${DIST_DIR}/version.json" "s3://${BUCKET}/version.json" \
  --cache-control "no-cache" \
  --content-type "application/json"

# ── 3. Sync remaining files + delete stale ───────────────────────────────────
# --delete removes files that no longer exist in dist/. We run this AFTER the
# new index.html is live so there is no window where a browser fetches the new
# index.html but the old assets it references have already been deleted.
echo "==> [3/4] Syncing remaining files and removing stale"
aws s3 sync "${DIST_DIR}/" "s3://${BUCKET}/" \
  --delete \
  --no-progress \
  --exclude "assets/*" \
  --exclude "index.html" \
  --exclude "version.json"

# ── 4. Invalidate only the no-cache files ────────────────────────────────────
# Assets are content-addressed — their URLs change with every build, so cached
# copies are never stale and don't need invalidation (and each /* invalidation
# costs $0.005 per path beyond the free 1000/month).
echo "==> [4/4] Invalidating /index.html and /version.json"
INVALIDATION_ID="$(aws cloudfront create-invalidation \
  --distribution-id "$DISTRIBUTION_ID" \
  --paths "/index.html" "/version.json" \
  --query 'Invalidation.Id' \
  --output text)"

echo ""
echo "publish complete"
echo "  bucket:       s3://${BUCKET}"
echo "  distribution: $DISTRIBUTION_ID"
echo "  invalidation: $INVALIDATION_ID"
