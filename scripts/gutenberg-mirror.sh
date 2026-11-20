#!/usr/bin/env bash
#
# gutenberg-mirror.sh — mirror the useful no-images Project Gutenberg subset to
# Cloudflare R2, with resumable rsync + rclone staging.
#
# Default subset:
#   books/<id>/pg<id>.epub                 (no-images EPUB)
#   books/<id>/pg<id>.cover.medium.jpg     (medium cover, optional)
#   catalog/GUTINDEX.ALL                   (full Gutenberg index)
#   catalog/pg_catalog.csv                 (when gutenberg.org is reachable)
#
# R2 layout (prefix defaults to "gutenberg"):
#   gutenberg/books/<id>/pg<id>.epub
#   gutenberg/books/<id>/pg<id>.cover.medium.jpg
#   gutenberg/catalog/GUTINDEX.ALL
#   gutenberg/catalog/pg_catalog.csv
#
# This script never prints secrets. It uses rsync from an official Gutenberg
# mirror into a local staging directory, then rclone copy into R2. Both tools
# are incremental, so a stopped or interrupted run resumes where it left off.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")"
SCRIPT_NAME="$(basename -- "$SCRIPT_PATH")"

# ---------------------------------------------------------------------------
# Configuration (all overridable from the environment)
# ---------------------------------------------------------------------------

R2_ACCOUNT_ID="${R2_ACCOUNT_ID:-c589b687de910faa1e453b0c1afb4f8c}"
R2_BUCKET="${R2_BUCKET:-voxglass-gutenberg}"
R2_PREFIX="${R2_PREFIX:-gutenberg}"
R2_ENDPOINT="${R2_ENDPOINT:-https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com}"

# rsync module containing <id>/pg<id>.epub + covers.
GUTENBERG_RSYNC_SOURCE="${GUTENBERG_RSYNC_SOURCE:-aleph.gutenberg.org::gutenberg-epub}"
# rsync module containing GUTINDEX.ALL.
GUTENBERG_CATALOG_RSYNC_SOURCE="${GUTENBERG_CATALOG_RSYNC_SOURCE:-aleph.gutenberg.org::gutenberg}"
# gutenberg.org is frequently in maintenance (HTTP 503). A failed CSV fetch is
# a warning; GUTINDEX.ALL from the rsync mirror remains the catalog fallback.
GUTENBERG_CATALOG_URL="${GUTENBERG_CATALOG_URL:-https://www.gutenberg.org/feeds/pg_catalog.csv}"
# The generated rsync module carries pg_catalog.csv even when the website is
# in maintenance. Prefer it over the HTTP feed when the website returns 503.
GUTENBERG_CATALOG_CSV_RSYNC_SOURCE="${GUTENBERG_CATALOG_CSV_RSYNC_SOURCE:-aleph.gutenberg.org::gutenberg-epub/feeds/pg_catalog.csv}"
GUTENBERG_BUILD_INDEX="${GUTENBERG_BUILD_INDEX:-1}"
GUTENBERG_INDEX_SCRIPT="${GUTENBERG_INDEX_SCRIPT:-$SCRIPT_DIR/build-gutenberg-index.py}"
GUTENBERG_INDEX_LANGUAGE="${GUTENBERG_INDEX_LANGUAGE:-en}"

GUTENBERG_STAGING_DIR="${GUTENBERG_STAGING_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/voxglass/gutenberg}"
GUTENBERG_STATE_DIR="${GUTENBERG_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/voxglass-gutenberg-mirror}"

# Upload at most this many books per rsync -> rclone move batch. The batch is
# deleted locally after a successful upload, so local disk stays bounded.
# Set to 0 for the legacy full-tree behavior (requires ~20 GB of local disk).
GUTENBERG_BATCH_SIZE="${GUTENBERG_BATCH_SIZE:-500}"
GUTENBERG_UPLOADED_IDS_FILE="${GUTENBERG_UPLOADED_IDS_FILE:-$GUTENBERG_STATE_DIR/uploaded-ids}"
GUTENBERG_ALL_IDS_FILE="${GUTENBERG_ALL_IDS_FILE:-$GUTENBERG_STATE_DIR/all-ids}"
GUTENBERG_REMAINING_IDS_FILE="${GUTENBERG_REMAINING_IDS_FILE:-$GUTENBERG_STATE_DIR/remaining-ids}"

GUTENBERG_INTERVAL="${GUTENBERG_INTERVAL:-86400}"   # seconds between loop cycles
GUTENBERG_ONLY_IDS="${GUTENBERG_ONLY_IDS:-}"
GUTENBERG_INCLUDE_COVERS="${GUTENBERG_INCLUDE_COVERS:-1}"
GUTENBERG_INCLUDE_ILLUSTRATED="${GUTENBERG_INCLUDE_ILLUSTRATED:-0}"
GUTENBERG_PRUNE="${GUTENBERG_PRUNE:-0}"
GUTENBERG_SKIP_CATALOG="${GUTENBERG_SKIP_CATALOG:-0}"
GUTENBERG_TRANSFERS="${GUTENBERG_TRANSFERS:-8}"
GUTENBERG_CHECKERS="${GUTENBERG_CHECKERS:-16}"

R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:-}"
R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:-}"
RCLONE_BIN="${RCLONE_BIN:-}"

STAGING_BOOKS="$GUTENBERG_STAGING_DIR/books"
STAGING_CATALOG="$GUTENBERG_STAGING_DIR/catalog"
STATE_FILE="$GUTENBERG_STATE_DIR/state"
PID_FILE="$GUTENBERG_STATE_DIR/pid"
LOCK_FILE="$GUTENBERG_STATE_DIR/lock"
LOG_FILE="$GUTENBERG_STATE_DIR/mirror.log"
RCLONE_CONFIG_FILE="$GUTENBERG_STATE_DIR/rclone.conf"
RCLONE_REMOTE="voxglass-gutenberg"

# ---------------------------------------------------------------------------
# Runtime state
# ---------------------------------------------------------------------------

MODE="start"
DRY_RUN=0
RESUME=0
ONLY_IDS_ARG=""
FORWARD_ARGS=()
CURRENT_CHILD=""
STOPPING=0

