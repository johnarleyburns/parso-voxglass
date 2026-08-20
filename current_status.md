# Voxglass — current status

**Updated:** 2026-08-19 (evening). **Tree:** `main` at `833f9a2` — the 2026-08-19 narration
field-test fixes are **committed, pushed and green on CI**.

---

## 2026-08-19 (evening) — narration field-test fixes: shipped

**Commit:** `833f9a2` (baseline `cf2d0a1`). **CI:** run `32315762467`, all four jobs green —
Guarded Tests, Compile (iOS), Logic Tests (swift test), TestFlight Build.
**Plan of record:** `docs/NARRATION_FIELD_FIXES_2026_08_19_PLAN.md` (local only — `docs/` is
gitignored as of `6f841e5`).

### Verification that ran

| Check | Result |
|---|---|
| `swift build`, `xcodebuild build -scheme Voxglass` | clean |
| `build-for-testing`, schemes `Voxglass` and `VoxglassNarrationE2E` | both succeed |
| `swift test --no-parallel --skip VoxglassPerformanceTests` | 1340 tests / 197 suites pass |
| Pre-commit gate (guards + logic + performance budgets + phone smoke + CarPlay smoke) | pass |
| CI run `32315762467` | success |

### Three defects the gates caught in my own work

1. **Quadratic validation.** The duplicate-issue guard added for item 5 was
   `issues.contains(where:)` — O(n) per issue, so `PerformanceBudgetTests` measured 433 ms on 3,000
   paragraphs against a ~130 ms linear expectation. Now a `Set<UUID>` membership insert
   (`Evaluator.emittedIssueIDs`). The budget test exists for exactly this class and earned its keep.
2. **`attest()` blanked the description.** It assigned `project.metadata.description = descriptionText`,
   so attesting wiped the description item 6 had just filled in. `buildParagraphs` now seeds the
   draft, and `resolvedDescription(title:author:narrator:existing:)` prefers the narrator's draft,
   then the stored value, then the generated one. **Other `attest()` fields still have this shape** —
   language and subjects will blank the same way if their drafts are ever empty.
3. **Ambiguous `BackButton` in the smoke test.** The dashboard's navigation bar stays in the
   accessibility tree behind the flow's full-screen cover, so a bare `app.buttons["BackButton"]`
   matched two elements. Scope to `app.navigationBars["Review"]`.

### Two simulator facts, learned the hard way

- **Never pass `CODE_SIGNING_ALLOWED=NO` to `xcodebuild test`.** The unsigned app has no CloudKit
  entitlement and traps in `CKContainer.init(identifier:)` inside `AppServices.init()` at launch,
  15 s in, with an `EXC_BREAKPOINT` that looks nothing like a signing problem.
  `scripts/test.sh` deliberately omits the flag.
- On a **throwaway simulator with no saved narrator name**, the phone smoke test still fails at
  `VoxglassUITests.swift:251` with `1 blocking · 21 warnings`, the blocker being
  `staleDisclaimerText`. That is N1 below, unchanged and pre-existing — see "Still open,
  deliberately". The shared `iPhone 16` has a name saved, which is why the gate is green there.

### Not yet run

`VoxglassNarrationE2E/NarrationStateFreshnessTests.swift` — seven tests covering approval
persistence, the source-URL prompt, validation freshness, on-check analysis, `normalizeLoudness`,
the description backfill, and the stale-save refusal. The file **compiles** but the harness is
on-demand by design (its own scheme, outside `scripts/test.sh`, the pre-commit hook and CI), so
nothing has executed them. Run with
`xcodebuild test -scheme VoxglassNarrationE2E -destination 'platform=iOS Simulator,name=iPhone 16'`.

### What changed, by work item

Implemented in the plan's order: W9 → W7 → W10 → W4/W3/W6 → W5/W11 → W1/W2/W8.

