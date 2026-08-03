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
trap cleanup EXIT

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
probe="VoxglassStudio/ProbeG1Synthesizer.swift"
plant "$probe" "let s = AVSpeechSynthesizer()"
expect_guard_fails 1 "AVSpeechSynthesizer in VoxglassStudio"
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
probe="VoxglassStudio/Features/Record/RecordingProbe.swift"
plant "$probe" "let g: LicenseGate? = nil"
expect_guard_fails 2 "LicenseGate in Features/Record/"
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
echo
if [ "$FAILURES" -gt 0 ]; then
  echo "test_guards: $FAILURES failure(s) found" >&2
  exit 1
fi
echo "test_guards: all gates fail on their probes and pass without them"