STATE_STATUS="idle"
STATE_PID=""
STATE_PHASE=""
STATE_STARTED_AT=""
STATE_FINISHED_AT=""
STATE_LAST_EXIT=""
STATE_LAST_RESULT=""
STATE_LAST_ERROR=""
STATE_LOCAL_FILES=""
STATE_LOCAL_BYTES=""
STATE_REMOTE_FILES=""
STATE_REMOTE_BYTES=""
STATE_REMOTE_CHECKED_AT=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

warn() {
  log "WARNING: $*"
}

die() {
  log "ERROR: $*"
  exit 1
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

human_bytes() {
  local bytes="${1:-0}"
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || printf '%s bytes' "$bytes"
  else
    awk -v b="$bytes" 'BEGIN { split("B KiB MiB GiB TiB", u, " "); i=1; while (b >= 1024 && i < 5) { b/=1024; i++ } printf "%.1f%s", b, u[i] }'
  fi
}

validate_only_ids() {
  local id
  for id in $ONLY_IDS; do
    if [[ ! "$id" =~ ^[0-9]+$ ]]; then
      die "--only-ids entries must be numeric Gutenberg IDs (got: $id)"
    fi
  done
}

read_pid() {
  if [[ -r "$PID_FILE" ]]; then
    tr -dc '0-9' < "$PID_FILE"
  fi
}

pid_alive() {
  local pid="${1:-}"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

is_our_process() {
  local pid="${1:-}"
  [[ -n "$pid" ]] || return 1
  if [[ -r "/proc/$pid/cmdline" ]]; then
    tr '\0' ' ' < "/proc/$pid/cmdline" | grep -Fq -- "$SCRIPT_NAME"
  else
    ps -p "$pid" -o args= 2>/dev/null | grep -Fq -- "$SCRIPT_NAME"
  fi
}

worker_running() {
  local pid
  pid="$(read_pid)"
  pid_alive "$pid" && is_our_process "$pid"
}

cleanup_pid() {
  local pid
  pid="$(read_pid)"
  if [[ -n "$pid" && "$pid" == "$$" ]]; then
    rm -f "$PID_FILE"
  fi
}

write_pid() {
  printf '%s\n' "$$" > "$PID_FILE"
  chmod 600 "$PID_FILE" 2>/dev/null || true
}

save_state() {
  local tmp="$STATE_FILE.tmp.$$"
  {
    printf 'STATUS=%s\n' "$STATE_STATUS"
    printf 'PID=%s\n' "$STATE_PID"
    printf 'PHASE=%s\n' "$STATE_PHASE"
    printf 'STARTED_AT=%s\n' "$STATE_STARTED_AT"
    printf 'FINISHED_AT=%s\n' "$STATE_FINISHED_AT"
    printf 'LAST_EXIT=%s\n' "$STATE_LAST_EXIT"
    printf 'LAST_RESULT=%s\n' "$STATE_LAST_RESULT"
    printf 'LAST_ERROR=%s\n' "$STATE_LAST_ERROR"
    printf 'LOCAL_FILES=%s\n' "$STATE_LOCAL_FILES"
    printf 'LOCAL_BYTES=%s\n' "$STATE_LOCAL_BYTES"
    printf 'REMOTE_FILES=%s\n' "$STATE_REMOTE_FILES"
    printf 'REMOTE_BYTES=%s\n' "$STATE_REMOTE_BYTES"
    printf 'REMOTE_CHECKED_AT=%s\n' "$STATE_REMOTE_CHECKED_AT"
  } > "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$STATE_FILE"
}

get_state() {
  local key="$1"
  [[ -r "$STATE_FILE" ]] || return 0
  grep -m1 "^${key}=" "$STATE_FILE" 2>/dev/null | cut -d= -f2- || true
}

load_state() {
  STATE_STATUS="$(get_state STATUS)";        STATE_STATUS="${STATE_STATUS:-idle}"
  STATE_PID="$(get_state PID)"
  STATE_PHASE="$(get_state PHASE)"
  STATE_STARTED_AT="$(get_state STARTED_AT)"
  STATE_FINISHED_AT="$(get_state FINISHED_AT)"
  STATE_LAST_EXIT="$(get_state LAST_EXIT)"
  STATE_LAST_RESULT="$(get_state LAST_RESULT)"
  STATE_LAST_ERROR="$(get_state LAST_ERROR)"
  STATE_LOCAL_FILES="$(get_state LOCAL_FILES)"
  STATE_LOCAL_BYTES="$(get_state LOCAL_BYTES)"
  STATE_REMOTE_FILES="$(get_state REMOTE_FILES)"
  STATE_REMOTE_BYTES="$(get_state REMOTE_BYTES)"
  STATE_REMOTE_CHECKED_AT="$(get_state REMOTE_CHECKED_AT)"
}

ensure_dirs() {
  mkdir -p "$STAGING_BOOKS" "$STAGING_CATALOG" "$GUTENBERG_STATE_DIR"
  chmod 700 "$GUTENBERG_STATE_DIR" 2>/dev/null || true
}

resolve_credentials() {
  if [[ -z "$R2_ACCESS_KEY_ID" && -r "$HOME/.r2-access-key-id" ]]; then
    R2_ACCESS_KEY_ID="$(tr -d '\r\n' < "$HOME/.r2-access-key-id")"
  fi
  if [[ -z "$R2_SECRET_ACCESS_KEY" && -r "$HOME/.r2-secret-access-key" ]]; then
    R2_SECRET_ACCESS_KEY="$(tr -d '\r\n' < "$HOME/.r2-secret-access-key")"
  fi
}

require_credentials() {
  resolve_credentials
  if [[ -z "$R2_ACCESS_KEY_ID" || -z "$R2_SECRET_ACCESS_KEY" ]]; then
    die "R2 credentials missing. Set R2_ACCESS_KEY_ID/R2_SECRET_ACCESS_KEY or create ~/.r2-access-key-id and ~/.r2-secret-access-key (mode 600)."
  fi
}

find_rclone() {
  if [[ -n "$RCLONE_BIN" ]]; then
    [[ -x "$RCLONE_BIN" ]] || die "RCLONE_BIN is not executable: $RCLONE_BIN"
    return
  fi
  if command -v rclone >/dev/null 2>&1; then
    RCLONE_BIN="$(command -v rclone)"
  elif [[ -x "$HOME/.local/bin/rclone" ]]; then
    RCLONE_BIN="$HOME/.local/bin/rclone"
  else
    die "rclone not found. Install rclone or set RCLONE_BIN."
  fi
}

write_rclone_config() {
  local tmp="$RCLONE_CONFIG_FILE.tmp.$$"
  (
    umask 077
    cat > "$tmp" <<EOF
[$RCLONE_REMOTE]
type = s3
provider = Cloudflare
access_key_id = $R2_ACCESS_KEY_ID
secret_access_key = $R2_SECRET_ACCESS_KEY
endpoint = $R2_ENDPOINT
region = auto
no_check_bucket = true
EOF
  )
  chmod 600 "$tmp"
  mv -f "$tmp" "$RCLONE_CONFIG_FILE"
}

build_rsync_filters() {
  RSYNC_FILTERS=(--include='*/')
  # Variant EPUBs are pg<id>-images.epub / pg<id>-images-3.epub. The canonical
  # no-images file is pg<id>.epub (no hyphen). Excluding any hyphenated variant
  # keeps logs, MOBI, ZIP, audio and illustrated EPUBs out by default.
  if [[ "$GUTENBERG_INCLUDE_ILLUSTRATED" != "1" ]]; then
    RSYNC_FILTERS+=(--exclude='pg*-*.epub')
  fi
  RSYNC_FILTERS+=(--include='pg*.epub')
  if [[ "$GUTENBERG_INCLUDE_COVERS" == "1" ]]; then
    RSYNC_FILTERS+=(--include='pg*.cover.medium.jpg')
  fi
  RSYNC_FILTERS+=(--exclude='*')
}

# Run a child while remembering its PID so TERM/INT can stop it promptly.
run_child() {
  "$@" &
  CURRENT_CHILD=$!
  local rc=0
  wait "$CURRENT_CHILD" || rc=$?
  CURRENT_CHILD=""
  return "$rc"
}

handle_signal() {
  STOPPING=1
  log "stop requested; terminating current child and leaving resumable state"
  if [[ -n "$CURRENT_CHILD" ]] && kill -0 "$CURRENT_CHILD" 2>/dev/null; then
    kill -TERM "$CURRENT_CHILD" 2>/dev/null || true
    wait "$CURRENT_CHILD" 2>/dev/null || true
  fi
  CURRENT_CHILD=""
  STATE_STATUS="stopped"
  STATE_PHASE="interrupted"
  STATE_FINISHED_AT="$(now_iso)"
  STATE_LAST_EXIT="130"
  STATE_LAST_RESULT="stopped"
  STATE_LAST_ERROR="stopped by signal; rerun --resume to continue"
  save_state
  cleanup_pid
  exit 130
}

install_traps() {
  trap handle_signal TERM INT
  trap cleanup_pid EXIT
}

acquire_lock() {
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    log "another mirror process holds $LOCK_FILE; nothing to do"
    exit 0
  fi
}

# ---------------------------------------------------------------------------
# Stats
# ---------------------------------------------------------------------------

local_stats() {
  if [[ -d "$GUTENBERG_STAGING_DIR" ]]; then
    find "$GUTENBERG_STAGING_DIR" -type f \
      ! -path '*/.rsync-partial/*' \
      ! -name '*.tmp' \
      ! -name '*.tmp.*' \
      -printf '%s\n' 2>/dev/null |
      awk '{ files++; bytes += $1 } END { printf "%d %d\n", files + 0, bytes + 0 }'
  else
    printf '0 0\n'
  fi
}

# Sets REMOTE_FILES / REMOTE_BYTES / REMOTE_ERROR. Returns non-zero on failure.
remote_stats() {
  REMOTE_FILES=""
  REMOTE_BYTES=""
  REMOTE_ERROR=""
  find_rclone
  require_credentials
  ensure_dirs
  write_rclone_config

  local err_file="$GUTENBERG_STATE_DIR/rclone-size.err"
  local json
  if json="$("$RCLONE_BIN" size "$R2_REMOTE_ROOT" --json \
      --config "$RCLONE_CONFIG_FILE" 2>"$err_file")"; then
    REMOTE_FILES="$(printf '%s' "$json" | sed -n 's/.*"count":\([0-9][0-9]*\).*/\1/p')"
    REMOTE_BYTES="$(printf '%s' "$json" | sed -n 's/.*"bytes":\([0-9][0-9]*\).*/\1/p')"
    rm -f "$err_file"
    return 0
  fi

  REMOTE_ERROR="$(tr '\n' ' ' < "$err_file" 2>/dev/null | cut -c1-500)"
  rm -f "$err_file"
  return 1
}

# ---------------------------------------------------------------------------
# Mirror phases
# ---------------------------------------------------------------------------

run_rsync_books() {
  local src="${GUTENBERG_RSYNC_SOURCE%/}"
  local -a args=(
    rsync --no-motd -rltz --partial-dir=.rsync-partial
    --timeout=300 --contimeout=60 --human-readable --stats
  )
  local -a extra=()
  if [[ "$DRY_RUN" == "1" ]]; then extra+=(--dry-run); fi
  if [[ "$GUTENBERG_PRUNE" == "1" ]]; then extra+=(--delete); fi

  build_rsync_filters

  if [[ -n "$ONLY_IDS" ]]; then
    local id
    for id in $ONLY_IDS; do
      log "rsync book $id from $src/$id/"
      mkdir -p "$STAGING_BOOKS/$id"
      run_child "${args[@]}" "${extra[@]}" "${RSYNC_FILTERS[@]}" \
        "$src/$id/" "$STAGING_BOOKS/$id/" || return $?
    done
  else
    log "rsync full no-images EPUB subset from $src (this lists every book directory)"
    run_child "${args[@]}" "${extra[@]}" "${RSYNC_FILTERS[@]}" \
      "$src/" "$STAGING_BOOKS/" || return $?
  fi
}

run_rsync_catalog() {
  if [[ "$GUTENBERG_SKIP_CATALOG" == "1" ]]; then
    log "skipping catalog (GUTENBERG_SKIP_CATALOG/--no-catalog)"
    return 0
  fi
  local src="${GUTENBERG_CATALOG_RSYNC_SOURCE%/GUTINDEX.ALL}"
  src="${src%/}"
  local -a args=(rsync --no-motd -rltz --partial-dir=.rsync-partial --timeout=120 --contimeout=60 --human-readable --stats)
  if [[ "$DRY_RUN" == "1" ]]; then args+=(--dry-run); fi
  mkdir -p "$STAGING_CATALOG"
  log "rsync GUTINDEX.ALL from $src/GUTINDEX.ALL"
  run_child "${args[@]}" "$src/GUTINDEX.ALL" "$STAGING_CATALOG/GUTINDEX.ALL" || return $?
}

fetch_catalog_csv() {
  if [[ "$GUTENBERG_SKIP_CATALOG" == "1" ]]; then
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    log "dry-run: would fetch pg_catalog.csv from $GUTENBERG_CATALOG_URL or rsync"
    return 0
  fi

  mkdir -p "$STAGING_CATALOG"
  local tmp="$STAGING_CATALOG/.pg_catalog.csv.tmp.$$"

  # Prefer the rsync mirror: www.gutenberg.org is frequently in maintenance,
  # and its 503 path can spend a long time in retries. The generated module
  # still has the same CSV.
  log "rsync pg_catalog.csv from $GUTENBERG_CATALOG_CSV_RSYNC_SOURCE"
  if run_child rsync --no-motd -z --timeout=180 --contimeout=30 \
      "$GUTENBERG_CATALOG_CSV_RSYNC_SOURCE" "$tmp" \
      && [[ -s "$tmp" ]] && head -n 1 "$tmp" | grep -q 'Text#'; then
    mv -f "$tmp" "$STAGING_CATALOG/pg_catalog.csv"
    log "saved pg_catalog.csv from rsync"
    return 0
  fi
  rm -f "$tmp"

  if command -v curl >/dev/null 2>&1; then
    log "rsync catalog failed; trying HTTP catalog"
    local rc=0
    run_child curl -fsSL --connect-timeout 5 --max-time 20 \
      -A 'voxglass-gutenberg-mirror/1.0' \
      "$GUTENBERG_CATALOG_URL" -o "$tmp" || rc=$?
    if [[ "$rc" -eq 0 && -s "$tmp" ]] && head -n 1 "$tmp" | grep -q 'Text#'; then
      mv -f "$tmp" "$STAGING_CATALOG/pg_catalog.csv"
      log "saved pg_catalog.csv from HTTP"
      return 0
    fi
    rm -f "$tmp"
  fi

  warn "pg_catalog.csv unavailable; keeping the previous copy and GUTINDEX.ALL"
  return 0
}

build_catalog_index() {
  if [[ "$GUTENBERG_SKIP_CATALOG" == "1" || "$GUTENBERG_BUILD_INDEX" != "1" ]]; then
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    log "dry-run: would build catalog index"
    return 0
  fi
  if [[ ! -s "$STAGING_CATALOG/pg_catalog.csv" ]]; then
    warn "no pg_catalog.csv available; skipping catalog index"
    return 0
  fi
  if [[ ! -x "$GUTENBERG_INDEX_SCRIPT" ]]; then
    warn "index builder not found: $GUTENBERG_INDEX_SCRIPT; skipping catalog index"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 not found; skipping catalog index"
    return 0
  fi

  local -a args=(
    python3 "$GUTENBERG_INDEX_SCRIPT"
    --catalog "$STAGING_CATALOG/pg_catalog.csv"
    --output-dir "$STAGING_CATALOG"
  )
  if [[ "${GUTENBERG_INDEX_LANGUAGE,,}" == "all" ]]; then
    args+=(--all-languages)
  else
    args+=(--language "$GUTENBERG_INDEX_LANGUAGE")
  fi

  log "building on-device catalog index"
  run_child "${args[@]}" || return $?
}

prepare_batch_ids() {
  local catalog="$STAGING_CATALOG/pg_catalog.csv"
  [[ -s "$catalog" ]] || return 1

  python3 - "$catalog" > "$GUTENBERG_ALL_IDS_FILE" <<'PY'
import csv
import sys

with open(sys.argv[1], newline="", encoding="utf-8-sig") as handle:
    for row in csv.DictReader(handle):
        if row.get("Type") != "Text":
            continue
        raw = (row.get("Text#") or "").strip()
        if raw.isdigit():
            print(int(raw))
PY
  LC_ALL=C sort -u -o "$GUTENBERG_ALL_IDS_FILE" "$GUTENBERG_ALL_IDS_FILE"

  if [[ -n "$ONLY_IDS" ]]; then
    printf '%s\n' $ONLY_IDS | LC_ALL=C sort -u > "$GUTENBERG_STATE_DIR/only-ids"
    LC_ALL=C comm -12 "$GUTENBERG_ALL_IDS_FILE" "$GUTENBERG_STATE_DIR/only-ids" > "$GUTENBERG_ALL_IDS_FILE.filtered"
    mv -f "$GUTENBERG_ALL_IDS_FILE.filtered" "$GUTENBERG_ALL_IDS_FILE"
  fi

  touch "$GUTENBERG_UPLOADED_IDS_FILE"
  LC_ALL=C sort -u -o "$GUTENBERG_UPLOADED_IDS_FILE" "$GUTENBERG_UPLOADED_IDS_FILE"
  LC_ALL=C comm -23 "$GUTENBERG_ALL_IDS_FILE" "$GUTENBERG_UPLOADED_IDS_FILE" > "$GUTENBERG_REMAINING_IDS_FILE"
}

rclone_common_args() {
  RCLONE_ARGS=(
    --config "$RCLONE_CONFIG_FILE"
    --transfers "$GUTENBERG_TRANSFERS"
    --checkers "$GUTENBERG_CHECKERS"
    --fast-list
    --s3-no-check-bucket
    --exclude '.rsync-partial/**'
    --exclude '*.tmp'
    --exclude '*.tmp.*'
    --stats 30s
    --stats-one-line
  )
}

run_rclone_move_books() {
  rclone_common_args
  local -a args=(move "${RCLONE_ARGS[@]}" --delete-empty-src-dirs)
  if [[ "$DRY_RUN" == "1" ]]; then args+=(--dry-run -v); fi
  log "rclone move batch books -> $R2_REMOTE_ROOT/books"
  if ! run_child "$RCLONE_BIN" "${args[@]}" "$STAGING_BOOKS" "$R2_REMOTE_ROOT/books"; then
    warn "rclone move failed; this batch remains staged for --resume"
    return 1
  fi
}

run_rclone_catalog() {
  rclone_common_args
  local -a args=(copy "${RCLONE_ARGS[@]}")
  if [[ "$DRY_RUN" == "1" ]]; then args+=(--dry-run -v); fi
  log "rclone copy catalog -> $R2_REMOTE_ROOT/catalog"
  run_child "$RCLONE_BIN" "${args[@]}" "$STAGING_CATALOG" "$R2_REMOTE_ROOT/catalog" || {
    warn "rclone could not write catalog objects to bucket '$R2_BUCKET'."
    return 1
  }
}

run_batched_books() {
  if [[ "$GUTENBERG_BATCH_SIZE" -le 0 ]]; then
    return 1
  fi
  if ! prepare_batch_ids; then
    warn "batch mode needs pg_catalog.csv; use --no-batch to explicitly allow a full local tree"
    return 1
  fi

  local total_ids remaining
  total_ids="$(wc -l < "$GUTENBERG_ALL_IDS_FILE" | tr -d ' ')"
  remaining="$(wc -l < "$GUTENBERG_REMAINING_IDS_FILE" | tr -d ' ')"
  if [[ "$remaining" -eq 0 ]]; then
    log "all $total_ids catalog IDs are already marked uploaded"
    return 0
  fi

  rm -f "$GUTENBERG_STATE_DIR"/batch-*
  local prefix="$GUTENBERG_STATE_DIR/batch-"
  split -l "$GUTENBERG_BATCH_SIZE" "$GUTENBERG_REMAINING_IDS_FILE" "$prefix"
  local batches
  batches=$(find "$GUTENBERG_STATE_DIR" -maxdepth 1 -type f -name 'batch-*' | wc -l | tr -d ' ')
  local index=0
  local batch paths id
  for batch in "$GUTENBERG_STATE_DIR"/batch-*; do
    index=$((index + 1))
    paths="$GUTENBERG_STATE_DIR/batch-paths"
    : > "$paths"
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      echo "$id/pg$id.epub" >> "$paths"
      if [[ "$GUTENBERG_INCLUDE_COVERS" == "1" ]]; then
        echo "$id/pg$id.cover.medium.jpg" >> "$paths"
      fi
      if [[ "$GUTENBERG_INCLUDE_ILLUSTRATED" == "1" ]]; then
        echo "$id/pg$id-images.epub" >> "$paths"
        echo "$id/pg$id-images-3.epub" >> "$paths"
      fi
    done < "$batch"

    STATE_PHASE="batch $index/$batches"; save_state
    local count
    count=$(wc -l < "$batch" | tr -d ' ')
    log "batch $index/$batches: rsync $count IDs"
    if ! run_child rsync --no-motd -rltz --partial-dir=.rsync-partial \
        --timeout=300 --contimeout=60 --ignore-missing-args \
        --files-from="$paths" "${GUTENBERG_RSYNC_SOURCE%/}/" "$STAGING_BOOKS/"; then
      warn "rsync failed for batch $index; staged files are preserved"
      rm -f "$paths"
      return 1
    fi

    if ! run_rclone_move_books; then
      rm -f "$paths"
      return 1
    fi

    cat "$batch" >> "$GUTENBERG_UPLOADED_IDS_FILE"
    LC_ALL=C sort -u -o "$GUTENBERG_UPLOADED_IDS_FILE" "$GUTENBERG_UPLOADED_IDS_FILE"
    rm -f "$batch" "$paths"
    log "batch $index/$batches uploaded; $(wc -l < "$GUTENBERG_UPLOADED_IDS_FILE" | tr -d ' ')/$total_ids IDs complete"
  done
  return 0
}

run_rclone_copy() {
  local -a args=(
    copy
    --config "$RCLONE_CONFIG_FILE"
    --transfers "$GUTENBERG_TRANSFERS"
    --checkers "$GUTENBERG_CHECKERS"
    --fast-list
    --s3-no-check-bucket
    --exclude '.rsync-partial/**'
    --exclude '*.tmp'
    --exclude '*.tmp.*'
    --stats 60s
    --stats-one-line
  )
  if [[ "$DRY_RUN" == "1" ]]; then args+=(--dry-run -v); fi

  log "rclone copy books -> $R2_REMOTE_ROOT/books"
  if ! run_child "$RCLONE_BIN" "${args[@]}" "$STAGING_BOOKS" "$R2_REMOTE_ROOT/books"; then
    warn "rclone could not write to bucket '$R2_BUCKET'. Confirm the bucket exists and the key has Object Read & Write for it (403/NoSuchBucket looks like 'is a file not a directory' here)."
    return 1
  fi

  log "rclone copy catalog -> $R2_REMOTE_ROOT/catalog"
  if ! run_child "$RCLONE_BIN" "${args[@]}" "$STAGING_CATALOG" "$R2_REMOTE_ROOT/catalog"; then
    warn "rclone could not write catalog objects to bucket '$R2_BUCKET'."
    return 1
  fi
}

run_cycle() {
  local rc=0
  local err=""

  STATE_STATUS="running"
  STATE_PID="$$"
  STATE_PHASE="starting"
  STATE_STARTED_AT="$(now_iso)"
  STATE_FINISHED_AT=""
  STATE_LAST_EXIT=""
  STATE_LAST_RESULT=""
  STATE_LAST_ERROR=""
  save_state

  STATE_PHASE="catalog-csv"; save_state
  fetch_catalog_csv

  STATE_PHASE="catalog-index"; save_state
  build_catalog_index || { local r=$?; [[ $rc -eq 0 ]] && rc=$r; err="${err:+$err; }catalog index failed (exit $r)"; }

  STATE_PHASE="rsync-catalog"; save_state
  run_rsync_catalog || { local r=$?; [[ $rc -eq 0 ]] && rc=$r; err="${err:+$err; }rsync GUTINDEX.ALL failed (exit $r)"; }

  if [[ -z "$R2_ACCESS_KEY_ID" || -z "$R2_SECRET_ACCESS_KEY" ]]; then
    require_credentials
  fi

  if [[ "$GUTENBERG_BATCH_SIZE" -gt 0 ]]; then
    STATE_PHASE="batched-books"; save_state
    run_batched_books || { local r=$?; [[ $rc -eq 0 ]] && rc=$r; err="${err:+$err; }batched book mirror failed (exit $r)"; }
    STATE_PHASE="rclone-catalog"; save_state
    run_rclone_catalog || { local r=$?; [[ $rc -eq 0 ]] && rc=$r; err="${err:+$err; }rclone catalog copy failed (exit $r)"; }
  else
    STATE_PHASE="rsync-books"; save_state
    run_rsync_books || { local r=$?; [[ $rc -eq 0 ]] && rc=$r; err="${err:+$err; }rsync books failed (exit $r)"; }
    STATE_PHASE="rclone"; save_state
    run_rclone_copy || { local r=$?; [[ $rc -eq 0 ]] && rc=$r; err="${err:+$err; }rclone copy failed (exit $r)"; }
  fi

  local stats files bytes
  stats="$(local_stats)"
  read -r files bytes <<< "$stats"
  STATE_LOCAL_FILES="$files"
  STATE_LOCAL_BYTES="$bytes"
  STATE_FINISHED_AT="$(now_iso)"
  STATE_LAST_EXIT="$rc"

  if [[ "$rc" -eq 0 ]]; then
    STATE_STATUS="idle"
    if [[ "$DRY_RUN" == "1" ]]; then STATE_LAST_RESULT="dry-run"; else STATE_LAST_RESULT="success"; fi
    STATE_LAST_ERROR=""
  else
    STATE_STATUS="error"
    STATE_LAST_RESULT="failure"
    STATE_LAST_ERROR="${err:-one or more phases failed}"
  fi
  STATE_PHASE="done"
  save_state

  if [[ "$rc" -eq 0 ]]; then
    log "cycle complete: ${files} local files, $(human_bytes "$bytes")"
  else
    log "cycle failed: $STATE_LAST_ERROR"
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------

run_once() {
  ensure_dirs
  require_credentials
  find_rclone
  write_rclone_config
  acquire_lock
  write_pid
  install_traps
  local rc=0
  run_cycle || rc=$?
  cleanup_pid
  return "$rc"
}

run_loop() {
  ensure_dirs
  require_credentials
  find_rclone
  write_rclone_config
  acquire_lock
  write_pid
  install_traps
  log "mirror loop started (pid $$), interval ${GUTENBERG_INTERVAL}s"
  while true; do
    local rc=0
    run_cycle || rc=$?
    if [[ "$STOPPING" == "1" ]]; then break; fi
    log "sleeping ${GUTENBERG_INTERVAL}s before next cycle (last exit $rc)"
    run_child sleep "$GUTENBERG_INTERVAL" || true
    if [[ "$STOPPING" == "1" ]]; then break; fi
  done
  cleanup_pid
}

start_background() {
  ensure_dirs
  if worker_running; then
    log "already running (pid $(read_pid)); use --status or --stop"
    return 0
  fi
  if ! ( exec 9>"$LOCK_FILE"; flock -n 9 ); then
    log "cannot start: $LOCK_FILE is held by another process"
    return 0
  fi
  rm -f "$PID_FILE"

  if [[ -f "$LOG_FILE" ]] && [[ "$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)" -gt 10485760 ]]; then
    mv -f "$LOG_FILE" "$LOG_FILE.1"
  fi

  local -a fwd=(--loop)
  if [[ "${#FORWARD_ARGS[@]}" -gt 0 ]]; then
    fwd+=("${FORWARD_ARGS[@]}")
  fi
  log "starting background mirror loop; log: $LOG_FILE"
  nohup "$SCRIPT_PATH" "${fwd[@]}" >> "$LOG_FILE" 2>&1 < /dev/null &
  local launcher=$!
  local i
  for i in $(seq 1 50); do
    if worker_running; then
      log "started (pid $(read_pid))"
      return 0
    fi
    if ! kill -0 "$launcher" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  log "failed to start background loop; last log lines:"
  tail -n 20 "$LOG_FILE" >&2 || true
  return 1
}

stop_background() {
  local pid
  pid="$(read_pid)"
  if ! pid_alive "$pid"; then
    log "not running"
    rm -f "$PID_FILE"
    return 0
  fi
  if ! is_our_process "$pid"; then
    log "refusing to signal pid $pid: it does not look like $SCRIPT_NAME"
    return 1
  fi
  log "stopping pid $pid"
  kill -TERM "$pid" 2>/dev/null || true
  local i
  for i in $(seq 1 60); do
    if ! pid_alive "$pid"; then
      rm -f "$PID_FILE"
      log "stopped"
      return 0
    fi
    sleep 0.25
  done
  warn "pid $pid did not exit after 15s; sending SIGKILL"
  kill -KILL "$pid" 2>/dev/null || true
  rm -f "$PID_FILE"
  return 0
}

print_status() {
  load_state
  local pid running="no"
  pid="$(read_pid)"
  if pid_alive "$pid" && is_our_process "$pid"; then
    running="yes"
  fi

  local lf lb
  read -r lf lb <<< "$(local_stats)"

  printf 'Gutenberg R2 mirror\n'
  if [[ "$running" == "yes" ]]; then
    printf '  running:        yes (pid %s)\n' "$pid"
  else
    printf '  running:        no\n'
  fi
  printf '  bucket:         %s\n' "$R2_BUCKET"
  printf '  prefix:         %s\n' "$R2_PREFIX"
  printf '  staging:        %s\n' "$GUTENBERG_STAGING_DIR"
  printf '  state:          %s\n' "$GUTENBERG_STATE_DIR"
  printf '  mode:           %s\n' "$(if [[ "$GUTENBERG_INCLUDE_ILLUSTRATED" == "1" ]]; then echo 'no-images + illustrated EPUBs'; else echo 'no-images EPUBs'; fi)"
  printf '  covers:         %s\n' "$(if [[ "$GUTENBERG_INCLUDE_COVERS" == "1" ]]; then echo 'yes'; else echo 'no'; fi)"
  if [[ "$GUTENBERG_BATCH_SIZE" -gt 0 ]]; then
    printf '  batch size:     %s books\n' "$GUTENBERG_BATCH_SIZE"
    if [[ -f "$GUTENBERG_UPLOADED_IDS_FILE" ]]; then
      printf '  uploaded ids:   %s\n' "$(wc -l < "$GUTENBERG_UPLOADED_IDS_FILE" | tr -d ' ')"
    fi
  else
    printf '  batch size:     off (full tree)\n'
  fi
  printf '  local objects:  %s files, %s\n' "$lf" "$(human_bytes "$lb")"
  printf '  last result:    %s (exit %s)\n' "${STATE_LAST_RESULT:-never}" "${STATE_LAST_EXIT:-n/a}"
  printf '  last phase:     %s\n' "${STATE_PHASE:-n/a}"
  printf '  last started:   %s\n' "${STATE_STARTED_AT:-n/a}"
  printf '  last finished:  %s\n' "${STATE_FINISHED_AT:-n/a}"
  if [[ "$STATE_STATUS" == "running" && "$running" != "yes" ]]; then
    printf '  state:          stale (previous run is gone; run --resume)\n'
  fi
  if [[ -n "${STATE_LAST_ERROR:-}" ]]; then
    printf '  last error:     %s\n' "$STATE_LAST_ERROR"
  fi
  if [[ -n "${STATE_REMOTE_FILES:-}" ]]; then
    printf '  remote objects: %s files, %s (verified %s)\n' \
      "$STATE_REMOTE_FILES" "$(human_bytes "${STATE_REMOTE_BYTES:-0}")" "${STATE_REMOTE_CHECKED_AT:-unknown}"
  else
    printf '  remote objects: not verified (run --verify)\n'
  fi
}

verify_remote() {
  load_state
  local lf lb
  read -r lf lb <<< "$(local_stats)"
  printf 'Local:  %s files, %s\n' "$lf" "$(human_bytes "$lb")"

  if remote_stats; then
    printf 'Remote: %s files, %s (%s/%s)\n' \
      "$REMOTE_FILES" "$(human_bytes "$REMOTE_BYTES")" "$R2_BUCKET" "$R2_PREFIX"
    STATE_REMOTE_FILES="$REMOTE_FILES"
    STATE_REMOTE_BYTES="$REMOTE_BYTES"
    STATE_REMOTE_CHECKED_AT="$(now_iso)"
    save_state

    if [[ "$GUTENBERG_BATCH_SIZE" -gt 0 ]]; then
      printf 'Result: remote-only check (batch mode keeps local staging bounded)\n'
      return 0
    fi
    if [[ "$REMOTE_FILES" == "$lf" && "$REMOTE_BYTES" == "$lb" ]]; then
      printf 'Result: match\n'
      return 0
    fi
    printf 'Result: mismatch (local %s/%s, remote %s/%s)\n' "$lf" "$lb" "$REMOTE_FILES" "$REMOTE_BYTES"
    return 1
  fi

  printf 'Remote: unavailable: %s\n' "$REMOTE_ERROR"
  return 1
}

cleanup_local() {
  ensure_dirs
  log "cleaning empty rsync partial directories and stale temp files"
  find "$GUTENBERG_STAGING_DIR" -type d -name '.rsync-partial' -empty -delete 2>/dev/null || true
  find "$STAGING_CATALOG" -maxdepth 1 -type f -name '.pg_catalog.csv.tmp.*' -delete 2>/dev/null || true
  if ! worker_running; then
    rm -f "$PID_FILE"
  fi
  log "cleanup complete"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage: gutenberg-mirror.sh [command] [options]

Commands (default: start):
  start              Start the background mirror loop (equivalent to --loop + nohup)
  --once             Run one rsync + rclone cycle in the foreground
  --loop             Run cycles forever in the foreground (systemd/tmux)
  --resume           Run one cycle now, continuing from local staging and R2
  --stop             Stop the background loop started by `start`
  --status           Show running state, local counts, and last known remote counts
  --verify           Compare local staging counts/sizes with the live R2 prefix
  --cleanup          Remove empty .rsync-partial dirs and stale catalog temp files

Options:
  --only-ids IDS     Mirror only comma/space-separated Gutenberg IDs (testing)
  --no-covers        Skip pg<id>.cover.medium.jpg
  --illustrated      Also mirror illustrated EPUBs (pg<id>-images*.epub)
  --prune            Pass --delete to rsync (remove books deleted upstream)
  --no-catalog       Skip GUTINDEX.ALL / pg_catalog.csv (useful for quick tests)
  --no-index         Skip building the on-device catalog search index
  --batch-size N     Books per local batch (default: 500; 0 = full tree)
  --no-batch         Disable batching and use the legacy full local tree
  --interval SECS    Seconds between loop cycles (default: 86400)
  --dry-run          Pass --dry-run to rsync and rclone; no data or remote changes
  -h, --help         Show this help

Environment:
  R2_ACCOUNT_ID                    Cloudflare account ID
  R2_BUCKET                        Target bucket (default: voxglass-gutenberg)
  R2_PREFIX                        Object prefix (default: gutenberg)
  R2_ACCESS_KEY_ID                 R2 S3 access key (fallback: ~/.r2-access-key-id)
  R2_SECRET_ACCESS_KEY             R2 S3 secret (fallback: ~/.r2-secret-access-key)
  R2_ENDPOINT                      S3 endpoint override
  GUTENBERG_RSYNC_SOURCE           rsync module for <id>/pg<id>.epub
                                   (default: aleph.gutenberg.org::gutenberg-epub)
  GUTENBERG_CATALOG_RSYNC_SOURCE   rsync module containing GUTINDEX.ALL
                                   (default: aleph.gutenberg.org::gutenberg)
  GUTENBERG_CATALOG_URL            pg_catalog.csv URL (default: gutenberg.org feeds)
  GUTENBERG_CATALOG_CSV_RSYNC_SOURCE rsync source for pg_catalog.csv
                                   (default: aleph.gutenberg.org::gutenberg-epub/feeds/pg_catalog.csv)
  GUTENBERG_BUILD_INDEX            0/1 (default: 1; build the on-device index)
  GUTENBERG_INDEX_SCRIPT           index builder path (default: scripts/build-gutenberg-index.py)
  GUTENBERG_INDEX_LANGUAGE         language code for the index, or "all" (default: en)
  GUTENBERG_BATCH_SIZE             Books per upload batch (default: 500; 0 = full tree)
  GUTENBERG_UPLOADED_IDS_FILE      Completed-ID state (default: state/uploaded-ids)
  GUTENBERG_STAGING_DIR            Local staging directory
  GUTENBERG_STATE_DIR              PID/lock/state/log directory
  GUTENBERG_INTERVAL               Loop interval seconds
  GUTENBERG_ONLY_IDS               Same as --only-ids
  GUTENBERG_INCLUDE_COVERS         0/1 (default: 1)
  GUTENBERG_INCLUDE_ILLUSTRATED    0/1 (default: 0)
  GUTENBERG_PRUNE                  0/1 (default: 0)
  GUTENBERG_SKIP_CATALOG           0/1 (default: 0; same as --no-catalog)
  GUTENBERG_TRANSFERS              rclone --transfers (default: 8)
  GUTENBERG_CHECKERS               rclone --checkers (default: 16)
  RCLONE_BIN                       rclone executable path

Examples:
  scripts/gutenberg-mirror.sh --dry-run --only-ids 84
  scripts/gutenberg-mirror.sh --once
  scripts/gutenberg-mirror.sh --loop
  scripts/gutenberg-mirror.sh --status
  scripts/gutenberg-mirror.sh --verify
  scripts/gutenberg-mirror.sh --stop
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    start) MODE="start" ;;
    stop) MODE="stop" ;;
    status) MODE="status" ;;
    verify) MODE="verify" ;;
    resume) MODE="once"; RESUME=1 ;;
    once) MODE="once" ;;
    loop|--foreground) MODE="loop" ;;
    cleanup) MODE="cleanup" ;;
    --start) MODE="start" ;;
    --once) MODE="once" ;;
    --loop) MODE="loop" ;;
    --resume) MODE="once"; RESUME=1 ;;
    --stop) MODE="stop" ;;
    --status) MODE="status" ;;
    --verify) MODE="verify" ;;
    --cleanup) MODE="cleanup" ;;
    --dry-run) DRY_RUN=1 ;;
    --only-ids)
      [[ "$#" -ge 2 ]] || die "--only-ids requires a value"
      ONLY_IDS_ARG="$2"
      FORWARD_ARGS+=(--only-ids "$2")
      shift
      ;;
    --id)
      [[ "$#" -ge 2 ]] || die "--id requires a value"
      ONLY_IDS_ARG="$2"
      FORWARD_ARGS+=(--only-ids "$2")
      shift
      ;;
    --no-covers)
      GUTENBERG_INCLUDE_COVERS=0
      FORWARD_ARGS+=(--no-covers)
      ;;
    --illustrated)
      GUTENBERG_INCLUDE_ILLUSTRATED=1
      FORWARD_ARGS+=(--illustrated)
      ;;
    --prune)
      GUTENBERG_PRUNE=1
      FORWARD_ARGS+=(--prune)
      ;;
    --no-catalog)
      GUTENBERG_SKIP_CATALOG=1
      FORWARD_ARGS+=(--no-catalog)
      ;;
    --no-index)
      GUTENBERG_BUILD_INDEX=0
      FORWARD_ARGS+=(--no-index)
      ;;
    --batch-size)
      [[ "$#" -ge 2 ]] || die "--batch-size requires a value"
      GUTENBERG_BATCH_SIZE="$2"
      FORWARD_ARGS+=(--batch-size "$2")
      shift
      ;;
    --no-batch)
      GUTENBERG_BATCH_SIZE=0
      FORWARD_ARGS+=(--no-batch)
      ;;
    --interval)
      [[ "$#" -ge 2 ]] || die "--interval requires a value"
      GUTENBERG_INTERVAL="$2"
      FORWARD_ARGS+=(--interval "$2")
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1 (try --help)"
      ;;
  esac
  shift
