# S5 remediation plan — Recording, takes, and audio metrics

Status: proposal. Nothing in this document has been implemented.

Scope: `Voxglass/Core/Production/Audio/**`, `VoxglassStudio/Services/AVAudioEngineCapture.swift`,
`VoxglassStudio/Services/AVMetricsCalculator.swift`, `VoxglassStudio/Features/Record/**`,
`VoxglassTests/Production/Audio/**`.

---

## 0. Headline

**The ReplayGain deferral rests on a misdiagnosis, and the filter that was deferred is the
cheap part.** The real problem is that `replayGainDB` and `truePeakDBFS` are currently wrong by
~104 dB and ~12 dB respectively, and nothing in the test suite can see it. The Yulewalk filter
is a 22-number table and a 12-line loop; it is stable in `Float`, let alone `Double`; and the
whole ReplayGain 1.0 algorithm has been validated below against `metaflac` to within 0.05 dB.

Everything in §1 was measured, not reasoned about. Scripts are in the session scratchpad.

---

## 1. Findings

### F-1 — The `z = 1` integrator pole does not exist (blocking, but cheap)

`ReplayGainCalculator.swift:75` says:

> Yulewalk filter cascade (10th-order ITU-R 468 weighting) deferred — the exact pole at z=1
> requires custom biquad handling to avoid numeric divergence.

Three separate claims, all incorrect:

| Claim | Measured |
|---|---|
| "ITU-R 468 weighting" | The RG 1.0 Yule filter approximates the **inverse equal-loudness contour** (Robinson–Dadson + spherical-head model). ITU-R 468 is an unrelated noise-weighting curve. |
| "exact pole at z=1" | Max pole magnitude of the 10th-order denominator is **0.90794** at 48 kHz and **0.89733** at 44.1 kHz. `sum(a) = 0.02848 ≠ 0`, so DC gain is finite (−7.52 dB). |
| "numeric divergence in biquad cascade" | Factored into 5 biquads and run over white noise: `max|y| = 0.38121` in **`Float32`** and identical in `Float64`. Both finite. Perturbing the denominator by 1e-6 relative never produces `|pole| > 1` in 500 draws. |

What is almost certainly being seen: the **Butterworth** stage — already in the code and
already working — has a **double zero at exactly z = 1**. It is a DC-blocking zero (a
differentiator), not an integrator pole. Zeros on the unit circle are unconditionally stable.
The Yule numerator additionally has a real zero at z ≈ −0.99994, near Nyquist.

The other likely path to this dead end is trying to *design* the filter (MATLAB `yulewalk`,
Yule–Walker normal equations, Levinson–Durbin). That is genuinely ill-conditioned at order 10.
**Do not design the filter. Use the published table.** No root-finding, no biquad factoring, no
pole-splitting — a single direct-form-II-transposed 11-tap section in `Double`.

### F-2 — `replayGainDB` is off by ~104 dB (blocking)

`ReplayGainCalculator.analyzeFull` computes `gain = 89.0 - (L + 0.691)` where
`L = 10·log10(meanSquare)` on unit-scale samples. That mixes the ReplayGain 89 dB SPL reference
with the EBU R128 K-weighting offset and applies both to a dBFS-scale number. It is
dimensionally wrong.

Measured, current implementation vs. the reference algorithm vs. `metaflac --add-replay-gain`:

| Signal (48 kHz mono) | Current impl | RG 1.0 reference | `metaflac` |
|---|---:|---:|---:|
| pink, −20 dBFS | **111.20 dB** | 4.27 dB | +4.26 dB |
| pink, −26 dBFS | **117.20 dB** | 10.27 dB | +10.26 dB |
| pink, −14 dBFS | **105.20 dB** | −1.73 dB | −1.74 dB |
| 1 kHz sine, −20 dBFS | **108.31 dB** | 2.83 dB | +2.83 dB |
| 100 Hz sine, −20 dBFS | **116.14 dB** | 9.87 dB | +9.88 dB |