| Item | Change |
|---|---|
| **W9** | `ScriptApplier` resolves every paragraph index against the live array instead of a chapter snapshot taken before the intro is inserted. That snapshot made the outro script overwrite the preceding **recorded** body paragraph while the real outro stayed stale, so "Regenerate" could never clear `staleDisclaimerText`. Its retail branch also now actually writes an existing credits chapter's text (it used to count `report.updated` and change nothing). |
| **W7** | `NarrationFlowRoot` takes `existingID: UUID?` and loads the project from the store; `ProjectDashboardView` holds `@State project`, adopts newer revisions from the model, and re-reads the store when the flow closes; `DiscoveryEnvironment.save` refuses a write whose `modifiedAt` is older than the stored row. This is the defect that reverted approvals, resurrected the source-URL prompt, and undid regenerated disclaimers. |
| **W10** | `SQLiteProductionStore.save` (and `InMemoryProductionStore.save`) carry forward `metrics_json` for takes whose incoming graph has none, so the delete-and-reinsert no longer erases analysis written by `setTakeMetrics`. `runValidation()` now reloads from the store and calls the new `analyzeMissingMetrics()`; `analyzeMetricsLater` / `recomputeMetrics` patch the one take in place instead of swapping in a whole reloaded project. The report sheet is presented *before* the check runs and shows `validation.analyzing` while it does. |
| **W4** | New `reloadProjectFromStore()` and `storedProject(_:)` on the model; the review screen drops focus before checking. |
| **W3** | The dashboard Details card is read-only until an `dashboard.details.edit` button is pressed, holds edits in a draft dictionary committed once on Done, and gained a Description field. |
| **W6** | `NarratableWork.summary`, `BookMetadata.defaultDescription(title:author:narrator:)`, populated by `importNeed` / `buildParagraphs` / `NarrationProjectBuilder`, plus a description repair in `backfillProjectDetailsIfNeeded` with the key bumped to `narration.backfill.details.v2` so already-marked projects are revisited. |
| **W5** | The intro and outro disclaimer issues now carry distinct titles, messages and `variant`s; `ValidationRuleEngine.add` refuses to append a second issue sharing an id. |
| **W11** | New `AssemblyLoudness` — `normalizationGainDB` **adds** ReplayGain (the old `SegmentQueueBuilder` negated it, doubling the deviation) and clamps against a true-peak ceiling. New `FixAction.normalizeLoudness` + `NarrationFlowModel.normalizeLoudness()`, wired into both fix-action switches. `evaluateLoudness` judges the audio that will actually export, and paragraph review shows each take's estimated dB. |
| **W1** | `NarrationPressStyle` (scale + opacity + haptic on press) replaces `.buttonStyle(.plain)` + `.tactileTap()` on the narration buttons — the old gesture also fired on disabled buttons. |
| **W2** | Approve / Flag / Re-record / Import each get their own full-width 48pt row in `ParagraphReviewView`, and Approve reads "Approved" once it lands. |
| **W8** | "Check my recording" removed from the dashboard and the assemble screen; it lives only on Review. |

### Files touched

Core: `ScriptApplier.swift`, `ScriptGenerator` consumers, `ValidationRuleEngine.swift`,
`FixAction.swift`, `SegmentQueueBuilder.swift`, new `Assembly/AssemblyLoudness.swift`,
`SQLiteProductionStore.swift`, `InMemoryProductionStore.swift`, `BookMetadata.swift`,
`NarrationNeed.swift`, `NarrationProjectBuilder.swift`.

Features: `NarrationFlow.swift`, `NarrationFlowScreens.swift`, `ProjectDashboardView.swift`,
`ParagraphReviewView.swift`, `ValidationReportView.swift`, `DiscoveryEnvironment.swift`,
`NarrationProjectRepository.swift`, `DesignSystem/NarrationButtons.swift`.

Tests: new `VoxglassTests/Production/Text/ScriptApplierIndexTests.swift`,
`Production/Validation/DisclaimerIssueIdentityTests.swift`,
`Production/Assembly/LoudnessNormalizationTests.swift`,
`Production/Store/TakeMetricsPersistenceTests.swift`,
`Production/Text/NarrationDescriptionTests.swift`; updated
`Production/Validation/FixActionCoverageTests.swift` (19 cases now); new
`VoxglassNarrationE2E/NarrationStateFreshnessTests.swift`; new leg
`assertNarrationDetailsAndReviewPersist` in `VoxglassUITests/VoxglassUITests.swift`
(still exactly one UI test function per device). `Voxglass.xcodeproj/project.pbxproj` regenerated
via `xcodegen generate` for the new E2E file.

### Known consequences to watch on the first real run

