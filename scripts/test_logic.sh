#!/bin/bash
# test_logic.sh — The ONLY sanctioned way to run the Swift Testing logic suites.
#
# Timing-budget tests (VoxglassPerformanceTests) can never run in a parallel batch:
# `swift test` runs test targets in parallel, and the budgets (spec §19.7) would be
# skewed by parallel-suite CPU contention and produce false failures. They are
# therefore gated behind the VOXGLASS_TIMING_TESTS environment variable (see
# VoxglassTests/Performance/PerformanceBudgetTests.swift) and run here serially.
#
# Usage: scripts/test_logic.sh
#   phase 1 — logic suites, parallel:    swift test --skip VoxglassPerformanceTests
#   phase 2 — timing budgets, serial:    VOXGLASS_TIMING_TESTS=1 swift test --no-parallel --filter VoxglassPerformanceTests
#
# CI (.github/workflows/ios.yml) and the pre-commit/pre-push hooks use this script so
# the serialization invariant cannot rot.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

echo ""
echo "=== swift test (logic suites, parallel) ==="
swift test --skip VoxglassPerformanceTests

echo ""
echo "=== swift test (timing budgets, serial) ==="
VOXGLASS_TIMING_TESTS=1 swift test --no-parallel --filter VoxglassPerformanceTests

echo ""
echo "test_logic: all logic suites passed"
