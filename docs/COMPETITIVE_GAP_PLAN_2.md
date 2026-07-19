# Voxglass — Competitive Gap Re-analysis & Closure Plan (round 2)

> **Superseded for release work by [`RELEASE_PLAN.md`](RELEASE_PLAN.md)**, which carries forward the
> phases still open here (2d pin-count, 2e force cast, 4A/4B/4D) alongside the monetization and
> App Store blockers. Phases 0, 1, 2a–2c, 2f, 3 and 4C shipped; this doc remains the record of that work.
>
> Successor to [`COMPETITIVE_GAP_PLAN.md`](COMPETITIVE_GAP_PLAN.md) (Step 0 + P0/P1/P2 + paywall refit)
> and [`remaining-gaps-plan.md`](remaining-gaps-plan.md). Those are now history.

## Context

We ran a competitive gap analysis in `docs/COMPETITIVE_GAP_PLAN.md` and a follow-up
`docs/remaining-gaps-plan.md`. Commits `90f4f43`…`eb1c127` claim all of it shipped. This re-analysis
verifies that claim against the code and asks what is genuinely left.

**Most of it did ship, and ship well.** Verified real and wired to UI: the `AudioEngine` protocol
widening (zero `as? AVPlayerAudioEngine` downcasts remain), variable speed 0.5–3.5x with per-book
memory and `changePlaybackRateCommand`, the sleep timer (including the tricky `cancelPreload` on
end-of-chapter), bookmarks with tombstoned iCloud sync, lock-screen artwork cached per-book,
library sort/filter, playlists-as-shelves, and the Dynamic Type sweep.

**But the P2 tier shipped as green tests over dead features, and the reason is structural: CI has
never run the test suite.** `.github/workflows/ios.yml` has exactly two jobs — `guarded-tests`
(ubuntu; despite the name it runs two `grep` steps and zero tests) and `testflight` (macOS archive).
There is no `xcodebuild test` anywhere; commit `ea20359` removed it. So `DynamicTypeGuardTests` and
~100 other tests have never gated a PR. That is the root cause, and it is why three features could
be committed, tested, and merged while being unreachable by a user.

The remedy is **not** to put the simulator back into CI — that stays deliberately local. It is that
*every one of these bugs is visible in the source text alone*, so the guards that catch them belong in
a shell script on the free ubuntu job. See Phase 0.

The intended outcome: repair what only *looks* shipped, make the guards real so it cannot recur,
tell the truth on the paywall, and close the cheap competitive gaps the first analysis never named
— above all **narrator names**, which our own analysis identified as BookDesign's most-complained-about
regression and which Voxglass also lacks.

### What the re-analysis found (all verified by grep, not inferred)

**Dead or broken despite being committed as shipped**

1. **Skip silence is unreachable.** `AppPreferencesStore.Keys.skipSilenceEnabled` is *read* at
   `PlaybackCoordinator.swift:257` but **no UI anywhere writes it**. The only writer is
   `PlaybackCoordinatorSilenceTests.swift:9`, in `setUp()` — so five tests pass green over a feature
   the user cannot switch on. (The README is honest about this; the commit message is not.)
2. **Volume normalization has a real math bug and zero tests.** In `BiquadFilter.swift:159-160`,
   `let energy = sample*sample; let rms = sqrt(energy)` is just `|sample|` — instantaneous magnitude,
   not the windowed running RMS the comment claims. The gain chases amplitude through every
   zero-crossing; this is a distortion generator, not an AGC. `EQEngine.reset()` (`:173`) also never
   resets `normGain`, so gain leaks across track changes. The planned `VolumeNormalizationTests.swift`
   was never written.
3. **`reconfigureSkipIntervals()` has zero callers** (`PlaybackCoordinator.swift:345`). Skip intervals
   work in-app, but `MPRemoteCommandCenter.preferredIntervals` stays pinned at the hardcoded `[30]`/`[15]`,
   so the lock screen still draws "15"/"30" no matter what the user picks.
