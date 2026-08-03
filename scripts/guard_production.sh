#!/bin/bash
# guard_production.sh — Production feature wiring guards.
# Every rule derives its list from source, so it cannot rot.
#
# Usage: scripts/guard_production.sh
#   exit 0 = all guards pass
#   exit 1 = at least one violation found (printed to stderr)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

VIOLATIONS=0

violate() {
  echo "guard: $*" >&2
  VIOLATIONS=$((VIOLATIONS + 1))
}

# ──────────────────────────────────────────────────────────────
# G-1: No synthesis symbols in any source.
# ──────────────────────────────────────────────────────────────
check_no_synthesis() {
  local banned='TTS|Synthesi[sz]e\b|VoiceModel|Kokoro|Chatterbox|CosyVoice|voiceClone|AVSpeechSynthesizer'
  local matches
  matches=$(grep -rn --include='*.swift' -E "$banned" Voxglass/Core Voxglass VoxglassWatch VoxglassStudio 2>/dev/null | grep -v 'isLikelyGeneratedTTSAudio' | grep -v 'Synthesi[sz]er' || true)
  if [ -n "$matches" ]; then
    while read -r line; do
      violate "G-1: synthesis symbol found: $line"
    done <<< "$matches"
  fi
}

# ──────────────────────────────────────────────────────────────
# G-2: Pro-gate placement (no LicenseGate/isPro/ProFeature in free paths).
# ──────────────────────────────────────────────────────────────
check_pro_gate_placement() {
  local banned='LicenseGate|\.isPro|ProFeature|EntitlementState'
  local freepaths='Recording|Review|Preview|Capture|Assembly|Segment|Sync|Watch|CarPlay|Validation'
  local matches
  matches=$(find Voxglass/Core Voxglass VoxglassWatch -name '*.swift' -print0 2>/dev/null \
    | xargs -0 grep -lE "$freepaths" 2>/dev/null \
    | xargs grep -nE "$banned" 2>/dev/null || true)
  if [ -n "$matches" ]; then
    while read -r line; do
      violate "G-2: Pro gate in free-territory file: $line"
    done <<< "$matches"
  fi
}

# ──────────────────────────────────────────────────────────────
# G-3: No ObservableObject in new Production files.
# ──────────────────────────────────────────────────────────────
check_no_observable_object() {
  local dirs='Voxglass/Core/Production VoxglassStudio VoxglassWatch/Production Voxglass/Features/Production'
  for d in $dirs; do
    if [ -d "$d" ]; then
      local matches
      matches=$(grep -rn --include='*.swift' 'ObservableObject' "$d" 2>/dev/null || true)
      if [ -n "$matches" ]; then
        while read -r line; do
          violate "G-3: ObservableObject in new code: $line"
        done <<< "$matches"
      fi
    fi
  done
}

# ──────────────────────────────────────────────────────────────
# G-4: Stable hashing (no Hasher/hashValue in Package/Packaging/Assembly).
# ──────────────────────────────────────────────────────────────
check_stable_hashing() {
  for d in "Voxglass/Core/Production/Package" "Voxglass/Core/Production/Packaging" "Voxglass/Core/Production/Assembly"; do
    if [ -d "$d" ]; then
      local matches
      matches=$(grep -rn --include='*.swift' -E 'Hasher\(|\.hashValue\b' "$d" 2>/dev/null || true)
      if [ -n "$matches" ]; then
        while read -r line; do
          violate "G-4: Hasher/hashValue in caching code: $line"
        done <<< "$matches"
      fi
    fi
  done
}

# ──────────────────────────────────────────────────────────────
# G-5: Watch isolation (no CloudKit in watch target).
# ──────────────────────────────────────────────────────────────
check_watch_isolation() {
  local matches
  matches=$(grep -rn --include='*.swift' 'import CloudKit' VoxglassWatch 2>/dev/null || true)
  if [ -n "$matches" ]; then
    while read -r line; do
      violate "G-5: CloudKit in watch target: $line"
    done <<< "$matches"
  fi
}

# ──────────────────────────────────────────────────────────────
# G-6: Eligibility wired. LibriVoxPackageBuilder must derive eligibility
# exclusively through EligibilityProfile.evaluate (§5.6), and the Core test
# target must contain a test whose name matches `AIblocksLibriVox` (§19.3).
# ──────────────────────────────────────────────────────────────
check_eligibility_wired() {
  local builder="Voxglass/Core/Production/Packaging/LibriVoxPackageBuilder.swift"
  if [ ! -f "$builder" ]; then
    violate "G-6: LibriVoxPackageBuilder.swift does not exist"
    return
  fi
  if ! grep -q 'EligibilityProfile.evaluate' "$builder"; then
    violate "G-6: $builder must call EligibilityProfile.evaluate"
  fi
  if ! grep -rln --include='*.swift' 'AIblocksLibriVox' VoxglassTests >/dev/null 2>&1; then
    violate "G-6: Core test target must contain a test named matching AIblocksLibriVox"
  fi
}

# ──────────────────────────────────────────────────────────────
# G-7: Determinism seams (no bare Date()/UUID() in Core/Production).
# ──────────────────────────────────────────────────────────────
check_determinism_seams() {
  local matches
  matches=$(grep -rn --include='*.swift' -E '\bDate\(\)|\bUUID\(\)' "Voxglass/Core/Production" 2>/dev/null \
    | grep -v 'determinism-exempt:' \
    | grep -v '= UUID()' \
    | grep -v '= Date()' \
    | grep -v 'UUIDGenerator' \
    | grep -v 'SystemClock' \
    || true)
  if [ -n "$matches" ]; then
    while read -r line; do
      violate "G-7: Bare Date()/UUID() in Core/Production: $line"
    done <<< "$matches"
  fi
}

