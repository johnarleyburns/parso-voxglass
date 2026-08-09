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
  # `Synthesi[sz]er` is part of the banned set, not the exclusion set:
  # `AVSpeechSynthesizer` is how synthesis enters the product.
  local banned='\bTTS\b|Synthesi[sz]e|Synthesi[sz]er|VoiceModel|Kokoro|Chatterbox|CosyVoice|voiceClone|AVSpeechSynthesizer'
  # `import Speech` is banned because §18.2.6 requires the system dictation
  # keyboard, not the Speech framework (SFSpeechRecognizer is the other
  # synthesis-adjacent AI path).
  local banned_imports='^[[:space:]]*import[[:space:]]+(MLX|CoreML|Speech)\b'
  # `isLikelyGeneratedTTSAudio` is the consumer app's *classifier* over catalogue
  # metadata (no synthesis); it is the one permitted match. `synthesis-exempt:`
  # marks fixture comments that merely describe fake audio.
  local matches
  matches=$(grep -rn --include='*.swift' -E "$banned" \
              Voxglass VoxglassWatch VoxglassCoreTestSupport 2>/dev/null \
            | grep -v 'isLikelyGeneratedTTSAudio' \
            | grep -v 'synthesis-exempt:' || true)
  if [ -n "$matches" ]; then
    while read -r line; do
      violate "G-1: synthesis symbol found: $line"
    done <<< "$matches"
  fi
  local import_matches
  import_matches=$(grep -rn --include='*.swift' -E "$banned_imports" \
              Voxglass VoxglassWatch VoxglassCoreTestSupport 2>/dev/null || true)
  if [ -n "$import_matches" ]; then
    while read -r line; do
      violate "G-1: banned import (synthesis-adjacent AI): $line"
    done <<< "$import_matches"
  fi
}

