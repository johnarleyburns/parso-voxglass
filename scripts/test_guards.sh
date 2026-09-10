#!/bin/bash
# test_guards.sh — self-test proving the grep gates can fail (gate G-19).
#
# Each grep gate in guard_production.sh gets a planted probe; the guard MUST
# fail on it, and MUST pass once the probe is removed. A gate that cannot fail
# is not a gate: this script is the regression test for the gates themselves.
#
# Usage: scripts/test_guards.sh
#   exit 0 = every gate fails on its probe and passes without it
#   exit 1 = at least one gate is broken

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

FAILURES=0
PROBES=()
RESTORE_ITEMS=()

cleanup() {
  for p in "${PROBES[@]:-}"; do
    rm -f "$p"
  done
  for item in "${RESTORE_ITEMS[@]:-}"; do
    mv "${item}.probe-hidden" "$item" 2>/dev/null || true
  done
}
# CI can terminate a long self-test while a probe is planted. Clean up on the
# common termination signals as well as normal exit so a cancelled run cannot
# poison the next guard invocation or the working tree.
trap cleanup EXIT
trap 'exit 143' INT TERM HUP

pass() { echo "ok: $1"; }
fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }

# run_guard prints the combined guard output; returns 0 when it passes.
run_guard() {
  bash scripts/guard_production.sh 2>&1 || true
}

# expect_guard_fails <gate-label> <description>
# Asserts the guard exits non-zero AND names the given gate.
expect_guard_fails() {
  local gate="$1" description="$2" out
  out="$(run_guard)"
  if [ "$(bash scripts/guard_production.sh >/dev/null 2>&1; echo $?)" -eq 0 ]; then
    fail "guard passed while probe planted: $description"
  fi
  if printf '%s' "$out" | grep -q "G-${gate}:"; then
    pass "probe for $description caught by G-${gate}"
  else
    fail "probe for $description was NOT caught by G-${gate} (guard output: $out)"
  fi
}

# expect_guard_passes <description>
expect_guard_passes() {
  local description="$1"
  if bash scripts/guard_production.sh >/dev/null 2>&1; then
    pass "guard passes after removing probe: $description"
  else
    fail "guard fails after removing probe: $description (probe not fully cleaned?)"
  fi
}

plant() { # <path> <content>
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" > "$1"
  PROBES+=("$1")
}
unplant() { rm -f "$1"; }

# ──────────────────────────────────────────────────────────────
# Baseline: the guards must be green before any probe is planted.
# ──────────────────────────────────────────────────────────────
if ! bash scripts/guard_production.sh >/dev/null 2>&1; then
  fail "baseline guard_production.sh must pass before probes are planted"
else
  pass "baseline guard_production.sh"
fi

# ──────────────────────────────────────────────────────────────
# G-1 probes: AVSpeechSynthesizer symbol and CoreML import.
# ──────────────────────────────────────────────────────────────
probe="Voxglass/Core/Production/ProbeG1Synthesizer.swift"
plant "$probe" "let s = AVSpeechSynthesizer()"
expect_guard_fails 1 "AVSpeechSynthesizer in Core/Production"
unplant "$probe"
expect_guard_passes "AVSpeechSynthesizer probe"

probe="Voxglass/Core/Production/ProbeG1CoreML.swift"
plant "$probe" "import CoreML"
expect_guard_fails 1 "import CoreML in Core/Production"
unplant "$probe"
expect_guard_passes "CoreML import probe"

# ──────────────────────────────────────────────────────────────
# G-2 probe: entitlement symbol in a free-territory filename.
# ──────────────────────────────────────────────────────────────
probe="Voxglass/Features/Production/RecordingProbe.swift"
plant "$probe" "let g: LicenseGate? = nil"
expect_guard_fails 2 "LicenseGate in Features/Production/RecordingProbe"
unplant "$probe"
expect_guard_passes "LicenseGate probe"