Downstream consequence: spec §15.3 derives perceived volume as `89 - replayGainDB` and warns
outside `[86, 92]`. Today that evaluates to **−22 dB** for a normal take, so
`perceivedVolumeOutOfBand` will fire on **every take in every LibriVox project** — the MVP's
primary destination and walkthrough W-1. This has to be fixed before S7 wires up validation.

Note also the 1 kHz vs 100 Hz rows: the reference gives the 100 Hz tone 7 dB more gain because
equal-loudness weighting knows bass is perceptually quieter. That spread is the entire point of
the Yule stage and the Butterworth-only version cannot produce it.

### F-3 — Butterworth coefficients are hardcoded for 48 kHz (major)

`ButterworthHP` (`ReplayGainCalculator.swift:56-73`) holds the 48 kHz coefficients and is used
regardless of the `sampleRate` argument. Recording defaults to 48 kHz so this is latent today,
but imported audio (spec §11.5 accepts WAV/AIFF/CAF/M4A/MP3/FLAC at any rate) will be analyzed
with the wrong filter. RG 1.0 defines a coefficient pair per supported rate.

### F-4 — `truePeakDBFS` reads 12.04 dB low (major)

`AudioMetricsCalculator.truePeakKernel()` normalizes the 33-tap Kaiser kernel so that **all**
taps sum to 1. A 4× polyphase interpolator needs **each phase** to sum to 1 — i.e. the kernel
must be scaled by 4. Measured: a 0.5-amplitude sine yields `max|y| = 0.1250`, exactly 0.5 / 4.

Consequence: the retail/ACX rule "true peak ≤ −3 dBTP" passes unconditionally, silently. Also
worth noting `truePeakDBFS` is currently reported *below* `peakDBFS`, which is impossible by
construction — a cheap invariant for a test.

### F-5 — Noise floor uses samples where the spec says milliseconds (major)

`computeNoiseFloor` (`AudioMetricsCalculator.swift:97-124`):

- `windowLength = 50`, `hop = 25` — **samples**, ~1 ms. Spec §11.6.4 says a **50 ms** window
  with a **25 ms** hop (2400 / 1200 samples at 48 kHz). At 1 ms the "envelope" tracks the
  waveform, so the 10th percentile lands in zero crossings of speech rather than in room tone.
- `absoluteFloor = 1e-7`. Spec says `10^(-70/20) = 3.162e-4`.
- `silentDuration = Double(silentCount * hop) / 48000.0` — sample rate hardcoded; the function
  does not take `sampleRate` at all.
- Step 4 averages the window **RMS values** linearly; the spec says the RMS **over** the silent
  windows (`sqrt(mean(e²))`).

### F-6 — Nothing tests the three broken metrics (major, and the reason F-2/F-4/F-5 shipped)

`MetricsCalculatorTests` covers peak, RMS, clip count, DC offset, duration and silence bounds.
It never asserts on `truePeakDBFS`, `noiseFloorDBFS`, or `replayGainDB`.

`ReplayGainTests` asserts only `isFinite`, monotonicity, and determinism — all of which a
constant 104 dB offset satisfies. There is no absolute-value assertion anywhere.

### F-7 — The capture tap does blocking file I/O and takes a lock on the render thread (blocking)

This is a bigger problem than the "ring buffer deferred" note implies. In
`processTapBuffer` (`AVAudioEngineCapture.swift:190-230`), on the real-time audio thread:

- `try? file.write(from: buffer)` — file I/O, allocation, and an internal lock.
- `levelContinuationsLock.withLock { ... continuation.yield(...) }` — `NSLock` plus
  `AsyncStream` continuation machinery, which allocates and can block.

Either can overrun the render deadline and drop buffers. The S5 acceptance criterion is "100
sequential paragraphs recorded without loss" — this is the thing most likely to fail it, and it
will fail intermittently and unreproducibly.

The `levels` stream is also created with the default `.unbounded` buffering policy, so a slow
consumer grows memory without bound.

### F-8 — Record format is never reconciled with hardware format (blocking)