4. **The free-tier offline pin limit is trivially bypassable.** `OfflineDownloadManager.swift:148`
   counts only `.cached` pins, though the comment right above it says "cached **or in-flight**". Start
   three downloads at once and all three land.
5. **Force cast.** `VoxglassCloudSync.swift:138` does `bmStore as! SQLiteBookmarkStore`; line 173 does
   the safe `as?` form of the same thing. Any other conformer crashes.
6. **The paywall's "Stays free forever" copy was never updated** (`ProPaywallView.swift:148`). It still
   reads the pre-P0 text and does **not** mention variable speed, sleep timer, bookmarks, lock-screen
   artwork, or "no ads ever" — the four features that *are* the competitive answer to BookDesign are
   invisible to a shopper. This was Phase A1 of `remaining-gaps-plan.md`; only the offline bullet got done.
7. **Dead UI shipped to users:** `BookDetailView.swift:461-470` renders an "Author Metadata / External
   Link" row, permanently disabled, detail text "Bundled metadata is not available yet".

**Two further bugs found while designing the fixes**

8. **Silence is detected on the wrong signal.** `EQAudioProcessor.swift:165-172` computes RMS on the
   *output* of `EQEngine.process` — i.e. after normalization, whose entire job is to raise quiet
   passages toward the target. Normalization actively defeats the detector downstream of it. RMS must
   be taken on the raw input sample.
9. **Even wired up, skip silence would not fire.** `SilenceDetector`'s threshold of `0.001` (≈−60 dBFS)
   is far below a volunteer LibriVox inter-sentence gap (≈−40 dBFS). It needs a realistic default
   (~0.02) plus on-device tuning.

**Architectural finding (drives Phase 1).** Volume normalization *and* skip silence both live inside
the EQ tap, which only attaches when the user has engaged the EQ
(`EQAudioProcessor.swift:45,54,63`; `AVPlayerAudioEngine.swift:178,195`). So neither can ever run for
a user who hasn't turned EQ on — and normalization is off even for users who never touch the EQ.

**Genuine competitive gaps the first analysis never named:** no way to text-search your own library
(zero `.searchable` in the codebase); per-chapter progress data exists in `PositionStore` but is never
surfaced; **no narrator names anywhere** (neither `Book` nor `Chapter` has the field); no AirPlay route
picker; nine feature views with zero VoiceOver annotations and zero `accessibilityValue` repo-wide.

### Decisions taken

- **Unbundle the audio tap from the EQ gate.** Normalization and skip silence ship **free**, per the
  original rule.
- **CarPlay stays out of scope** — the Apple entitlement is still pending.
- Library search, per-chapter progress, narrator names, and accessibility + AirPlay are all in scope.
- **The simulator never runs in GitHub Actions.** CI stays fast, free, and Linux-only; the
  `xcodebuild test` simulator suite is a **local** gate. This constrains Phase 0 below.

---

## Phase 0 — Make the guards real (blocks everything)

Nothing else is trustworthy until a failure can actually fail. This is the phase that prevents a
round 3 of this same document.

**The constraint:** GitHub Actions must not boot a simulator. An iOS `xcodebuild test` always needs a
simulator destination, so the full suite cannot run there — and that is fine, because *every bug this
document is about is detectable from source text alone*. Skip silence has no writer; `reconfigureSkipIntervals`
has no caller; a dead row says "not available yet". None of those need a running app to catch. So the
guards move to a shell script on the free ubuntu job, and the simulator suite becomes a local gate.

**0.1 New `scripts/guard_wiring.sh` — runs in the existing ubuntu `guarded-tests` job.** Pure source-level
greps: no Xcode, no simulator, no Swift toolchain, runs in seconds. Each rule derives its list *from
source*, so it cannot rot as new keys and methods are added. Rules:

- **Every `AppPreferencesStore.Keys` entry has a writer** (`@AppStorage(...)` or `.set(_:forKey:)`) under
  `Voxglass/Features/` or `Voxglass/App/`. **Catches #1** — the skip-silence toggle that never existed.
- **Every non-private `func` in `PlaybackCoordinator` is named in some other file**, with an explicit
  `SYSTEM_INVOKED` allowlist (each entry carrying a why-comment) for system-callback-only methods.
  **Catches #3** — `reconfigureSkipIntervals`.
- **No dead placeholder rows:** no `isEnabled: false` within a few lines of "not available yet" /
  "coming soon" under `Voxglass/Features/`. **Catches #7.**
- **No dead placeholder rows:** no `isEnabled: false` within a few lines of "not available yet" /
  "coming soon" under `Voxglass/Features/`. **Catches #7.**
- **Port the existing source-walking XCTest guards into the script** — `DynamicTypeGuardTests`'s
  bare-`Font.system(size:)` rule, plus (from 4D) "any `Features/` file with a `Button` has an
  `accessibilityLabel`" and "any file with a `Slider(` has an `accessibilityValue`". Today
  `DynamicTypeGuardTests` gates nothing because it only runs in the simulator suite; in the script it
  gates every PR. **The shell script is the CI source of truth**; keep the XCTest versions only if you
  want them locally, and don't let the two drift.

Five cheap rules, each traceable to a bug that actually shipped — deliberately not a general dead-code
detector.

**0.2 Guard `.xcodeproj` drift** (same ubuntu job): `xcodegen generate && git diff --exit-code Voxglass.xcodeproj`.
CI archives from the checked-in `Voxglass.xcodeproj` (`ios.yml:208`), not `project.yml`, so a `project.yml`
edit that isn't regenerated silently does nothing — and Phase 4D adds AVKit. Needs `xcodegen` on the runner;
if installing it on ubuntu proves annoying, fall back to asserting that `project.yml` and `Voxglass.xcodeproj`
were touched in the same commit.

**0.3 Make the simulator suite a real *local* gate.** New `scripts/test.sh` wrapping
`xcodebuild test -scheme Voxglass -destination 'platform=iOS Simulator,name=iPhone 16'`, plus an opt-in
`.githooks/pre-push` that runs it (and `guard_wiring.sh`) before a push. Document both in the README.

**Honest limitation, stated plainly:** this closes the gap for the *class* of bug that actually bit us
(unwired features, dead code, false paywall copy), and it costs nothing. It does **not** make the ~100
behavioural unit tests gate a PR — they remain a local discipline. If a wiring bug ever slips through that
the source-level rules cannot see, that is the moment to reconsider. Not before.

**New `VoxglassTests/WiringGuardTests.swift`** may still be written for local dev ergonomics (same rules,
XCTest form, walking sources from `#filePath` exactly like `DynamicTypeGuardTests`), but **CI enforcement
lives in the shell script** — that is what makes it real.

---

## Phase 1 — Unbundle the audio tap (blocks 2a/2b)

**Pure decision** — new `Core/Services/Playback/AudioTapPolicy.swift`:

```swift
enum AudioTapPolicy {
    struct Stages: Equatable {
        var applyEQ: Bool          // eqEngaged && isPro
        var normalize: Bool        // FREE
        var detectSilence: Bool    // FREE
        var shouldAttach: Bool { applyEQ || normalize || detectSilence }
    }
    static func stages(eqEngaged: Bool, isPro: Bool,
                       normalizationEnabled: Bool, skipSilenceEnabled: Bool) -> Stages
}
```

