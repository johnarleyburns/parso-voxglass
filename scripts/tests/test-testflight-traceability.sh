#!/usr/bin/env bash
set -Eeuo pipefail
script=.github/scripts/record-testflight-delivery.sh
test -x "$script" || test -f "$script"
grep -Eq 'closingIssuesReferences' "$script"
grep -Eq 'testflight-delivery:' "$script"
grep -Eq 'CFBundleShortVersionString' "$script"
grep -Eq 'CFBundleVersion' "$script"
grep -Eq 'commits/\$commit/pulls' "$script"
grep -Eq 'issues/comments/\$existing' "$script"
grep -Eq 'claude-issue' "$script"
! grep -Eq 'declare -A|\$\{[^}]*,,\}|mapfile|readarray' "$script"
echo 'traceability static regression checks passed'