`startRecording` creates the `AVAudioFile` at `RecordingDefaults` (48 kHz, mono, Float32) but
installs the tap with `inputNode.outputFormat(forBus: 0)` — the hardware format. There is no
`AVAudioConverter`. On any Mac whose input is 44.1 kHz or stereo (most built-in and USB
interfaces), `file.write(from:)` throws, `try?` swallows it, and the result is a **zero-length
WAV** while `recordSampleCount` keeps incrementing — so `CapturedTake.duration` reports a full
take that does not exist on disk.

`configureInputFormat(_:)` (line 236) only checks `hwFormat.sampleRate > 0` and ignores the
requested format entirely.

### F-9 — `CapturedTake.peakDBFS` receives a linear amplitude (minor, trivial)

`AVAudioEngineCapture.swift:166`: `peakDBFS: Double(recordPeak)` where `recordPeak` is linear
`max|x|`. A take peaking at −1.9 dBFS reports `0.8`.

### F-10 — Device selection is a no-op (major)

`prepare(device:)` stores `currentDeviceID` and `configureEngineSession()` only sets
`inputNode.volume = 1`. The engine always uses the system default input. Additionally
`availableInputDevices()` hardcodes `channelCount: 1` and `isDefault: false` for every device,
so the UI cannot mark a default.

### F-11 — Unsynchronized shared mutable state (major)

`AVAudioEngineCapture` is `@unchecked Sendable` with `state`, `recordSampleCount`, `recordPeak`,
`clippedDuringCapture`, `recordFile` and `recordURL` written from the render thread and read
from `stopRecording()`/`cancelRecording()` on another thread with no synchronization. The tap
can also be mid-callback when `removeTap` returns, so the final buffer can race `recordFile = nil`.

### F-12 — S5 scope not yet delivered

Per spec §20 S5, still missing:

- `VoxglassStudio/Features/ImportAudio/**` (§11.5 — decode, silence-split, per-segment slicing,
  mandatory origin declaration with the `import.originWarning` element)
- `VoxglassStudio/Features/TakeCompare/**` (§11.7)
- Autosave/recovery. `RecordingModel` writes to `FileManager.default.temporaryDirectory`, not to
  the project package's `Autosave/takes` directory that `ProjectPackage.swift:28` already
  reserves and that `ProjectIntegrity` already models via `.autosaveOrphan` /
  `.recoverAutosave(URL)`. Nothing scans for or recovers an orphaned autosave on launch.
- `RecordingModel.ingestTake` writes `sha256: ""`, `byteCount: 0`, `textHashAtRecording: ""` and
  never moves the file into the asset store — so no recorded take is actually persisted or
  integrity-checkable.
- `FakeAudioCapture` in `VoxglassCoreTestSupport` (only `FixedClock`, `SequentialIDGenerator`
  and `ProjectFixtures` exist), which the acceptance criterion explicitly requires.
- Test suites `RecordingFlowTests`, `RenderCountProbeTests`, `ImportAssignmentTests`,
  `AIOriginLabelTests`.

### F-13 — Minor deviations in `SilenceSegmenter`

- Threshold is absolute (`max(thresholdDBFS, -50)` → −40 dBFS fixed). Spec §11.5 says
  **relative to file peak**, clamped to an absolute −50 dBFS floor. A take peaking at −20 dBFS
  currently gets a threshold 20 dB too high.
- `Options.boundaryPadding` is declared and never used.
- `var threshold` is never mutated (`let`).

### F-14 — Metrics likely miss the 150 ms performance budget

Spec §11.6.9: metrics for a 30 s take in < 150 ms. Measured on this machine, `swiftc -O`,
30 s @ 48 kHz:

- `upsample4x` (true peak) alone: **83.6 ms**, and it materializes a 46 MB `[Double]`.
- 10th-order Yule direct form: **54.7 ms**.