**Thin shell:** delete the three guard conditions in `EQAudioProcessor.swift:45,54,63`
(gating now lives in one place, not smeared across three methods); `AVPlayerAudioEngine.swift:178,195`
attaches on `stages.shouldAttach` rather than `eqEngagedDesired`; `AudioEngine.setEQEngaged(_:)` becomes
`setTapStages(_:)`, recorded by `FakeAudioEngine`. **Also move the silence RMS to the raw input sample**
(`EQAudioProcessor.swift:165-172`), before `EQEngine.process` — fixes finding #8.

**Tests:** `AudioTapPolicyTests` over all 16 combinations, notably
`testFreeUserWithNormalizationOnlyStillAttachesTap` and `testEQStagesOffForFreeUserEvenWhenEngaged`.

---

## Phase 2 — Repair the dead features

**2a — Volume normalization math.** Extract a testable `Core/Services/Playback/EQ/VolumeNormalizer.swift`
out of `EQEngine`: true windowed RMS (ring buffer + running sum-of-squares, ~2048 samples ≈ 46 ms), gain
updated once per ~256-sample hop rather than per sample, asymmetric attack/release, **gain clamped to
[0.25, 4.0]** (the real anti-wind-up, not the silence guard), and `reset()` restoring unity. Wire
`EQEngine.reset()` to call it.

New `VolumeNormalizationTests` — the load-bearing one is `testGainDoesNotChaseZeroCrossings`: feed a
steady 440 Hz sine at constant amplitude, assert gain variance across one period is ~0. **The current
code fails this loudly.** Plus convergence, limiter-never-clips, silence-doesn't-wind-up, reset-restores-unity.

**2b — Skip silence becomes reachable.** Add the missing `@AppStorage` toggle in `SettingsView`'s Playback
group (**the missing writer**), plus a new `volumeNormalizationEnabled` key (default on) with its own
toggle. Raise `SilenceDetector`'s default threshold to ~0.02 and make it injectable. In
`PlaybackCoordinator.handleSilenceChanged` boost *relative* to the user's rate
(`min(playbackRate * 1.5, 3.5)`) — today a user at 2.0x gets "boosted" to a slower 3.0x… which is only
1.5x. Extend `SilenceDetectorTests` with realistic LibriVox noise-floor fixtures.

**2c — `reconfigureSkipIntervals()` gets a caller.** `.onChange` on the two `@AppStorage` values already
in `SettingsView.swift:738`, plus one call from `configureRemoteCommands()` so the initial intervals
reflect stored prefs instead of the hardcoded `[30]`/`[15]`.

**2d — Free-pin limit.** Pure `pinCount(states:)` counting `.cached` **and `.downloading`**
(`OfflineDownloadManager.swift:148`). Tests: two in-flight downloads ⇒ a third returns `.needsPro`;
a failed download does not consume a pin.

**2e — Force cast.** Don't swap `as!` for `as?` — hoist `bookmarksForSync(bookID:)` onto the
**`BookmarkStore` protocol** so both call sites go through it and the downcast disappears. Same medicine
Step 0 applied to `AudioEngine`. Test: push works against an in-memory fake (today it crashes).

**2f — Delete the dead "Author Metadata / External Link" row** (`BookDetailView.swift:461-470`). Phase 4C
puts a real Narrators section in that space.

---

## Phase 3 — Paywall truth (depends on 1, 2)

Normalization ships **free** (LibriVox-specific quality fix; the rule is no new gates; Phase 1 makes it
structurally reachable). Therefore:

- Rewrite `foreverFreeSection` (`:144-153`) to name what actually shipped: speed 0.5–3.5x, sleep timer,
  bookmarks, lock-screen artwork, per-chapter narrators, volume normalization, skip silence, library
  search, FLAC/MP3, **no ads ever**, no telemetry, no accounts.

No `ProFeature` case is added or removed. New assertions:
`testForeverFreeSectionNamesTheP0Features`,
`testVolumeNormalizationIsFree`, `testSkipSilenceIsFree`.

---

## Phase 4 — New competitive work

