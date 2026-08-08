#!/bin/bash
# test.sh — Local UI smoke test suite. The two UI smoke tests in the repo are
# the ONLY UI tests; everything else runs under `swift test`.
# Does NOT run in CI (GitHub Actions runs `swift test` only).
#
# Usage: scripts/test.sh [--device "iPhone 16"] [--watch-device "Apple Watch Series 10 (46mm)"]
#
# With no arguments, defaults to iPhone 16 and the first available Apple Watch.
# --all is retained for compatibility and runs the same two smoke tests:
# iPhone (VoxglassUITests + CarPlay scene) and Watch (VoxglassWatchUITests).

set -euo pipefail

DEVICE_NAME="iPhone 16"
WATCH_DEVICE_NAME=""
RUN_ALL=0

# Parse args before using defaults.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) RUN_ALL=1; shift ;;
    --device) DEVICE_NAME="$2"; shift 2 ;;
    --watch-device) WATCH_DEVICE_NAME="$2"; shift 2 ;;
    *) shift ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

trap 'bash "$SCRIPT_DIR/kill_zombie_test_helpers.sh"' EXIT

echo ""
echo "=== reaping orphaned test helpers from prior runs ==="
bash "$SCRIPT_DIR/kill_zombie_test_helpers.sh"

# ── Phone smoke test ──────────────────────────────────────────────────────────

echo "=== Voxglass phone smoke test (simulator) ==="
echo "Device name: $DEVICE_NAME"
echo ""

if ! xcrun simctl list devices available | grep -q "$DEVICE_NAME ("; then
  echo "ERROR: No available simulator named \"$DEVICE_NAME\" found."
  echo "Available devices:"
  xcrun simctl list devices available | grep -i iphone || true
  exit 1
fi

# The narration smoke step starts a real recording; pre-grant microphone
# access so the permission prompt never blocks it (deterministic runs).
echo "=== granting microphone permission on \"$DEVICE_NAME\" ==="
xcrun simctl boot "$DEVICE_NAME" 2>/dev/null || true
if ! xcrun simctl privacy "$DEVICE_NAME" grant microphone guru.parso.voxglass; then
  echo "WARNING: could not grant microphone permission — the narration record step may fail."
fi

xcodebuild test \
  -scheme Voxglass \
  -project Voxglass.xcodeproj \
  -destination "platform=iOS Simulator,name=$DEVICE_NAME" \
  -quiet

# ── Watch smoke test ──────────────────────────────────────────────────────────

echo ""
echo "=== Voxglass watch smoke test (simulator) ==="

# Auto-detect the first available Apple Watch simulator if none was requested.
if [ -z "$WATCH_DEVICE_NAME" ]; then
  WATCH_DEVICE_NAME=$(xcrun simctl list devices available | grep -E "Apple Watch|Watch-" | head -1 | sed -E 's/^[[:space:]]*//; s/[[:space:]]+\(.*//' || true)
  if [ -z "$WATCH_DEVICE_NAME" ]; then
    echo "WARNING: No Apple Watch simulator found — skipping watch smoke test."
  fi
fi

if [ -n "$WATCH_DEVICE_NAME" ]; then
  echo "Watch device name: $WATCH_DEVICE_NAME"
  echo ""

  if xcrun simctl list devices available | sed -E 's/^[[:space:]]*//' | grep -q "^$WATCH_DEVICE_NAME ("; then
    xcodebuild test \
      -scheme VoxglassWatch \
      -project Voxglass.xcodeproj \
      -destination "platform=watchOS Simulator,name=$WATCH_DEVICE_NAME" \
      -quiet
  else
    echo "WARNING: Watch simulator \"$WATCH_DEVICE_NAME\" not available — skipping watch smoke test."
  fi
fi

echo ""
echo "Local UI smoke tests complete."
