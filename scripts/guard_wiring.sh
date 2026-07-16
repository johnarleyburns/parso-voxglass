#!/bin/bash
# guard_wiring.sh — Source-level wiring guards for the ubuntu CI job.
# Every rule derives its list from source, so it cannot rot as new keys
# and methods are added.
#
# Usage: scripts/guard_wiring.sh
#   exit 0 = all guards pass
#   exit 1 = at least one violation found (printed to stderr)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

VIOLATIONS=0
SWIFT_FILES="Voxglass/App Voxglass/Core Voxglass/Features Voxglass/DesignSystem"

# ──────────────────────────────────────────────────────────────
# Rule 1 — Preference-key writer check
# Every AppPreferencesStore.Keys entry has a writer (@AppStorage or
# .set(_:forKey:)), excluding the Keys enum definition itself.
# ──────────────────────────────────────────────────────────────
check_pref_key_writers() {
  local keys_file="Voxglass/Core/AppPreferencesStore.swift"
  local had_failure=0

  while IFS='|' read -r key_name key_value; do
    [ -z "$key_name" ] && continue
    # Skip RecentlyViewedBooksStore entries
    [ "$key_name" = "key" ] && continue

    local writer_found=0

    # Approach A: the raw VALUE string is used with @AppStorage or .set(
    for dir in Voxglass/Features Voxglass/App; do
      local matches
      matches=$(grep -rn "$key_value" "$dir" --include='*.swift' 2>/dev/null | grep -E '@AppStorage|\.set\(' || true)
      if [ -n "$matches" ]; then
        writer_found=1
        break
      fi
    done

    # Approach B: the key NAME (constant) is used with @AppStorage on the same line
    if [ "$writer_found" -eq 0 ]; then
      for dir in Voxglass/Features Voxglass/App; do
        local matches
        matches=$(grep -rnE "@AppStorage\(.*$key_name" "$dir" --include='*.swift' 2>/dev/null || true)
        if [ -n "$matches" ]; then
          writer_found=1
          break
        fi
      done
    fi

    if [ "$writer_found" -eq 0 ]; then
      echo "::error title=Preference-key writer guard::Key '$key_name' ('$key_value') has no writer under Voxglass/Features/ or Voxglass/App/"
      had_failure=1
    fi
  done < <(sed -n 's/.*static let \([a-zA-Z_][a-zA-Z0-9_]*\) = "\([^"]*\)".*/\1|\2/p' "$keys_file")

  return $had_failure
}

# ──────────────────────────────────────────────────────────────
# Rule 2 — PlaybackCoordinator public-method caller check
# Every non-private func in PlaybackCoordinator is named in some
# other file, with an explicit SYSTEM_INVOKED allowlist for
# system-callback-only methods.
# ──────────────────────────────────────────────────────────────
check_coordinator_callers() {
  local coord_file="Voxglass/Core/Playback/PlaybackCoordinator.swift"
  local had_failure=0

  # Methods called exclusively by system remote-command handlers or
  # internal timer/notification callbacks — they legitimately have
  # zero external callers.
  local SYSTEM_INVOKED=(
    pause                   # MPRemoteCommandCenter pauseCommand handler
    skipToNextChapter       # MPRemoteCommandCenter nextTrackCommand handler
    skipToPreviousChapter   # MPRemoteCommandCenter previousTrackCommand handler
    fadeOutAndPause         # sleep timer callback (handleSleepTimerFired)
    refreshBookmarkCount    # internal, called from addBookmark()
    nowPlayingInfo          # pure static builder, called only from updateNowPlayingInfo
    resolveResume           # pure static resolver, called only from play(_:chapter:)
    snapshotWins            # pure static tie-break, called from reconcile/restore paths
    preferredPosition       # pure static merge, called from restore/resume paths
  )

  while IFS= read -r method_name; do
    [ -z "$method_name" ] && continue

    # Check if in SYSTEM_INVOKED allowlist
    local is_allowed=0
    for allowed in "${SYSTEM_INVOKED[@]}"; do
      [ "$method_name" = "$allowed" ] && is_allowed=1 && break
    done
    [ "$is_allowed" -eq 1 ] && continue

    # Search for the method name in other .swift files
    local external_count=0
    for dir in $SWIFT_FILES; do
      external_count=$(( external_count + $(find "$dir" -name '*.swift' ! -path '*/PlaybackCoordinator.swift' \
        -exec grep -l "$method_name" {} \; 2>/dev/null | wc -l) ))
    done

    if [ "$external_count" -eq 0 ]; then
      echo "::error title=Coordinator-caller guard::Method '$method_name' in PlaybackCoordinator has zero external callers and is not in the SYSTEM_INVOKED allowlist."
      had_failure=1
    fi
  done < <(grep -n 'func ' "$coord_file" | grep -v 'private func' | sed -n 's/.*func \([a-zA-Z_][a-zA-Z0-9_]*\)(.*/\1/p')

  return $had_failure
}

