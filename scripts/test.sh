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

# Pin the destination to the simulator *by name* (default: iPhone 16). Binding by
# name to a device that already exists on disk keeps every run on the same
# simulator and stops xcodebuild from resolving to — or downloading — any other
# one. The machine is expected to have exactly one "iPhone 16" installed.
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
