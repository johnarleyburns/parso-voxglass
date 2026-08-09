#!/usr/bin/env bash
set -euo pipefail
fail=0
if grep -REl 'swiftLanguageMode\(\.v[0-5]\)|enableUpcomingFeature\("StrictConcurrency"\)|SWIFT_VERSION: "[0-5]' Package.swift project.yml Voxglass.xcodeproj >/dev/null; then fail=1; fi
if grep -El 'SWIFT_VERSION = [0-5]' Voxglass.xcodeproj/project.pbxproj >/dev/null 2>&1; then fail=1; fi
if ! grep -q 'SWIFT_STRICT_CONCURRENCY = complete' Voxglass.xcodeproj/project.pbxproj; then fail=1; fi
if grep -REl 'nonisolated\(unsafe\)|MainActor\.assumeIsolated' Voxglass VoxglassCore VoxglassCoreTestSupport VoxglassTests --include='*.swift' >/dev/null 2>&1; then fail=1; fi
if ((fail)); then echo 'Swift 6 guard: FAILED' >&2; exit 1; fi
echo 'Swift 6 guard: OK'