**4A — Local library search** (independent). New pure `Core/Library/LibrarySearch.swift`: case/diacritic
folding, token-AND across title ∪ authors ∪ narrators, ranked title-prefix > title-contains > author >
narrator. Fold a `@Published searchQuery` into `LibraryStore`'s existing in-memory `visibleBooks`
(`LibraryStore.swift:18-41`) — **no DB round-trip**. `.searchable` on `LibraryView`.
*Risk:* `.searchable` may fight the custom `GlassDock` chrome; fallback is an inline glass `TextField` in
`filterSortBar`. The pure layer is identical either way, so the risk cannot spread past one view.

**4B — Per-chapter progress** (independent; cheapest high-value win). Add
`PositionStore.positions(forBookID:)` — one query, not the N+1 that `position(for:chapterID:)` would force
for a 30-chapter book. New pure `ChapterProgressRules.state(position:duration:)` →
`.unstarted` / `.inProgress(fraction:remaining:)` / `.finished` (`< 5 s` ⇒ unstarted; `isFinished` or
`>= 0.98` ⇒ finished; nil/zero duration never divides by zero). Surface as a 2 pt `ProgressView` +
checkmark in `ChapterRow` (`BookDetailView.swift:483`) and the `NowPlayingView` chapter list.

**4C — Narrator names — the competitive wedge** (the long pole; start early).

*Feasibility was resolved against the live APIs, not assumed.* Archive.org **cannot** supply per-section
narrators (file-level `creator` is the *author*). But archive.org item metadata carries
`call_number` = the **LibriVox book id** (12/12 on a sampled `collection:librivoxaudio`), and
`librivox.org/api/feed/audiobooks/?id=<id>&extended=1` returns a `sections` array with per-section
`readers`. Verified: LibriVox id 4489 has sections read by Mike Harris, Don W. Jenkins, Gregg Margarite,
Adam Whybray… **This is exactly the data BookDesign deleted, and `librivox.org` is already on the CI host
allowlist.**

Three real join hazards found on live data, each designed around and unit-tested: `file_name` is `null`
on older books (fall back to `listen_url.lastPathComponent`); `section_number` is 0-based on some books
and 1-based on others (never index by its value, use ascending order); `num_sections` can disagree with
`sections.count` (never trust the count).

- **Migration 6** (next id; 5 is the bookmarks tombstone): `narrators_json TEXT NOT NULL DEFAULT '[]'` on
  both `chapters` and `books`, mirroring the existing `authors_json` convention.
- `Chapter.narrators` / `Book.narrators`, defaulted. *Safe:* no persisted JSON anywhere encodes a `Chapter`
  or `Book`, so synthesized `Decodable` cannot break an existing payload.
- New `Core/Catalog/LibriVoxClient.swift` behind a protocol (so unit tests inject fixtures — **zero network
  in tests**), plus `call_number` on `InternetArchiveItemMetadata`.
- New pure `Core/Catalog/NarratorMatcher.swift`: normalize `file_name ?? listen_url` → strip extension,
  strip `_64kb`/`_128kb`, strip non-alphanumerics → join to `chapter.remoteURL`. Cascade:
  **stem-join → positional (only when counts match) → book-level only.** Every response is validated by
  `url_iarchive` against our identifier first, so a wrong `call_number` degrades to *no* narrator, never a
  *wrong* narrator.
- Enrichment hangs off `LibraryRepository.importInternetArchiveItem` (~`:252-275`), plus a launch backfill.
  **It must never block or fail an import** — 404 / timeout / join failure ⇒ empty narrators, import proceeds.
- UI: "Read by …" in the `BookDetailView` header (replacing the row deleted in 2f) and per-chapter in
  `ChapterRow` — but a pure `NarratorDisplay.chapterLine` returns `nil` when one narrator reads the whole
  book, so we don't stamp the same name on 30 rows (that would be *worse* than BookDesign).