- The dashboard no longer offers "Check my recording", so any manual script that taps
  `dashboard.checkRecording` will fail by design.
- `NarrationFlowRoot(existing:)` no longer exists; the resume path is `existingID:`. The
  value-taking `NarrationFlowModel(existing:)` initializer is unchanged and still used by the
  smoke test and the E2E harness.
- The details-backfill key bump means every existing project is repaired once more on next launch.

### Still open, deliberately

**"Plan — pick the narrator name up front (N1)" below is NOT closed by this work.** W9 makes
Regenerate actually fix a stale disclaimer and W5 makes the two issues legible, but a first-time
narrator with no saved name still records an intro that says *"Recording by ."*, because tapping a
featured need goes straight to the record screen and skips the name prompt. That is a separate,
still-unimplemented plan.

---

## 2026-08-19 — CI hang diagnosed and fixed; smoke-test blocker cleared

### Where we are

Every CI run since `539e495` (2026-08-17 23:23) failed the same way: the **Logic Tests (swift test)**
job hit its 30-minute `timeout-minutes` and was killed, so `testflight` (which `needs` it) never ran
and no build was delivered. `Compile (iOS)` and `Guarded Tests` were green throughout.

**Why the logs said nothing.** The job log stopped dead at `Build complete!` with zero test output.
swift-testing block-buffers stdout when it is not a TTY and flushes only at process exit, so a hung
run logs *nothing* — the last green run's output all arrived in a single burst at the end. The runner
image, macOS version, and Xcode (26.6 / 17F113) were byte-identical between the last green run and
the first hang, and `539e495` touched only `Voxglass/Features/**` (not in the SwiftPM package), so
this is a **latent deadlock in the logic tests**, not a code regression.

**The deadlocks found.** Both are unbounded waits that can never be satisfied once a scheduling race
goes the wrong way — harmless on a 10+ core dev Mac, fatal on a 3-core hosted runner:

1. `CaptureRingBufferTests.concurrentProducerConsumerPreservesOrderAndCount` — the producer pushed
   65,536 samples into an 8,192-sample ring relying only on `Task.yield()` to keep the consumer fed.
   `CaptureRingBuffer.push` **drops** when full, so one starved moment makes the consumer's
   `while box.received < total` unsatisfiable, and `await consumer.value` parks the whole serial
   suite forever.
2. `FakeAudioEngine.resumeSuspendedLoad()` / `resumeAllSuspendedLoads()` / `failSuspendedLoad(_:)` —
   each dropped the call on the floor when no continuation was queued yet. Tests reach the suspension
   point by *sleeping* (`drainMainQueue()` = a 200 ms `Task.sleep`), so on a loaded runner the resume
   can land first; `PlaybackCoordinatorSelectionTests.playPublishesPreparingBeforeEngineLoad` then
   blocks forever on `await playTask.value`.

### What changed

| File | Change |
|---|---|
| `VoxglassTests/Production/Audio/CaptureRingBufferTests.swift` | Producer waits for room before each push (so "no drops" is a precondition, not luck); consumer stops once production is done and the ring is drained; every wait is deadline-bounded; an overrun now fails `#expect(ring.droppedSampleCount == 0)` instead of hanging. |
| `VoxglassTests/Fixtures/FakeAudioEngine.swift` | Adds `armedResumes`: a resume that arrives before the matching `load` reaches its suspension point is queued and consumed FIFO by the next suspending load. Behaviour is unchanged whenever a continuation *is* queued. |
| `scripts/ci-logic-tests.sh` (new) | Runs the suite under `script -q /dev/null` so output streams (a hang now names the last started test) and `sample`s the test process past a 20-minute watchdog, then kills it — so a future hang explains itself instead of costing a 30-minute round trip. Verified locally: exit-code passthrough (0 and non-zero) and watchdog kill both work. |
| `.github/workflows/ios.yml` | Logic-tests step calls `bash scripts/ci-logic-tests.sh`. |
| `Voxglass/Features/Production/Discovery/NarrationFlow.swift` | `play(url:…)` reports which step failed instead of collapsing four causes into one message (see "What is left", item 1). |
| `VoxglassUITests/VoxglassUITests.swift` | The review-playback assertion quotes the "Playback unavailable" alert on failure. |