# ──────────────────────────────────────────────────────────────
# G-4 probe: removing every SHA256Hex from Production/Assembly.
# ──────────────────────────────────────────────────────────────
target="Voxglass/Core/Production/Assembly/RenderPlan.swift"
if [ -f "$target" ]; then
  mv "$target" "${target}.probe-hidden"
  RESTORE_ITEMS+=("$target")
  expect_guard_fails 4 "Assembly contains no SHA256Hex"
  mv "${target}.probe-hidden" "$target"
  RESTORE_ITEMS=()
  expect_guard_passes "Assembly SHA256Hex restore"
else
  fail "G-4 probe: $target does not exist"
fi

# ──────────────────────────────────────────────────────────────
# G-5 probe: CloudKit in the watch target (spec G-W1 / R-7).
# ──────────────────────────────────────────────────────────────
probe="VoxglassWatch/Production/ProbeG5.swift"
plant "$probe" "import CloudKit"
expect_guard_fails 5 "CloudKit import in VoxglassWatch"
unplant "$probe"
expect_guard_passes "watch CloudKit isolation probe"

# ──────────────────────────────────────────────────────────────
# G-7 probe: bare UUID() in Core/Production/Domain.
# ──────────────────────────────────────────────────────────────
probe="Voxglass/Core/Production/Domain/ProbeG7.swift"
plant "$probe" "let id = UUID()"
expect_guard_fails 7 "bare UUID() in Core/Production/Domain"
unplant "$probe"
expect_guard_passes "bare UUID() probe"

# ──────────────────────────────────────────────────────────────
# G-10 probe: literal platform number in Validation/.
# ──────────────────────────────────────────────────────────────
probe="Voxglass/Core/Production/Validation/ProbeG10.swift"
plant "$probe" "let b = 192"
expect_guard_fails 10 "literal 192 in Validation/"
unplant "$probe"
expect_guard_passes "destination constant probe"

# ──────────────────────────────────────────────────────────────
# G-P2 probe: a license gate in the Internet Archive builder.
# ──────────────────────────────────────────────────────────────
probe="Voxglass/Core/Production/Packaging/InternetArchivePackageBuilder.swift"
if [ -f "$probe" ]; then
  mv "$probe" "${probe}.probe-hidden"
  printf '%s\n' "public struct InternetArchivePackageBuilder { let gate: LicenseGate?; let f: ProFeature? }" > "$probe"
  expect_guard_fails "P2" "license gate referenced in Internet Archive builder"
  rm -f "$probe"
  mv "${probe}.probe-hidden" "$probe"
  expect_guard_passes "Internet Archive builder clean"
else
  fail "G-P2 probe: $probe does not exist"
fi

# ──────────────────────────────────────────────────────────────
# G-P6 probes: the deleted Studio module in a source file, in a project
# manifest, and as a reappearing directory.
# ──────────────────────────────────────────────────────────────
probe="Voxglass/Core/Production/ProbeGP6.swift"
plant "$probe" "import VoxglassStudioKit"
expect_guard_fails "P6" "VoxglassStudioKit reference in source"
unplant "$probe"
expect_guard_passes "VoxglassStudioKit source probe"

probe="Voxglass/Core/Production/ProbeGP6b.swift"
plant "$probe" "let x = VoxglassStudio"
expect_guard_fails "P6" "VoxglassStudio reference in source"
unplant "$probe"
expect_guard_passes "VoxglassStudio source probe"

probe_dir="VoxglassStudio"
mkdir -p "$probe_dir"
plant "$probe_dir/ProbeDir.swift" "let x = 1"
expect_guard_fails "P6" "VoxglassStudio tree reappeared"
rm -rf "$probe_dir"
expect_guard_passes "VoxglassStudio tree probe"

# ──────────────────────────────────────────────────────────────
# G-P7 probe: the legacy Pro product id in a source file.
# ──────────────────────────────────────────────────────────────
probe="Voxglass/Core/Production/ProbeGP7.swift"
plant "$probe" "let legacy = \"voxglass.studio.pro\""
expect_guard_fails "P7" "legacy product id reference"
unplant "$probe"
expect_guard_passes "legacy product id probe"

