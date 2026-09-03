#!/bin/bash
# check_watch_app_icon.sh — validate the Watch app icon before Xcode invokes actool.
#
# The Watch catalog must use the watch-marketing idiom. A generic/universal
# image can look valid in Finder and still be rejected by actool as having no
# applicable content for watchOS.

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

matches = [
    image for image in images
    if image.get("idiom") == "watch-marketing"
    and image.get("size") == "1024x1024"
    and image.get("scale") == "1x"
]
if len(matches) != 1:
    raise SystemExit(
        "Watch app icon manifest must contain exactly one "
        "watch-marketing 1024x1024 1x image"
    )

image = matches[0]
filename = image.get("filename")
if not isinstance(filename, str) or not filename:
    raise SystemExit("Watch app icon image must declare a filename")

image_path = icon_set / filename
if not image_path.is_file():
    raise SystemExit(f"Watch app icon file is missing: {image_path}")

png_signature = b"\x89PNG\r\n\x1a\n"
with image_path.open("rb") as image_file:
    if image_file.read(8) != png_signature:
        raise SystemExit(f"Watch app icon is not a PNG: {image_path}")
    length_bytes = image_file.read(4)
    chunk_type = image_file.read(4)
    if len(length_bytes) != 4 or chunk_type != b"IHDR":
        raise SystemExit(f"Watch app icon has no PNG IHDR: {image_path}")
    width, height = struct.unpack(">II", image_file.read(8))

if (width, height) != (1024, 1024):
    raise SystemExit(
        f"Watch app icon must be 1024x1024, got {width}x{height}: {image_path}"
    )

print(f"Watch app icon valid: {filename} ({width}x{height}, watch-marketing)")
PY
