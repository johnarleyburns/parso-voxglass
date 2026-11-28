#!/usr/bin/env bash
# prepare_batch_ids must combine new, changed, and rotating-refresh IDs from
# the upstream listing and only commit the new baseline after a successful run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export GUTENBERG_MIRROR_LIB_ONLY=1
export GUTENBERG_STAGING_DIR="$TMP"
export GUTENBERG_STATE_DIR="$TMP/state"
export GUTENBERG_REFRESH_SCRIPT="$ROOT/scripts/gutenberg-refresh-plan.py"
export GUTENBERG_REFRESH_BATCH_SIZE=0
export ONLY_IDS=""
export GUTENBERG_UPSTREAM_CHECK=1
export GUTENBERG_RSYNC_SOURCE="fake::module"
export GUTENBERG_TRANSFERS=1
export GUTENBERG_CHECKERS=1
mkdir -p "$TMP/catalog" "$TMP/state"

cat > "$TMP/catalog/pg_catalog.csv" <<'EOF'
Type,Text#,Title,Authors,Language,Subjects,Bookshelves,Issued
Text,1,"One","Author","en","Subject","Shelf","2020-01-01"
Text,2,"Two","Author","en","Subject","Shelf","2020-01-01"
Text,3,"Three","Author","en","Subject","Shelf","2020-01-01"
EOF

printf '1\n2\n' > "$TMP/state/uploaded-ids"
printf '1\tepub\t100\t2026/11/20 22:08:43\n' > "$TMP/state/upstream-files"
printf '2\tepub\t200\t2026/11/20 22:08:43\n' >> "$TMP/state/upstream-files"
printf '3\tepub\t300\t2026/11/20 22:08:43\n' >> "$TMP/state/upstream-files"
printf '4\n' > "$TMP/state/refresh-cursor"

cat > "$TMP/rsync" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"--files-from"* && "${FAKE_RSYNC_BATCH_FAIL:-0}" == "1" ]]; then
  exit 1
fi
cat <<'LISTING'
-rw-r--r-- 200 2026/11/25 12:00:00 1/pg1.epub
-rw-r--r-- 200 2026/11/20 22:08:43 2/pg2.epub
-rw-r--r-- 300 2026/11/20 22:08:43 3/pg3.epub
LISTING
EOF
chmod +x "$TMP/rsync"
export PATH="$TMP:$PATH"

# shellcheck source=/dev/null
source "$ROOT/scripts/gutenberg-mirror.sh"

prepare_batch_ids
mapfile -t queued < "$GUTENBERG_REMAINING_IDS_FILE"
[[ "${queued[*]}" == "1 3" ]]
[[ -f "$GUTENBERG_UPSTREAM_PENDING" ]]

# The old baseline stays in place until commit_refresh_plan runs after every
# queued upload succeeds.
[[ "$(grep '^1	epub	100' "$GUTENBERG_UPSTREAM_SNAPSHOT")" == $'1\tepub\t100\t2026/11/20 22:08:43' ]]

export GUTENBERG_BATCH_SIZE=500
export FAKE_RSYNC_BATCH_FAIL=1
if run_batched_books; then
  echo "expected the failing batch to abort the refresh" >&2
  exit 1
fi
[[ "$(grep '^1	epub	100' "$GUTENBERG_UPSTREAM_SNAPSHOT")" == $'1\tepub\t100\t2026/11/20 22:08:43' ]]

unset FAKE_RSYNC_BATCH_FAIL
DRY_RUN=0
commit_refresh_plan
[[ -f "$GUTENBERG_UPSTREAM_SNAPSHOT" ]]
[[ "$(grep -c '^1	epub	200' "$GUTENBERG_UPSTREAM_SNAPSHOT")" == "1" ]]

echo "refresh wiring: ok"
