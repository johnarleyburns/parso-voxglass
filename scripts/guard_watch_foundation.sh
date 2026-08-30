#!/bin/bash
set -euo pipefail

fail=0
for dir in VoxglassWatchProtocol VoxglassWatchCore; do
  while IFS= read -r file; do
    if grep -En '^[[:space:]]*import[[:space:]]+(CloudKit|WatchConnectivity|AVFoundation|SwiftUI)|(^|[^[:alnum:]_])(CKContainer|CKRecord|URLSession|CredentialStore)([^[:alnum:]_]|$)' "$file" >/dev/null; then
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
