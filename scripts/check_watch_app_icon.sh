#!/bin/bash
# check_watch_app_icon.sh — validate the Watch app icon before Xcode invokes actool.
#
# The Watch app's icon is the watchOS circle (Icon Composer's 1088 canvas) of the
# shared Icon Composer file `Voxglass/Resources/AppIcon.icon`, which the
# VoxglassWatch target compiles as `AppIcon`. actool then writes
# CFBundleIconName into the built Watch app and App Store Connect generates the
# marketing icon from the same file.
#
# History: a missing watchOS runtime icon builds silently and only fails at
# archive export / TestFlight upload ("Missing Info.plist value...
# CFBundleIconName", "Missing Icons. No icons found for watch application...").
# This guard fails the build instead when the .icon is missing, malformed, or no
# longer declares watchOS. `WatchAppIconContractTests` additionally compiles it
# with watchOS actool and checks the generated CFBundleIconName.
#
# The pre-build phase runs sandboxed, so this script reads only its declared
# input (icon.json).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ICON_JSON="$REPO_ROOT/Voxglass/Resources/AppIcon.icon/icon.json"

python3 - "$ICON_JSON" <<'PY'
import json
import sys
from pathlib import Path

icon_json = Path(sys.argv[1])
if not icon_json.is_file():
    raise SystemExit(f"Watch app icon is missing: {icon_json} (the Watch uses the shared AppIcon.icon)")

try:
    manifest = json.loads(icon_json.read_text())
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"AppIcon.icon/icon.json is not valid JSON: {error}")

circles = manifest.get("supported-platforms", {}).get("circles", [])
if "watchOS" not in circles:
    raise SystemExit(
        "AppIcon.icon does not declare watchOS under supported-platforms.circles; "
        "enable watchOS in Icon Composer so the Watch app gets a runtime icon"
    )

layers = [layer for group in manifest.get("groups", []) for layer in group.get("layers", [])]
if not any(layer.get("image-name") for layer in layers):
    raise SystemExit("AppIcon.icon has no image layers")

print("Watch app icon valid: AppIcon.icon declares the watchOS circle")
PY