**Verified locally:** `swift test --no-parallel --skip VoxglassPerformanceTests` → 1319 tests /
192 suites pass (73–166 s depending on machine load); `check-swift6.sh` and `guard_wiring.sh` pass.

### What is left

1. **Resolved — the phone smoke test passes again; the failure was device state, not `HEAD`.**
   `VoxglassUITests.testAppBootsVisitsAllTabsEQAndProductions()` had been failing at
   `VoxglassUITests.swift:378` (`Paragraph playback did not expose now-playing state`) with no
   diagnostic, because `NarrationFlow.play(url:…)` swallowed all four possible failures into one
   message. Two changes were made and the test now passes 3/3 on a clean simulator:

   - `NarrationFlow.play(url:…)` no longer wraps the whole attempt in one `do`/`catch`. Each step —
     audio-session activation, the missing-file check, `AVAudioPlayer(contentsOf:)`, `prepareToPlay()`,
     `play()` — reports its own message, and the two that carry an `Error` quote it. The nil-`paragraphID`
     case is now an explicit precondition instead of a `CocoaError` thrown *after* the player was already
     installed. Behaviour on the success path is unchanged.
   - `assertReviewPlaybackShowsState` appends the "Playback unavailable" alert text to its failure
     message (`playbackFailureDetail`), so this assertion can never again fail anonymously.

   Verified: `xcodebuild test -scheme Voxglass` on a throwaway `Voxglass-Agent-iPhone-16` → **Passed,
   3/3**, review-playback leg included. The simulator was deleted afterwards.

