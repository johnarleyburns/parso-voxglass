# S5 — Current status and fix list

**For the implementing agent.** This is the authoritative task list for finishing S5 (Recording
and takes). Every finding below was measured, not inferred. Background, measurements and the
reasoning behind each decision are in `docs/voxglass-mvp/S5-REMEDIATION-PLAN.md`; this file is
the executable version.

Repo: `/Users/arley/github/parso-voxglass`. Build with `swift build`; the Studio app is the
`VoxglassStudio` scheme in `Voxglass.xcodeproj`.

---

## Read this first: the deferral note in the code is wrong

`Voxglass/Core/Production/Audio/ReplayGainCalculator.swift:75-77` says the Yulewalk filter was
deferred because of "an exact integrator pole (z=1)" causing "numerical divergence in
straightforward biquad cascade." All three parts of that are false and were verified:

- Max pole magnitude of the RG Yule denominator is **0.90794** at 48 kHz and **0.89733** at
  44.1 kHz. There is no pole at or near z=1. `sum(a) = 0.0285`, so DC gain is finite (−7.52 dB).
- Factored into 5 biquads and run over white noise, the cascade is stable in **Float32**
  (`max|y| = 0.38121`), never mind Double.
- The thing at z=1 is a **double zero in the Butterworth stage** — already in the code, already
  working. A DC-blocking zero, not an integrator pole. Unit-circle zeros are always stable.
- It is not "ITU-R 468 weighting"; it is the inverse equal-loudness contour.

**Do not try to design the filter** (MATLAB `yulewalk`, Yule–Walker normal equations,
Levinson–Durbin) and **do not factor it into biquads**. Both require root-finding on a degree-10
polynomial, which is the ill-conditioned step that caused this detour. RG 1.0 defines the Yule
stage as a single direct-form 11-tap section. Use the published table verbatim in `Double`.

---

## Decisions already made — do not relitigate

1. **Do not reuse `BiquadFilter.swift`** for ReplayGain, despite spec §11.6.8 and §23 saying
   "SHOULD reuse." It is `Float`, metrics are specified in `Double`, and the Yule stage is not a
   biquad. Add a new `Double` direct-form filter under `Production/Audio/` instead. Record the
   deviation in the spec (T10).
2. **Revert the uncommitted `BiquadFilter.configureDirect(b0:b1:b2:a1:a2:)`** — it exists only to
   support the abandoned cascade approach.
3. **Ship 44.1 kHz and 48 kHz coefficient tables only**; resample anything else to 48 kHz before
   analysis. Never silently apply the wrong table.
4. **Golden vectors get committed as WAV + expected values.** CI must not need `flac`/`metaflac`
   installed.
5. **A lock-free SPSC ring buffer stays deferred.** T7 uses a buffer pool + serial writer queue,
   which is enough to get I/O and locks off the render thread.

---

# Tasks

Ordered. T1–T3 block S7 (the validation rule engine consumes these metrics). T7–T8 block the S5
acceptance criterion. Each task is independently committable.

---

## T1 — Rewrite `ReplayGainCalculator` [blocking]

**File:** `Voxglass/Core/Production/Audio/ReplayGainCalculator.swift`

**Problem.** Line 40 computes `gain = 89.0 - (percentile95 + 0.691)`, mixing the ReplayGain
89 dB SPL reference with the EBU R128 K-weighting offset and applying both to a dBFS-scale
number. It is dimensionally wrong, and the equal-loudness filter is missing entirely. Measured
against `metaflac --add-replay-gain`:

| Signal (48 kHz mono) | Current | Correct |
|---|---:|---:|
| pink, −20 dBFS | **111.20 dB** | +4.26 dB |
| pink, −26 dBFS | **117.20 dB** | +10.26 dB |
| 1 kHz sine, −20 dBFS | **108.31 dB** | +2.83 dB |
| 100 Hz sine, −20 dBFS | **116.14 dB** | +9.88 dB |

Because §15.3 derives perceived volume as `89 - replayGainDB`, this currently evaluates to
−22 dB and will fire `perceivedVolumeOutOfBand` on **every take in every LibriVox project**.

Also: `ButterworthHP` (lines 56-73) hardcodes the 48 kHz coefficients and is applied at any
sample rate, so imported audio is filtered wrongly.

### Do

**a. Add `Voxglass/Core/Production/Audio/DirectFormFilter.swift`** — a `Double` direct-form-II
transposed section of arbitrary order. Roughly:

```swift
struct DirectFormFilter {
    private let b: [Double]      // b.count == a.count
    private let a: [Double]      // a[0] == 1
    private var v: [Double]      // state, count == b.count - 1

    init(b: [Double], a: [Double]) { … v = .init(repeating: 0, count: b.count - 1) }

    mutating func process(_ x: Double) -> Double {
        let y = b[0] * x + v[0]
        let n = v.count
        for k in 0..<(n - 1) { v[k] = b[k+1] * x - a[k+1] * y + v[k+1] }
        v[n-1] = b[n] * x - a[n] * y
        return y
    }
    mutating func reset() { for i in v.indices { v[i] = 0 } }
}
```

**b. Add `Voxglass/Core/Production/Audio/ReplayGainCoefficients.swift`** with the tables below
keyed by sample rate, plus `static let supportedRates: Set<Int> = [44100, 48000]`.

**48 000 Hz — Yule** (verified: max pole 0.90794)
```
b: 0.03857599435200, -0.02160367184185, -0.00123395316851, -0.00009291677959,
  -0.01655260341619,  0.02161526843274, -0.02074045215285,  0.00594298065125,
   0.00306428023191,  0.00012025322027,  0.00288463683916
a: 1.00000000000000, -3.84664617118067,  7.81501653005538, -11.34170355132042,
  13.05504219327545, -12.28759895145294,  9.48293806319790,  -5.87257861775999,
   2.75465861874613,  -0.86984376593551,  0.13919314567432
```

**48 000 Hz — Butterworth** (already correct in the current code, keep the values)
```
b: 0.98621192462708, -1.97242384925416, 0.98621192462708
a: 1.00000000000000, -1.97223372919527, 0.97261396931306
```

**44 100 Hz — Yule** (verified: max pole 0.89733)
```
b: 0.05418656406430, -0.02911007808948, -0.00848709379851, -0.00851165645469,
  -0.00834990904936,  0.02245293253339, -0.02596338512915,  0.01624864962975,
  -0.00240879051584,  0.00674613682247, -0.00187763777362
a: 1.00000000000000, -3.47845948550071,  6.36317777566148, -8.54751527471874,
   9.47693607801280, -8.81498681370155,  6.85401540936998, -4.39470996079559,
   2.19611684890774, -0.75104302451432,  0.13149317958808
```

**44 100 Hz — Butterworth**
```
b: 0.98500175787242, -1.97000351574484, 0.98500175787242
a: 1.00000000000000, -1.96977855582618, 0.97022847566350
```

**c. Rewrite `analyzeFull` to exactly this algorithm.** It was validated end-to-end against
`metaflac --add-replay-gain` at both rates, agreement ≤ 0.05 dB, including signals that are
60 % silence.

1. Run the unit-scale mono samples through **Yule, then Butterworth**, both `DirectFormFilter`,
   both `Double`, coefficients chosen by sample rate.
2. Split into **non-overlapping 50 ms blocks** (`Int(sampleRate * 0.05)`); mean square per block.
3. `L_i = 10 * log10(ms_i + 1e-37)`, then **clamp** to a sane range (e.g. `[-110, 30]`).
   **Do not drop silent or quiet blocks.** The current code drops blocks below −70 dB; that
   drifts 0.24 dB at 60 % silence (normal for narration), while clamping matched `metaflac`
   to 0.04 dB.
4. Sort ascending; 95th percentile index = `min(Int(ceil(Double(n) * 0.95)) - 1, n - 1)`.
5. `gainDB = -25.4885 - L95`

   The constant is `64.82 - 20*log10(32768)` — `PINK_REF` from `gain_analysis.c` rebased from
   ±32768 to ±1.0 sample scale. **This single missing number is the 104 dB error.**

6. `peakDBFS` stays as-is (linear max of the *unfiltered* samples → dBFS). That part is correct.

**d. Unsupported sample rates.** Anything not in `supportedRates` must be resampled to 48 kHz
before analysis, or return an explicit unsupported signal. It must never silently use the wrong
table. (`AVMetricsCalculator` decodes via `AVAudioFile`, so resampling belongs in the Studio-side
decoder in `AVMetricsCalculator.decodeFile`, not in Core.)

**e. Delete the comment at lines 75-77.** Replace it with a one-line reference to
`gain_analysis.c` / ReplayGain 1.0 as the source of the tables.

**f. Revert `BiquadFilter.configureDirect`** — `git diff Voxglass/Core/Services/Playback/EQ/BiquadFilter.swift`
is the only change to that file and should go back to zero.

**Done when:** T3's golden-vector test passes within 0.25 dB.