# ──────────────────────────────────────────────────────────────
# G-15 probe (N-1): a start-narrating CTA without a recordableOniOS gate, and
# a reintroduced LongWorkHandoff reference.
# ──────────────────────────────────────────────────────────────
probe="Voxglass/Features/Production/Discovery/ProbeG15.swift"
plant "$probe" 'struct X { let cta = "Start narrating" }'
expect_guard_fails 15 "start-narrating CTA without a recordableOniOS gate"
unplant "$probe"
expect_guard_passes "G-15 recordableOniOS gate probe"

probe="Voxglass/Features/Production/Discovery/ProbeG15b.swift"
plant "$probe" 'struct X { let handoff = LongWorkHandoff }'
expect_guard_fails 15 "retired LongWorkHandoff reference"
unplant "$probe"
expect_guard_passes "G-15 handoff-retired probe"

# ──────────────────────────────────────────────────────────────
# G-P3 probe: a ProductionStudio reference under a shipping surface.
# ──────────────────────────────────────────────────────────────
probe="Voxglass/Features/Production/Discovery/ProbeGP3.swift"
plant "$probe" 'struct X { let studio = ProductionStudio }'
expect_guard_fails "P3" "ProductionStudio reference under Features"
unplant "$probe"
expect_guard_passes "G-P3 ProductionStudio probe"

# ──────────────────────────────────────────────────────────────
# G-P4 probe: a color literal in a production surface.
# ──────────────────────────────────────────────────────────────
probe="Voxglass/Features/Production/Discovery/ProbeGP4.swift"
plant "$probe" 'struct X { let c = Color(hex: 0x21170B) }'
expect_guard_fails "P4" "color literal in production surface"
unplant "$probe"
expect_guard_passes "G-P4 color literal probe"

# ──────────────────────────────────────────────────────────────
# G-U1 probes (replaces G-P5): the retired Mac-handoff phrasing, not the bare
# word "Mac" (which is now legitimate — U-2, §0.6). One probe per phrase, one
# per surface, so the "everywhere" claim is actually exercised.
# ──────────────────────────────────────────────────────────────
probe="Voxglass/Features/Production/ProbeGU1.swift"
plant "$probe" 'let caption = "Continue on Mac"'
expect_guard_fails "U1" "retired 'Continue on Mac' phrasing in Features/Production"
unplant "$probe"
expect_guard_passes "G-U1 Continue-on-Mac probe"

probe="VoxglassWatch/Production/ProbeGU1.swift"
plant "$probe" 'let caption = "Record on Mac"'
expect_guard_fails "U1" "retired 'Record on Mac' phrasing in Watch/Production"
unplant "$probe"
expect_guard_passes "G-U1 watch Record-on-Mac probe"

probe="VoxglassMac/ProbeGU1.swift"
plant "$probe" 'let caption = "Requires a Mac"'
expect_guard_fails "U1" "retired 'Requires a Mac' phrasing in VoxglassMac"
unplant "$probe"
expect_guard_passes "G-U1 VoxglassMac Requires-a-Mac probe"

probe="Voxglass/Features/Production/ProbeGU1b.swift"
plant "$probe" 'let caption = "Recording on your Mac keeps your book in one place"'
expect_guard_passes "G-U1 bare 'Mac' word is legitimate (U-2)"
unplant "$probe"

# ──────────────────────────────────────────────────────────────
# G-U2 probe: a platform UI import reintroduced into Core/Production.
# ──────────────────────────────────────────────────────────────
probe="Voxglass/Core/Production/ProbeGU2.swift"
plant "$probe" 'import AppKit'
expect_guard_fails "U2" "AppKit import in Core/Production"
unplant "$probe"
expect_guard_passes "G-U2 Core platform-free probe"