- Tests from captured real API responses, including
  `testMultiReaderCollectionAssignsDifferentNarratorsPerChapter` (the wedge, asserted) and
  `testRejectsResponseWhoseIArchiveURLDoesNotMatchIdentifier`.

**4D — Accessibility + AirPlay** (after 4B/4C, whose data the labels read). New `AirPlayRouteButton`
(`UIViewRepresentable` over `AVRoutePickerView` — the repo's first; **requires adding AVKit to
`project.yml` + regenerating**, which Phase 0.2 now enforces). New pure
`AccessibilityAnnouncements.scrubberValue/chapterRowLabel/bookRowLabel` — the repo has **zero**
`accessibilityValue` uses today, so the scrubber announces nothing. Sweep labels across the nine bare
views. Two new source-guard rules: any `Features/` file with a `Button` needs an `accessibilityLabel`;
any file with a `Slider(` needs an `accessibilityValue`.

---

## Sequencing

| Phase | Work | Blocks on |
|---|---|---|
| **0** | `guard_wiring.sh` in ubuntu CI; xcodeproj-drift guard; local `test.sh` + pre-push hook | — |
| **1** | `AudioTapPolicy`; unbundle tap from EQ gate; raw-input RMS | 0 |
| **2a/2b** | Normalization math; skip silence reachable | 1 |
| **2c/2d/2e/2f** | Skip-interval wiring; pin limit; force cast; dead row | 0 |
| **3** | Paywall truth | 1, 2 |
| **4A / 4B** | Library search; chapter progress | — |
| **4C** | Narrators (migration 6 → client → matcher → UI → backfill) | 4B |
| **4D** | Accessibility + AirPlay | 4B, 4C |

2c–2f, 4A and 4B are independent and parallelizable. **4C is the long pole — start it early.**

---

## Verification

**In GitHub Actions (ubuntu, no simulator, seconds):**

```
scripts/guard_wiring.sh
xcodegen generate && git diff --exit-code Voxglass.xcodeproj
```

plus the two existing greps (host allowlist — `librivox.org` is already permitted, so
4C trips nothing).

**Locally (simulator — never in CI):**

```
scripts/test.sh    # xcodebuild test -scheme Voxglass -destination 'platform=iOS Simulator,name=iPhone 16'
```

**Falsification first — run each new guard against today's `main` and confirm it FAILS before fixing
anything.** A guard that passes on broken code is theater.

- Preference-key-writer rule must fail today (`skipSilenceEnabled` has readers but no writer).
- Coordinator-caller rule must fail today (`reconfigureSkipIntervals`).
- Dead-placeholder-row rule must fail today (`BookDetailView.swift:461`).
- Dynamic Type rule must **pass** today (that sweep really did land) — a rule that fails everywhere is
  as useless as one that passes everywhere.
- `VolumeNormalizationTests.testGainDoesNotChaseZeroCrossings` must fail against the current `EQEngine.process`.
- `BookmarkSyncTests.testPushWorksWithAnyBookmarkStoreConformer` must **crash** today (`as!` at `:138`).

**Device (irreducible):** skip silence actually firing on a real LibriVox recording (threshold is a physical
property — tune on device; **do not ship the toggle until this passes**, better no toggle than a dead one);
volume normalization by ear across a quiet and a loud book **with EQ off** (a free user's path — impossible
before Phase 1); AirPlay picker switching a real route; a VoiceOver pass over Now Playing.

---

## Out of scope

**CarPlay** (Apple entitlement still pending; P0 prerequisites are already shipped, so it stays a small job
whenever it lands), **localization** (zero infrastructure today; every `Text` is a hardcoded literal),
**cross-book continuous playback** (`PlaybackSession` is book-scoped by explicit design — needs a queue
abstraction above it; a separate epic), **Apple Watch**, **widgets/Siri** (needs an app group + relocating
the SQLite DB out of Application Support), **light theme** (app is hardcoded `.preferredColorScheme(.dark)`).