That is 138 ms before the Butterworth stage, the noise-floor envelope, RMS, peak, DC offset and
silence bounds. Accelerate (`vDSP_biquadm`, `vDSP_desamp`, `vDSP_maxmgv`, `vDSP_svesq`) makes
this a non-issue, and true peak should stream a running max rather than allocating.

---

## 2. The validated ReplayGain recipe

Verified against `metaflac --add-replay-gain` at both 48 kHz and 44.1 kHz, agreement ≤ 0.05 dB
across pink noise at −14 / −20 / −26 dBFS, sine tones, and signals with 0 / 30 / 60 % silence.

1. Filter the unit-scale mono samples through the **Yule** section, then the **Butterworth**
   section, both direct-form (DF-II transposed), both in `Double`, coefficients selected by
   sample rate.
2. Split into **non-overlapping 50 ms blocks**; compute the mean square of each block.
3. `L_i = 10·log10(ms_i + 1e-37)`, **clamped** into range — **do not drop silent blocks.**
   (Dropping them drifts 0.24 dB at 60 % silence, which is normal for narration; clamping
   matched `metaflac` to 0.04 dB. See table below.)
4. 95th percentile: sort ascending, take index `ceil(N · 0.95) - 1`.
5. `gainDB = (64.82 - 20·log10(32768)) - L₉₅ = -25.4885 - L₉₅`.

The `-25.4885` constant is `PINK_REF` from `gain_analysis.c` rebased from ±32768 to ±1.0
sample scale. This is the single number that is missing today.

| pink −20 dBFS | drop silent blocks | clamp (correct) | `metaflac` |
|---|---:|---:|---:|
| continuous | 4.39 dB | 4.39 dB | +4.39 dB |
| 30 % silence | 4.38 dB | 4.45 dB | +4.41 dB |
| 60 % silence | 4.33 dB | 4.56 dB | +4.57 dB |

### Coefficients (both verified)

**48 000 Hz — Yule** (max pole 0.90794)

```
b: 0.03857599435200, -0.02160367184185, -0.00123395316851, -0.00009291677959,
  -0.01655260341619,  0.02161526843274, -0.02074045215285,  0.00594298065125,
   0.00306428023191,  0.00012025322027,  0.00288463683916
a: 1.00000000000000, -3.84664617118067,  7.81501653005538, -11.34170355132042,
  13.05504219327545, -12.28759895145294,  9.48293806319790, -5.87257861775999,
   2.75465861874613,  -0.86984376593551,  0.13919314567432
```

**48 000 Hz — Butterworth** (already in the code, correct)

```
b: 0.98621192462708, -1.97242384925416, 0.98621192462708
a: 1.00000000000000, -1.97223372919527, 0.97261396931306
```

**44 100 Hz — Yule** (max pole 0.89733)

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

RG 1.0 defines tables for 8 k / 11.025 k / 12 k / 16 k / 18.9 k / 22.05 k / 24 k / 28 k / 32 k /
36 k / 37.8 k / 44.1 k / 48 k. Two options for anything else:

- **(recommended)** ship only 44.1 k and 48 k and resample other rates to 48 k before analysis.
  The decoder already exists; recording is 48 kHz; imports are the only other source.
- ship the full table (~26 more lines of constants).

Either way, `analyze` must **not** silently apply the wrong table. Make the rate selection
explicit and return a "rate unsupported" signal rather than guessing.

---

## 3. Recommendation on `BiquadFilter`

Spec §11.6.8 and §23 say the ReplayGain implementation "SHOULD reuse" `BiquadFilter.swift`. The
uncommitted `configureDirect(b0:b1:b2:a1:a2:)` addition is that attempt.

**Recommend not reusing it, and reverting that method.** Reasons:

- `BiquadFilter` is `Float`. Metrics are specified in `Double` throughout (§11.6: "all levels
  are dBFS with 1.0 full scale").
- The Yule stage is order 10 and is *defined* as a single direct-form section. Factoring it into
  biquads requires root-finding on a degree-10 polynomial — precisely the ill-conditioned step
  that appears to have caused this detour. It buys nothing.
- `BiquadFilter` lives in `Core/Services/Playback/EQ` and is on the realtime playback path.
  Widening its API for an offline analyzer couples two unrelated subsystems.

Instead add a small `Production/Audio/DirectFormFilter.swift` (a `Double` DF-IIt section of
arbitrary order, ~25 lines) used by ReplayGain and available for future metrics. This is a
deliberate deviation from §11.6.8/§23 and should be recorded as such in the spec.

---

## 4. Proposed work, in order

Each step is independently reviewable and testable. Steps 1–3 are the ones that block S7.

### Step 1 — ReplayGain, done properly (≈ 1 h)

- Add `Production/Audio/DirectFormFilter.swift`.
- Add `Production/Audio/ReplayGainCoefficients.swift` — the tables above keyed by rate, plus an
  explicit `supportedRates` set.
- Rewrite `ReplayGainCalculator` to §2. Keep the `analyze` / `analyzeFull` signatures; add a
  rate-unsupported path (resample or throw — decide with Step 4).
- Revert `BiquadFilter.configureDirect`.
- Delete the incorrect comment at `ReplayGainCalculator.swift:75`.

**Accept:** golden-vector test (Step 3) matches `metaflac` within 0.25 dB.

### Step 2 — Fix true peak and noise floor (≈ 1 h)

- Scale the true-peak kernel by 4 (per-phase normalization). Assert `truePeak >= peak - 0.01`.
- `computeNoiseFloor` takes `sampleRate`; window 50 ms, hop 25 ms; `absoluteFloor = 10^(-70/20)`;
  RMS (not mean) over silent windows.
- Stream the true-peak max instead of materializing `[Double](count: n*4)`.

**Accept:** the assertions in Step 3.

### Step 3 — Tests that would have caught all of this (≈ 2 h)

Extend `ReplayGainTests` and `MetricsCalculatorTests`:

- **Golden vectors.** Commit 4–6 short WAVs (pink at −14/−20/−26 dBFS, 1 kHz and 100 Hz tones,
  one with 60 % silence) with `metaflac`-derived expected gains in a checked-in JSON. Assert
  within 0.25 dB. Generation script committed alongside so the fixtures are reproducible.
- **Frequency weighting.** A 100 Hz tone must receive ≥ 5 dB more gain than a 1 kHz tone at the
  same dBFS — this fails on any Butterworth-only implementation.
- **Absolute level.** Pink noise at −20 dBFS → gain in `[3, 6]` dB. (Today: 111 dB.)
- **Perceived volume.** `89 - replayGainDB` for a −20 dBFS take lands inside `[86, 92]` — the
  band the §15.3 warning actually uses.
- **True peak.** A 0.5-amplitude sine → `truePeakDBFS ≈ -6.02 ± 0.1`; and
  `truePeakDBFS >= peakDBFS` for every fixture. (Today: −18 dB.)
- **Noise floor.** Speech-like signal + −60 dBFS noise in the gaps → `noiseFloorDBFS` within
  3 dB of −60, `noiseFloorReliable == true`; and a gapless signal → `-90`, `reliable == false`.
- **Sample-rate independence.** The same signal generated at 44.1 k and 48 k must agree within
  0.3 dB on gain, RMS and noise floor. This catches F-3 and F-5's hardcoded 48000.
- **Performance.** 30 s of audio through `metrics(for:sampleRate:channels:)` in < 150 ms
  (§11.6.9). Expect this to fail initially — see Step 7.

### Step 4 — `FakeAudioCapture` + `RecordingFlowTests` (≈ 2 h)

Add `FakeAudioCapture` to `VoxglassCoreTestSupport`: scripted level stream, synthesized WAV
output, injectable failures (device disappears mid-take, disk full, permission denied).

`RecordingFlowTests` must cover the acceptance criterion — 100 sequential paragraphs, each take
persisted with a real `sha256`/`byteCount`, no take lost, no ID collision — plus the cases
`RecordingModel` currently gets wrong: `stopRecording` force-unwraps `currentParagraphID!`
(line 85, crashes if stop arrives without a start), and pre-roll uses a bare `Task.sleep` that
cannot be cancelled (line 58, so cancel during pre-roll still records).

### Step 5 — Make `AVAudioEngineCapture` correct (≈ 4 h)

Not a full lock-free ring buffer — that deferral is fine — but the render thread must stop doing
I/O and locking:

- Tap copies into a preallocated `AVAudioPCMBuffer` pool and hands off to a serial
  `writerQueue`; `AVAudioFile.write` happens there (F-7).
- Insert an `AVAudioConverter` from hardware format to project format in the writer queue (F-8).
  If conversion is impossible, fail the take loudly instead of `try?`.
- Replace the lock + multi-continuation broadcast with a single atomic level snapshot polled at
  30 Hz from the main actor (F-7). Give any retained `AsyncStream` an explicit
  `.bufferingNewest(1)` policy.
- Convert `recordPeak` to dBFS in `stopRecording` (F-9).
- Apply the selected device via `inputNode.auAudioUnit` / `kAudioOutputUnitProperty_CurrentDevice`,
  and report real `channelCount` / `isDefault` (F-10).
- Move all non-render state behind an actor or a single lock, and drain the writer queue before
  reading counters in `stopRecording` (F-11).

**Accept:** M-1 manual check — 20 min continuous capture on a 44.1 kHz stereo USB interface
produces a 48 kHz mono file whose duration matches wall clock within 50 ms and whose
`peakDBFS` is negative.

### Step 6 — Remaining S5 scope (F-12, F-13) (≈ 2 days)

`Features/ImportAudio`, `Features/TakeCompare`, real autosave into the package's
`Autosave/takes` with launch-time recovery, `RecordingModel.ingestTake` writing through the
asset store, and `ImportAssignmentTests` / `AIOriginLabelTests` / `RenderCountProbeTests`.
Fold in the `SilenceSegmenter` fixes (F-13) here, since import is its only consumer.

### Step 7 — Performance (F-14) (≈ 3 h, only if Step 3's budget test fails)

Move peak, RMS, DC, the true-peak polyphase FIR and the ReplayGain filters onto Accelerate.
Expect a 5–20× improvement; the budget stops being close.

---

## 5. Decisions needed

1. **`BiquadFilter` reuse.** §3 recommends deviating from spec §11.6.8/§23. Confirm, and amend
   the spec rather than leaving the code silently divergent.
2. **Sample-rate coverage.** Two rates + resample (recommended), or the full RG table.
3. **Scope of Step 5 for MVP.** F-7/F-8/F-11 are correctness, not polish — recommend doing all
   of Step 5 now. The lock-free ring buffer proper stays deferred.
4. **`metaflac` as a test dependency.** Recommend generating the golden vectors once and
   committing the WAVs + expected values, so CI does not need `flac` installed.
5. **Commit hygiene.** S1–S5 are currently one untracked working tree
   (`Voxglass/Core/Production/`, `VoxglassStudio/`, `VoxglassTests/Production/`,
   `VoxglassCoreTestSupport/` are all `??`). The stage plan calls for one reviewable commit per
   stage. Recommend splitting before adding more.

---

## 6. What should stay deferred

- **Lock-free SPSC ring buffer** in the capture tap. The pool + serial writer queue in Step 5
  gets the render thread clean; a true ring buffer is a later optimization.
- **`punchIn(from:)`.** Currently throws `.punchInNotSupported`; not in the MVP acceptance path.
- **EBU R128 / LUFS.** Tempting — better specified than RG and what retail actually uses — but
  LibriVox's checker is a ReplayGain tool, and §3.2.1 commits to reporting the number
  proof-listeners see. Revisit for the retail/ACX path in S7, alongside RG rather than instead
  of it.

The `AudioMetricsCalculator` static-method structure noted in the handoff is fine and should
stay; the problem was never testability, it was that the tests asserted `isFinite` where they
needed to assert a number.
