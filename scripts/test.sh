#!/bin/bash
# test.sh — Local simulator test suite.
# Runs xcodebuild test for the phone (iOS) and watch (watchOS) smoke tests.
# Does NOT run in CI.
#
# Usage: scripts/test.sh [--device "iPhone 16"] [--watch-device "Apple Watch Series 10 (46mm)"]
#
# With no arguments, defaults to iPhone 16 and the first available Apple Watch.

set -euo pipefail

DEVICE_NAME="iPhone 16"
WATCH_DEVICE_NAME=""

# Parse args before using defaults.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE_NAME="$2"; shift 2 ;;
    --watch-device) WATCH_DEVICE_NAME="$2"; shift 2 ;;
    *) shift ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

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
    exit 0
  fi
fi

echo "Watch device name: $WATCH_DEVICE_NAME"
echo ""

if ! xcrun simctl list devices available | sed -E 's/^[[:space:]]*//' | grep -q "^$WATCH_DEVICE_NAME ("; then
  echo "WARNING: Watch simulator \"$WATCH_DEVICE_NAME\" not available — skipping watch smoke test."
  exit 0
fi

xcodebuild test \
  -scheme VoxglassWatch \
  -project Voxglass.xcodeproj \
  -destination "platform=watchOS Simulator,name=$WATCH_DEVICE_NAME" \
  -quiet
