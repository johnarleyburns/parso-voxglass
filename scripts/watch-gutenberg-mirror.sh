#!/usr/bin/env bash
#
# Print Voxglass Gutenberg mirror progress once an hour (or once with --once).
# This only reads the VPS mirror state; it never downloads Gutenberg data.
#
# Usage:
#   scripts/watch-gutenberg-mirror.sh
#   scripts/watch-gutenberg-mirror.sh --once
#
# Optional:
#   VOXGLASS_VPS_HOST=root@217.76.158.90
#   VOXGLASS_MONITOR_INTERVAL=3600

set -euo pipefail

VPS_HOST="${VOXGLASS_VPS_HOST:-root@217.76.158.90}"
INTERVAL="${VOXGLASS_MONITOR_INTERVAL:-3600}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new)

print_stats() {
  ssh "${SSH_OPTS[@]}" "$VPS_HOST" 'bash -s' <<'REMOTE'
set -uo pipefail
STATE="${VOXGLASS_GUTENBERG_STATE:-/opt/voxglass-gutenberg/state}"
CACHE="${VOXGLASS_GUTENBERG_CACHE:-/opt/voxglass-gutenberg/cache}"
UNIT=voxglass-gutenberg-mirror.service

total=$(wc -l < "$STATE/all-ids" 2>/dev/null || echo 0)
done=$(wc -l < "$STATE/uploaded-ids" 2>/dev/null || echo 0)
pct=$(awk -v d="$done" -v t="$total" 'BEGIN { printf "%.2f", (t > 0 ? 100 * d / t : 0) }')
phase=$(grep '^PHASE=' "$STATE/state" 2>/dev/null | cut -d= -f2-)
service=$(systemctl is-active "$UNIT" || true)
cache=$(du -sm "$CACHE" 2>/dev/null | awk '{print $1}')

declare -A start_epoch
durations=()
total_batches=0
completed_batches=0
now=$(date -u +%s)

while IFS= read -r line; do
  [[ "$line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z) ]] || continue
  iso="${BASH_REMATCH[1]}"
  epoch=$(date -u -d "$iso" +%s 2>/dev/null) || continue
  if [[ "$line" =~ batch[[:space:]]+([0-9]+)/([0-9]+):[[:space:]]+rsync ]]; then
    batch="${BASH_REMATCH[1]}"
    total_batches="${BASH_REMATCH[2]}"
    start_epoch[$batch]=$epoch
  elif [[ "$line" =~ batch[[:space:]]+([0-9]+)/([0-9]+)[[:space:]]+uploaded ]]; then
    batch="${BASH_REMATCH[1]}"
    total_batches="${BASH_REMATCH[2]}"
    completed_batches="$batch"
    if [[ -n "${start_epoch[$batch]:-}" ]]; then
      durations+=("$((epoch - start_epoch[$batch]))")
    fi
  fi
done < <(journalctl -u "$UNIT" --since "-7 days" -o short-iso --no-pager 2>/dev/null |
  grep -E 'batch [0-9]+/[0-9]+' || true)

avg_min="unknown"
eta_utc="unknown"
eta_est="unknown"
if [[ "${#durations[@]}" -gt 0 && "$total_batches" -gt 0 ]]; then
  window=6
  count=${#durations[@]}
  first=$((count > window ? count - window : 0))
  sum=0
  for ((i = first; i < count; i++)); do sum=$((sum + durations[i])); done
  avg_sec=$((sum / (count - first)))
  remaining=$((total_batches - completed_batches))
  eta_epoch=$((now + remaining * avg_sec))
  avg_min=$(awk -v s="$avg_sec" 'BEGIN { printf "%.1f", s / 60 }')
  eta_utc=$(date -u -d "@$eta_epoch" '+%Y-%m-%d %H:%M UTC')
  eta_est=$(TZ=America/New_York date -d "@$eta_epoch" '+%Y-%m-%d %H:%M EST')
fi

printf 'uploaded=%s total=%s percent=%s%% phase=%s service=%s cache_mb=%s batches=%s/%s avg_batch_min=%s eta_utc=%s eta_est=%s\n' \
  "$done" "$total" "$pct" "${phase:-unknown}" "$service" "${cache:-0}" \
  "$completed_batches" "$total_batches" "$avg_min" "$eta_utc" "$eta_est"
REMOTE
}

case "${1:-}" in
  --once)
    print_stats
    ;;
  -h|--help)
    sed -n '2,20p' "$0"
    ;;
  "")
    printf 'Watching Gutenberg mirror on %s every %ss. Ctrl-C to stop.\n' "$VPS_HOST" "$INTERVAL"
    while true; do
      printf '\n[%s]\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
      print_stats || printf 'monitor: SSH/status failed\n'
      sleep "$INTERVAL"
    done
    ;;
  *)
    printf 'Unknown argument: %s\n' "$1" >&2
    exit 2
    ;;
esac
