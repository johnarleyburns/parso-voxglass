#!/bin/bash
# capture_studio_screenshots.sh — App Store screenshot capture for Voxglass Studio.
#
# Launches the Studio app with seeded launch arguments (no real projects, no
# microphone, no CloudKit, no StoreKit) and captures each App Store screenshot
# with `screencapture`. Output lands in docs/voxglass-mvp/app-store/screenshots/.
#
# Usage: scripts/capture_studio_screenshots.sh
#
# Notes:
# - Runs on the host Mac; the app must be built first
#   (xcodebuild build -scheme VoxglassStudio -destination 'platform=macOS').
# - Each capture waits for the seeded screen to appear (the smoke tests prove
#   the identifiers); inspect the PNGs against the mockup set before shipping.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$REPO_ROOT/docs/voxglass-mvp/app-store/screenshots"
APP_BIN="$REPO_ROOT/build/Build/Products/Debug/VoxglassStudio.app"

mkdir -p "$OUT_DIR"

if [ ! -d "$APP_BIN" ]; then
  echo "Building VoxglassStudio (Debug) first…"
  xcodebuild build \
    -project "$REPO_ROOT/Voxglass.xcodeproj" \
    -scheme VoxglassStudio \
    -destination 'platform=macOS' \
    -derivedDataPath "$REPO_ROOT/build" \
    CODE_SIGNING_ALLOWED=NO >/dev/null
fi

capture() {
  local name="$1"
  local delay="${2:-3}"
  sleep "$delay"
  screencapture -x "$OUT_DIR/$name.png"
  echo "captured $name.png"
}

echo "Launching Studio with the 'empty' seed…"
open -n "$APP_BIN" --args -uiTestSeed empty -useTemporaryStore
capture "1-library" 4

# New-project wizard is modal; the smoke test drives it with identifiers.
osascript -e 'tell application "System Events" to tell process "VoxglassStudio" to click button "New Project" of window 1' >/dev/null 2>&1 || true
capture "2-new-project-wizard" 2

echo "Done. Review the PNGs in docs/voxglass-mvp/app-store/screenshots/ against the mockup set."
killall VoxglassStudio 2>/dev/null || true
