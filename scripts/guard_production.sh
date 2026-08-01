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
# G-6: Eligibility wired (EligibilityProfile in LibriVox builder).
# Deferred until S<n>: LibriVoxPackageBuilder does not exist yet.
# ──────────────────────────────────────────────────────────────

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
# G-8: Deferred until S<n> — not yet implemented.
# ──────────────────────────────────────────────────────────────

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
check_determinism_seams
check_no_test_support

if [ "$VIOLATIONS" -gt 0 ]; then
  echo "guard_production: $VIOLATIONS violation(s) found" >&2
  exit 1
fi

echo "guard_production: all guards passed"