# ──────────────────────────────────────────────────────────────
# G-U3 probe: the Mac bundle id line removed from project.yml, and the dead
# Studio bundle id reintroduced.
# ──────────────────────────────────────────────────────────────
if [ -f project.yml ] && grep -q 'PRODUCT_BUNDLE_IDENTIFIER: guru.parso.voxglass$' project.yml; then
  cp project.yml project.yml.probe-hidden
  RESTORE_ITEMS+=("project.yml")
  # Comment out every exact-match line so none of the (possibly several)
  # occurrences survives to satisfy the gate.
  sed 's/^\([[:space:]]*PRODUCT_BUNDLE_IDENTIFIER: guru\.parso\.voxglass\)$/#\1/' project.yml > project.yml.tmp
  mv project.yml.tmp project.yml
  expect_guard_fails "U3" "no PRODUCT_BUNDLE_IDENTIFIER: guru.parso.voxglass line in project.yml"
  mv project.yml.probe-hidden project.yml
  RESTORE_ITEMS=()
  expect_guard_passes "G-U3 bundle id restored"
else
  fail "G-U3 probe: project.yml has no 'PRODUCT_BUNDLE_IDENTIFIER: guru.parso.voxglass' line to remove"
fi

probe="project.yml.gu3-dead-id-probe"
if [ -f project.yml ]; then
  cp project.yml "$probe"
  printf '\n# PRODUCT_BUNDLE_IDENTIFIER: guru.parso.voxglass.studio\n' >> project.yml
  expect_guard_fails "U3" "dead Studio bundle id reintroduced in project.yml"
  mv "$probe" project.yml
else
  fail "G-U3 dead-id probe: project.yml does not exist"
fi

# ──────────────────────────────────────────────────────────────
# G-P4 probe (VoxglassMac extension): a color literal in the Mac tree,
# outside its palette definition file.
# ──────────────────────────────────────────────────────────────
probe="VoxglassMac/Features/ProbeGP4.swift"
plant "$probe" 'struct X { let c = Color(hex: 0x21170B) }'
expect_guard_fails "P4" "color literal in VoxglassMac feature code"
unplant "$probe"
expect_guard_passes "G-P4 VoxglassMac color literal probe"

# ──────────────────────────────────────────────────────────────
# G-P6 probe (VoxglassMac extension): the deleted Studio module reintroduced
# in the resurrected tree's own directories.
# ──────────────────────────────────────────────────────────────
probe="VoxglassMacTests/ProbeGP6.swift"
plant "$probe" 'import VoxglassStudioKit'
expect_guard_fails "P6" "VoxglassStudioKit reference in VoxglassMacTests"
unplant "$probe"
expect_guard_passes "G-P6 VoxglassMacTests probe"

# ──────────────────────────────────────────────────────────────
# G-P7 probe (VoxglassMac extension): the legacy product id reintroduced in
# the Mac tree.
# ──────────────────────────────────────────────────────────────
probe="VoxglassMac/Services/ProbeGP7.swift"
plant "$probe" 'let legacy = "voxglass.studio.pro"'
expect_guard_fails "P7" "legacy product id reference in VoxglassMac"
unplant "$probe"
expect_guard_passes "G-P7 VoxglassMac probe"

# ──────────────────────────────────────────────────────────────
# G-2 / G-U5 probe: a Pro gate in a free-territory Mac file.
# ──────────────────────────────────────────────────────────────
probe="VoxglassMac/Features/Record/RecordingProbe.swift"
plant "$probe" 'let g: LicenseGate? = nil'
expect_guard_fails 2 "LicenseGate in VoxglassMac/Features/Record"
unplant "$probe"
expect_guard_passes "G-U5 VoxglassMac LicenseGate placement probe"

# ──────────────────────────────────────────────────────────────
# G-3 / G-U4 probe: ObservableObject reintroduced in VoxglassMac.
# ──────────────────────────────────────────────────────────────
probe="VoxglassMac/Features/ProbeGU4.swift"
plant "$probe" 'class X: ObservableObject {}'
expect_guard_fails 3 "ObservableObject in VoxglassMac"
unplant "$probe"
expect_guard_passes "G-U4 VoxglassMac ObservableObject probe"

# ──────────────────────────────────────────────────────────────
if ! bash "$SCRIPT_DIR/guard_watch_foundation.sh"; then
  FAILURES=$((FAILURES + 1))
fi

echo
if [ "$FAILURES" -gt 0 ]; then
  echo "test_guards: $FAILURES failure(s) found" >&2
  exit 1
fi
echo "test_guards: all gates fail on their probes and pass without them"
