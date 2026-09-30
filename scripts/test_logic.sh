#!/bin/bash
# test_logic.sh — The ONLY sanctioned way to run the Swift Testing logic suites.
#
# The regular logic suites use Swift Testing's default parallel runner. Timing-
# budget tests (VoxglassPerformanceTests) are additionally gated behind the
# VOXGLASS_TIMING_TESTS environment variable (see
# VoxglassTests/Performance/PerformanceBudgetTests.swift) and run here in a
# second invocation.
#
# Usage: scripts/test_logic.sh
#   phase 1 — all logic suites, parallel: swift test --skip VoxglassPerformanceTests
#   phase 2 — timing budgets:             VOXGLASS_TIMING_TESTS=1 swift test --filter VoxglassPerformanceTests
#
# This script is an optional expanded local verification path. The pre-commit
# hook intentionally runs the plain host `swift test` command only. GitHub Actions runs
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
echo "=== swift test (all logic suites, parallel) ==="
swift test --skip VoxglassPerformanceTests

echo ""
echo "=== swift test (timing budgets) ==="
VOXGLASS_TIMING_TESTS=1 swift test --filter VoxglassPerformanceTests

echo ""
echo "test_logic: all logic suites passed"
