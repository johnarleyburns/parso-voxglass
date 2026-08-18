#!/bin/bash
# test_logic.sh — The ONLY sanctioned way to run the Swift Testing logic suites.
#
# ALL suites run serially (`--no-parallel`): `swift test` runs test targets in
# parallel by default, and load-sensitive suites (playback seek timing,
# performance budgets, audio metrics) produce false failures when the runner
# saturates the CPU. Timing-budget tests (VoxglassPerformanceTests) are
# additionally gated behind the VOXGLASS_TIMING_TESTS environment variable (see
# VoxglassTests/Performance/PerformanceBudgetTests.swift) and run here in a
# second serial invocation.
#
# Usage: scripts/test_logic.sh
#   phase 1 — all logic suites, serial:  swift test --no-parallel --skip VoxglassPerformanceTests
#   phase 2 — timing budgets, serial:    VOXGLASS_TIMING_TESTS=1 swift test --no-parallel --filter VoxglassPerformanceTests
#
# The pre-commit hook uses this script so the full local suite, including timing
# budgets, remains a single serialized gate. GitHub Actions intentionally runs
# only the non-performance phase because hosted macOS CPU performance is too
# variable for the timing budgets. The EXIT trap reaps orphaned test-helper
# processes left behind by a crashed runner (see kill_zombie_test_helpers.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

trap 'bash "$SCRIPT_DIR/kill_zombie_test_helpers.sh"' EXIT

echo ""
echo "=== reaping orphaned test helpers from prior runs ==="
bash "$SCRIPT_DIR/kill_zombie_test_helpers.sh"

echo ""
echo "=== swift test (all logic suites, serial) ==="
swift test --no-parallel --skip VoxglassPerformanceTests

echo ""
echo "=== swift test (timing budgets, serial) ==="
VOXGLASS_TIMING_TESTS=1 swift test --no-parallel --filter VoxglassPerformanceTests

echo ""
echo "test_logic: all logic suites passed"
