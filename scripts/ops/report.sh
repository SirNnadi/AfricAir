#!/usr/bin/env bash
# report.sh — analyse AfricAir nginx JSON access logs
# Usage: ./scripts/ops/report.sh [logfile]
#   logfile defaults to /var/log/nginx/africair.access.json
set -Eeuo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: $0 [logfile]"
  echo "  Prints traffic report from the AfricAir nginx JSON access log."
  echo "  logfile defaults to /var/log/nginx/africair.access.json"
  exit 0
fi

LOG="${1:-/var/log/nginx/africair.access.json}"

if [[ ! -f "$LOG" ]]; then
  echo "ERROR: log file not found: $LOG" >&2
  exit 1
fi

echo "======================================================"
echo " AfricAir Traffic Report"
echo " Log: $LOG"
echo " Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "======================================================"

# ── Top 10 client IPs ─────────────────────────────────────────────────────────
echo ""
echo "--- Top 10 Client IPs ---"
jq -r '.ip' "$LOG" \
  | sort \
  | uniq -c \
  | sort -rn \
  | head -10 \
  | awk '{printf "  %6s requests  %s\n", $1, $2}'

# ── Request counts by status class ───────────────────────────────────────────
echo ""
echo "--- Requests by Status Class ---"
jq -r '.status' "$LOG" \
  | awk '{
      c = int($1/100) * 100
      counts[c]++
    }
    END {
      for (c in counts) printf "  %sxx  %d\n", c/100, counts[c]
    }' \
  | sort

# ── Top 10 most requested paths ──────────────────────────────────────────────
echo ""
echo "--- Top 10 Most Requested Paths ---"
jq -r '.path' "$LOG" \
  | sort \
  | uniq -c \
  | sort -rn \
  | head -10 \
  | awk '{printf "  %6s requests  %s\n", $1, $2}'

# ── Requests per minute for the last hour ────────────────────────────────────
echo ""
echo "--- Requests per Minute (last hour) ---"
SINCE="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M)"
jq -r '.time' "$LOG" \
  | awk -F: -v since="$SINCE" '{
      minute = substr($1,1,16)
      if (minute >= since) counts[minute]++
    }
    END {
      for (m in counts) printf "  %s  %d requests\n", m, counts[m]
    }' \
  | sort \
  | tail -60
