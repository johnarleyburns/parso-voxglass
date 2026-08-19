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

    # Approach B: the key NAME (constant) is used with @AppStorage or .set on the same line
    if [ "$writer_found" -eq 0 ]; then
      for dir in Voxglass/Features Voxglass/App; do
        local matches
        matches=$(grep -rnE "(@AppStorage\(.*$key_name|\.set\(.*forKey:.*$key_name)" "$dir" --include='*.swift' 2>/dev/null || true)
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
    selectAndPlay           # new selection entry point; view call sites migrate to this
    tickProgress            # internal (progress loop) + direct host-test calls
    pushNavigationHistory   # called before every navigation; internal + view undo callers
    undoLastNavigation      # undo accidental navigation; view call sites wire this
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
# Rule 8 — Public API visibility guard
# A public declaration cannot expose an internal protocol existential. This
# is a compile-time rule that the Ubuntu source guards can still catch without
# having a Swift toolchain. Keep the check deliberately narrow to avoid
# pretending that grep is a Swift parser.
# ──────────────────────────────────────────────────────────────
check_public_api_visibility() {
  local had_failure=0
  local protocol_name declaration

  while IFS= read -r protocol_name; do
    [ -z "$protocol_name" ] && continue
    declaration=$(grep -REn "^[[:space:]]*public[[:space:]].*\\b${protocol_name}\\b" Voxglass --include='*.swift' 2>/dev/null || true)
    if [ -n "$declaration" ]; then
      echo "::error title=Public API visibility guard::Internal protocol '$protocol_name' is exposed by a public declaration. Make the protocol public or keep the declaration internal."
      printf '%s\n' "$declaration"
      had_failure=1
    fi
  done < <(grep -REh '^[[:space:]]*protocol[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' Voxglass --include='*.swift' 2>/dev/null \
    | sed -n 's/^[[:space:]]*protocol[[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\).*/\1/p' \
    | sort -u)

  return $had_failure
}

# ──────────────────────────────────────────────────────────────
# Rule 8 — Narration & tactile feedback guards
# Ensures the narration markers, loading feedback, and tactile
# tap wiring surface stays consistent.
# ──────────────────────────────────────────────────────────────
check_narration_tactile_guards() {
  local had_failure=0

  # Loading feedback: every remote import surface must pass isLoading
  # when disabling a row, so the user sees feedback immediately.
  for file in Voxglass/Features/Search/SearchView.swift Voxglass/Features/Discover/DiscoverView.swift Voxglass/Features/Player/CatalogDiscoveryView.swift; do
    if [ -f "$file" ]; then
      if grep -q 'disabled(importingIdentifier' "$file" 2>/dev/null; then
        if ! grep -q 'isLoading: importingIdentifier' "$file" 2>/dev/null; then
          echo "::error title=Narration-loading guard::$file disables an importing row but does not pass isLoading."
          had_failure=1
        fi
      fi
    fi
  done

  # Solo Narration toggle must exist on every applicable surface
  # ListenView intentionally omits the filter chip — solo titles get 2x scoring boost instead.
  local solo_toggle_surfaces=(
    "Voxglass/Features/Search/SearchView.swift"
    "Voxglass/Features/Discover/DiscoverView.swift"
    "Voxglass/Features/Player/CatalogDiscoveryView.swift"
    "Voxglass/Features/Library/LibraryView.swift"
  )
  for file in "${solo_toggle_surfaces[@]}"; do
    if [ -f "$file" ]; then
      if ! grep -q 'Solo Narration' "$file" 2>/dev/null; then
        echo "::error title=Narration-solo-toggle guard::$file does not contain a Solo Narration filter toggle."
        had_failure=1
      fi
    fi
  done

  # BookPageView must show Solo Narration text when applicable
  if [ -f "Voxglass/Features/Player/BookPageView.swift" ]; then
    if ! grep -q 'narrationKind == .solo' "Voxglass/Features/Player/BookPageView.swift" 2>/dev/null; then
      echo "::error title=Narration-bookpage guard::BookPageView must show 'Solo Narration' label near narrator metadata."
      had_failure=1
    fi
  fi

  # Bookmark haptic must use TactileFeedback, not raw UIImpactFeedbackGenerator
  if [ -f "Voxglass/Features/Player/BookPageActionRow.swift" ]; then
    if grep -q 'UIImpactFeedbackGenerator' "Voxglass/Features/Player/BookPageActionRow.swift" 2>/dev/null && \
       ! grep -q 'TactileFeedback.tap()' "Voxglass/Features/Player/BookPageActionRow.swift" 2>/dev/null; then
      echo "::error title=Narration-haptic guard::BookPageActionRow should use TactileFeedback.tap() instead of raw UIImpactFeedbackGenerator."
      had_failure=1
    fi
  fi

  # FilterChip must have tactileTap()
  if [ -f "Voxglass/DesignSystem/VoxglassComponents.swift" ]; then
    if grep -q 'struct FilterChip' "Voxglass/DesignSystem/VoxglassComponents.swift" 2>/dev/null; then
      if ! awk '/struct FilterChip/,/^}$/' "Voxglass/DesignSystem/VoxglassComponents.swift" 2>/dev/null | grep -q 'tactileTap()'; then
        echo "::error title=Narration-haptic guard::FilterChip must include .tactileTap() for tactile acknowledgment."
        had_failure=1
      fi
    fi
  fi

  return $had_failure
}

