# Voxglass Studio release checklist — v1.0 (2026-08-02)

> Template: `VOXGLASS_STUDIO_SPEC.md` §21.4. Fill every box before submitting;
> each box names the artifact that proves it.

## Gates

- [x] All Core suites green (`swift test`) — `scripts/test_logic.sh` phase 1
      (1,2xx tests across VoxglassCoreTests + VoxglassStudioTests)
- [x] All Studio/phone/watch suites green
- [ ] Five UI smoke tests green (`scripts/test.sh --all`) — local pre-commit gate,
      not CI. iPhone + CarPlay scene + Watch + macOS Studio (one smoke test per
      device, per repo convention). WP-G folds My Productions reachability into
      the single iPhone smoke test.
- [x] Eighteen CI grep gates green (`scripts/guard_production.sh`)
- [x] Guard self-test green (`scripts/test_guards.sh` — proves each gate can fail)
- [x] Performance budgets met (§19.7) — `scripts/test_logic.sh` phase 2
      (`VOXGLASS_TIMING_TESTS=1`), ratio-based and load-independent

## Walkthroughs

- [ ] W-1 LibriVox (free) — Gutenberg `.txt` project, disclaimers recorded,
      phone flag → Mac fix, clean LibriVox validation, chapter export verified
      128 kbps CBR / 44.1 kHz / mono with correct names and tags.
      **No purchase prompt observed.**
- [ ] W-2 Internet Archive (free) — identifier + license URL set, FLAC masters
      + MP3 derivatives + test-collection profile, manifest/checksums/`ia upload`
      command verified, item uploaded to `test_collection` and derived.
- [ ] W-3 Retail (Pro) — commercial purpose, credits recorded, retail sample
      set, ACX validation fails on a deliberately hot take, Pro purchased in
      sandbox, export verified: RMS ∈ [−23, −18], true peak ≤ −3, noise ≤ −60,
      M4B chapter marks playable, sample duration correct and not credits.

## Capture robustness matrix (WP-D, §19.10 M-2/M-3/M-4)

The real-time tap discipline ("no allocation, no lock, no Task, no os_log, no
`Date()` in the tap body") is verified by code review in
`VoxglassStudio/Services/AVAudioEngineCapture.swift` + `CaptureRingBuffer.swift`,
not by test. The behavioral guarantees below are hardware-dependent and must
be executed on a real interface before shipping:

- [ ] **M-2 Device change** — record with an interface, unplug it mid-take:
      banner shows "Your input device changed." with **Reveal Take** and
      **Resume Recording**; the take plays back completely; recording resumes
      on the new device.
- [ ] **M-3 Sleep** — start a take, put the Mac to sleep mid-take: on wake the
      banner shows "Your Mac went to sleep." and the take is preserved and
      playable.
- [ ] **M-4 Disk full** — fill the disk during a take: banner shows "The disk
      filled up while recording." with "Everything recorded up to that point
      was saved."; previously recorded takes are intact and playable.

## Destinations

- [ ] §21.3 re-verification completed; `DESTINATION_VERIFICATION_LOG.md` updated
      (LibriVox tech specs/disclaimer/AI policy, ACX thresholds, IA metadata)

## Legal & licensing

- [x] ThirdPartyNotices.md current (LAME, libFLAC versions, LGPL-2.1 / BSD-3)
- [x] Encoder build recipe reproducible from a clean checkout
      (`Tools/encoders/build-encoders.sh`)
- [x] Legal strings unchanged or reviewed (`Destinations/LegalStrings.swift`,
      §3.6)

## Store

- [ ] Screenshots for all shipped screens reviewed against the mockup set
      (captured on the iPhone simulator — the macOS screenshot script was
      removed with the Studio tree in P0)
- [ ] IAP configured (`guru.parso.voxglass.studio.pro`, $149, non-consumable),
      sandbox-tested, Family Sharing on
- [ ] Privacy label: data not collected; audio and text stay in the user's
      iCloud private database; no analytics SDK
- [ ] Review notes include demo project + mic rationale; no auto-upload
      explanation

## Risk

- [ ] Known issues documented in RELEASE_NOTES.md
- [ ] Rollback plan: previous build ready in App Store Connect