---

## T2 — Fix true peak and noise floor [blocking]

**File:** `Voxglass/Core/Production/Audio/AudioMetricsCalculator.swift`

### T2a — True peak reads 12.04 dB low

`truePeakKernel()` (lines 199-219) normalizes so that **all 33 taps** sum to 1 (lines 215-217).
A 4× polyphase interpolator needs **each phase** to sum to 1 — the kernel must be scaled by 4.

Measured: a 0.5-amplitude sine yields `max|y| = 0.1250`, exactly 0.5 / 4. Consequence:
`truePeakDBFS` is always ~12 dB below `peakDBFS` (physically impossible), and the retail/ACX
"true peak ≤ −3 dBTP" rule passes unconditionally.

**Fix:** multiply the normalized kernel by 4 (or normalize per-phase). Add the invariant
`truePeakDBFS >= peakDBFS - 0.01` as a test assertion.

### T2b — True peak allocates 46 MB

`upsample4x` (lines 180-197) materializes `[Double](repeating: 0, count: n * 4)` — 46 MB for a
30 s take. Replace with a streaming running max; nothing consumes the oversampled array.

### T2c — Noise floor uses samples where the spec says milliseconds

`computeNoiseFloor` (lines 97-124) deviates from spec §11.6.4 in four ways:

| Line | Current | Spec §11.6.4 |
|---|---|---|
| 101 | `windowLength = 50` (samples, ~1 ms) | 50 **ms** → 2400 samples @ 48 kHz |
| 98 | `hop = 25` (samples) | 25 **ms** → 1200 samples @ 48 kHz |
| 111 | `absoluteFloor: Float = 1e-7` | `10^(-70/20)` = `3.162e-4` |
| 120 | `Double(silentCount * hop) / 48000.0` | must use the actual sample rate |
| 122 | `silentSum / count` — mean of RMS values | RMS **over** the silent windows: `sqrt(mean(e²))` |

At a 1 ms window the "envelope" tracks the waveform rather than room tone, so the 10th
percentile lands in speech zero-crossings.

**Fix:** add a `sampleRate: Double` parameter to `computeNoiseFloor` (update the call site at
line 44), derive window and hop from it, correct the floor constant and the averaging.

**Done when:** T3's noise-floor and true-peak assertions pass.

---

## T3 — Tests that would have caught T1 and T2 [blocking]

**Files:** `VoxglassTests/Production/Audio/ReplayGainTests.swift`,
`VoxglassTests/Production/Audio/MetricsCalculatorTests.swift`

**Why these bugs shipped:** `ReplayGainTests` asserts only `isFinite`, monotonicity and
determinism — a constant 104 dB offset satisfies all three. `MetricsCalculatorTests` never
asserts on `truePeakDBFS`, `noiseFloorDBFS` or `replayGainDB` at all. Every new test below must
assert an **absolute value**, not a property.

Add:

- **Golden vectors.** Commit 4–6 short WAV fixtures (pink at −14/−20/−26 dBFS, 1 kHz and 100 Hz
  tones, one signal that is 60 % silence) plus a checked-in JSON of expected gains. Assert within
  **0.25 dB**. Commit the generation script so fixtures are reproducible. Reference values from
  `metaflac --add-replay-gain`, generated once locally — CI must not depend on it.
- **Frequency weighting.** A 100 Hz tone gets **≥ 5 dB more gain** than a 1 kHz tone at the same
  dBFS. This assertion fails on any Butterworth-only implementation and is the single best guard
  against the Yule stage silently going missing again.
- **Absolute level.** Pink noise at −20 dBFS → gain in `[3, 6]` dB. (Today: 111 dB.)
- **Perceived volume.** `89 - replayGainDB` for a −20 dBFS take lands inside `[86, 92]` — the
  exact band the §15.3 warning uses.
- **True peak.** 0.5-amplitude sine → `truePeakDBFS` = −6.02 ± 0.1; and
  `truePeakDBFS >= peakDBFS` for every fixture. (Today: −18 dB.)
- **Noise floor.** Speech-like signal with −60 dBFS noise in the gaps → `noiseFloorDBFS` within
  3 dB of −60 and `noiseFloorReliable == true`; a gapless signal → `-90` and `reliable == false`.
- **Sample-rate independence.** The same logical signal generated at 44.1 kHz and 48 kHz agrees
  within 0.3 dB on gain, RMS and noise floor. Catches every hardcoded-48000 regression.
