#!/bin/bash
# kill_zombie_test_helpers.sh — kills leaked swiftpm-testing-helper processes.
#
# When `swift test`'s runner crashes (e.g. a SIGTRAP in the test binary), its
# worker helper processes are orphaned — reparented to launchd (PPID 1) — and
# keep spinning forever at full CPU. A handful of these can saturate a dev
# machine for days (observed: load average 425, 1000+ CPU-hours each). See
# VoxglassTests/Performance/PerformanceBudgetTests.swift for the load guard
# that makes the budgets skip instead of false-fail while a host is saturated.
#
# This script kills ONLY orphaned helpers (PPID 1) running from THIS repo's
# .build directory, so it can never touch a live test run's processes. It is
# called at the start and on exit of every sanctioned test run
# (scripts/test_logic.sh, scripts/test.sh).
#
# Assumes a single-user dev machine: concurrent `swift test` runs from two
# shells would orphan-check each other's live helpers.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_PATH="$REPO_ROOT/.build"

is_orphan() {
  local ppid
  ppid="$(ps -o ppid= -p "$1" 2>/dev/null | tr -d ' ' || true)"
  [ "$ppid" = "1" ]
}

find_orphaned_helpers() {
  local pids
  pids="$(pgrep -f "swiftpm-testing-helper.*$BUNDLE_PATH" || true)"
  for pid in $pids; do
    if is_orphan "$pid"; then
      echo "$pid"
    fi
  done
}

orphans="$(find_orphaned_helpers)"
if [ -z "$orphans" ]; then
  exit 0
fi

echo "kill_zombie_test_helpers: found orphaned test helper(s): $(echo "$orphans" | tr '\n' ' ')"
for pid in $orphans; do
  kill -TERM "$pid" 2>/dev/null || true
done

sleep 1

# SIGKILL whatever survived SIGTERM.
for pid in $orphans; do
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
done

count="$(find_orphaned_helpers | wc -l | tr -d ' ')"
echo "kill_zombie_test_helpers: killed $(echo "$orphans" | wc -l | tr -d ' ') process(es); $count remaining"