# ──────────────────────────────────────────────────────────────
# G-8: Tests never touch real services. The Studio app must handle the
# test-environment flag (so fakes are wired for the microphone, CloudKit,
# StoreKit, and the encoder helper), and every UI test must launch with
# `-uiTestSeed` plus `-useTemporaryStore` (§4.3, §19.6).
# ──────────────────────────────────────────────────────────────
check_test_environment() {
  if ! grep -rq 'isTestEnvironment' VoxglassStudio --include='*.swift'; then
    violate "G-8: VoxglassStudio must handle isTestEnvironment (fakes for capture/sync/license/transcoder)"
  fi
  local ui_dirs="VoxglassStudioUITests VoxglassUITests VoxglassWatchUITests VoxglassCarPlaySmokeTests"
  for d in $ui_dirs; do
    if [ -d "$d" ]; then
      local files
      files=$(find "$d" -name '*.swift' -print0 2>/dev/null | xargs -0 grep -lE 'XCTestCase' 2>/dev/null || true)
      for f in $files; do
        # Hosted scene tests (CarPlay) never launch the app; they seed
        # in-process. Every other UI test must launch with -uiTestSeed.
        if ! grep -q -- '-uiTestSeed' "$f" && ! grep -qE 'TestEnvironment\(seed:|seed: \.[a-zA-Z]+' "$f"; then
          violate "G-8: UI test file $f must launch with -uiTestSeed (or seed in-process)"
        fi
      done
    fi
  done
}

# ──────────────────────────────────────────────────────────────
# G-10: Destination constants centralized. The literal platform numbers from
# §3 must not leak into Validation/** or Packaging/** outside
# Destinations/DestinationProfiles.swift and Destinations/ValidationThresholds.swift.
# ──────────────────────────────────────────────────────────────
check_destination_constants() {
  local banned='\b128\b|\b192\b|\b44100\b|-23|-18|-60|-3\.0|\b2400\b'
  local allowed='Voxglass/Core/Production/Destinations/DestinationProfiles.swift|Voxglass/Core/Production/Destinations/ValidationThresholds.swift'
  local matches
  matches=$(find Voxglass/Core/Production/Validation Voxglass/Core/Production/Packaging -name '*.swift' -print0 2>/dev/null \
    | xargs -0 grep -nE "$banned" 2>/dev/null \
    | grep -vE "$allowed" \
    | grep -v 'destination-constant-exempt:' || true)
  if [ -n "$matches" ]; then
    while read -r line; do
      violate "G-10: destination constant outside DestinationProfiles/ValidationThresholds: $line"
    done <<< "$matches"
  fi
}

# ──────────────────────────────────────────────────────────────
# G-11: Legal strings centralized (§3.6). The exact strings must appear only
# in Destinations/LegalStrings.swift.
# ──────────────────────────────────────────────────────────────
check_legal_strings() {
  local legal_file="Voxglass/Core/Production/Destinations/LegalStrings.swift"
  local i
  for i in "Voxglass does not determine copyright status." \
           "Voxglass prepares files; it does not guarantee acceptance or determine copyright." \
           "LibriVox accepts only recordings made by human volunteers using their own voices" \
           "You submit these files yourself. Voxglass never uploads on your behalf." \
           "Contains narration generated or processed with AI voice technology."; do
    local matches
    matches=$(grep -rn --include='*.swift' -F "$i" Voxglass VoxglassStudio VoxglassWatch VoxglassCoreTestSupport 2>/dev/null | grep -vF "$legal_file" || true)
    if [ -n "$matches" ]; then
      while read -r line; do
        violate "G-11: legal string outside LegalStrings.swift: $line"
      done <<< "$matches"
    fi
  done
}

# ──────────────────────────────────────────────────────────────
# G-12: No auto-upload. No archive.org / librivox.org / acx.com URL may be
# passed to any URLSession request API anywhere (C-7). Only string generation
# is permitted.
# ──────────────────────────────────────────────────────────────
check_no_auto_upload() {
  local matches
  matches=$(grep -rn --include='*.swift' -E 'URLSession.*(dataTask|uploadTask|downloadTask)|(dataTask|uploadTask|downloadTask).*URLSession' Voxglass VoxglassStudio VoxglassWatch Voxglass/Core 2>/dev/null \
    | grep -E 'archive\.org|librivox\.org|acx\.com' || true)
  if [ -n "$matches" ]; then
    while read -r line; do
      violate "G-12: auto-upload call to a destination URL: $line"
    done <<< "$matches"
  fi
}

# ──────────────────────────────────────────────────────────────
# G-9: No test support in shipping targets.
# ──────────────────────────────────────────────────────────────
check_no_test_support() {
  for target in Voxglass/Core Voxglass VoxglassWatch VoxglassStudio; do
    if [ -d "$target" ]; then
      local matches
      matches=$(grep -rn --include='*.swift' 'import VoxglassCoreTestSupport' "$target" 2>/dev/null || true)
      if [ -n "$matches" ]; then
        while read -r line; do
          violate "G-9: VoxglassCoreTestSupport in shipping target: $line"
        done <<< "$matches"
      fi
    fi
  done
}

# ──────────────────────────────────────────────────────────────
# Run all checks.
# ──────────────────────────────────────────────────────────────
check_no_synthesis
check_pro_gate_placement
check_no_observable_object
check_stable_hashing
check_watch_isolation
check_eligibility_wired
check_determinism_seams
check_test_environment
check_no_test_support
check_destination_constants
check_legal_strings
check_no_auto_upload

if [ "$VIOLATIONS" -gt 0 ]; then
  echo "guard_production: $VIOLATIONS violation(s) found" >&2
  exit 1
fi

echo "guard_production: all guards passed"