done

if [[ -n "$ONLY_IDS_ARG" ]]; then
  ONLY_IDS="${ONLY_IDS_ARG//,/ }"
else
  ONLY_IDS="${GUTENBERG_ONLY_IDS//,/ }"
fi
validate_only_ids

if [[ ! "$GUTENBERG_INTERVAL" =~ ^[0-9]+$ ]] || [[ "$GUTENBERG_INTERVAL" -lt 1 ]]; then
  die "GUTENBERG_INTERVAL/--interval must be a positive integer"
fi

if [[ ! "$GUTENBERG_BATCH_SIZE" =~ ^[0-9]+$ ]]; then
  die "GUTENBERG_BATCH_SIZE/--batch-size must be a non-negative integer"
fi

R2_PREFIX="${R2_PREFIX#/}"
R2_PREFIX="${R2_PREFIX%/}"
[[ -n "$R2_BUCKET" ]] || die "R2_BUCKET must not be empty"
R2_REMOTE_ROOT="$RCLONE_REMOTE:$R2_BUCKET"
if [[ -n "$R2_PREFIX" ]]; then
  R2_REMOTE_ROOT="$R2_REMOTE_ROOT/$R2_PREFIX"
fi

# A dry run should never daemonize.
if [[ "$DRY_RUN" == "1" && "$MODE" == "start" ]]; then
  MODE="once"
fi

case "$MODE" in
  start)
    start_background
    ;;
  stop)
    stop_background
    ;;
  status)
    print_status
    ;;
  verify)
    verify_remote
    ;;
  cleanup)
    cleanup_local
    ;;
  once)
    if worker_running; then
      log "another mirror run is active (pid $(read_pid)); use --status or --stop"
      exit 0
    fi
    rm -f "$PID_FILE"
    run_once
    ;;
  loop)
    if worker_running && [[ "$(read_pid)" != "$$" ]]; then
      log "another mirror run is active (pid $(read_pid)); use --status or --stop"
      exit 0
    fi
    run_loop
    ;;
  *)
    die "unknown mode: $MODE"
    ;;
esac
