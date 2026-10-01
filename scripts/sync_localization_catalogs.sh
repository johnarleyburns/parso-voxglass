#!/usr/bin/env bash
# Extracts every localizable string with the Swift compiler (SWIFT_EMIT_LOC_STRINGS)
# and syncs the String Catalogs, exactly as Xcode does when it builds.
#
# Run this after adding or changing UI text. New keys arrive with no
# translations; add them in all catalog languages with state `needs_review`,
# and let a native speaker flip them to `translated` in Xcode's catalog editor.
# Never fill a catalog with machine output marked `translated`, and never copy
# the English text into another language as a placeholder.
#
# Builds for a generic iOS device (no simulator), serialised like every other
# xcodebuild in this repository — do not run it while another build is active.
set -euo pipefail
cd "$(dirname "$0")/.."

derived_data="${VOXGLASS_L10N_DERIVED_DATA:-/tmp/voxglass-l10n}"
xcodebuild build -project Voxglass.xcodeproj -scheme Voxglass \
  -destination 'generic/platform=iOS' -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO -quiet

stringsdata() {
  find "$derived_data/Build/Intermediates.noindex" -path "*/Debug-*/$1.build/*" -name '*.stringsdata'
}

# shellcheck disable=SC2046 # one argument per .stringsdata file is intended
xcrun xcstringstool sync Voxglass/Resources/Localizable.xcstrings Voxglass/Resources/AppShortcuts.xcstrings \
  --stringsdata $(stringsdata Voxglass)
# shellcheck disable=SC2046
xcrun xcstringstool sync Voxglass/Core/Resources/Localizable.xcstrings --stringsdata $(stringsdata VoxglassCore)
# shellcheck disable=SC2046
xcrun xcstringstool sync VoxglassWatch/Resources/Localizable.xcstrings --stringsdata $(stringsdata VoxglassWatch)
# shellcheck disable=SC2046
xcrun xcstringstool sync VoxglassWidgets/Localizable.xcstrings --stringsdata $(stringsdata VoxglassWidgets)
# shellcheck disable=SC2046
xcrun xcstringstool sync VoxglassWatchWidgets/Localizable.xcstrings --stringsdata $(stringsdata VoxglassWatchWidgets)

echo "Catalogs synced. Stale keys are marked extractionState=stale; remove them once confirmed unused."
