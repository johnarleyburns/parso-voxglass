#!/bin/bash
# check_watch_app_icon.sh — validate the Watch app icon before Xcode invokes actool.
#
# Two entries are both required, and this script has failed to catch a missing
# one before:
#   - "watch-marketing" (1024x1024, scale 1x): the App Store listing icon.
#   - "universal" (1024x1024, no scale): the watchOS 10+ single-size *runtime*
#     icon. This is the one that actually produces CFBundleIconName /
#     CFBundleIconFiles in the built app. Its absence does not fail a plain
#     build — actool and `xcodebuild build` are both silent about it — it only
#     surfaces as an export/upload-time failure ("Missing Info.plist value...
#     CFBundleIconName", "Missing Icons. No icons found for watch
#     application..."), which is exactly the failure this guard was added
#     after and then didn't prevent, because the guard only ever checked for
#     "watch-marketing". Every "fix" that re-added watch-marketing satisfied
#     this script while leaving the app itself iconless.
#
# App icons (any platform) must also have no alpha channel — App Store
# Connect rejects transparency in the runtime icon at upload/validation time,
# again after a plain build succeeds silently.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ICON_SET="$REPO_ROOT/VoxglassWatch/Resources/Assets.xcassets/AppIcon.appiconset"
CONTENTS="$ICON_SET/Contents.json"

python3 - "$CONTENTS" "$ICON_SET" <<'PY'
import json
import struct
import sys
from pathlib import Path

contents_path = Path(sys.argv[1])
icon_set = Path(sys.argv[2])

if not contents_path.is_file():
    raise SystemExit(f"Watch app icon manifest is missing: {contents_path}")

try:
    manifest = json.loads(contents_path.read_text())
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"Watch app icon manifest is not valid JSON: {error}")

images = manifest.get("images")
if not isinstance(images, list):
    raise SystemExit("Watch app icon manifest must contain an images array")

def find(idiom, *, scale=None):
    matches = [
        image for image in images
        if image.get("idiom") == idiom
        and image.get("platform") == "watchos"
        and image.get("size") == "1024x1024"
        and (scale is None or image.get("scale") == scale)
    ]
    return matches

def validate_icon_file(image, label):
    filename = image.get("filename")
    if not isinstance(filename, str) or not filename:
        raise SystemExit(f"Watch app icon ({label}) must declare a filename")

    image_path = icon_set / filename
    if not image_path.is_file():
        raise SystemExit(f"Watch app icon file is missing ({label}): {image_path}")

    png_signature = b"\x89PNG\r\n\x1a\n"
    with image_path.open("rb") as image_file:
        if image_file.read(8) != png_signature:
            raise SystemExit(f"Watch app icon ({label}) is not a PNG: {image_path}")
        length_bytes = image_file.read(4)
        chunk_type = image_file.read(4)
        if len(length_bytes) != 4 or chunk_type != b"IHDR":
            raise SystemExit(f"Watch app icon ({label}) has no PNG IHDR: {image_path}")
        width, height, bit_depth, color_type = struct.unpack(">IIBB", image_file.read(10))

    if (width, height) != (1024, 1024):
        raise SystemExit(
            f"Watch app icon ({label}) must be 1024x1024, got {width}x{height}: {image_path}"
        )

    # PNG color types 4 (grayscale+alpha) and 6 (truecolor+alpha) carry an
    # alpha channel. App Store Connect rejects a transparent runtime app icon
    # at upload time, not at build time, so this has to be caught here.
    if color_type in (4, 6):
        raise SystemExit(
            f"Watch app icon ({label}) has an alpha channel (PNG color type "
            f"{color_type}); flatten it to opaque before committing: {image_path}"
        )

    return filename

# The runtime icon: the entry that actually ships as the app's icon.
universal = find("universal")
if len(universal) != 1:
    raise SystemExit(
        "Watch app icon manifest must contain exactly one 'universal' "
        "1024x1024 watchos image (the watchOS 10+ runtime icon) — its "
        "absence builds fine but fails at archive export / TestFlight "
        "upload with a missing CFBundleIconName error"
    )
universal_filename = validate_icon_file(universal[0], "universal")

# The App Store listing icon.
marketing = find("watch-marketing", scale="1x")
if len(marketing) != 1:
    raise SystemExit(
        "Watch app icon manifest must contain exactly one "
        "watch-marketing 1024x1024 1x image"
    )
marketing_filename = validate_icon_file(marketing[0], "watch-marketing")

print(
    f"Watch app icon valid: universal={universal_filename}, "
    f"watch-marketing={marketing_filename} (1024x1024, opaque)"
)
PY
