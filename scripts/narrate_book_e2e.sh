#!/bin/bash
# Development-only whole-book narration harness. It is deliberately absent
# from scripts/test.sh, hooks and CI.
set -euo pipefail

device="iPhone 16"
output="/tmp/voxglass-narration-e2e"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) device="$2"; shift 2 ;;
    --out) output="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$output"
cd "$repo_root"
xcodegen generate

result_log="$(mktemp -t voxglass-narration-e2e.XXXXXX)"
trap 'rm -f "$result_log"' EXIT
VOXGLASS_E2E_OUTPUT="$output" xcodebuild test \
  -project Voxglass.xcodeproj \
  -scheme VoxglassNarrationE2E \
  -destination "platform=iOS Simulator,name=$device" \
  -only-testing:VoxglassNarrationE2E/NarrateBookE2ETests/testNarratesAndExportsAListenableAudiobook \
  ASSETCATALOG_COMPILER_APPICON_NAME= | tee "$result_log"

simulator_package="$(sed -n 's/^E2E_PACKAGE //p' "$result_log" | tail -n 1)"
if [[ -z "$simulator_package" || ! -d "$simulator_package" ]]; then
  echo "The test passed but its narrated package could not be located." >&2
  exit 1
fi
host_package="$output/$(basename "$simulator_package")"
ditto "$simulator_package" "$host_package"

echo "Narrated audiobook package: $host_package"
find "$host_package" -type f \( -name '*.m4a' -o -name '*.m4b' -o -name 'checksums.sha256' \) -print
