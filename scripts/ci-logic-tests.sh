#!/usr/bin/env bash
#
# Logic-test driver for the hosted macOS runner.
#
# Two things a bare `swift test` does not give us on CI:
#
#   1. Streaming output. swift-testing block-buffers stdout when it is not a
#      TTY, so it flushes only at process exit. A hung suite therefore produced
#      a log that stopped dead at "Build complete!" and named no test at all.
#      `script` allocates a pty, which restores line buffering and makes the
#      last "◇ Test ... started." line the culprit.
#
#   2. A stack trace when it does hang. Past the watchdog we `sample` the test
#      process before the runner's own timeout kills the job, so the next hang
#      explains itself instead of costing another 30-minute round trip.
#
# Performance/timing tests stay local-only: hosted runners have insufficiently
# stable CPU performance for those budgets, and the pre-commit hook runs them
# on the developer's machine.
set -uo pipefail

watchdog_seconds="${WATCHDOG_SECONDS:-1200}"

script -q /dev/null swift test --no-parallel --skip VoxglassPerformanceTests &
test_pid=$!

(
  sleep "$watchdog_seconds"
  if kill -0 "$test_pid" 2>/dev/null; then
    echo "::error title=Logic tests hung::No completion after ${watchdog_seconds}s. Sampling the test process."
    for pid in $(pgrep -f 'swiftpm-testing-helper|xctest|VoxglassCorePackageTests' 2>/dev/null); do
      echo "--- sample $pid ---"
      sample "$pid" 5 -mayDie 2>&1 | head -400
    done
    pkill -9 -f 'swiftpm-testing-helper|xctest|VoxglassCorePackageTests' 2>/dev/null
    kill -9 "$test_pid" 2>/dev/null
  fi
) &
watchdog_pid=$!

wait "$test_pid"
status=$?

kill "$watchdog_pid" 2>/dev/null
wait "$watchdog_pid" 2>/dev/null

exit "$status"
