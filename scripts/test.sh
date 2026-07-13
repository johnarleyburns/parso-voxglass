#!/bin/bash
# test.sh — Local simulator test suite.
# Runs xcodebuild test with the simulator. Does NOT run in CI.
#
# Usage: scripts/test.sh [--device "iPhone 16"]
#
# With no arguments, defaults to iPhone 16.

set -euo pipefail

DEVICE="${1:-iPhone 16}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

echo "=== Running Voxglass test suite (simulator) ==="
echo "Device: $DEVICE"
echo ""

if [ "$#" -gt 0 ] && [ "$1" = "--device" ]; then
  DEVICE="$2"
fi

xcodebuild test \
  -scheme Voxglass \
  -project Voxglass.xcodeproj \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -quiet