- **Performance (§11.6.9).** 30 s through `metrics(for:sampleRate:channels:)` in < 150 ms.
  **Expect this to fail initially** — see T9.

---

## T4 — `FakeAudioCapture` [blocking]

**File (new):** `VoxglassCoreTestSupport/Fakes/FakeAudioCapture.swift`

Only `FixedClock`, `SequentialIDGenerator` and `ProjectFixtures` exist today. The S5 acceptance
criterion explicitly requires a fake capture, so it cannot currently be tested at all.

Conform to `AudioCapturing` (`Voxglass/Core/Production/Audio/AudioCapturing.swift`). Needs:
scripted level stream, synthesized WAV output of a requested duration, and injectable failures —
device disappears mid-take, disk full, permission denied, `stopRecording` without `startRecording`.

---

## T5 — `RecordingFlowTests` + `RecordingModel` fixes [blocking]

**Files:** `VoxglassTests/Production/Audio/RecordingFlowTests.swift` (new),
`VoxglassStudio/Features/Record/RecordingModel.swift`

**Acceptance criterion to encode:** 100 sequential paragraphs recorded without loss, each take
persisted with a real `sha256` and `byteCount`, no take lost, no ID collision.

Bugs in `RecordingModel` the tests must pin down:

- **Line 85** — `currentParagraphID!` force-unwrap. `stopRecording()` arriving without a
  preceding `startRecording()` crashes the app.
- **Line 58** — `try? await Task.sleep(for: .seconds(preRoll))` is not cancellation-aware, so
  cancelling during pre-roll still starts a recording.
- **Lines 123-140** — `ingestTake` writes `sha256: ""`, `byteCount: 0`,
  `textHashAtRecording: ""` and never moves the file into the asset store. **No recorded take is
  currently persisted or integrity-checkable.** Wire it through `FileAssetStore`.
- **Lines 62-64** — autosave goes to `FileManager.default.temporaryDirectory`, not the project
  package's `Autosave/takes` directory that `ProjectPackage.swift:28` already reserves. See T8.

---

## T6 — (folded into T5) — reserved

---

## T7 — Make `AVAudioEngineCapture` real-time safe [blocking]

**File:** `VoxglassStudio/Services/AVAudioEngineCapture.swift`

This is the single most likely cause of failing "100 paragraphs without loss," and it will fail
intermittently and unreproducibly. The handoff note called it "direct buffer writing, acceptable
for MVP" — it is not; two operations in `processTapBuffer` (lines 190-230) run on the real-time
render thread and can both overrun the deadline:

- **Line 228** — `try? file.write(from: buffer)`: file I/O, allocation, and an internal lock.
- **Lines 221-225** — `levelContinuationsLock.withLock { … continuation.yield(…) }`: `NSLock`
  plus `AsyncStream` continuation machinery, which allocates and can block.

### Do

**a. Get I/O off the render thread.** Tap copies into a **preallocated `AVAudioPCMBuffer` pool**
and hands off to a serial `writerQueue`; `AVAudioFile.write` happens there. (A true lock-free
ring buffer remains deferred — the pool + queue is sufficient.)

**b. Insert an `AVAudioConverter`** in the writer queue. **This is a correctness bug, not
polish:** lines 121-137 create the `AVAudioFile` at `RecordingDefaults` (48 kHz mono Float32)
but line 141 installs the tap with `inputNode.outputFormat(forBus: 0)` — the *hardware* format.
On any Mac whose input is 44.1 kHz or stereo (most built-in and USB interfaces),
`file.write(from:)` throws, `try?` swallows it, and you get a **zero-length WAV** while
`recordSampleCount` keeps incrementing — so `CapturedTake.duration` reports a full take that
does not exist on disk. If conversion is impossible, fail the take loudly; never `try?`.

`configureInputFormat(_:)` (lines 236-241) currently only checks `hwFormat.sampleRate > 0` and
ignores the requested format — make it actually reconcile the two.

**c. Replace the level broadcast.** Store a single atomic level snapshot from the tap; poll it
at ~30 Hz from a `@MainActor` timer. Any retained `AsyncStream` must use an explicit
`.bufferingNewest(1)` policy — the current default is `.unbounded`, so a slow consumer grows
memory without bound.

**d. Line 166** — `peakDBFS: Double(recordPeak)` passes a **linear** amplitude into a field
declared as dBFS. A take peaking at −1.9 dBFS reports `0.8`. Convert with
`20 * log10(max(peak, 1e-7))`.