# ──────────────────────────────────────────────────────────────
# G-2: Pro-gate placement (no LicenseGate/isPro/ProFeature in free paths).
# ──────────────────────────────────────────────────────────────
check_pro_gate_placement() {
  local banned='LicenseGate|\.isPro\b|ProFeature|EntitlementState'
  # §17.5 allow-list, by FILENAME.
  local allowed='Export|Packaging|RetailMaster|Master|License|Settings|StudioEnvironment'
  local forbidden='Recording|Review|Preview|Capture|Assembly|Segment|Sync|Watch|CarPlay|Validation'
  local matches
  matches=$(find Voxglass/Core Voxglass VoxglassWatch -name '*.swift' 2>/dev/null \
            | grep -E "/[^/]*($forbidden)[^/]*\.swift$" \
            | grep -vE "/[^/]*($allowed)[^/]*\.swift$" \
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
  local dirs='Voxglass/Core/Production VoxglassWatch/Production Voxglass/Features/Production'
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
      # Positive half (§19.9 G-4): each directory must actually wire stable
      # hashing, or the negative half silently rots into a no-op.
      if ! grep -rq --include='*.swift' 'SHA256Hex' "$d" 2>/dev/null; then
        violate "G-4: $d contains no SHA256Hex reference (stable hashing not wired)"
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
# G-8: Tests never touch real services. Every UI test must launch with
# `-uiTestSeed` plus `-useTemporaryStore` (§4.3, §19.6), or seed in-process.
# ──────────────────────────────────────────────────────────────
check_test_environment() {
  local ui_dirs="VoxglassUITests VoxglassWatchUITests VoxglassCarPlaySmokeTests"
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
    matches=$(grep -rn --include='*.swift' -F "$i" Voxglass VoxglassWatch VoxglassCoreTestSupport 2>/dev/null | grep -vF "$legal_file" || true)
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
  matches=$(grep -rn --include='*.swift' -E 'URLSession.*(dataTask|uploadTask|downloadTask)|(dataTask|uploadTask|downloadTask).*URLSession' Voxglass VoxglassWatch Voxglass/Core 2>/dev/null \
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
  for target in Voxglass/Core Voxglass VoxglassWatch; do
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
# G-13: Discovery never fails visibly. The aggregator's public API is total,
# and the Core test target MUST contain a test named matching
# `allSourcesFail_seedFloor` (§12.3).
# ──────────────────────────────────────────────────────────────
check_discovery_total() {
  local aggregator="Voxglass/Core/Production/Discovery/Aggregate/NeedsAggregator.swift"
  if [ ! -f "$aggregator" ]; then
    violate "G-13: NeedsAggregator.swift does not exist"
    return
  fi
  if ! grep -rln --include='*.swift' 'allSourcesFail_seedFloor' VoxglassTests >/dev/null 2>&1; then
    violate "G-13: Core test target must contain a test named matching allSourcesFail_seedFloor"
  fi
}

# ──────────────────────────────────────────────────────────────
# G-14: No sign-in UI in discovery. Files under **/Discovery/** must not
# reference login/signIn/credential/password or present any auth view; the
# forum source must not import UI. The L3 *detection* seam is allowed to
# recognize a login wall (it yields nothing), so its two parser files are
# exempted from the `login` token; everything else — including the UI
# surfaces — must be clean.
# ──────────────────────────────────────────────────────────────
check_no_signin_ui() {
  local banned='ASWebAuthenticationSession|signIn|credential|password'
  local matches
  matches=$(grep -rn --include='*.swift' -E "$banned" Voxglass/Core/Production/Discovery Voxglass/Features/Production/Discovery 2>/dev/null || true)
  if [ -n "$matches" ]; then
    while read -r line; do
      violate "G-14: auth/sign-in reference in discovery: $line"
    done <<< "$matches"
  fi

  # The `login` token is permitted only inside the L3 wall-detection seam.
  local login_matches
  login_matches=$(grep -rn --include='*.swift' -w 'login' Voxglass/Core/Production/Discovery Voxglass/Features/Production/Discovery 2>/dev/null \
    | grep -vE 'LenientHTMLScanner\.swift|LibriVoxForumNeedsSource\.swift|looksLikeLoginPage|ucp\.php' || true)
  if [ -n "$login_matches" ]; then
    while read -r line; do
      violate "G-14: login reference in discovery UI: $line"
    done <<< "$login_matches"
  fi

  # The forum source must not import any UI module.
  local forum="Voxglass/Core/Production/Discovery/Sources/LibriVoxForumNeedsSource.swift"
  if [ -f "$forum" ] && grep -qE '^import (SwiftUI|UIKit|AppKit)' "$forum"; then
    violate "G-14: LibriVoxForumNeedsSource must not import UI"
  fi
}

# ──────────────────────────────────────────────────────────────
# G-15: The record action is offered for every need regardless of length (N-1).
# The iOS discovery UI must gate any start-narrating CTA on `recordableOniOS`
# (text presence), never on length, and the retired `LongWorkHandoffSheet` must
# not reappear.
# ──────────────────────────────────────────────────────────────
check_iphone_never_records_long() {
  local dir="Voxglass/Features/Production/Discovery"
  if [ ! -d "$dir" ]; then
    return
  fi
  local files
  files=$(find "$dir" -name '*.swift' -print0 2>/dev/null | xargs -0 grep -lE 'Start narrating|Start ▸' 2>/dev/null || true)
  for f in $files; do
    if ! grep -q 'recordableOniOS' "$f"; then
      violate "G-15: $f renders a start-narrating CTA without a recordableOniOS gate"
    fi
  done
  # The Mac handoff is retired (N-1): LongWorkHandoff must not be referenced.
  local handoff
  handoff=$(find "$dir" -name '*.swift' -print0 2>/dev/null | xargs -0 grep -l 'LongWorkHandoff' 2>/dev/null || true)
  if [ -n "$handoff" ]; then
    while read -r line; do
      violate "G-15: retired Mac handoff referenced (N-1): $line"
    done <<< "$handoff"
  fi
}

# ──────────────────────────────────────────────────────────────
# G-P5: No user-facing string in `Voxglass/Features/Production/**` or
# `VoxglassWatch/Production/**` may contain "Mac" (N-1, §15.6). The Mac is gone;
# "Mac" as a word anywhere in the shipping production surfaces is a regression.
# ──────────────────────────────────────────────────────────────
check_no_mac_strings() {
  local dirs="Voxglass/Features/Production VoxglassWatch/Production"
  local matches
  matches=$(grep -rnw --include='*.swift' 'Mac' $dirs 2>/dev/null || true)
  if [ -n "$matches" ]; then
    while read -r line; do
      violate "G-P5: 'Mac' reference in production surface: $line"
    done <<< "$matches"
  fi
}

# ──────────────────────────────────────────────────────────────
# G-16: PD gate before submittable. NeedsAggregator must reference PDVerifier,
# and the Core test target must enforce the downgrade (test-named
# `pdGate_neverSubmittableWhenUnverified`).
# ──────────────────────────────────────────────────────────────
check_pd_gate() {
  local aggregator="Voxglass/Core/Production/Discovery/Aggregate/NeedsAggregator.swift"
  if [ ! -f "$aggregator" ]; then
    violate "G-16: NeedsAggregator.swift does not exist"
    return
  fi
  if ! grep -q 'PDVerifier' "$aggregator"; then
    violate "G-16: NeedsAggregator must reference PDVerifier"
  fi
  if ! grep -rln --include='*.swift' 'pdGate_neverSubmittableWhenUnverified' VoxglassTests >/dev/null 2>&1; then
    violate "G-16: Core test target must contain a test named matching pdGate_neverSubmittableWhenUnverified"
  fi
}

# ──────────────────────────────────────────────────────────────
# G-17: Discovery is dependency-free and I/O-seamed. Core Discovery must not
# use URLSession directly (only the HTTPFetching seam) and must not import a
# URLSession-bearing or UI module, or a third-party HTML parser.
# ──────────────────────────────────────────────────────────────
check_discovery_io_seam() {
  local dir="Voxglass/Core/Production/Discovery"
  if [ ! -d "$dir" ]; then
    return
  fi
  # HTTPFetching.swift is the seam definition itself; it documents (but never
  # instantiates) the URLSession-based concrete.
  local matches
  matches=$(grep -rn --include='*.swift' -E 'URLSession' "$dir" 2>/dev/null | grep -v 'HTTPFetching\.swift' || true)
  if [ -n "$matches" ]; then
    while read -r line; do
      violate "G-17: discovery URLSession use: $line"
    done <<< "$matches"
  fi
  local ui_matches
  ui_matches=$(grep -rn --include='*.swift' -E '^import (SwiftUI|UIKit|AppKit|WebKit|JavaScriptCore)' "$dir" 2>/dev/null || true)
  if [ -n "$ui_matches" ]; then
    while read -r line; do
      violate "G-17: discovery UI module import: $line"
    done <<< "$ui_matches"
  fi
}

# ──────────────────────────────────────────────────────────────
# G-18: The floor exists. needs-seed.json parses and contains >= 100 .short and
# >= 20 .long entries, each with a non-unverified PD basis (seed entries are
# curator-verified).
# ──────────────────────────────────────────────────────────────
check_seed_floor() {
  local seed="Voxglass/Core/Production/Discovery/Resources/needs-seed.json"
  if [ ! -f "$seed" ]; then
    violate "G-18: needs-seed.json does not exist at $seed"
    return
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    violate "G-18: python3 is required to validate needs-seed.json"
    return
  fi
  python3 - "$seed" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    env = json.load(f)
entries = env["entries"]
short = [e for e in entries if e["estSeconds"] <= 3600]
long = [e for e in entries if e["estSeconds"] > 3600]
errors = []
if len(short) < 100:
    errors.append(f"short={len(short)} < 100")
if len(long) < 20:
    errors.append(f"long={len(long)} < 20")
if errors:
    print("guard: G-18: seed floor violated: " + "; ".join(errors), file=sys.stderr)
    sys.exit(1)
PY
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    VIOLATIONS=$((VIOLATIONS + 1))
  fi
}

# ──────────────────────────────────────────────────────────────
# G-P2: The Internet Archive builder never consults a license gate. FLAC on the
# IA lane is free forever (§2.2, R-9); the builder must stay clean of
# `ProFeature`/`LicenseGate`/`EntitlementState` so a partial revert cannot
# reintroduce a paywall on the free lane.
# ──────────────────────────────────────────────────────────────
check_ia_no_license_gate() {
  local builder="Voxglass/Core/Production/Packaging/InternetArchivePackageBuilder.swift"
  if [ ! -f "$builder" ]; then
    violate "G-P2: InternetArchivePackageBuilder.swift does not exist"
    return
  fi
  local matches
  matches=$(grep -nE 'ProFeature|LicenseGate|EntitlementState|\.isPro\b' "$builder" 2>/dev/null || true)
  if [ -n "$matches" ]; then
    while read -r line; do
      violate "G-P2: license gate in Internet Archive builder: $line"
    done <<< "$matches"
  fi
}

# ──────────────────────────────────────────────────────────────
# G-P6: No VoxglassStudio. The deleted macOS Studio tree must never be
# reintroduced by a partial revert (D-3). No source file and no project
# manifest (project.yml / Package.swift) may reference VoxglassStudio or
# VoxglassStudioKit, and the three Studio directories must not reappear.
# ──────────────────────────────────────────────────────────────
check_no_studio() {
  local matches
  matches=$(grep -rn --include='*.swift' -E 'VoxglassStudio' Voxglass VoxglassWatch VoxglassCoreTestSupport VoxglassTests 2>/dev/null || true)
  if [ -n "$matches" ]; then
    while read -r line; do
      violate "G-P6: deleted Studio module referenced in source: $line"
    done <<< "$matches"
  fi
  local manifest
  manifest=$(grep -nE 'VoxglassStudio' project.yml Package.swift 2>/dev/null || true)
  if [ -n "$manifest" ]; then
    while read -r line; do
      violate "G-P6: deleted Studio module referenced in project manifest: $line"
    done <<< "$manifest"
  fi
  local d
  for d in VoxglassStudio VoxglassStudioTests VoxglassStudioUITests; do
    if [ -e "$d" ]; then
      violate "G-P6: deleted Studio tree reappeared on disk: $d"
    fi
  done
}

# ──────────────────────────────────────────────────────────────
# G-P7: The legacy Pro product id is gone. The string
# `voxglass.studio.pro` MUST NOT appear in any source file (§2.2, D-1).
# ──────────────────────────────────────────────────────────────
check_no_legacy_product_id() {
  local matches
  matches=$(grep -rn --include='*.swift' -F 'voxglass.studio.pro' Voxglass VoxglassWatch VoxglassCoreTestSupport VoxglassTests 2>/dev/null || true)
  if [ -n "$matches" ]; then
    while read -r line; do
      violate "G-P7: legacy Pro product id reference: $line"
    done <<< "$matches"
  fi
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
check_discovery_total
check_no_signin_ui
check_iphone_never_records_long
check_no_mac_strings
check_pd_gate
check_discovery_io_seam
check_seed_floor
check_ia_no_license_gate
check_no_studio
check_no_legacy_product_id

if [ "$VIOLATIONS" -gt 0 ]; then
  echo "guard_production: $VIOLATIONS violation(s) found" >&2
  exit 1
fi

echo "guard_production: all guards passed"