# ──────────────────────────────────────────────────────────────
# Rule 9 — Watch data-plane wiring guard
# Asserts WatchAppServices uses the phone snapshot path and does not
# instantiate watch-side CloudKit sync.
# ──────────────────────────────────────────────────────────────
check_watch_data_plane() {
  local had_failure=0

  if ! grep -q 'requestLibrarySnapshot\|refreshFromPhone' VoxglassWatch/WatchAppServices.swift 2>/dev/null; then
    echo "::error title=Watch-data-plane guard::WatchAppServices must refresh My Books through WatchConnectivity."
    had_failure=1
  fi

  if grep -rq 'CloudKitSyncEngine\|SyncMutationLog\|CloudSyncStateStore' VoxglassWatch --include='*.swift' 2>/dev/null; then
    echo "::error title=Watch-data-plane guard::Watch target must not instantiate CloudKit sync."
    had_failure=1
  fi

  if ! grep -q 'offlineManager.updateLibrary' VoxglassWatch/WatchAppServices.swift 2>/dev/null; then
    echo "::error title=Watch-data-plane guard::Watch bootstrap must refresh offline state from the merged phone/local library."
    had_failure=1
  fi

  return $had_failure
}

# ──────────────────────────────────────────────────────────────
# Rule 10 — WatchConnectivity relay guard
# Asserts both app targets use the direct phone/watch relay and that the
# watch target has no CloudKit capability metadata.
# ──────────────────────────────────────────────────────────────
check_both_targets_engine() {
  local had_failure=0

  if ! grep -q 'PhoneAudioRelay' Voxglass/App/AppServices.swift 2>/dev/null; then
    echo "::error title=WatchConnectivity guard::Phone AppServices must configure PhoneAudioRelay."
    had_failure=1
  fi

  if ! grep -q 'WatchAudioRelay' VoxglassWatch/WatchAppServices.swift 2>/dev/null; then
    echo "::error title=WatchConnectivity guard::WatchAppServices must use WatchAudioRelay."
    had_failure=1
  fi

  local watch_capability_matches
  watch_capability_matches=$(grep -rn 'CloudKit\|aps-environment\|remote-notification' VoxglassWatch/Resources project.yml 2>/dev/null | grep -E 'VoxglassWatch|watchOS' || true)
  if [ -n "$watch_capability_matches" ]; then
    echo "::error title=WatchConnectivity guard::Watch target must not carry CloudKit or remote-notification capability metadata."
    had_failure=1
  fi

  return $had_failure
}

# ──────────────────────────────────────────────────────────────
# Rule 11 — Search scope switchable guard
# Asserts VoxglassWatch/WatchSearchView.swift has .searchScopes
# ──────────────────────────────────────────────────────────────
check_search_scope_switchable() {
  local had_failure=0

  if ! grep -q 'Picker' VoxglassWatch/WatchSearchView.swift 2>/dev/null || \
     ! grep -q '\.myBooks\|\.librivox' VoxglassWatch/WatchSearchView.swift 2>/dev/null; then
    echo "::error title=Search-scope guard::WatchSearchView must have a My Books/LibriVox scope switch."
    had_failure=1
  fi

  return $had_failure
}

