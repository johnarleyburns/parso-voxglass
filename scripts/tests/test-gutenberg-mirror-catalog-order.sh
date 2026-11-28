#!/usr/bin/env bash
# The search-index manifest must be uploaded only after every versioned index
# object exists. A failed index upload must leave the previous manifest live.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CATALOG="$TMP/catalog"
LOG="$TMP/rclone.log"
mkdir -p "$CATALOG" "$TMP/state"
printf 'catalog\n' > "$CATALOG/pg_catalog.csv"
printf 'index\n' > "$CATALOG/index-0123456789abcdef.json.zlib"
printf 'manifest\n' > "$CATALOG/manifest.json"

cat > "$TMP/rclone" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_RCLONE_LOG"
if [[ -n "${FAKE_RCLONE_FAIL_ON:-}" && "$*" == *"$FAKE_RCLONE_FAIL_ON"* ]]; then
  exit 1
fi
exit 0
EOF
chmod +x "$TMP/rclone"

export GUTENBERG_MIRROR_LIB_ONLY=1
export RCLONE_BIN="$TMP/rclone"
export FAKE_RCLONE_LOG="$LOG"
export R2_REMOTE_ROOT="voxglass-gutenberg:test/gutenberg"
export R2_BUCKET="test"
export R2_PREFIX="gutenberg"
export GUTENBERG_STAGING_DIR="$TMP"
export GUTENBERG_STATE_DIR="$TMP/state"

# shellcheck source=/dev/null
source "$ROOT/scripts/gutenberg-mirror.sh"

run_rclone_catalog

mapfile -t lines < "$LOG"
[[ "${#lines[@]}" -eq 3 ]]
[[ "${lines[0]}" == *"copy"* ]]
[[ "${lines[0]}" == *"--exclude manifest.json"* ]]
[[ "${lines[0]}" == *"--exclude index-*.json.zlib"* ]]
[[ "${lines[1]}" == *"copyto"*"index-0123456789abcdef.json.zlib"* ]]
[[ "${lines[2]}" == *"copyto"*"manifest.json"* ]]
[[ "${lines[2]}" != *"index-"* ]]

: > "$LOG"
export FAKE_RCLONE_FAIL_ON="index-0123456789abcdef.json.zlib"
if run_rclone_catalog; then
  echo "expected the index upload failure to abort catalog publication" >&2
  exit 1
fi
if grep -q "copyto.*manifest.json" "$LOG"; then
  echo "manifest was uploaded after an index upload failed" >&2
  exit 1
fi

echo "catalog publication ordering: ok"
