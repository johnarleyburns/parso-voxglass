#!/bin/bash
set -euo pipefail

# Files allowed to import AVFoundation despite the general ban below: the
# watch genuinely validates installed AAC assets on-device (WatchSessionAdapter
# calls WatchAACAssetValidator.validate before accepting a transferred file),
# which needs AVAudioFile. Every other forbidden import/symbol stays banned
# for these files too — only the AVFoundation import itself is exempted.
AVFOUNDATION_ALLOWLIST=(
  "VoxglassWatchCore/WatchAACAssetValidator.swift"
)

is_avfoundation_allowed() {
  local file="$1"
  for allowed in "${AVFOUNDATION_ALLOWLIST[@]}"; do
    [[ "$file" == "$allowed" ]] && return 0
  done
  return 1
}

fail=0
for dir in VoxglassWatchProtocol VoxglassWatchCore; do
  while IFS= read -r file; do
    if grep -En '^[[:space:]]*import[[:space:]]+(CloudKit|WatchConnectivity|SwiftUI)|(^|[^[:alnum:]_])(CKContainer|CKRecord|URLSession|CredentialStore)([^[:alnum:]_]|$)' "$file" >/dev/null; then
      echo "watch foundation dependency leak: $file" >&2
      fail=1
    fi
    if grep -En '^[[:space:]]*import[[:space:]]+AVFoundation' "$file" >/dev/null && ! is_avfoundation_allowed "$file"; then
      echo "watch foundation dependency leak: $file" >&2
      fail=1
    fi
  done < <(find "$dir" -name '*.swift' -type f)
done

grep -q 'cloudKitDatabase = "none"' VoxglassWatchCore/WatchCore.swift || { echo 'watch store lacks explicit CloudKit opt-out' >&2; fail=1; }
grep -q 'product: VoxglassWatchProtocol' project.yml || { echo 'Watch target does not link VoxglassWatchProtocol' >&2; fail=1; }
grep -q 'product: VoxglassWatchCore' project.yml || { echo 'Watch target does not link VoxglassWatchCore' >&2; fail=1; }

if [ "$fail" -ne 0 ]; then exit 1; fi
echo 'ok: watch foundation dependency closure'
