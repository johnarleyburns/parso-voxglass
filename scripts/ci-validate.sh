#!/usr/bin/env bash
# Single source of truth for PR validation. Used by the PR Swift Validation
# workflow, the issue agent and the repair agent so the three cannot drift.
# Runs the same headless logic and guard checks as the repository CI.
set -euo pipefail
cd "${CI_VALIDATE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

step() { echo "::group::$*"; echo "=== $* ==="; }
endstep() { echo "::endgroup::"; }

step "Shell syntax"
while IFS= read -r f; do
  bash -n "$f" || { echo "Shell syntax error: $f" >&2; exit 1; }
done < <(git ls-files '*.sh')
endstep

step "Workflow YAML"
while IFS= read -r f; do
  ruby -ryaml -e 'YAML.safe_load(File.read(ARGV[0]), aliases: true)' "$f" \
    || { echo "Invalid workflow YAML: $f" >&2; exit 1; }
done < <(git ls-files '.github/workflows/*.yml')
endstep

step "TestFlight crash collector"
ruby -c .github/scripts/testflight-crash-intake.rb
ruby scripts/tests/test-testflight-crash-intake.rb
endstep

step "Automation regression tests"
bash scripts/tests/test-issue-pr-policy.sh
bash scripts/tests/test-issue-backlog-order.sh
bash scripts/tests/test-release-repair-policy.sh
bash scripts/tests/test-testflight-delivery-body.sh
bash scripts/tests/test-testflight-reconciler-discovery.sh
if [[ -f scripts/tests/test-pr-maintenance.sh && -f .github/scripts/pr-maintenance.sh ]]; then
  bash scripts/tests/test-pr-maintenance.sh
fi
endstep

[[ "${1:-}" == "--fast" ]] && exit 0

step "Swift 6 contract"
bash scripts/check-swift6.sh
endstep

step "Wiring and production guards"
bash scripts/guard_wiring.sh
bash scripts/test_guards.sh
bash scripts/guard_production.sh
bash scripts/audit_app_store_release.sh
endstep

step "Swift package logic tests"
bash scripts/ci-logic-tests.sh
endstep

step "Repository hygiene"
git diff --check
endstep
