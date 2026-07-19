# Remaining Gaps — Implementation Plan

> Covers the 3 items that are still open after the `COMPETITIVE_GAP_PLAN.md`
> sweep: P2-2 skip silence and P2-3
> Dynamic Type.  Everything else (Step 0, P0, P1, P2-1, docs)
> is already shipped and green.

---

## Phase A — README adjustments

### A1 — Copy adjustments (no longer needed)

Pro paywall copy is no longer relevant — all features are free. Skip.

### A2 — README updates

**File:** `README.md`

Three changes:

1. **Check off completed roadmap items** (lines 70-92).  Every item from
   Step 0 through P2-1 is shipped.  Change each `- [ ]` to `- [x]` for:
   - Step 0 (both sub-items)
   - P0 (all four sub-items)
   - P1 (all three sub-items)
   - P2 volume normalization
   Leave P2 skip silence and Dynamic Type unchecked.

2. **Update "Current focus" section** (lines 114-118).  It currently references
   a stale `plan.md` and discusses post-field-test work that has already
   shipped.  Replace with a short note about the competitive gap plan being
   substantially complete and pointing at `docs/COMPETITIVE_GAP_PLAN.md`.

3. **No other README changes needed.**  The iCloud entitlement section was
   already corrected, and there is no false light-theme claim present.

---

## Phase B — P2-3 Dynamic Type sweep

### Context

`DynamicTypeGuardTests.swift` already exists and walks the Voxglass sources
via `#filePath`, grepping for `Font.system(` + `size:` without `relativeTo:`.
It currently fails with 100+ violations across 15 SwiftUI view files.

### B1 — Convert all views

**Affected files:** all `Voxglass/Features/**/*.swift` with `.system(size:)`.

**Transformation rules:**

| Current | Replace with |
|---------|-------------|
| `.font(.system(size: X))` | `.font(.system(size: X, relativeTo: .body))` |
| `.font(.system(size: X, weight: Y))` | `.font(.system(size: X, weight: Y, relativeTo: .body))` |
| `.font(.system(size: X, weight: Y, design: Z))` | `.font(.system(size: X, weight: Y, design: Z, relativeTo: .body))` |
| `.font(.system(size: X).monospacedDigit())` | `.font(.system(size: X, relativeTo: .body).monospacedDigit())` |
| `.font(.system(size: X, weight: Y).bold())` | `.font(.system(size: X, weight: Y, relativeTo: .body).bold())` |

**Files by hit count (approx):**

| File | Hits |
|------|------|
| `Features/Settings/SettingsView.swift` | ~35 |
| `Features/Player/NowPlayingView.swift` | ~25 |
| `Features/Library/BookDetailView.swift` | ~18 |
| `Features/Settings/ProPaywallView.swift` | ~13 |
| `Features/Player/EQView.swift` | ~10 |
| `Features/Stats/ListeningStatsView.swift` | ~10 |
| `Features/Listen/ListenView.swift` | ~6 |
| `Features/Search/SearchView.swift` | ~7 |
| `Features/Discover/DiscoverView.swift` | ~7 |
| `Features/Library/BookRowView.swift` | ~1 |
| `Features/Library/LibraryView.swift` | ~1 |
| `Features/Onboarding/SplashView.swift` | ~3 |
| `Features/Player/MiniPlayerView.swift` | ~1 |
| `Features/Player/BookmarksView.swift` | ~4 |
| `Features/Chrome/GlassDock.swift` | ~3 |
| `Features/Settings/FolderWatchView.swift` | ~3 |

### B2 — Verify guard test

**No code change needed.**  `DynamicTypeGuardTests.testNoBareSystemSizeWithoutRelativeTo`
walks source files from `#filePath`.  After B1, zero violations remain and the
test is green.

---

## Phase C — P2-2 Skip silence (rate-boost approach)

### Architecture overview

```
MTAudioProcessingTap process callback  →  compute buffer RMS
      →  SilenceDetector.process(rms:)
            →  state change?
                  →  dispatch to @MainActor
                        →  PlaybackCoordinator.setRate(boosted) or setRate(userRate)
```

The `SilenceDetector` (already written, `Core/Services/Playback/SilenceDetector.swift`)
is a pure RMS-window detector with hysteresis — it requires N consecutive
silent windows to enter `.silent` and exits immediately on speech.  It needs
to be wired into the audio tap, and the state transitions need to reach
`PlaybackCoordinator` through the existing `AudioEngine` protocol.

### C1 — Integrate SilenceDetector into EQAudioProcessor

**Files:** `EQAudioProcessor.swift`, `SilenceDetector.swift`

- Add a `private let silenceDetector = SilenceDetector()` property.
- In the tap's `process` callback (line 138 of `EQAudioProcessor.swift`),
  after the existing `for j in 0..<count` loop, compute per-buffer RMS:

```swift
// Compute buffer RMS for silence detection
var sum: Float = 0
for j in 0..<count { sum += samples[j] * samples[j] }
let rms = sqrt(sum / Float(count))
```

- Feed RMS to the detector and dispatch state changes to main actor:

```swift
let newState = silenceDetector.process(rms: rms)
if newState != previousState {
    DispatchQueue.main.async { [weak self] in
        self?.onSilenceChanged?(newState == .silent)
    }
}
```

- Store `previousState` as a `SilenceDetector.State` property initialized
  to `.speech`.
- Add `var onSilenceChanged: (@MainActor (Bool) -> Void)?` to
  `EQAudioProcessor`.
- Add a `func resetSilenceDetector()` that calls `silenceDetector.reset()` and
  resets `previousState` — called by `attach(to:)` on new items and by
  `detachAll()`.

