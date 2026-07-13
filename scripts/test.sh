#!/bin/bash
# test.sh — Local simulator test suite.
# Runs xcodebuild test with the simulator. Does NOT run in CI.
#
# Usage: scripts/test.sh [--device "iPhone 16"]
#
# With no arguments, defaults to iPhone 16.

set -euo pipefail

DEVICE_NAME="iPhone 16"

# Parse args before using DEVICE_NAME.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE_NAME="$2"; shift 2 ;;
    *) shift ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

echo "=== Running Voxglass test suite (simulator) ==="
echo "Device name: $DEVICE_NAME"
echo ""

# Resolve device name to concrete UDID. When multiple simulators share a name
# (e.g. two "iPhone 16" entries on different runtimes), pick the newest runtime.
UDID=$(
  xcrun simctl list devices available \
    | grep "$DEVICE_NAME (" \
    | tail -1 \
    | sed -E 's/.*\(([A-F0-9-]+)\).*/\1/'
)

if [ -z "$UDID" ]; then
  echo "ERROR: No available simulator matching \"$DEVICE_NAME\" found."
  echo "Available devices:"
  xcrun simctl list devices available | grep -i iphone || true
  exit 1
fi

echo "UDID: $UDID"

xcodebuild test \
  -scheme Voxglass \
  -project Voxglass.xcodeproj \
  -destination "platform=iOS Simulator,id=$UDID" \
  -quiet
