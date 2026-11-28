#!/usr/bin/env bash
# A failed book sync or index build must not publish a new catalog manifest.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export GUTENBERG_MIRROR_LIB_ONLY=1
export GUTENBERG_STAGING_DIR="$TMP"
export GUTENBERG_STATE_DIR="$TMP/state"
export R2_ACCESS_KEY_ID=test
export R2_SECRET_ACCESS_KEY=test
export R2_REMOTE_ROOT="test:bucket/gutenberg"
export GUTENBERG_BATCH_SIZE=500

# shellcheck source=/dev/null
source "$ROOT/scripts/gutenberg-mirror.sh"

PUBLISH_LOG="$TMP/published"
BOOKS_RESULT=0
INDEX_RESULT=0

fetch_catalog_csv() { :; }
run_rsync_catalog() { :; }
require_credentials() { :; }
save_state() { :; }
now_iso() { printf '2026-11-27T00:00:00Z'; }
local_stats() { printf '0 0\n'; }
build_catalog_index() { return "$INDEX_RESULT"; }
run_batched_books() { return "$BOOKS_RESULT"; }
run_rclone_catalog() { printf 'published\n' >> "$PUBLISH_LOG"; return 0; }

expect_no_publish() {
  : > "$PUBLISH_LOG"
  if run_cycle; then
    echo "run_cycle unexpectedly succeeded" >&2
    exit 1
  fi
  if [[ -s "$PUBLISH_LOG" ]]; then
    echo "catalog was published despite a failed prerequisite" >&2
    exit 1
  fi
}

BOOKS_RESULT=1
expect_no_publish

BOOKS_RESULT=0
INDEX_RESULT=1
expect_no_publish

BOOKS_RESULT=0
INDEX_RESULT=0
: > "$PUBLISH_LOG"
run_cycle
[[ "$(cat "$PUBLISH_LOG")" == "published" ]]

echo "catalog publication gate: ok"