### C2 — Thread callback through AudioEngine protocol

**Files:** `AudioEngine.swift`, `AVPlayerAudioEngine.swift`, `FakeAudioEngine.swift`

**`AudioEngine` protocol addition:**

```swift
var onSilenceChanged: (@MainActor (Bool) -> Void)? { get set }
```

**`AVPlayerAudioEngine`:** bridges `eqProcessor.onSilenceChanged`:

```swift
var onSilenceChanged: (@MainActor (Bool) -> Void)? {
    get { eqProcessor.onSilenceChanged }
    set { eqProcessor.onSilenceChanged = newValue }
}
```

**`FakeAudioEngine`:** settable property so tests can fire it directly:

```swift
var onSilenceChanged: (@MainActor (Bool) -> Void)?
```

Add `.fireSilenceChanged(Bool)` to the `Call` enum so the call log captures
it, or just have tests set a closure externally — the call log assertion
pattern is cleaner: add `case fireSilenceChanged(Bool)` to `FakeAudioEngine.Call`
and emit it from a public `func fireSilenceChanged(_ value: Bool)` wrapper.

### C3 — Wire PlaybackCoordinator + add settings toggle

**Files:** `PlaybackCoordinator.swift`, `AppPreferencesStore.swift`, `SettingsView.swift`

**`AppPreferencesStore`:**
Add `static let skipSilenceEnabled = "voxglass.skipSilence.enabled"`.  Default
`false`.  The user-facing label is "Skip Silence (boost through quiet passages)".

**`PlaybackCoordinator` changes:**

- New private property: `private var silenceBoosted = false`.
- In `init`, register the silence callback:

```swift
engine.onSilenceChanged = { [weak self] isSilent in
    guard let self, self.isSkipSilenceEnabled else { return }
    if isSilent && !self.silenceBoosted {
        self.silenceBoosted = true
        self.engine.setRate(self.skipSilenceBoost)
    } else if !isSilent && self.silenceBoosted {
        self.silenceBoosted = false
        self.engine.setRate(self.playbackRate)
    }
}
```

- `skipSilenceBoost` constant: `3.0`.
- On `pause()`, `stopPlayback()`, `seek(to:)`, `setPlaybackRate()`, and loading
  a new chapter: reset `silenceBoosted = false` so the boost doesn't carry
  across sessions or strand the user.
- Read `@AppStorage(AppPreferencesStore.Keys.skipSilenceEnabled)` to determine
  `isSkipSilenceEnabled`.

**`SettingsView`:** add a toggle row in the Playback group, between the
existing speed/sleep/skip rows.  Mirror the style of `SkipIntervalRow`.

### C4 — Unit tests

**New: `SilenceDetectorTests.swift`**

Pure tests, zero AVFoundation:

- `testSingleSilentBufferDoesNotTrigger` — one silent frame below threshold
  does not transition; `state` stays `.speech`.
- `testConsecutiveSilentBuffersTrigger` — N consecutive silent frames
  transition to `.silent` on frame N.
- `testSpeechReturnsImmediately` — a single speech frame from `.silent`
  transitions back to `.speech` immediately (no hysteresis on exit).
- `testNoFlapping` — alternating speech/silence stays `.speech` the whole
  time (never accumulates enough consecutive silent frames).
- `testReset` — resets state and counters.

**New: `PlaybackCoordinatorSilenceTests.swift`**

Uses `FakeAudioEngine`, zero AVFoundation:

- `testSilenceDetectedBoostsRate` — fire `onSilenceChanged(true)` → assert
  the `FakeAudioEngine` call log contains `setRate(3.0)`.
- `testSpeechRestoresUserRate` — set user rate to 1.5, fire silence→speech
  transition → assert `setRate(1.5)`.
- `testPauseResetsBoost` — boost active, pause → assert `silenceBoosted` is
  `false` (indirectly: next silence fires a fresh boost).
- `testManualRateChangeResetsBoost` — boost active, user sets rate to 2.0 →
  assert `silenceBoosted` is `false`.
- `testSkipSilenceDisabledDoesNotBoost` — toggle off → fire silence →
  assert no `setRate(3.0)` in call log.

---

## Phase D — Verification

### D1 — Full test suite

```bash
xcodebuild test -scheme Voxglass -destination 'platform=iOS Simulator,name=iPhone 16'
```

### D2 — Guard tests

- `DynamicTypeGuardTests.testNoBareSystemSizeWithoutRelativeTo` must pass.

### D3 — CI

The existing GitHub Actions workflow (`.github/workflows/ios.yml`) runs
guarded-tests (network endpoint allowlist) followed
by the full test suite on macOS.  Nothing in this plan changes the CI
configuration — all new tests are XCTest cases that run as part of the
existing scheme.

---

## Execution order

```
Phase A  (copy + README)  ─┐
                             ├── Phase D (verify)
Phase B  (Dynamic Type)   ─┘
                             │
Phase C1 → C2 → C3 → C4  ───┘
```

- **A** and **B** are independent mechanical sweeps (2 files + ~15 files),
  can run in parallel.
- **C** is a sequential dependency chain through the audio pipeline
  (tap → engine → coordinator → tests).  It is also independent of A/B.
- **D** is the final gate after everything lands.

---

## Notes

- **No new files need to be added to any target
  except the two test files (`SilenceDetectorTests.swift`,
  `PlaybackCoordinatorSilenceTests.swift`), which are picked up automatically
  by the XcodeGen-generated project.
- **No third-party dependencies.**  All work uses existing Apple frameworks.
