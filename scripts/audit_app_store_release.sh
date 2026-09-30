#!/bin/bash
# Audit the source and (optionally) an archived app bundle for App Store
# distribution requirements that can be checked without signing credentials.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

BUILT_BUNDLE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --bundle)
      [ "$#" -ge 2 ] || { echo "--bundle requires an app path" >&2; exit 2; }
      BUILT_BUNDLE="$2"
      shift 2
      ;;
    *)
      echo "usage: $0 [--bundle /path/to/App.app]" >&2
      exit 2
      ;;
  esac
done

python3 - "$BUILT_BUNDLE" <<'PY'
import pathlib
import plistlib
import re
import sys

root = pathlib.Path.cwd()
errors = []

def read_plist(path):
    try:
        with path.open("rb") as handle:
            return plistlib.load(handle)
    except Exception as error:
        errors.append(f"{path}: invalid plist ({error})")
        return {}

def require(condition, message):
    if not condition:
        errors.append(message)

def accessed_types(manifest):
    return {
        item.get("NSPrivacyAccessedAPIType"): set(item.get("NSPrivacyAccessedAPITypeReasons", []))
        for item in manifest.get("NSPrivacyAccessedAPITypes", [])
    }

manifest_specs = {
    "iOS": (
        root / "Voxglass/Resources/PrivacyInfo.xcprivacy",
        {
            "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1"},
            "NSPrivacyAccessedAPICategoryFileTimestamp": {"C617.1", "3B52.1"},
            "NSPrivacyAccessedAPICategoryDiskSpace": {"E174.1"},
        },
    ),
    "watchOS": (
        root / "VoxglassWatch/Resources/PrivacyInfo.xcprivacy",
        {
            "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1"},
            "NSPrivacyAccessedAPICategoryFileTimestamp": {"C617.1"},
        },
    ),
    "macOS": (
        root / "VoxglassMac/Resources/PrivacyInfo.xcprivacy",
        {
            "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1"},
            "NSPrivacyAccessedAPICategoryFileTimestamp": {"C617.1", "3B52.1"},
        },
    ),
}

for platform, (path, expected) in manifest_specs.items():
    require(path.is_file(), f"{platform}: missing {path}")
    if path.is_file():
        manifest = read_plist(path)
        require(manifest.get("NSPrivacyTracking") is False, f"{platform}: NSPrivacyTracking must be false")
        require(manifest.get("NSPrivacyCollectedDataTypes") == [], f"{platform}: collected-data manifest must be explicit and empty")
        require(manifest.get("NSPrivacyTrackingDomains") == [], f"{platform}: tracking domains must be explicit and empty")
        actual = accessed_types(manifest)
        for api, reasons in expected.items():
            require(api in actual, f"{platform}: privacy manifest is missing {api}")
            require(reasons.issubset(actual.get(api, set())), f"{platform}: privacy manifest is missing approved reason(s) for {api}")

project = (root / "project.yml").read_text()
for path in (
    "Voxglass/Resources/PrivacyInfo.xcprivacy",
    "VoxglassWatch/Resources/PrivacyInfo.xcprivacy",
    "VoxglassMac/Resources/PrivacyInfo.xcprivacy",
    "Voxglass/Resources/Assets.xcassets",
):
    require(path in project, f"project.yml: missing target resource wiring for {path}")
require("ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon" in project, "project.yml: AppIcon must be explicit for shipped targets")
require('TARGETED_DEVICE_FAMILY: "1,2"' in project, "project.yml: iPhone and iPad must remain supported")
require("exactVersion: 1.2.2" in project, "project.yml: PAE must remain pinned to the published release")

for info_path, required_keys in (
    (root / "Voxglass/Resources/Info.plist", {"CFBundleIconName", "NSMicrophoneUsageDescription", "ITSAppUsesNonExemptEncryption"}),
    (root / "VoxglassMac/Resources/Info.plist", {"CFBundleIconName", "NSMicrophoneUsageDescription", "ITSAppUsesNonExemptEncryption", "LSApplicationCategoryType"}),
):
    info = read_plist(info_path)
    for key in required_keys:
        require(key in info and info[key] not in (None, ""), f"{info_path}: missing {key}")

for info_path in (root / "Voxglass/Resources/Info.plist", root / "VoxglassWatch/Resources/Info.plist", root / "VoxglassMac/Resources/Info.plist"):
    info = read_plist(info_path)
    version = str(info.get("CFBundleShortVersionString", ""))
    build = str(info.get("CFBundleVersion", ""))
    require(version == "$(MARKETING_VERSION)", f"{info_path}: version must come from MARKETING_VERSION")
    require(build == "$(CURRENT_PROJECT_VERSION)", f"{info_path}: build must come from CURRENT_PROJECT_VERSION")

for entitlements in (
    root / "Voxglass/Resources/Voxglass-release.entitlements",
    root / "VoxglassWatch/Resources/VoxglassWatch-release.entitlements",
    root / "VoxglassMac/Resources/VoxglassMac-release.entitlements",
):
    require(entitlements.is_file(), f"missing release entitlements: {entitlements}")

require((root / "Voxglass/Resources/AppIcon.icon/icon.json").is_file(), "iOS/macOS app icon (.icon) is missing")
require(not (root / "VoxglassWatch/Resources/Assets.xcassets/AppIcon.appiconset").exists(), "watchOS icon must come from AppIcon.icon, not a Watch appiconset")
require("guru.parso.voxglass.studio" not in project, "retired native Mac bundle identifier must not return")

# Draft translations are useful during development but must never ship without
# native-speaker review. Human review of every catalog was completed on
# 2026-09-30 and all entries were promoted to `translated`; this gate stays so
# new strings cannot ship as unreviewed `needs_review` drafts.
for catalog in root.rglob("*.xcstrings"):
    # Build products (SwiftPM `.build`, DerivedData) hold stale copies of the catalogs.
    if {".build", "DerivedData"} & set(catalog.relative_to(root).parts):
        continue
    try:
        payload = __import__("json").loads(catalog.read_text())
    except Exception as error:
        errors.append(f"{catalog}: invalid string catalog ({error})")
        continue
    def walk(value, path=()):
        if isinstance(value, dict):
            if value.get("state") == "needs_review":
                errors.append(f"{catalog}: translation needs review at {'/'.join(path)}")
            for key, child in value.items():
                walk(child, path + (str(key),))
        elif isinstance(value, list):
            for index, child in enumerate(value):
                walk(child, path + (str(index),))
    walk(payload)

bundle = pathlib.Path(sys.argv[1]) if sys.argv[1] else None
if bundle:
    require(bundle.is_dir(), f"built app bundle does not exist: {bundle}")
    if bundle.is_dir():
        manifest_candidates = [bundle / "PrivacyInfo.xcprivacy", bundle / "Contents/Resources/PrivacyInfo.xcprivacy"]
        require(any(path.is_file() for path in manifest_candidates), f"built app is missing PrivacyInfo.xcprivacy: {bundle}")
        info_path = bundle / "Info.plist" if (bundle / "Info.plist").is_file() else bundle / "Contents/Info.plist"
        info = read_plist(info_path)
        require(bool(info.get("CFBundleIdentifier")), f"built app is missing CFBundleIdentifier: {info_path}")
        require(bool(info.get("CFBundleShortVersionString")), f"built app is missing marketing version: {info_path}")
        require(bool(info.get("CFBundleVersion")), f"built app is missing build number: {info_path}")

if errors:
    print("App Store release audit: FAIL")
    for error in errors:
        print(f"  - {error}")
    sys.exit(1)

print("App Store release audit: PASS")
PY
