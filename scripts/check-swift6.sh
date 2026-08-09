#!/usr/bin/env bash
set -euo pipefail
fail=0
if [[ -n "$(rg -l 'swiftLanguageMode\(\.v[0-5]\)|enableUpcomingFeature\("StrictConcurrency"\)|SWIFT_VERSION: "[0-5]' Package.swift project.yml Voxglass.xcodeproj 2>/dev/null || true)" ]]; then fail=1; fi
if [[ -n "$(rg -l 'SWIFT_VERSION = [0-5]' Voxglass.xcodeproj/project.pbxproj 2>/dev/null || true)" ]]; then fail=1; fi
if ! rg -q 'SWIFT_STRICT_CONCURRENCY = complete' Voxglass.xcodeproj/project.pbxproj; then fail=1; fi
if [[ -n "$(rg -l 'nonisolated\(unsafe\)|MainActor\.assumeIsolated' Voxglass VoxglassCore VoxglassCoreTestSupport VoxglassTests --glob '*.swift' 2>/dev/null || true)" ]]; then fail=1; fi
if ((fail)); then echo 'Swift 6 guard: FAILED' >&2; exit 1; fi
echo 'Swift 6 guard: OK'
