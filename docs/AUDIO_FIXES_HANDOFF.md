# Handoff: volume normalization, skip silence, paywall truth, test script

**Status:** planned, not started. No code written yet.
**Prerequisite:** merged as of `83dd549` (release unblocked, CI green, 244 tests passing).

---

## 0. Handoff brief — read this before touching anything

You are picking up work on Voxglass, a SwiftUI/AVFoundation iOS audiobook app. Five repo
invariants will bite you if you don't know them. They are not obvious from the code.

**A green CI run does NOT mean the code compiles.** The `guarded-tests` job runs on
`ubuntu-latest` and has no Swift toolchain — it is a set of grep-level guards
(`scripts/guard_wiring.sh`), nothing more. A build break sails straight through it and only
surfaces in the macOS TestFlight archive. This is not hypothetical: `main` sat broken and
unreleasable this way (commit `c0cfd1b`). **Run the simulator suite locally before every push.**

**New source files must be added to the Xcode project via `xcodegen`.** The project is generated
from `project.yml`. If you add a `.swift` file and don't regenerate, it belongs to no target and
the compiler reports it only as `cannot find type X in scope` — which is exactly how `main` broke.
After adding any file:

```sh
xcodegen generate --spec project.yml     # NOT --project Voxglass.xcodeproj — see below
git add Voxglass.xcodeproj/project.pbxproj
```

`xcodegen`'s `--project` flag names the output *directory*, not the project path. Passing
`--project Voxglass.xcodeproj` silently writes a nested `Voxglass.xcodeproj/Voxglass.xcodeproj/`
and leaves the real project stale. Guard rule 6 (`target membership`) now catches this, but don't
create the problem in the first place.

**The simulator suite is the real gate, and the script that runs it is broken.** See §5 — fixing
it is part of this work. Until you fix it, run the suite by UDID:

```sh
xcrun simctl list devices available | grep "iPhone 17 ("      # grab a UDID
xcodebuild test -scheme Voxglass -project Voxglass.xcodeproj \
  -destination "platform=iOS Simulator,id=<UDID>"
```

**`scripts/guard_wiring.sh` must stay green — it will fail your PR.** Seven guards, all derived
from source so they can't rot. The two that constrain *this* work:

- *Rule 1, preference-key writers*: every key in `AppPreferencesStore.Keys` needs a writer
  (`@AppStorage` or `.set(_:forKey:)`) under `Voxglass/Features/` or `Voxglass/App/`. Adding
  `volumeNormalizationEnabled` **without its Settings toggle in the same commit fails CI.**
- *Rule 2, coordinator callers*: every non-private `func` in `PlaybackCoordinator` needs a caller
  in some other file, or an entry in the `SYSTEM_INVOKED` allowlist. Adding
  `setVolumeNormalizationEnabled(_:)` without wiring its `.onChange` **fails CI.**

Run it before you push: `bash scripts/guard_wiring.sh`

**Guards prove wiring exists, not that it works.** Rule 1 only proves a preference has a *writer*.
That is precisely how the bug in §2 shipped: a Skip Silence toggle that writes a key nothing acts
on. When you finish, **drive the app** (§Verification) — do not conclude from a green suite.

