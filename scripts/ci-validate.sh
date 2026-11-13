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
bash scripts/tests/test-claude-turn-budget.sh
bash scripts/tests/test-es256-jws.sh
bash scripts/tests/test-issue-pr-candidate.sh
bash scripts/tests/test-testflight-traceability.sh
bash scripts/tests/test-testflight-upload-policy.sh
if [[ -f scripts/tests/test-pr-maintenance.sh && -f .github/scripts/pr-maintenance.sh ]]; then
  bash scripts/tests/test-pr-maintenance.sh
fi
endstep

step "Source-level wiring guards"
bash scripts/guard_wiring.sh
bash scripts/guard_watch_foundation.sh
endstep

[[ "${1:-}" == "--fast" ]] && exit 0

step "Swift 6 contract"
bash scripts/check-swift6.sh
endstep

step "Release-input guard"
bash scripts/audit_app_store_release.sh
endstep

step "Swift package logic tests"
bash scripts/ci-logic-tests.sh
endstep

step "Select stable Xcode"
# The repair agent's workflow (release-repair.yml) does not select Xcode
# before calling this script, unlike pr-validation.yml and issue-to-pr.yml;
# select it here so a real build is possible regardless of caller.
XCODE=$(find /Applications -maxdepth 1 -type d -name 'Xcode_*.app' ! -iname '*beta*' ! -iname '*rc*' -print | sort -V | tail -1)
test -n "$XCODE"
sudo xcode-select -s "$XCODE"
xcodebuild -version
endstep

step "iOS + watchOS build (Voxglass.xcodeproj)"
# A missing-import or other cross-target compile error (the class of bug that
# repeatedly let a bad release-repair candidate merge — see #299) is invisible
# to `swift test` alone, since the Watch target is not part of the SPM
# package. Build both app schemes for real, matching ios.yml's Compile job.
xcodebuild build \
  -project Voxglass.xcodeproj \
  -scheme Voxglass \
  -destination generic/platform=iOS \
  CODE_SIGNING_ALLOWED=NO
bash scripts/check_watch_app_icon.sh
xcodebuild build \
  -project Voxglass.xcodeproj \
  -scheme VoxglassWatch \
  -destination 'generic/platform=watchOS' \
  CODE_SIGNING_ALLOWED=NO
endstep

step "Repository hygiene"
git diff --check
endstep