# ──────────────────────────────────────────────────────────────
# Rule 3 — Dead placeholder rows
# No isEnabled: false within a few lines of "not available yet" /
# "coming soon" / "not supported yet" under Voxglass/Features/.
# ──────────────────────────────────────────────────────────────
check_dead_placeholders() {
  local had_failure=0

  local matches
  matches=$(grep -rln -E 'isEnabled:\s*false' Voxglass/Features --include='*.swift' 2>/dev/null \
    | xargs grep -ln -E 'not available yet|coming soon|not supported yet|Bundled metadata is not available' 2>/dev/null || true)

  if [ -n "$matches" ]; then
    while IFS= read -r file; do
      local line
      line=$(grep -n -E 'isEnabled:\s*false' "$file" 2>/dev/null | head -1 | cut -d: -f1)
      echo "::error title=Dead-placeholder-row guard::File $file has a disabled row at line $line with dead placeholder text."
      had_failure=1
    done <<< "$matches"
  fi

  return $had_failure
}

# ──────────────────────────────────────────────────────────────
# Rule 4 — Pro feature advertisement enforcement
# Every ProFeatureAdvertisement.feature in the paywall appears in a
# real ProFeature.isEnabled(.x) call somewhere in the source.
# ──────────────────────────────────────────────────────────────
check_pro_feature_enforcement() {
  local paywall_file="Voxglass/Features/Settings/ProPaywallView.swift"
  local had_failure=0

  while IFS= read -r feature_case; do
    [ -z "$feature_case" ] && continue

    local usage_count
    usage_count=$(grep -r "ProFeature.isEnabled(.$feature_case)" Voxglass --include='*.swift' -l 2>/dev/null | wc -l | tr -d ' ')

    if [ "$usage_count" -eq 0 ]; then
      echo "::error title=Pro-feature-enforcement guard::Advertised feature '.$feature_case' has zero ProFeature.isEnabled(.$feature_case) calls anywhere in the codebase."
      had_failure=1
    fi
  done < <(sed -n 's/.*feature:\s*\.\([a-zA-Z_][a-zA-Z0-9_]*\).*/\1/p' "$paywall_file")

  return $had_failure
}

# ──────────────────────────────────────────────────────────────
# Rule 5 — Dynamic Type guard
# No bare .font(.system(size:) in SwiftUI files (except the modifier
# implementation itself). Ported from DynamicTypeGuardTests.
# ──────────────────────────────────────────────────────────────
check_dynamic_type() {
  local had_failure=0

  local violations
  violations=$(grep -rn '\.font(.system(' Voxglass --include='*.swift' 2>/dev/null \
    | grep 'size:' \
    | grep -v 'ScaledFontModifier.swift' || true)

  if [ -n "$violations" ]; then
    echo "::error title=Dynamic Type guard::Bare .font(.system(size:) without Dynamic Type support found. Use .scaledFont(size: X) instead."
    while IFS= read -r v; do
      echo "::error file=${v%%:*},line=${v}" | sed 's/\(.*\),line=\(.*\):\(.*\)/\1,line=\2::\3/'
    done <<< "$violations"
    had_failure=1
  fi

  return $had_failure
}