2. **Found while verifying — first-run LibriVox export is blocked by a stale disclaimer.**
   Not fixed; recorded here as the next narration defect.

   On a simulator with **no saved narrator name**, the same test fails earlier, at
   `VoxglassUITests.swift:251`, with the validation report reading `1 blocking · 6 warnings` and the
   blocking issue `staleDisclaimerText` ("The LibriVox disclaimer for Nothing Gold Can Stay does not
   match the current metadata").

   Cause: `buildParagraphs()` bakes the LibriVox intro text from `LibriVoxScriptGenerator`, which
   interpolates `project.metadata.narrator`. Tapping a featured need goes **straight to the record
   screen**, skipping the paragraph-list screen that owns the "Choose your narration name" prompt, so a
   first-time narrator records an intro that says *"Recording by ."*. Entering the name later on the
   metadata screen sets `project.metadata.narrator` (`attest()`, `NarrationFlow.swift:1592`) but never
   re-applies the script plan, so the recorded text and the engine's expectation diverge and LibriVox
   export is blocked behind the `Regenerate` fix action.

   Fix plan: **[Pick the narrator name up front](#plan--pick-the-narrator-name-up-front-n1)** below.

   This is invisible on the shared `iPhone 16` simulator and on any real device where the narrator name
   has ever been saved, which is why the gate has been green.

3. **Confirm on CI.** After pushing, watch the logic-tests job: with streaming output restored, a
   remaining hang will name the test that caused it.

### Build/test efficiency — findings

**"Compile the shared code once instead of three times" is not achievable.** The three builds target
three different platform triples and cannot share object code:

| Phase | Triple | Build system |
|---|---|---|
| `swift test` | macOS arm64 | SwiftPM → `.build/` |
| `xcodebuild -scheme Voxglass` | iOS Simulator arm64 | Xcode → DerivedData |
| `xcodebuild -scheme VoxglassWatch` | watchOS Simulator arm64 | Xcode → DerivedData |

`VoxglassCore` is consumed by the Xcode project as a local SwiftPM package (`project.yml` →
`packages: VoxglassCore: path: .`), and the `VoxglassWatch` scheme builds only `VoxglassWatch.app`,
so there is no *redundant* build to remove — just three genuinely different platforms.

Real wins, largest first:

1. **Move the two simulator legs from `pre-commit` to `pre-push`.** This is the dominant cost and the
   only change that alters the order of magnitude: commits drop to roughly guards + `swift test`
   (~3 min) and the simulator gate runs once per push instead of once per commit. `pre-push`
   currently runs nothing at all. *Not done — it changes the project's stated gate, so it needs a
   decision.*
2. **Pin an explicit `-derivedDataPath` (e.g. `.build/dd`)** in `scripts/test.sh`. Today both
   `xcodebuild` calls use the shared global DerivedData, which other projects on this machine evict
   and churn; a repo-local path makes incremental reuse predictable.
3. **Merge the two `swift test` phases in `scripts/test_logic.sh`.** Phase 1 (`--skip
   VoxglassPerformanceTests`) built in 0.66 s, then phase 2 (`--filter VoxglassPerformanceTests`)
   spent **23.7 s rebuilding**. The performance tests already self-skip on `VOXGLASS_TIMING_TESTS`
   (all six reported `skipped`), so the second phase exists only to set that variable — a single run
   with the variable set should remove the rebuild. Worth ~24 s/commit; cause of the rebuild not yet
   confirmed.
4. **`build-for-testing` + `test-without-building`** for the simulator legs. No help for the hook
   (sources always change), but it removes a full app rebuild per iteration when debugging a UI test.

Measured, for reference (this machine, warm caches): guards ~5 s; `swift test` 73–166 s;
phone smoke leg 104 s to failure; watch smoke leg not reached.

### Simulator hygiene (agent convention)

Agent runs must use **dedicated, tagged** simulators and delete them afterwards, never the shared
`iPhone 16` device (`scripts/test.sh` boots that one by default and permanently grants it microphone
access). Verified working:

```sh
# up
xcrun simctl create "Voxglass-Agent-iPhone-16" \
  com.apple.CoreSimulator.SimDeviceType.iPhone-16 com.apple.CoreSimulator.SimRuntime.iOS-26-5
xcrun simctl create "Voxglass-Agent-Watch" \
  com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-10-46mm com.apple.CoreSimulator.SimRuntime.watchOS-26-5

bash scripts/test.sh --device "Voxglass-Agent-iPhone-16" --watch-device "Voxglass-Agent-Watch"

# down (always)
xcrun simctl shutdown "Voxglass-Agent-iPhone-16" "Voxglass-Agent-Watch" || true
xcrun simctl delete   "Voxglass-Agent-iPhone-16" "Voxglass-Agent-Watch"
```

As of this update no agent simulators exist and none are booted.

---

## Plan — pick the narrator name up front (N1)

**Status:** specified 2026-08-19, not started. **Fixes:** the first-run `staleDisclaimerText` block
recorded above.

### The decision

Ask for the narrator name **the first time the user opens the Narration tab with no name saved**, not
somewhere inside the recording flow. The name is an identity choice, not a per-project field: it is the
one piece of metadata every LibriVox disclaimer interpolates, and it must be known *before* any
disclaimer text is generated. Asking at the tab is the earliest point where the user has expressed
intent to narrate and the latest point that is still before `buildParagraphs()`.

Prompt copy, exactly:

> **Your narrator name**
>
> Pick your name to use as a narrator, it can be your real name or a pseudonym, up to you.

### Why the current design fails

`voxglass.narratorName` (`UserDefaults.standard`) is read in three places and written in two, and the
only two prompts that can set it live *inside* the flow:

| Site | Role |
|---|---|
| `NarrationFlow.swift:322` | `var narrator = UserDefaults…string(forKey:) ?? ""` — read at model init |
| `NarrationFlow.swift:985` | `resume(_:)` backfill of `project.metadata.narrator` |
| `NarrationProjectRepository.swift:157` | read when materialising a project |
| `NarrationFlow.saveNarratorName(_:)` | write — reached only from the two in-flow alerts |
| `NarrationFlow.attest()` (`:1601`) | write — the metadata screen, *after* recording |
| `NarrationFlowScreens.swift:103` | prompt on the paragraph-list screen |
| `NarrationFlowScreens.swift:778`, `ProjectDashboardView.swift:77` | prompt on review/dashboard |

Tapping a featured need goes straight to `RecordView`, so **none** of those prompts is on the path a
first-time narrator actually takes. The intro is generated with `narrator == ""`, recorded as
*"Recording by ."*, and only then does the metadata screen set the real name — at which point the
recorded text and `LibriVoxScriptGenerator`'s expectation diverge and LibriVox export is blocked.

### Steps

**N1.1 — one owner for the name.** Add `NarratorIdentity` (a small `Sendable` store over
`UserDefaults`, in `Voxglass/Features/Production/Discovery/`) exposing `current: String`,
`isSet: Bool`, and `save(_:)`. Route all five sites in the table above through it; nothing else reads
or writes the raw key. `NarrationTabView` needs the name before any `NarrationFlow` exists, so the
store must not depend on the flow model.

**N1.2 — ask on the Narration tab.** In `NarrationTabView` (`NarrationTabView.swift:14`), on first
appearance with `!NarratorIdentity.isSet`, present the prompt above as an `.alert` with a `TextField`
(matching the existing prompts' treatment), identifier `narration.narratorPrompt`. Save trims
whitespace and is disabled while the field is blank. Offer **"Not now"** — the tab must stay usable —
but re-ask on each fresh appearance until a name is saved, and record the decline only for the current
app run (no persisted "never ask" flag).

**N1.3 — never bake a blank name into a disclaimer.** `buildParagraphs()` must not generate LibriVox
intro text while the narrator is empty. Two guards, both needed:

- If `NarratorIdentity.isSet` is false when a need or import is opened, present the same prompt before
  the flow builds paragraphs.
- If the user still declines, `saveNarratorName(_:)` and `attest()` re-apply the LibriVox plan
  (`ScriptApplier().apply(LibriVoxScriptGenerator().plan(for:)…)`) to disclaimer paragraphs that have
  **no takes yet**. A disclaimer that is already recorded is deliberately left stale — its audio really
  does say the wrong name, so `staleDisclaimerText` must keep asking for a re-record. That asymmetry is
  the whole point and must be stated in the code comment.

**N1.4 — changeable later.** Add a "Narrator name" row to the Settings → Narration group
(`SettingsView.swift:36`), identifier `settings.narratorName`, writing through `NarratorIdentity`.
Changing it there must run the same N1.3 resync so unrecorded disclaimers follow the new name.

**N1.5 — guard it.** Extend `check_pref_key_writers` in `scripts/guard_wiring.sh` so `voxglass.narratorName`
may only appear inside `NarratorIdentity`. This is the guard that keeps N1.1 from rotting.

### Tests

- **Logic tests** (`VoxglassTests`, the real coverage): a fresh store reports `isSet == false`; saving
  trims and persists; `buildParagraphs()` after a save produces an intro whose text equals
  `LibriVoxScriptGenerator().plan(for:)`; `saveNarratorName` resyncs an unrecorded disclaimer and
  **leaves a recorded one stale**; a project whose disclaimer is recorded still raises
  `staleDisclaimerText` after a rename.
- **One UI smoke test per device stays the rule.** Extend
  `VoxglassUITests.testAppBootsVisitsAllTabsEQAndProductions` in place with a leg that answers the new
  tab prompt; do **not** add a second smoke test. This also removes the test's dependence on ambient
  simulator state — the reason the `:251` failure was invisible on the shared `iPhone 16`.
- **Verify on a throwaway simulator with no saved name**, per the simulator-hygiene convention below.
  That is the only configuration that reproduces the bug.

### Risk

The smoke test currently reaches the record screen with no interstitial. N1.2 adds an alert on the
Narration tab that fires before the "Start a Narration" shelf is usable, so every UI test leg that taps
`Narration` needs the prompt answered or dismissed first — that is the one change most likely to break
the gate, and it should land together with the test update rather than before it.

---

## Narration review & export fix plan — implemented

**Plan of record: [`docs/NARRATION_REVIEW_EXPORT_FIX_PLAN.md`](docs/NARRATION_REVIEW_EXPORT_FIX_PLAN.md).**
Approved on 2026-08-17 and implemented on 2026-08-18.

**Why it is next.** A field test on 2026-08-17 (on `539e495`, i.e. *after* the "follow-up review
fixes" recorded below) found that the narration flow cannot actually produce an audiobook. Seventeen
defects, each traced to code in the plan's §1:

- **Review is unusable.** Playback state is set optimistically and cleared on pause, so nothing
  visibly starts or stops; the chapter-play control is buried in a `DisclosureGroup` label that owns
  the tap; a collapsed chapter cannot be re-expanded (the `isExpanded` setter is discarded); the
  chapter counter counts *approved* and reads "3/4 Complete" with all four recorded; filters that
  match nothing still render "0/0" headers; approval has two affordances on opposite edges of the
  row; tapping a paragraph lands in the *recording* screen, not a review screen.
- **Old narrations aren't repaired.** The backfill lives in `resume(_:)`, which the dashboard entry
  point never calls — so narrator and source URL stay empty, which in turn disables export.
- **Export is unreachable.** "Everything recorded — review" is disabled by exactly the condition that
  produces its caption; "Produce files" is gated on narrator/author/language for *every* destination
  though Personal Listening requires only a title; the "Re-analyze" fix button is one of fifteen
  `FixAction` cases that fall through to `break`; validation can only be run on the last screen.
- **Nothing is listenable.** A finished Personal Listening export is copied to
  `My Completed Narrations`, a directory with one writer and **no reader** anywhere in the app, and
  the done screen tells every narrator to upload to the LibriVox forum regardless of destination.
- **Recorded takes never get audio metrics** (found while tracing), so the validation report a
  narrator sees is nearly content-free.

**What landed.** The review list now has honest paragraph/chapter playback state, expandable chapter
headers, separate recorded/approved counts, useful empty filters, one approval control, and a full
paragraph-review screen with take selection and re-recording. Dashboard and resume paths run the
same persisted narrator/source backfill. Validation is available from dashboard, review, and
assembly; all `FixAction` cases perform work or navigate to a working destination; captured and
imported takes are analyzed for real metrics.

Export requirements are destination-specific. Personal Listening needs only a title and no public
rights attestation, produces real chapter audio, imports only true chapter files into My Books, and
offers playback there. The audit caught and fixed an additional package defect: the whole-book M4B
had inherited the `.chapter` role and was being imported as a spurious extra chapter.

Key decisions preserved from the plan:

- Personal Listening needs no public-distribution rights attestation (the rule engine already agrees;
  the code path contradicted it).
- A finished Personal Listening export is auto-added to **My Books** through
  `LibraryRepository.importLocalFolder`, so it plays in the normal player with position sync.
- **Exactly one UI smoke test per platform, unchanged.** All cheap regression coverage is added as
  helper legs *inside* the existing `VoxglassUITests.testAppBootsVisitsAllTabsEQAndProductions`.
- The whole-book proof is a **development harness**, not a smoke test: `VoxglassNarrationE2E`, a
  hosted unit-test target on its own scheme, run by `scripts/narrate_book_e2e.sh`. It is not in the
  `Voxglass` scheme, `scripts/test.sh`, the pre-commit hook, or CI. It narrates a 3-chapter fixture
  book with Apple speech synthesis and asserts the exported audio is real (per-chapter duration
  within 5 %, mean RMS above −45 dBFS, true peak below −0.1 dBFS, non-silent opening).

**Verification.** The production/wiring guards, new focused logic tests, iPhone simulator build, and
the hosted 3-chapter narration harness pass. The harness generated 18 spoken paragraph takes,
analyzed their metrics, exported three listenable AAC chapter files, verified duration/RMS/peak and
checksums, and proved the resulting three-chapter book is imported and playable in My Books. The
existing single iPhone smoke test was extended in place with review playback, collapse/filter/count,
paragraph-detail, shared-button, early-validation, and completed-dashboard regression legs; no
second UI smoke test was added.

---

## Status of the shipped MVP

The revised iPhone + Watch narration MVP (`docs/iphone-watch-only-revised-mvp/SPEC.md`) is
implemented across stages P0–P9. On 2026-08-10 all thirteen gaps from `GAP_ANALYSIS.md` were closed
per `GAP_FIX_BRIEF.md` (F1–F8) and merged to `main`; see the closure record at the top of
`GAP_ANALYSIS.md`.

**Caveat, recorded 2026-08-17:** the "Follow-up review fixes" below claim working review playback,
chapter-order playback, chapter collapse and narrator/source-URL backfill. The field test on
`539e495` disproved all four. Treat those entries as history, not as current behaviour; the fix plan
above supersedes them.

### Where the tree stood at `495df6f` (2026-08-11)

- **`swift test`** green: **1319 tests / 189 suites**.
- **CI green on `main`**: Logic Tests, Guarded Tests (`guard_wiring.sh` + `test_guards.sh` +
  `guard_production.sh` + network allow-list), Compile (iOS), TestFlight Build.
- **Local pre-commit gate green**: wiring guards + logic tests + both simulator smoke tests via
  `scripts/test.sh`.
- **The iPhone smoke test** drives the full §16.3 path: create a narration from a need → record
  (flag + re-record leg) → validate (0 blocking) → single-chapter LibriVox export → **verifies the
  produced package bytes** (128 kbps CBR / 44.1 kHz / mono via `MP3FrameParser`, ID3 tags,
  `checksums.sha256`, checklist, `metadata.json`). Corruption was demonstrated by forcing 192 kbps.

### Next MVP — specified, not yet implemented

On 2026-08-11 the **Mac + iPad Universal MVP** was specified in `docs/mac-ipad-universal-mvp/`
(`SPEC.md`, `GAP_ANALYSIS.md` with 41 gaps, `AGENT_BRIEF.md`, 13 mockups). It adds a native macOS app
under Universal Purchase, iPad as a first-class narration surface, and a two-writer merge model
replacing revised §4.2's single-writer model.

The deleted macOS Studio tree was **resurrected verbatim** from `c0c6712^` into `VoxglassMac/` (58
source files), `VoxglassMacTests/` (19) and `VoxglassMacUITests/` (1), under new directory names so
gate G-P6's on-disk check stays green. Git records these as plain additions, so `git log --follow`
does not reach the pre-deletion history — read it at the old path with
`git log c0c6712^ -- VoxglassStudio/<path>`. **The tree is inert and unadapted**: no `project.yml`
target references it, `Package.swift` does not compile it, `swift test` does not see it.

Implementation has **not** started, and it is sequenced *after* the narration fix plan. Stage U0 is
the unlock: gates G-P5, G-P6 and G-P7 keep the Mac deleted and run in the pre-commit hook, so no
adaptation commit can land until they are amended.

---

## Recently landed

### 2026-08-17 — follow-up review fixes (`539e495`)

Review playback pause state per paragraph, chapter-order playback, paragraph rows opening the
recording screen, one full-width button treatment for review actions, narrator backfill from the
saved local name, and a source-URL prompt for older projects. **Superseded by the field test the same
day** — see the caveat above.

Verification at the time: iPhone simulator app build succeeded; the phone smoke test was rerun but
remained intermittently flaky in pre-existing library/detail navigation assertions.

### 2026-08-11 — narration MVP gap closure (`495df6f`)

Visible take playback controls, locally persisted narrator identity with a prompt when missing,
persisted source URL and rights attestation, chapter-collapsed paragraph review with completion
controls, project artwork selection and packaging, and a free `Personal Voxglass Listening` export
producing a chapterized M4B, a Files-shareable package and a local `My Completed Narrations` copy.

Two wiring defects the smoke test surfaced, both fixed:

- `buildParagraphs` generates LibriVox intros/outros through the same `ScriptApplier` +
  `LibriVoxScriptGenerator` the validation engine expects (the hand-built disclaimer format failed
  `staleDisclaimerText` and blocked every need-created project from exporting).
- `attest()` persists the Source URL field (`.missingSourceURL` previously blocked LibriVox export
  when the source wasn't prefilled).

---

## Release gates still outstanding

Recorded in `GAP_ANALYSIS.md` as "not verifiable from the repository" — human/device steps, not code
gaps. These come **after** the narration fix plan, since the plan changes the flow they sign off on.

1. **Manual hardware matrix M-1…M-14** (§16.5) — record sign-off in `RELEASE_CHECKLIST.md`.
2. **Walkthroughs W-1 / W-2 / W-3 on real hardware** (§16.6).
3. **Encoder build from a clean checkout** (iOS device + simulator + watchOS slices, §16.6).
4. **D-2 pricing ($49 / $79)** — an App Store Connect value, correctly absent from code.
5. **Store & release polish** — TestFlight build, privacy labels, IAP sandbox testing of
   `guru.parso.voxglass.narration.pro`, and the store section of `RELEASE_CHECKLIST.md`.

### Optional engineering follow-ups (not required by the spec)

- Extend the smoke test's export leg to a **multi-chapter fixture** (the narration fix plan's E2E
  harness covers multi-chapter export, so this may become redundant).
- The `validation.destination.*` rows share the container identifier `validation.destination` at
  runtime (SwiftUI container-id quirk) — cosmetic; tests key on the container.
- A device-accessible "Save a copy" test of the `.voxproject` re-import path.
