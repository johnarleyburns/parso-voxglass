#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
script="$root/.github/scripts/release-repair.sh"
workflow="$root/.github/workflows/release-repair.yml"
rg -q 'workflow_run:' "$workflow"
rg -q 'conclusion == .failure.' "$workflow"
rg -q 'fix\\\(release\\\)' "$script"
rg -q 'This pull request does not close any issue' "$script"
rg -q 'provision|signing|certificate' "$script"
validate_line=$(grep -nF 'if validate "$attempt"' "$script" | cut -d: -f1)
commit_line=$(grep -nE '^git commit -m "fix\(release\)' "$script" | cut -d: -f1)
[[ "$validate_line" -lt "$commit_line" ]]
rg -Fq 'No branch or PR was published.' "$script"
echo 'Release repair policy: pre-publication validation; deployment failures escalate'