**e. Apply the selected input device.** `prepare(device:)` stores `currentDeviceID` but
`configureEngineSession()` (lines 232-234) only sets `inputNode.volume = 1`, so the engine always
uses the system default. Set it via `inputNode.auAudioUnit` /
`kAudioOutputUnitProperty_CurrentDevice`. Also `availableInputDevices()` (lines 42-62) hardcodes
`channelCount: 1` and `isDefault: false` for every device, so the UI cannot mark a default.

**f. Synchronize shared state.** The class is `@unchecked Sendable` (line 5) with `state`,
`recordSampleCount`, `recordPeak`, `clippedDuringCapture`, `recordFile` and `recordURL` written
from the render thread and read from `stopRecording()`/`cancelRecording()` with no
synchronization. The tap can also still be mid-callback when `removeTap` returns, racing
`recordFile = nil`. Put non-render state behind an actor or a single lock, and **drain the writer
queue before reading counters** in `stopRecording`.

**Done when (manual, M-1):** 20 minutes of continuous capture on a **44.1 kHz stereo USB
interface** produces a 48 kHz mono file whose duration matches wall clock within 50 ms and whose
`peakDBFS` is negative.

---

## T8 — Remaining S5 scope

Per spec §20 S5, still entirely missing:

- **`VoxglassStudio/Features/ImportAudio/**`** (spec §11.5) — decode, silence-split, per-segment
  slicing into `Audio/Original`, and the **mandatory origin declaration** sheet with the
  a11y-labeled `import.originWarning` element.
- **`VoxglassStudio/Features/TakeCompare/**`** (spec §11.7).
- **Autosave and recovery.** `ProjectPackage.swift:28` already reserves `Autosave/takes`, and
  `ProjectIntegrity.swift:36,45` already models `.autosaveOrphan` and `.recoverAutosave(URL)` —
  nothing writes there and nothing scans for orphans at launch. Wire both ends.
- **Test suites:** `ImportAssignmentTests`, `AIOriginLabelTests`, `RenderCountProbeTests`.

**Fold in the `SilenceSegmenter` fixes here** (`Voxglass/Core/Production/Audio/SilenceSegmenter.swift`),
since import is its only consumer:

- Lines 31-32: threshold is absolute (`max(thresholdDBFS, -50)` → a fixed −40 dBFS). Spec §11.5
  says **relative to file peak**, clamped to an absolute −50 dBFS floor. A take peaking at
  −20 dBFS currently gets a threshold 20 dB too high.
- Line 9: `Options.boundaryPadding` is declared and never used.
- Line 32: `var threshold` is never mutated — make it `let`.

---

## T9 — Performance (only if T3's budget test fails)

Measured on this machine (`swiftc -O`, 30 s @ 48 kHz): `upsample4x` alone is **83.6 ms** and the
10th-order Yule filter is **54.7 ms** — 138 ms before the Butterworth stage, noise-floor
envelope, RMS, peak, DC offset and silence bounds. The §11.6.9 budget is 150 ms.

Move peak, RMS, DC, the true-peak polyphase FIR and the ReplayGain filters onto Accelerate
(`vDSP_maxmgv`, `vDSP_svesq`, `vDSP_desamp`, `vDSP_biquadm`). Expect 5–20×.

---

## T10 — Housekeeping

- **Amend the spec** for the two deliberate deviations: §11.6.8 and §23 say ReplayGain "SHOULD
  reuse `BiquadFilter.swift`" — record that it does not, and why (see "Decisions already made").
- **Split the commits.** S1–S5 are currently one untracked working tree —
  `Voxglass/Core/Production/`, `VoxglassStudio/`, `VoxglassTests/Production/` and
  `VoxglassCoreTestSupport/` are all `??` in `git status`. The stage plan calls for one
  reviewable commit per stage (`feat(studio): S<N> — <summary>`). Split before adding more.
- Run `scripts/guard_production.sh` before each commit.

---

## Do not do

- Do not implement EBU R128 / LUFS as a replacement for ReplayGain. LibriVox's checker is a
  ReplayGain tool and §3.2.1 commits to reporting the number proof-listeners see. R128 for the
  retail/ACX path is an S7 conversation, and would be *in addition to* RG, not instead of it.
- Do not build a lock-free SPSC ring buffer. T7's pool + serial queue is the agreed scope.
- Do not implement `punchIn(from:)`. It correctly throws `.punchInNotSupported` and is not on the
  MVP acceptance path.
- Do not restructure `AudioMetricsCalculator`'s static-method layout. It is fine. The problem was
  never testability — it was that the tests asserted `isFinite` where they needed to assert a
  number.
