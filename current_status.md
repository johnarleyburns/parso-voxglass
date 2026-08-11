# Voxglass — current status

**Updated:** 2026-08-10. **Tree:** `main` @ `85afc51`, pushed, CI green.

## Status

The revised iPhone + Watch narration MVP (SPEC `docs/iphone-watch-only-revised-mvp/SPEC.md`)
is implemented and shipping across stages P0–P9. On 2026-08-10 all thirteen gaps
from `GAP_ANALYSIS.md` were closed per `GAP_FIX_BRIEF.md` (F1–F8) and merged to
`main`. See the closure record at the top of `GAP_ANALYSIS.md` for the per-gap
summary.

### Where the tree stands

- **`swift test`** green: **1319 tests / 189 suites** (up from 1309 / 186 at gap analysis).
- **CI green on `main`**: Logic Tests (`swift test`), Guarded Tests
  (`guard_wiring.sh` + `test_guards.sh` + `guard_production.sh` + network
  allow-list), Compile (iOS), TestFlight Build — all `success`.
- **Local pre-commit gate green**: wiring guards + logic tests + the two
  simulator smoke tests pass via `scripts/test.sh` (ran on the last two
  commits).
- **New `ExportScopeSelectionTests`, `ProjectPurposeRoundTripTests`, and
  `LicenseGatePlacementTests`** ship; `AccessibilityAuditTests` now parses the
  mockup HTML as the identifier contract instead of the stale Studio-era list.
- **The iPhone smoke test** (`VoxglassUITests.swift`) now drives the full §16.3
  path: create a narration from a need → record (flag + re-record review leg) →
  validate (0 blocking) → single-chapter LibriVox export → **verifies the
  produced package bytes** (128 kbps CBR / 44.1 kHz / mono via
  `MP3FrameParser`, ID3 tags, `checksums.sha256` digests, checklist,
  `metadata.json`). The corruption check was demonstrated (forcing 192 kbps
  fails the test). `ffprobe` on the exported MP3 confirms 128 kbps / 44.1 kHz /
  mono, and the on-disk SHA-256 matches `checksums.sha256`.

### Two wiring defects the smoke test surfaced (fixed)

- `buildParagraphs` now generates LibriVox intros/outros through the same
  `ScriptApplier` + `LibriVoxScriptGenerator` the validation engine expects.
  Previously the hand-built disclaimer format failed `staleDisclaimerText` and
  blocked every need-created project from exporting.
- `attest()` now persists the Source URL field (previously `.missingSourceURL`
  blocked LibriVox export when the source wasn't prefilled).

## What's next

These are the remaining process gates — recorded in `GAP_ANALYSIS.md` as "Not
verifiable from the repository"; they are human/device steps, not code gaps:

1. **Manual hardware matrix M-1…M-14** (§16.5) — human-executed on device;
   record the sign-off in `RELEASE_CHECKLIST.md`.
2. **Walkthroughs W-1 / W-2 / W-3 on real hardware** (§16.6) — identifiers are
   now correct (F3 re-derived them); a human still runs them and checks the
   `RELEASE_CHECKLIST.md` boxes.
3. **Encoder build from a clean checkout** (iOS device + simulator + watchOS
   slices, §16.6).
4. **D-2 pricing ($49 / $79)** — an App Store Connect value, correctly absent
   from code; set at submission.
5. **Store & release polish** — TestFlight build, privacy labels, IAP
   sandbox-testing of `guru.parso.voxglass.narration.pro`, and the
   `RELEASE_CHECKLIST.md` store section.

### Optional engineering follow-ups (not required by the spec)

- Extend the smoke test's export leg to a **multi-chapter fixture** and assert a
  genuinely single-section package (the single-chapter scope is currently
  exercised on a one-chapter project; the Core engine proof lives in
  `ExportEndToEndTests.singleChapterScopeExportsOneFile`).
- The `validation.destination.*` rows share the container identifier
  `validation.destination` at runtime (SwiftUI container-id quirk, same class as
  the scope picker that was fixed) — cosmetic, since tests key on the container.
- Consider a device-accessible "Save a copy" test of the `.voxproject` re-import
  path.