# ──────────────────────────────────────────────────────────────
# Rule 6 — target-membership guard
# Every app-target .swift file on disk is a member of the xcodeproj.
# Catches the "added a source file, never regenerated the project"
# bug, which the compiler only reports as `cannot find type X in
# scope` — and which the ubuntu job cannot see any other way, because
# it has no Swift toolchain. Pure grep, so it runs everywhere.
# Voxglass/Core/ and VoxglassTests/ are excluded: they are VoxglassCore
# SwiftPM package sources (see Package.swift; project.yml excludes Core
# from the app target), compiled by the `compile` and `logic-tests`
# jobs, so xcodeproj membership does not apply to them.
# ──────────────────────────────────────────────────────────────
check_xcodeproj_membership() {
  local pbxproj="Voxglass.xcodeproj/project.pbxproj"
  local had_failure=0

  while IFS= read -r file; do
    [ -z "$file" ] && continue
    if ! grep -q "$(basename "$file")" "$pbxproj"; then
      echo "::error title=Target-membership guard::$file is on disk but is not a member of any xcodeproj target. Run 'xcodegen generate' and commit the result."
      had_failure=1
    fi
  done < <(find Voxglass VoxglassUITests -name '*.swift' -not -path 'Voxglass/Core/*' 2>/dev/null)

  return $had_failure
}

# ──────────────────────────────────────────────────────────────
# Rule 7 — xcodeproj drift guard
# If xcodegen is available, regenerate and diff. Note: `--project`
# takes the *output directory*, not the project path — passing
# `--project Voxglass.xcodeproj` writes a nested
# Voxglass.xcodeproj/Voxglass.xcodeproj and silently diffs nothing.
# Otherwise, assert project.yml and the xcodeproj moved together.
# ──────────────────────────────────────────────────────────────
check_xcodeproj_drift() {
  local had_failure=0

  if command -v xcodegen &>/dev/null; then
    xcodegen generate --spec project.yml --quiet 2>/dev/null || true
    if ! git diff --exit-code -- Voxglass.xcodeproj >/dev/null 2>&1; then
      echo "::error title=Xcodeproj drift guard::project.yml and Voxglass.xcodeproj are out of sync. Run 'xcodegen generate' and commit the result."
      git diff --stat -- Voxglass.xcodeproj
      had_failure=1
    fi
  else
    local commit_range="${GITHUB_BASE_REF:-HEAD~1..HEAD}"
    local yml_touched proj_touched
    yml_touched=$(git diff --name-only "$commit_range" -- project.yml 2>/dev/null | wc -l | tr -d ' ')
    proj_touched=$(git diff --name-only "$commit_range" -- Voxglass.xcodeproj 2>/dev/null | wc -l | tr -d ' ')

    if [ "$yml_touched" -gt 0 ] && [ "$proj_touched" -eq 0 ]; then
      echo "::error title=Xcodeproj drift guard::project.yml was modified but Voxglass.xcodeproj was not regenerated."
      echo "Run 'xcodegen generate' and commit the result."
      had_failure=1
    fi
  fi

  return $had_failure
}

# ──────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────

echo "=== guard_wiring.sh — source-level wiring guards ==="
echo ""

SUMMARY_FILE="$(mktemp)"
trap 'rm -f "$SUMMARY_FILE"' EXIT

run_check() {
  local name="$1"
  local fn="$2"
  printf "  %-28s " "$name"
  if "$fn"; then
    echo "PASS"
    echo "$name:PASS" >> "$SUMMARY_FILE"
  else
    echo "FAIL"
    echo "$name:FAIL" >> "$SUMMARY_FILE"
    VIOLATIONS=$((VIOLATIONS + 1))
  fi
}

run_check "preference-key writers"  check_pref_key_writers
run_check "coordinator callers"     check_coordinator_callers
run_check "dead placeholder rows"   check_dead_placeholders
run_check "pro-feature enforcement" check_pro_feature_enforcement
run_check "Dynamic Type"            check_dynamic_type
run_check "target membership"       check_xcodeproj_membership
run_check "xcodeproj drift"         check_xcodeproj_drift

echo ""
echo "=== Summary ==="
while IFS=: read -r name result; do
  printf "  %-28s %s\n" "$name" "$result"
done < "$SUMMARY_FILE"
echo ""

if [ "$VIOLATIONS" -gt 0 ]; then
  echo "$VIOLATIONS guard(s) failed. Fix the violations above before merging."
  exit 1
fi

echo "All guards passed."
exit 0