**One product decision is already made** (don't relitigate it): volume normalization ships **free**.
EQ bands stay Pro. This follows `docs/COMPETITIVE_GAP_PLAN_2.md` ("no new gates") and forces the
paywall copy change in §4.

---

## 1. Context — what's actually broken

**The volume-normalization math is wrong.** `EQEngine.process` in
`Voxglass/Core/Services/Playback/EQ/BiquadFilter.swift:149-171` computes:

```swift
let energy = sample * sample
let rms = sqrt(energy)                                  // == |sample|, a SINGLE sample
if rms > silenceThreshold {
    normGain += normSpeed * (targetRMS / rms - normGain)
}
```

`sqrt(sample * sample)` is just `|sample|` — an instantaneous magnitude, not a windowed RMS. For
any periodic signal it collapses to near zero twice per cycle, so `targetRMS / rms` explodes and
the gain **chases zero crossings**, modulating at twice the signal frequency. That is audible
distortion, not leveling. Three further defects in the same block:

- **No gain clamp.** A sample just above `silenceThreshold` (0.0001) asks for a gain of
  `0.158 / 0.0001` ≈ 1580×. The silence freeze is not an anti-wind-up; it only skips the update
  when the sample is *below* the floor.
- **`reset()` never restores `normGain`** (`:173-177` only resets the biquads), so a stale gain
  leaks across chapters and prepares.
- Gain is recomputed **per sample** rather than per hop.

**Skip Silence is dead for free users.** The silence detector lives *inside the EQ tap*
(`EQAudioProcessor.swift:15`), and:

- `EQAudioProcessor.attach(to:)` is gated on `ProFeature.isEnabled(.eq)` (`:63`), and
- the tap is only attached when the user *engages EQ* (`AVPlayerAudioEngine.setEQEngaged`, `:83-93`).

The signal path is `tap → EQAudioProcessor.onSilenceChanged → AudioEngine → PlaybackCoordinator`
(`PlaybackCoordinator.swift:88`). So silence events only ever reach the coordinator for a **Pro
user who has turned EQ on**. Skip Silence has no `ProFeature` case — it is a free feature, and its
Settings toggle (shipped in `83dd549`) writes a preference nothing acts on. The wiring guard passed
because a writer exists.

**Consequences.** The tap must attach for *everyone*, or Skip Silence stays a lie. Once it does,
normalization runs for free users too — which is the intended outcome, and which makes the paywall
line "10-Band EQ + Volume Normalization" (`ProPaywallView.swift:25`) false.

**Outcome we want:** normalization that levels quiet LibriVox recordings instead of distorting
them; a Skip Silence toggle that works; a paywall that only claims what it gates; a test script
that runs.

---

## 2. `VolumeNormalizer` — a pure, testable AGC

Create `Voxglass/Core/Services/Playback/EQ/VolumeNormalizer.swift`. No AVFoundation import, so it
unit-tests directly. It replaces the per-sample block in `EQEngine.process`.

Requirements:

- **True windowed RMS.** 2048-sample ring buffer (~46 ms at 44.1 kHz) with a running
  sum-of-squares: add the incoming square, subtract the evicted one. O(1) per sample. For a steady
  sine the window RMS is *constant* — this is what kills the zero-crossing chase.
- **Hop-rate updates.** Recompute the target gain once per 256 samples, not per sample.
- **Asymmetric attack/release.** Fast attack, slow release, as a smoothing coefficient toward
  `targetRMS / windowRMS`. Keep `targetRMS = 0.158` (~−16 dBFS).
- **Gain clamped to [0.25, 4.0].** This is the real anti-wind-up.
- **Noise-floor hold.** Below the floor, hold gain rather than adapt (belt and braces with the clamp).
- **`reset()` restores unity gain** and zeroes the window.
- **Hard limiter** clamping output to [−1, 1], applied *after* gain.
- Expose `currentGain` so tests can assert on it.

Wire it in: `EQEngine` (in `BiquadFilter.swift`) holds one `VolumeNormalizer`, calls it from
`process(_:)` after the biquad chain, and calls `normalizer.reset()` from `reset()`. Delete the old
`normGain` / `targetRMS` / `normSpeed` / `silenceThreshold` fields.

**New `VolumeNormalizerTests`.** The load-bearing one is `testGainDoesNotChaseZeroCrossings`: feed a
steady 440 Hz sine at constant amplitude, assert gain variance across one period is ~0. **Write this
test first and watch it fail against the current code** — that failure is the whole point. Plus:
converges toward target for a quiet input, limiter never clips, silence does not wind gain up,
`reset()` restores unity, gain never leaves [0.25, 4.0].

## 3. Make the tap structurally reachable

This is what un-deads Skip Silence. Without it, §2 only ever runs for Pro users with EQ engaged.

- `EQAudioProcessor.attach(to:)` — **drop the `ProFeature.isEnabled(.eq)` guard** (`:63`) so every
  user gets a tap. *Keep* the guard on `applyPreset` (`:45`) and `setGain` (`:54`) — those are the
  Pro surface.
- `EQEngine` — add an `eqStagesEnabled` flag, set from `ProFeature.isEnabled(.eq)` when `TapContext`
  constructs it (`EQAudioProcessor.swift:37-41`). When false, skip the biquad chain. Free users run
  the tap with EQ bypassed: normalization and silence detection only.
- `AVPlayerAudioEngine` — attach the tap on `load` / `preloadNext` unconditionally rather than only
  from `setEQEngaged` (`:83-93`, `:179`, `:196`). `eqEngagedDesired` now toggles EQ *stages*, not
  the tap's existence.

New tests: `testFreeUserWithNormalizationOnlyStillAttachesTap`,
`testEQStagesOffForFreeUserEvenWhenEngaged`. Existing `EQTapRegistryTests` must still pass.

## 4. Skip-silence behavior + preferences

- **Relative boost.** `PlaybackCoordinator.handleSilenceChanged` (`:261-270`) hardcodes
  `skipSilenceBoost = 3.0` (`:56`), so a user at 3.5× is *slowed down* during silence. Replace with
  `min(playbackRate * 1.5, PlaybackRate.maximum)` — `maximum` is already 3.5, in
  `Voxglass/Core/Services/Playback/PlaybackRateStore.swift:8`.
- **`SilenceDetector` threshold.** Raise the default from 0.001 to ~0.02
  (`Voxglass/Core/Services/Playback/SilenceDetector.swift:13`). 0.001 sits below the noise floor of
  most LibriVox recordings, so real room tone never registers as silence. It is already injectable;
  have `EQAudioProcessor` accept one (`:15`) so tests can supply their own.
- **New `volumeNormalizationEnabled` key** (default on) in `AppPreferencesStore.Keys`
  (`Voxglass/App/AppPreferencesStore.swift:15`), plus a toggle in the Playback settings group next
  to the existing Skip Silence row (`SettingsView.swift`, the `settingsGroup("Playback")` block).
  Route changes through a new `PlaybackCoordinator.setVolumeNormalizationEnabled(_:)` called from
  the toggle's `.onChange`. **Both halves must land in the same commit** — see guard rules 1 and 2
  in §0.

**Test updates.** `VoxglassTests/PlaybackCoordinatorSilenceTests.swift` asserts `setRate(3.0)` in
four places (`:41`, `:51`, `:64`, `:70`, `:79`, `:85`); those become the relative values
(1.0× → 1.5×, 1.5× → 2.25×). Add the regressions this fixes: at 3.5× the rate must **not drop**,
and 2.5× must clamp to 3.5× rather than overshoot. Extend `SilenceDetectorTests` with a realistic
noise-floor fixture — hiss at ~0.01 reads as silence at the new threshold; speech at ~0.05 does not.

## 5. Paywall truth

- `ProPaywallView.swift:25` — `"10-Band EQ + Volume Normalization"` → `"10-Band EQ"`. The
  normalization clause is now false.
- Rewrite `foreverFreeSection` (`:144-157`) to name what actually ships free: speed 0.5–3.5×, sleep
  timer, bookmarks, lock-screen artwork, per-chapter narrators, volume normalization, skip silence,
  FLAC/MP3, no ads, no telemetry, no accounts.

No `ProFeature` case is added or removed, so `FreeTierRegistryTests` needs no structural edit. Add
assertions to `ProPaywallContentTests`: the EQ advertisement does not claim normalization; the free
section names normalization and skip silence.

## 6. `scripts/test.sh`

The script defaults to `-destination "platform=iOS Simulator,name=iPhone 16"`, which is **ambiguous**
on the dev machine (two simulators share that name). xcodebuild refuses, dumps the full destination
list, and runs nothing — so the script looks like it hangs.

- Resolve the device name to a concrete UDID via `xcrun simctl list devices available`, choosing the
  newest runtime when several match, and pass `-destination "platform=iOS Simulator,id=$UDID"`.
- Fail with a clear message if no simulator matches.
- Fix the arg parsing: `DEVICE="${1:-iPhone 16}"` (`:11`) swallows `--device` as the device *name*
  before the later `--device` branch (`:21-23`) corrects it.

---

## Suggested order

§2 (normalizer + failing test) → §3 (reachability) → §4 (behavior + prefs) → §5 (paywall) → §6
(script). §6 is independent; do it first if the broken script is slowing you down.

## Acceptance criteria

- [ ] `VolumeNormalizerTests.testGainDoesNotChaseZeroCrossings` fails against current `EQEngine`,
      passes after §2.
- [ ] Full simulator suite green (244 tests today, plus the new ones).
- [ ] `bash scripts/guard_wiring.sh` — all 7 guards pass.
- [ ] `scripts/test.sh` runs with no arguments, on a clean checkout, without a destination dump.
- [ ] Paywall makes no claim the app does not gate.
- [ ] **Driven in the app, as a free user** (see below).

## Verification

Tests are necessary but not sufficient here — a fully green suite is exactly what shipped a dead
Skip Silence toggle. Build and drive the app:

1. As a **free** user (EQ never engaged), turn on Skip Silence, play a quiet LibriVox chapter, and
   confirm the rate actually rises in the silent gaps and returns to the user's chosen rate on
   speech. This is the bug this work exists to fix; if it doesn't happen, §3 is incomplete.
2. Confirm a quiet recording is audibly **leveled** with EQ off — that is normalization running free.
3. Confirm EQ bands still do nothing for a free user (stages bypassed, tap attached).
4. Set playback to 3.5× and confirm silence does not *slow you down*.
5. Push a branch, confirm `guarded-tests` is green in CI **before** merging to `main` — and remember
   a green ubuntu job does not mean it compiles. The simulator suite is the compile gate.

## Risks

- **Always-on taps** mean every user now pays the per-sample processing cost, not just Pro users
  with EQ engaged. It is a tight loop over a buffer that Pro users already run. If it shows up on
  older devices, the fallback is to attach the tap only when Skip Silence or normalization is
  actually enabled — a preference-driven attach rather than an unconditional one.
- Changing `handleSilenceChanged` and the `SilenceDetector` threshold changes audible behavior for
  anyone already using Skip Silence — which, given it was inert, is nobody.

## Reference

- `docs/COMPETITIVE_GAP_PLAN_2.md` — the live roadmap. This work is its Phase 2a/2b/2c plus the
  Phase 1 reachability and Phase 3 paywall items that turned out to be load-bearing for them.
- Commit `83dd549` — unblocked the release; added the Skip Silence toggle and the target-membership
  guard. The dead-toggle bug in §1 is a bug in *that* commit's feature, found while planning this one.