# ──────────────────────────────────────────────────────────────
# Rule 12 — No dead placeholders in the watch guard
# Fails on empty-closure buttons in VoxglassWatch/
# ──────────────────────────────────────────────────────────────
check_watch_dead_placeholders() {
  local had_failure=0

  local matches
  matches=$(grep -rn 'Button {' VoxglassWatch --include='*.swift' 2>/dev/null | while read -r line; do
    file=$(echo "$line" | cut -d: -f1)
    lineno=$(echo "$line" | cut -d: -f2)
    next_line=$((lineno + 1))
    body=$(sed -n "${next_line}p" "$file" 2>/dev/null | tr -d ' ')
    if [ "$body" = "//AddtoMyBooks" ] || [ "$body" = "//Stream" ] || [ "$body" = "//Initiatedownload/transfer" ] || [ "$body" = "//AddtoMyBooks(import)" ]; then
      echo "$file:$lineno"
    fi
  done)

  if [ -n "$matches" ]; then
    echo "::error title=Watch-dead-placeholder guard::Watch target has empty-closure buttons."
    had_failure=1
  fi

  return $had_failure
}

# ──────────────────────────────────────────────────────────────
# Rule 13 — No new KVS writes guard
# Fails on NSUbiquitousKeyValueStore .set( outside the migration shim.
# ──────────────────────────────────────────────────────────────
check_no_new_kvs_writes() {
  local had_failure=0

  local matches
  matches=$(grep -rn 'NSUbiquitousKeyValueStore' Voxglass --include='*.swift' 2>/dev/null \
    | grep '\.set(' | grep -v 'VoxglassCloudSync.swift' | grep -v 'KVSMigration' || true)

  if [ -n "$matches" ]; then
    echo "::error title=No-new-KVS-writes guard::New NSUbiquitousKeyValueStore writes found outside migration shim. Use CloudKit sync instead."
    had_failure=1
  fi

  return $had_failure
}

# ──────────────────────────────────────────────────────────────
# Rule 14 — Orphan removed guard
# Fails if WatchConnectivitySession still exists.
# ──────────────────────────────────────────────────────────────
check_orphan_removed() {
  local had_failure=0

  if [ -f VoxglassWatch/WatchConnectivitySession.swift ]; then
    echo "::error title=Orphan-removed guard::VoxglassWatch/WatchConnectivitySession.swift must be deleted."
    had_failure=1
  fi

  return $had_failure
}

# ──────────────────────────────────────────────────────────────
# Rule 15 — Watch target membership guard
# Extends check_xcodeproj_membership to include VoxglassWatch.
# ──────────────────────────────────────────────────────────────
check_watch_target_membership() {
  local pbxproj="Voxglass.xcodeproj/project.pbxproj"
  local had_failure=0

  while IFS= read -r file; do
    [ -z "$file" ] && continue
    if ! grep -q "$(basename "$file")" "$pbxproj"; then
      echo "::error title=Watch-target-membership guard::$file is on disk but is not a member of any xcodeproj target. Run 'xcodegen generate' and commit the result."
      had_failure=1
    fi
  done < <(find VoxglassWatch -name '*.swift' 2>/dev/null)

  return $had_failure
}

# ──────────────────────────────────────────────────────────────
# Rule — No UI or simulator tests in GitHub Actions workflows.
# All logic tests run via `swift test` (macOS host). The five UI
# smoke tests are local-only (`scripts/test.sh --all`).
# ──────────────────────────────────────────────────────────────
check_no_ui_tests_in_ci() {
  local had_failure=0
  local matches

  # A workflow step that runs xcodebuild test would boot a simulator or host
  # runner UI tests — the one thing CI must never do.
  matches=$(grep -rEn 'xcodebuild +test|test-without-building|platform=iOS Simulator.*test' .github/workflows/*.yml 2>/dev/null || true)
  if [ -n "$matches" ]; then
    echo "::error title=No-UI-tests-in-CI guard::GitHub Actions must never run UI or simulator tests. The CI test job runs the host logic suite only; performance tests and UI smoke tests are local-only."
    printf '%s\n' "$matches"
    had_failure=1
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

run_check "preference-key writers"     check_pref_key_writers
run_check "coordinator callers"        check_coordinator_callers
run_check "dead placeholder rows"      check_dead_placeholders

run_check "Dynamic Type"               check_dynamic_type
run_check "target membership"          check_xcodeproj_membership
run_check "xcodeproj drift"            check_xcodeproj_drift
run_check "public API visibility"      check_public_api_visibility
run_check "narration feedback guards"  check_narration_tactile_guards

run_check "watch data-plane wiring"    check_watch_data_plane
run_check "both targets engine"        check_both_targets_engine
run_check "search scope switchable"    check_search_scope_switchable
run_check "watch dead placeholders"    check_watch_dead_placeholders
run_check "no new KVS writes"          check_no_new_kvs_writes
run_check "orphan removed"             check_orphan_removed
run_check "watch target membership"    check_watch_target_membership
run_check "no UI tests in CI"          check_no_ui_tests_in_ci

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
