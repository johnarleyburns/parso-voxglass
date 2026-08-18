# Narration Review & Export Fix Plan

**Status:** approved for implementation · **Written:** 2026-08-17 · **Baseline commit:** `539e495`

**Goal.** A narrator can record a whole book on iPhone, review it paragraph by paragraph and chapter
by chapter with playback that visibly starts, pauses and stops, fix what needs fixing, check the
recording *before* committing to metadata, export it, and **listen to the finished audiobook inside
Voxglass**.

**This document is the complete specification.** Every decision is made, every API it depends on is
verified against the code at `539e495`, and every new type, string and accessibility identifier is
named. An implementing agent should need no further input: build it top to bottom, in the order in
§7, and stop only if reality contradicts a stated fact here.

**House rules that apply throughout** (`CLAUDE.md`): Swift 6 language mode, complete strict
concurrency, no warning suppression, no escape hatches. `git commit` needs a ≥ 25 minute timeout
(the hook runs guards + logic tests + simulator smoke tests); `git push` needs ~2 minutes.

---

## 0. The reported failures

Field report, 2026-08-17, iPhone. Fourteen reported defects, plus three found while tracing them.

| # | Reported | Verified cause | Work item |
|---|----------|----------------|-----------|
| 1 | Review play button doesn't show that anything started or stopped | Playback state set optimistically; the poll task clears it on pause | W2 |
| 2 | No way to play a whole chapter in order | `playChapter` exists but its button is inside a `DisclosureGroup` label that owns the tap | W2, W3 |
| 3 | Tapping a paragraph gives no examine/listen/re-record view; playback shows no state, can't pause | Row tap pushes `RecordView`; its transport ignores which paragraph is playing | W1, W2 |
| 4 | Tapping a paragraph should open a paragraph review/edit/retake view | Same as 3 | W1 |
| 5 | "Assemble the recording" / "Export this narration" differ in size from everything else | Three different ad-hoc button bodies in the flow | W4 |
| 6 | Source URL and narrator not backfilled on old narrations | Backfill lives in `resume(_:)`, which the dashboard entry never calls | W5 |
| 7 | Recorded outro has no checkbox on the left, only one on the right | Left glyph is a static icon; approve is a separate trailing button | W3 |
| 8 | Chapter reads "3/4" though 4 are recorded | Counter counts *approved*, unlabelled, next to a button captioned "Complete" | W3 |
| 9 | "Flagged" / "Not recorded" filters show spurious "0/0 Complete" | Chapters with no matching rows still render a header | W3 |
| 10 | Collapse works, re-expand does nothing | `isExpanded` bound to a computed getter with a discarded setter | W3 |
| 11 | "Everything recorded — review" is greyed out | `.disabled(dashboard.recordNext == nil)` — the caption's own condition | W6 |
| 12 | Personal Listening should be first; drop "Voxglass" from the bold title | Row order + label literals; default destination hardcoded | W7 |
| 13 | "Re-analyze" does nothing; no way to analyze before publishing | `apply(_:)` `break`s on 15 of 17 `FixAction`s; `runValidation()` has one caller | W9 |
| 14 | "Produce files" greyed out for Personal Listening | `hasMetadata` demands narrator/author/language for every destination | W8 |
| 15 | *(implied)* A personal export is not listenable | `completedNarrationsDirectory` has one writer and **no reader** | W10 |
| 16 | *(implied)* The done screen sends every narrator to the LibriVox forum | `SubmitView` is destination-blind | W10 |
| 17 | *(found)* Recorded takes never get audio metrics | Nothing calls `setTakeMetrics`, so quality rules can't evaluate | W9 |

---

## 1. Verified root causes

### RC1 — Playback state is optimistic, and pausing erases it

`NarrationFlowModel.play(url:paragraphID:)` — `Voxglass/Features/Production/Discovery/NarrationFlow.swift:1455-1481`:

```swift
playbackPlayer = try? AVAudioPlayer(contentsOf: url)   // failure → nil, silent
playbackPlayer?.play()                                  // return value discarded
isPlayingTake = true                                    // claimed regardless
playbackTask = Task { @MainActor in
    while ... self.playbackPlayer?.isPlaying == true { ... }
    self.isPlayingTake = false
    self.playbackParagraphID = nil                      // also runs on pause
}
```

- A missing/undecodable file, or a failed `setActive`, flips the UI to "playing" and back within a
  frame, with no error. **Symptom 1.**
- `togglePlayback` (`:1510-1517`) pauses; the poll loop then clears `playbackParagraphID`, so the row
  loses identity, cannot show "paused at 0:12", and the next tap calls `play(id)` — restarting at
  zero instead of resuming. **Symptoms 1, 3.**
- `play(_ id:)` (`:1443-1446`) returns silently when there is no selected take.
- `playChapter` (`:1484-1508`) is structurally correct but is only reachable from a button embedded
  in a `DisclosureGroup` label alongside a second button (`NarrationFlowScreens.swift:700-717`); the
  label's own tap target is the expansion toggle. **Symptom 2.**

### RC2 — The review list is a status display, not a review surface

`ReviewView` — `Voxglass/Features/Production/Discovery/NarrationFlowScreens.swift:657-937`:

- `:686-690` — `isExpanded: Binding(get: { chapterRows.contains { $0.state != .approved } }, set: { _ in })`.
  The setter is discarded, so user intent is never stored and a fully-approved chapter is permanently
  collapsed. **Symptom 10.**
- `:697` — `"\(approved.count)/\(chapterRows.count)"` immediately left of a `Complete` button
  (`:711`), reading as "3/4 Complete". **Symptom 8.**
- `chapterRows` is the *filtered* set, so every chapter renders a `0/0` header under a filter that
  matches nothing. **Symptom 9.**
- `statusIcon` (`:888-899`) is a non-interactive glyph on the leading edge; approval is a trailing
  checkmark button (`:857-866`). Two affordances, one concept, opposite sides. **Symptom 7.**
- `onTapGesture` (`:884`) pushes `RecordView` — a capture screen. **Symptoms 3, 4.**
- `:725-752` — the two bottom buttons use `.frame(maxWidth: .infinity, minHeight: 48)`, one wrapping
  `Text` and one wrapping `Label`; every other primary button in the flow uses `.padding(.vertical, 13)`
  with no minimum height (`assemble.continue` `:970-983`; `dashboard.recordNext`
  `ProjectDashboardView.swift:95-108`; `export.share` `NarrationFlowScreens.swift:2320-2328`).
  **Symptom 5.**

### RC3 — Legacy repair runs on one of three entry points

`resume(_:)` (`NarrationFlow.swift:860-897`) is the only code that backfills a missing narrator from
`voxglass.narratorName`, preserves a pending source URL, sets `needsSourceURLPrompt`, loads
`paragraphNotes`, loads the source text, and checks for recovered sessions.

`NarrationFlowRoot.task` (`NarrationFlow.swift:2251-2268`) calls it **only** when `startNeed != nil`.
The dashboard path (`ProjectDashboardView.swift:96` → `NarrationFlowRoot(existing:)`) runs
`NarrationFlowModel.init(existing:)` (`:463-499`), which sets `project`, `draftTitle`, `draftAuthor`
and the source string — nothing else. Opening an old narration from My Narrations or the dashboard
therefore gets no backfill, no prompt, no review notes, no recovery check. **Symptom 6.**

Underneath: `NarrationProjectBuilder.swift:63` hardcodes `intendedDestination: .librivox` regardless
of the purpose chosen in the wizard, and nothing repairs `metadata.narrator` / `rights.sourceURL` on
disk.

### RC4 — The dashboard's review entry is disabled by its own success condition

`ProjectDashboardView.swift:95-115`: `.disabled(dashboard.recordNext == nil)` while
`recordNextCaption` returns `"Everything recorded — review"` for exactly that case. **Symptom 11.**
There is also no route *to* the review list: `FlowResumeRouter` (`NarrationFlow.swift:2359-2378`)
picks the screen itself and shows `RecordView` whenever any paragraph is unrecorded.

### RC5 — Export gating is destination-blind

`ValidateExportView.hasMetadata` (`NarrationFlowScreens.swift:1563-1570`) requires title, author,
narrator *and* language for every destination. The Personal Listening profile
(`DestinationProfiles.swift:107-121`, `losslessMaster`) declares `requiredMetadata: [.title]`, and
`ValidationRuleEngine.severity` returns `.warning` for `(.personalMaster, .missingTitle)` (`:633`) and
`nil` — not evaluated — for `missingNarrator` and `unattestedRights` (`:635-647`). The button is
disabled by rules the destination does not have, with no reason shown. **Symptom 14.**

`runExport` (`NarrationFlow.swift:1994-1995`) additionally returns silently unless
`project.rights.isAttested`.

Destination rows are ordered LibriVox → Internet Archive → Personal → Retail
(`NarrationFlowScreens.swift:1453-1461`), the personal row's bold title is "Personal Voxglass
Listening", and `validationDestination` defaults to `.librivox`. **Symptom 12.**

### RC6 — Dead fix buttons, and validation unreachable before the end

`ValidateExportView.apply(_ fix:)` (`NarrationFlowScreens.swift:1836-1845`) implements
`.openAudioSetup` and `break`s for the other fifteen `FixAction` cases (`FixAction.swift`), including
`.reanalyzeTake`, `.goToParagraph`, `.recordParagraph`, `.openMetadata`, `.chooseArtwork`,
`.selectTake`. Each renders as a live pill that does nothing. **Symptom 13a.**

`runValidation()` has exactly one caller — `ValidateExportView.task` (`NarrationFlowScreens.swift:1535`).
**Symptom 13b.**

### RC7 — Personal Listening produces files nobody can play

`runExport` for `.personalMaster` (`NarrationFlow.swift:2034-2037, 2065-2070`) builds per-chapter
`.m4a` files (`RetailMasterPackageBuilder.swift:93-103`) and copies the bundle to
`Application Support/Voxglass/My Completed Narrations/<slug>`. `grep -rn "My Completed Narrations"`
returns exactly one hit — the writer. **Symptom 15.**

The seam that fixes it already exists and is proven:
`LibraryRepository.importLocalFolder(folderURL:folderName:files:)`
(`Voxglass/Core/Library/LibraryRepository.swift:655`) creates one local source + one book + one
chapter per file, is idempotent on re-scan, and is called today by `FolderWatchService.scan`
(`Voxglass/Core/Services/Import/FolderWatchService.swift:136`) followed by `libraryStore.refresh()`.
`LocalAudioImport` is `{ url, title, sortKey, duration }` (`LibraryRepository.swift:55-60`).

`SubmitView` (`NarrationFlowScreens.swift:2275-2440`) shows "SUBMIT TO LIBRIVOX", the weekly-poetry
link and the `ia upload` command for every destination. **Symptom 16.**

### RC8 — Smaller defects found while tracing

- `NarrationFlowScreens.swift:484` renders a literal string as the remaining-time label —
  `Text("-(max(0, model.playbackDuration - model.playbackPosition).formattedShort)")` — the `\(`
  interpolation is missing, so that text appears verbatim on the record screen.
- `NarrationFlowScreens.swift:437-444`: the left transport button is captioned "Play the take for this
  paragraph in context", draws `arrow.uturn.backward.circle.fill`, and calls the same
  `model.play(currentParagraphID)` as the right one.
- `:463-472`: the right transport button reads `model.isPlayingTake` without comparing
  `playbackParagraphID`, so it shows "pause" while a different paragraph plays.
- `ReviewView` never stops playback on disappear.

### RC9 — Recorded takes never get metrics

`ingestCapturedTake` (`NarrationProjectRepository.swift:179-220`) builds a `Take` with no `metrics`,
and no code path calls `ProductionStore.setTakeMetrics` (declared `ProductionStore.swift:113`,
implemented `SQLiteProductionStore.swift:203`). `PackagingSupport.selectedTakeMetrics`
(`PackageBuilder.swift:124-133`) therefore returns an empty map for a freshly recorded project, so
every audio-quality rule is either skipped or reports `missingMetrics`. The validation report a
narrator sees today is nearly content-free, and `.reanalyzeTake` has nothing to re-analyze.
**Symptom 17.**

---

## 2. Decisions — all resolved, none outstanding

| ID | Decision | Source |
|----|----------|--------|
| **D1** | Recorded and approved stay distinct in the data; the UI names them (`4 recorded · 3 approved`) and gives approval exactly one control — a tappable leading checkbox. No auto-approve on stop. | Plan recommendation, accepted |
| **D2** | **Personal Listening does not require the public-distribution rights attestation.** The code path is corrected to match the rule engine, which already declines to evaluate `unattestedRights` for `.personalMaster`. Attestation stays mandatory for LibriVox, Internet Archive and retail. | User, 2026-08-17 |
| **D3** | The selected publish destination is derived from `project.profile.intendedDestination`, which `NarrationProjectBuilder` starts persisting from the chosen `ProjectPurpose` (`personal → .personalMaster`, `commercial → .acx`, `publicDomainCommunity → .librivox`). Personal Listening is listed **first** regardless. | Plan recommendation, accepted |
| **D4** | **A finished Personal Listening export is added to My Books automatically**, as a local book with one chapter per exported chapter file. | User, 2026-08-17 |
| **D5** | The paragraph detail screen is a **new** `ParagraphReviewView`. `RecordView` stays the capture surface and is pushed from it for a retake. | Plan recommendation, accepted |
| **D6** | **Exactly one UI smoke test per platform, unchanged.** All cheap regression coverage is added *inside* the existing `VoxglassUITests.testAppBootsVisitsAllTabsEQAndProductions` and, where relevant, the existing watch smoke test. No new UI-test target, no second UI test function on any device. | User, 2026-08-17 |
| **D7** | The whole-book narrate-and-export proof is a **development harness**, not a smoke test: a hosted *unit*-test target (`VoxglassNarrationE2E`, no `XCUIApplication`) on its own scheme, run on demand by `scripts/narrate_book_e2e.sh`. It is **not** in the `Voxglass` scheme, **not** in `scripts/test.sh`, **not** in the pre-commit hook, and **not** in CI. Its job is to prove this round of fixes and to stay available for the next one. | User, 2026-08-17 |
| **D8** | Take metrics are computed on ingest (RC9), in a detached task after the take is durable, so validation has something to say and `.reanalyzeTake` has something to redo. | Plan, new |

---

## 3. Work items — UI and model

Each work item is one commit. The order in §7 is the build order.

### W1 — `ParagraphReviewView`

**New file:** `Voxglass/Features/Production/Discovery/ParagraphReviewView.swift`

```swift
struct ParagraphReviewView: View {
    @Bindable var model: NarrationFlowModel
    let paragraphID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var reRecordID: UUID?
    @State private var showCompare = false
    @State private var showImport = false
    @State private var flagNote = ""
    @State private var showFlagSheet = false
}
```

Layout, top to bottom:

1. **Header card** — `Chapter \(chapterOrdinal + 1) · ¶ \(numberInChapter) of \(chapterCount)`
   (`paragraphReview.title`), a role chip (`Intro` / `Body` / `Outro`, from `ParagraphRole`:
   `.libriVoxIntro` / `.body` / `.libriVoxOutro` / `.chapterHeading` / retail credits), and a state
   chip (`paragraphReview.state`) reading `Not recorded` / `Recorded` / `Approved` / `Flagged`.
2. **Text** — full paragraph text, `.textSelection(.enabled)`, no line limit (`paragraphReview.text`).
3. **Drift banner** when `model.paragraph(at:)?.isDrifted == true`: "The text changed after this was
   recorded", with **Re-record** and **Keep this take** (the latter re-stamps
   `take.textHashAtRecording` via a new `model.acceptDrift(paragraphID:)`).
4. **Transport** (`paragraphReview.play` / `.pause` / `.progress`) bound to `model.takePlayback`
   (W2), showing elapsed / remaining and a scrubber. Never enabled without a playable take; when the
   take is remote-only it shows the same hydrate chip the list uses
   (`paragraphReview.hydrate`), calling `model.hydrateForPlayback(paragraphID)`.
5. **Takes list** — every take with `isArchived == false`, newest last: duration, `peakDBFS` when
   metrics exist, recorded-at (relative), origin label, and a radio selecting it
   (`paragraphReview.take.<index>`, selection via `model.selectTake(paragraphID:takeID:)` — new thin
   wrapper over `ProductionStore.setSelectedTake`). Two or more takes show **Compare**
   (`paragraphReview.compare`) presenting the existing `TakeComparisonView`.
6. **Actions row** — `Approve` (`paragraphReview.approve`, calls `model.acceptParagraph`),
   `Flag` (`paragraphReview.flag`, opens a note sheet, calls `model.flagParagraph(_:note:)`),
   `Re-record` (`paragraphReview.rerecord`, sets `model.currentParagraphID` then pushes
   `RecordView(model:paragraphID:fromReview: true)`), `Import audio` (`paragraphReview.import`,
   existing `ImportAudioView`).
7. **Navigation row** — `‹ Previous ¶` (`paragraphReview.previous`) and `Next ¶ ›`
   (`paragraphReview.next`), driven by `model.previousParagraph(before:)` /
   `model.nextParagraph(after:)`, replacing the view's paragraph in place (a `@State currentID`
   seeded from `paragraphID`) so the navigation stack never grows.

`.onDisappear { model.stopPlayback() }`. Toolbar: back only, via the existing
`narrationFlowBackOnlyToolbar(if:)` modifier.

**Also in W1:** `RecordView` gains `.navigationTitle("¶ \(number) · Chapter \(n)")` and stops
playback in `onDisappear` alongside its existing recording stop.

### W2 — Playback state the UI can trust

**File:** `Voxglass/Features/Production/Discovery/NarrationFlow.swift`

Replace the four independent fields with one state value plus derived accessors:

```swift
enum TakePlayback: Equatable {
    case idle
    case playing(paragraph: UUID, chapter: UUID?)
    case paused(paragraph: UUID, chapter: UUID?, at: TimeInterval)

    var paragraphID: UUID? { ... }
    var chapterID: UUID? { ... }
    var isPlaying: Bool { if case .playing = self { return true }; return false }
}

var takePlayback: TakePlayback = .idle
var playbackError: String?

// Kept as computed shims so existing call sites compile unchanged:
var isPlayingTake: Bool { takePlayback.isPlaying }
var playbackParagraphID: UUID? { takePlayback.paragraphID }
var playbackChapterID: UUID? { takePlayback.chapterID }
```

Behaviour, precisely:

1. `private func play(url:paragraph:chapter:) -> Bool` — sets the session category, and on any
   failure (`AVAudioSession.setActive` throws, `AVAudioPlayer(contentsOf:)` throws,
   `player.play() == false`) sets `playbackError` and returns `false` **without** touching
   `takePlayback`. Messages: `"Couldn't play this recording — the audio file is missing."` for a nil
   URL or missing file, `"Couldn't start audio playback."` otherwise. `playbackError` is presented as
   an alert by whichever screen is up (`review.playbackError`, `paragraphReview.playbackError`).
2. Completion is delivered by `AVAudioPlayerDelegate.audioPlayerDidFinishPlaying(_:successfully:)`
   through a small `@MainActor` forwarder class held by the model — **not** by the poll loop. The
   poll task only writes `playbackPosition` every 100 ms and is cancelled on any state change.
3. `func togglePlayback(_ id: UUID)`:
   - `.playing(paragraph: id, _)` → `player.pause()`, `takePlayback = .paused(paragraph: id, chapter: nil, at: player.currentTime)`.
   - `.paused(paragraph: id, _, let at)` → `player.currentTime = at; player.play()`, back to `.playing`.
   - anything else → start `id` from zero.
   Chapter playback is cancelled when the user toggles a single paragraph.
4. `func playChapter(_ chapterID: UUID, from paragraphID: UUID? = nil)` — plays every paragraph in
   the chapter with a selected take, in `chapter.paragraphs` order, starting at `paragraphID` when
   given. `takePlayback` carries **both** ids for the whole run. Advancing happens in the delegate
   callback, not a poll. Paragraphs whose selected take is remote-only (present in
   `remoteAssetBytesBySHA`) are skipped, and the count is reported once as
   `playbackNotice = "\(n) paragraphs are in iCloud — download them to include them."`
5. `func playAll(from paragraphID: UUID? = nil)` — the same, across chapters in `project.chapters`
   order.
6. `func stopPlayback()` — cancels tasks, stops the player, `takePlayback = .idle`,
   `playbackPosition = 0`, and restores the shared audio session to the consumer player's
   configuration by calling `AppServices.shared.playbackCoordinator`'s engine configuration path —
   concretely: `try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])`.
   Called from `onDisappear` of `ReviewView`, `ParagraphReviewView` and `RecordView`.

**Logic tests** — `VoxglassTests/NarrationPlaybackStateTests.swift`, driving the state machine through
a `TakePlaying` seam (a protocol with `play/pause/stop/currentTime/duration` that `AVAudioPlayer`
satisfies via a thin adapter, so the tests need no audio hardware): play → pause → resume preserves
offset; play B while A plays; chapter order; skip-remote; failure sets `playbackError` and leaves
`.idle`.

### W3 — Rebuild the review list

**File:** `NarrationFlowScreens.swift` (`ReviewView`)

**Counts come from the domain, not the view.** Use
`ProjectDashboard(project:).chapters` — `ChapterProgress` already exposes `paragraphCount`,
`recordedCount`, `approvedCount`, `flaggedCount`, `isComplete`
(`Voxglass/Core/Production/Domain/ProjectDashboard.swift:5-42`). Delete the inline `chapterRows`
counting.

- **Expansion.** `@State private var collapsedChapterIDs: Set<UUID> = []`, persisted per project:
  `@AppStorage(AppPreferencesStore.Keys.narrationCollapsedChapters)` holding a JSON `[String]` keyed
  by `"\(projectID)/\(chapterID)"`. Add the key to `AppPreferencesStore.Keys` as
  `narrationCollapsedChapters = "voxglass.narration.collapsedChapters.v1"` — guard rule 1 requires a
  writer, and `@AppStorage` satisfies it. Every chapter starts **expanded**. The `DisclosureGroup`
  goes away entirely; the chapter header is a plain row and the paragraph rows render conditionally.
- **Chapter header row** (`review.chapter.header.<ordinal>`), tappable across its whole width to
  toggle collapse (`.contentShape(Rectangle())`):
  - line 1: `Chapter \(ordinal + 1): \(title)` + a chevron rotated by collapse state
    (`review.chapter.toggle.<ordinal>`).
  - line 2 (`review.chapter.counts.<ordinal>`): `"\(recordedCount) recorded · \(approvedCount) approved · \(clockTime)"`,
    plus `"\(flaggedCount) flagged"` in `NarrationPalette.brassSoft` when non-zero. The literal
    `"/"` form is gone — this is symptom 8's fix and the text a test asserts on.
  - trailing controls, each `.buttonStyle(.borderless)` so they do not compete with the row's tap
    target: **play/pause chapter** (`review.chapter.play.<ordinal>`, icon `play.circle.fill` /
    `pause.circle.fill`, driven by `model.takePlayback.chapterID == chapter.id`) and
    **Approve chapter** (`review.chapter.approveAll.<ordinal>`, renamed from "Complete", disabled
    when nothing is in `.unreviewed`, with a `disabledReason` caption when flagged or unrecorded
    paragraphs remain).
- **Filtered chapters with no rows are not rendered at all.** When the whole filtered list is empty,
  render a centred empty state (`review.empty`) with copy per filter: `All` → "Nothing here yet —
  record a paragraph to begin."; `Flagged` → "Nothing flagged."; `To record` → "Everything is
  recorded." **Symptom 9.**
- **Filter segments carry counts and disable at zero**: `All (14)`, `Flagged (2)`, `To record (0)`.
  (`ReviewFilter.pickup`'s label changes from "Not recorded" to "To record"; the enum case name is
  unchanged.)
- **Row** (`review.row.<globalIndex>`):
  - **leading: one tappable checkbox** (`review.row.approve.<globalIndex>`), 30×30, replacing both
    the static `statusIcon` and the trailing checkmark button:
    | state | symbol | tint | tap |
    |---|---|---|---|
    | `.notRecorded` | `circle.dashed` | `Palette.ink3` | opens `ParagraphReviewView` |
    | `.recorded` | `circle` | `Palette.brass` | approves |
    | `.approved` | `checkmark.circle.fill` | `Palette.ok` | un-approves (back to `.unreviewed`) |
    | `.flagged` | `flag.fill` | `NarrationPalette.brassSoft` | opens `ParagraphReviewView` |
    Accessibility labels: "Approve paragraph" / "Approved — tap to un-approve" / "Flagged" /
    "Not recorded". **Symptom 7.**
  - middle: text (2 lines), then `"¶ · 0:42 · recorded"`, then the flag note when present.
  - trailing: play/pause for **this** paragraph (`review.row.play.<globalIndex>`), or the existing
    iCloud download chip when `remoteTakeByteCount != nil`, then `chevron.right`.
  - the rest of the row opens `ParagraphReviewView` (W1) — **not** `RecordView`. The re-record
    affordance keeps a stable id `review.row.rerecord.<globalIndex>` for flagged rows.
- **Now-playing bar** (`review.nowPlaying`), pinned between the list and the bottom buttons whenever
  `model.takePlayback != .idle`: `"Chapter 2 · ¶ 7"` (`review.nowPlaying.label`), a progress bar,
  pause/resume (`review.nowPlaying.pause`), stop (`review.nowPlaying.stop`), and skip-to-next
  (`review.nowPlaying.next`). This is the answer to "it doesn't indicate anything is playing".
- **Toolbar**: `Play all` (`review.playAll`) → `model.playAll()`.
- `.onDisappear { model.stopPlayback() }`, and the `needsSourceURLPrompt` / `needsNarratorPrompt`
  alerts from W5.

### W4 — One primary button

**New file:** `Voxglass/DesignSystem/NarrationButtons.swift`

```swift
struct NarrationPrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var isBusy: Bool = false
    var disabledReason: String? = nil        // non-nil ⇒ disabled, caption shown beneath
    var identifier: String
    let action: () -> Void
}

struct NarrationSecondaryButton: View { /* same API, outlined treatment */ }
```

One geometry for every primary button in the narration flow: full width, `minHeight: 50`,
`RoundedRectangle(cornerRadius: 14)`, the brass gradient, `NarrationPalette.espresso` foreground,
`.buttonStyle(.plain)`, `.tactileTap()`, `scaledFont(size: 15, weight: .heavy)`, and — when
`disabledReason != nil` — `.disabled(true)` plus an 11.5 pt `Palette.ink3` caption below carrying the
reason and the identifier `\(identifier).reason`.

Adopt in: `ReviewView` (`review.toAssemble`, `review.toExport`), `AssembleView` (`assemble.continue`),
`MetadataView` (`metadata.toExport`), `ValidateExportView` (`validation.continueToExport`),
`SubmitView` (share, save-a-copy, evict), `ProjectDashboardView` (`dashboard.recordNext`,
`dashboard.startReviewQueue`), `NarrationHelpSheet` (`narration.helpSheet.dismiss`).

Screen content insets stay 18 pt, so every primary button on a screen reports the same width.

### W5 — Backfill everywhere, and repair on disk

**Files:** `NarrationFlow.swift`, `NarrationProjectRepository.swift`, `NarrationProjectBuilder.swift`,
`ProjectDashboardView.swift`

1. **One load path.** Rename `resume(_:)` to `func load(_ project: AudiobookProject) async` (keep
   `resume` as a deprecated alias if any test calls it) and call it from **every** entry:
   - `NarrationFlowRoot.task`: `if let existing { await model.load(existing) }` — *this is the missing
     call that causes symptom 6*;
   - the `startNeed` path, unchanged in behaviour;
   - `init(existing:)` keeps only its synchronous seeding.
2. **Both prompts.** `needsSourceURLPrompt` already exists (`:295`); `needsNarratorPrompt` exists at
   `:294` and is never set — set it in `load` when the project's narrator and the saved
   `voxglass.narratorName` are both empty. Both alerts appear on `ReviewView` **and**
   `ProjectDashboardView` (`dashboard.prompt.narrator`, `dashboard.prompt.sourceURL`).
3. **Repository backfill, so the data is fixed on disk.** New method, modelled on the library's
   `backfillNarratorsIfNeeded` naming:

   ```swift
   /// One-shot repair for projects created before narrator/source-URL capture
   /// was reliable. Idempotent: a per-project receipt is written into the
   /// project's sync-value table, so a repaired project is never touched again.
   public func backfillProjectDetailsIfNeeded(knownNeeds: [NarrationNeed]) async
   ```

   For each project from `allProjects()` whose receipt key `narration.backfill.details.v1`
   (via `store(for:).syncValue` / `setSyncValue`, the same mechanism as
   `NarrationMigration.needIDKey`, see `NarrationProjectRepository.swift:132-146`) is absent:
   - if `metadata.narrator` is empty and `UserDefaults.standard.string(forKey: "voxglass.narratorName")`
     is non-empty, set it;
   - if `rights.sourceURL == nil` and `needID(for:)` matches a need in `knownNeeds`, set it from that
     need's `work.sourcePageURL`;
   - save only when something changed; write the receipt either way.
   Called from `DiscoveryEnvironment.reloadNarrations()` after the projects load, passing
   `self.needs`. Anything it cannot derive is covered by the prompts in step 2.
4. **Purpose → destination.** `NarrationProjectBuilder.swift:63` stops hardcoding
   `intendedDestination: .librivox`; it maps the builder's purpose argument (D3). Add the mapping as
   a single `public static func destination(for purpose: ProjectPurpose) -> DestinationID` on
   `DestinationProfile` so the UI and the builder share it.
5. **Editable details on the dashboard.** A `Details` card between Progress and Needs-your-attention
   with title, author, narrator, language, source URL (`dashboard.details.<field>`), writing through
   the same persistence `MetadataView` uses (`model.saveNarratorName`, `model.saveSourceURL`, and a
   new `model.saveMetadataField`), so these can be fixed without walking the flow.

**Logic test** — `VoxglassTests/NarrationBackfillTests.swift`: a repository rooted at a temp
directory, one project with empty narrator and nil source URL plus a need id, one already-repaired
project with a receipt; assert exactly one is modified, the receipt is written, and a second run is a
no-op.

### W6 — Dashboard opens review

**Files:** `ProjectDashboardView.swift`, `NarrationFlow.swift`

- Delete `.disabled(dashboard.recordNext == nil)`. When `recordNext == nil`, the button keeps the
  caption "Everything recorded — review" and opens the flow **at the review list**.
- `NarrationFlowRoot` gains `let startAt: NarrationStep?` (default `nil`), threaded into the model as
  `model.requestedStep`. `FlowResumeRouter` honours it **before** its own heuristic:

  ```swift
  switch model.requestedStep {
  case .reviewList: ReviewView(model: model)
  case .record(let id): RecordView(model: model, paragraphID: id)
  case .validateExport: ValidateExportView(model: model)
  case .none: /* today's heuristic */
  default: /* today's heuristic */
  }
  ```
  `NarrationStep` already has the cases (`NarrationFlow.swift:193-202`).
- The dashboard passes a filter too: `NarrationFlowRoot(existing:startAt:reviewFilter:)`, with
  `ReviewView`'s `filter` seeded from it. "Start review queue" → `.flagged`; the Flagged row →
  `.flagged`; Needs-pickup → `.pickup`; Drift → `.all` scrolled to the first drifted paragraph;
  a Chapters-card row → `.all` scrolled to that chapter (`ScrollViewReader`, id
  `review.chapter.header.<ordinal>`).

### W7 — Publish-to list

**File:** `NarrationFlowScreens.swift` (`ValidateExportView`), `NarrationFlow.swift`

Row order and copy (exact strings):

| order | id | bold title | subtitle |
|---|---|---|---|
| 1 | `validation.destination.personal` | `Personal listening` | `Play it in Voxglass · chapterized M4B, plus a copy in Files · free` |
| 2 | `validation.destination.librivox` | `LibriVox` | `128 kbps MP3 per section` |
| 3 | `validation.destination.internetArchive` | `Internet Archive` | `FLAC masters + MP3 derivatives` |
| 4 | `validation.destination.retail` | `Commercial retail` | `ACX, Apple Books, aggregator, M4B` (Pro chip) |

`destinationName` for `.personalMaster` becomes `"Personal listening"` (used in "Checking …" and
"Ready to export — every check passed for …"). Initial selection: `model.validationDestination` is
seeded in `load(_:)` from `project.profile.intendedDestination` rather than defaulting to `.librivox`.

### W8 — "Produce files" enabled when the destination is satisfiable

**File:** `NarrationFlowScreens.swift`, `NarrationFlow.swift`

1. New model API, driven by the profile rather than by hardcoded fields:

   ```swift
   /// The required-metadata fields the destination declares that the project
   /// does not yet have. Empty ⇒ metadata is satisfied for this destination.
   func missingRequiredMetadata(for destination: DestinationID) -> [MetadataField]
   ```
   reading `DestinationProfile.profile(for:).requiredMetadata` — `losslessMaster` declares
   `[.title]` only (`DestinationProfiles.swift:115`).
2. `hasMetadata` is deleted. `validation.continueToExport` becomes a `NarrationPrimaryButton` whose
   `disabledReason` is the **first** applicable of:
   - `"Add a title before exporting."` / `"Add a narrator name before exporting."` … (from step 1);
   - `"\(n) blocking issue\(s) to fix first."`;
   - `"Pick at least one chapter to export."` (`!exportScopeIsValid`);
   - `"Downloading \(bytes) from iCloud…"` (hydration pending);
   - `nil` ⇒ enabled.
   The caption is itself tappable where a destination exists for the fix (metadata → `MetadataView`,
   blocking issues → scrolls to the first issue row).
3. **D2 in code.** `runExport`'s `guard project.rights.isAttested` becomes:

   ```swift
   if DestinationProfile.requiresRightsAttestation(validationDestination), !project.rights.isAttested {
       exportError = "Attest the rights for this recording before exporting to \(destinationName)."
       return
   }
   ```
   with `requiresRightsAttestation` returning `false` only for `.personalMaster`. `MetadataView`
   keeps a one-line personal acknowledgement (`metadata.personalAcknowledgement`): *"This is my own
   recording, for my own listening."* — recorded on the project, not gating export.
4. `ReviewView`'s "Export this narration" button is no longer conditional on `rightsAttested`; it is
   always present once `readyToAssemble`, and routes to whatever is missing.

### W9 — Analyze early, live fixes, and real metrics

**Files:** `NarrationFlow.swift`, `NarrationFlowScreens.swift`, new
`Voxglass/Features/Production/Discovery/ValidationReportView.swift`, `NarrationProjectRepository.swift`,
`scripts/guard_production.sh`

1. **Metrics on ingest (RC9/D8).** After `stopRecordingParagraph` persists a take, kick a detached
   `Task` that decodes with `AVFoundationDecoder` (the decoder `AudioSetupView.swift:237` already
   uses), computes `AudioMetricsCalculator(decoder:).metrics(for: url)`, writes them with
   `repository.store(for: project.id).setTakeMetrics(_:forTake:)`, and reloads the project. Same for
   `ingestImportedSlice` callers that pass `nil` metrics. Never blocks the record loop; failures are
   silent except for leaving `missingMetrics` to the validator.
2. **`ValidationReportView`** — the report body (summary chip, `BLOCKS EXPORT`, `WARNINGS`, issue
   rows, the clean-state card) extracted verbatim from `ValidateExportView` into a reusable view that
   takes `@Bindable model` and a `onFix: (FixAction) -> Void`. `ValidateExportView` renders it inline;
   the new entry points present it as a sheet (`validation.reportSheet`) with a
   **Re-analyze all** button in its toolbar (`validation.reanalyzeAll`).
3. **Analyze early.** `NarrationPrimaryButton`-styled `Check my recording`
   (`review.checkRecording`, `dashboard.checkRecording`, `assemble.checkRecording`) on the review,
   dashboard and assemble screens. Each runs `await model.runValidation()` against
   `project.profile.intendedDestination` and presents `ValidationReportView`.
4. **Every `FixAction` implemented.** `apply(_ fix:)` becomes an exhaustive switch with **no
   `break`**:

   | case | behaviour |
   |---|---|
   | `.reanalyzeTake(let takeID)` | `await model.recomputeMetrics(takeIDs: [takeID])` → re-run validation |
   | `.goToParagraph(let id)` / `.recordParagraph(let id)` | push `ParagraphReviewView` / `RecordView` for `id` |
   | `.selectTake(let paragraphID, _)` | push `ParagraphReviewView` scrolled to its takes list |
   | `.goToChapter(let id)` | push `ReviewView` scrolled to that chapter header |
   | `.splitChapter(let id, atParagraph:)` | push `ScriptEditorView` positioned at the split point |
   | `.openMetadata(let field)` | push `MetadataView` with `focusedField = field` |
   | `.openRights` | push `MetadataView` scrolled to the rights card |
   | `.chooseArtwork` | present the existing `PhotosPicker` from `MetadataView` |
   | `.regenerateDisclaimers` / `.regenerateCredits` | `ScriptApplier().apply(plan, to: &project, ids:clock:)` with `LibriVoxScriptGenerator` / `RetailScriptGenerator` (`ScriptGenerator.swift:40,115`), persist, re-validate |
   | `.applyMastering` | set `ExportOptions.applyMastering`, re-validate |
   | `.setRetailSample` | present a sample picker seeded by `defaultRetailSample()` |
   | `.clearPickup(let id)` | `model.updateParagraph(id) { $0.reviewState = .unreviewed }`, persist |
   | `.hydrateAssets` | `await model.hydrateAllForExport()` |
   | `.backupNow` | `await model.saveCopyOfProject()` and share it |
   | `.manageStorage` | push `StorageSettingsView` |
   | `.openAudioSetup` | present `AudioSetupView` (unchanged) |

   New model API for the first row:
   `func recomputeMetrics(takeIDs: [UUID]) async` and `func recomputeAllMetrics() async`, both
   reporting progress via a `metricsProgress: (done: Int, total: Int)?` the report sheet shows.
5. **Guard rule** in `scripts/guard_production.sh`, in the style of the existing G-rules:

   ```
   # G-12: No dead fix buttons. Every FixAction case must be handled with real
   # behaviour in the Features layer — a bare `break` inside a switch over
   # FixAction is a dead button by definition.
   check_fix_action_coverage() {
     # 1. every case name in Core/Production/Validation/FixAction.swift appears
     #    in Voxglass/Features/**/apply(_ fix: FixAction) switch
     # 2. no line matching '^\s*break\s*$' inside that switch
   }
   ```

### W10 — A personal export you can actually listen to

**Files:** `NarrationFlow.swift`, `NarrationFlowScreens.swift` (`SubmitView`),
`DiscoveryEnvironment.swift`, `VoxglassApp.swift`, `RetailMasterPackageBuilder.swift`

1. **The seam.** New protocol in the app target:

   ```swift
   @MainActor
   protocol NarrationLibraryImporting: AnyObject {
       /// Registers a finished narration's chapter files as a local book and
       /// returns it, refreshing the library surface.
       func importNarration(directory: URL, title: String, files: [LocalAudioImport]) async throws -> BookWithChapters
       /// Starts playback of a previously imported narration.
       func play(_ book: BookWithChapters) async
   }
   ```
   Concrete `NarrationLibraryImporter` wraps `AppServices.libraryRepository.importLocalFolder`,
   `AppServices.libraryStore.refresh()` and `AppServices.playbackCoordinator.play(_:chapter:)`
   (`PlaybackCoordinator.swift:511`). `DiscoveryEnvironment` gains
   `public var library: (any NarrationLibraryImporting)?`, set in `VoxglassApp`'s `.task` beside the
   existing `discovery.phoneProduction = services.productionEnvironment`
   (`VoxglassApp.swift:30`). `NarrationFlowRoot` passes it to the model as
   `model.library = discovery.library`, exactly as it does `model.phoneProduction`.
2. **On successful `.personalMaster` export**, after the existing copy into
   `completedNarrationsDirectory` (`NarrationFlow.swift:2065-2070`): build `[LocalAudioImport]` from
   the bundle's `.chapter`-role files in ordinal order — `title` = the chapter's title, `sortKey` =
   the filename, `duration` from the bundle's file entry — call
   `library?.importNarration(directory: completed, title: project.metadata.title, files:)`, and store
   the result on `model.importedBook`. Failures set `exportError` but never lose the files.
3. **Tags.** `RetailMasterPackageBuilder.swift:183` currently titles every personal chapter
   `"Personal Voxglass Listening"`. Change to: `title` = chapter title, `album` = project title,
   `artist` = narrator (falling back to the author), `track` = ordinal + 1 of chapter count, so the
   imported book shows real chapter names.
4. **Destination-aware `SubmitView`:**
   - `.personalMaster` → headline `"Your audiobook is ready to listen"`; primary
     **`Play in Voxglass`** (`submit.playInVoxglass`) calling `library.play(importedBook)` and then
     dismissing the whole flow so the miniplayer is visible; secondary `Save to Files` (the existing
     `ShareLink`); a line `"Added to My Books as \"\(title)\"."` (`submit.addedToLibrary`). No
     LibriVox or Archive sections.
   - every other destination → today's content, unchanged.
5. The Files copy and the zip are still produced for every destination.

### W11 — Small corrections

- `NarrationFlowScreens.swift:484` — restore the missing `\(` interpolation:
  `Text("-\(max(0, model.playbackDuration - model.playbackPosition).formattedShort)")`.
- `NarrationFlowScreens.swift:437-444` — the left transport button becomes **Previous paragraph**
  (`record.transport.previous`, `arrow.uturn.backward.circle.fill`, calling the existing
  `goPrevious`); the right one stays the take transport and reads `takePlayback` for the current
  paragraph only.
- `"Complete"` → `"Approve chapter"`; the `pickup` filter's label `"Not recorded"` → `"To record"`.
- `NarrationHelpSheet` step 4 rewritten: *"After the last paragraph, review the list — tap any
  paragraph to listen, approve or re-record it, or play a whole chapter — then produce your files."*

---

## 4. Test strategy

Two layers, and **no new UI smoke tests** (D6).

### 4.1 Logic tests (`swift test`, runs in CI and pre-commit)

New files under `VoxglassTests/` (or `VoxglassCoreTests` where the type lives in the package):

| File | Covers |
|---|---|
| `NarrationPlaybackStateTests.swift` | W2 state machine, incl. pause/resume offset and failure surfacing |
| `NarrationBackfillTests.swift` | W5.3 repository backfill: repairs once, receipts, idempotent |
| `NarrationReviewCountsTests.swift` | `ChapterProgress` drives the header string; `4 recorded · 3 approved` for the reported case |
| `DestinationRequirementsTests.swift` | W8 `missingRequiredMetadata` per destination; personal needs only a title; `requiresRightsAttestation` is false only for personal |
| `FixActionCoverageTests.swift` | Every `FixAction` case has a non-empty handler description (compile-time exhaustiveness + a table assertion) |
| `PersonalExportImportPlanTests.swift` | W10.2 mapping from an export bundle to `[LocalAudioImport]`: order, titles, sort keys, durations |

### 4.2 The single phone smoke test — extended in place

**File:** `VoxglassUITests/VoxglassUITests.swift`, inside the existing
`testAppBootsVisitsAllTabsEQAndProductions`. No new test function, no new target. Add these legs as
`private func` helpers called from the one test, in this order, between the existing record leg and
the existing metadata leg:

1. `assertReviewPlaybackShowsState(app:)` — tap `review.row.play.0`; assert the button's label flips
   to "Pause paragraph" and `review.nowPlaying` exists; tap `review.nowPlaying.pause`; assert the
   bar persists and the label returns to "Play paragraph"; tap play again and assert
   `review.nowPlaying` reports a non-zero position (symptoms 1, 3).
2. `assertChapterPlaybackRuns(app:)` — tap `review.chapter.play.0`; assert `review.nowPlaying.label`
   changes value at least once within 30 s (it advanced to the next paragraph); tap
   `review.nowPlaying.stop`; assert the bar disappears (symptom 2).
3. `assertChapterCollapseRoundTrips(app:)` — tap `review.chapter.header.0`; assert
   `review.row.0` is gone; tap it again; assert `review.row.0` is back (symptom 10).
4. `assertFilterEmptyState(app:)` — select the `To record` segment with everything recorded; assert
   `review.empty` exists and **no** `review.chapter.counts.0` exists (symptom 9).
5. `assertCountsSeparateRecordedFromApproved(app:)` — assert `review.chapter.counts.0`'s label
   contains `"recorded"` and `"approved"` and not `"/"`; tap `review.row.approve.<n>` on a recorded
   row and assert the count text changes (symptoms 7, 8).
6. `assertRowOpensParagraphReview(app:)` — tap `review.row.1`; assert `paragraphReview.title`,
   `paragraphReview.text` and `paragraphReview.rerecord` exist; play there and assert
   `paragraphReview.play` flips to pause; go back (symptoms 3, 4).
7. `assertPrimaryButtonsShareGeometry(app:)` — assert `review.toAssemble.frame.width ==
   review.toExport.frame.width` and equal heights (symptom 5).

And these, later in the same test:

8. In the **export leg**: assert the first row of `validation.destination` is
   `validation.destination.personal`; select it; assert `validation.continueToExport` `isEnabled`
   **without** a narrator having been typed and that `validation.continueToExport.reason` does not
   exist (symptoms 12, 14). Then select `validation.destination.librivox` and continue with the
   existing byte-verified LibriVox export, unchanged.
9. `assertValidationReachableEarly(app:)` — from the review screen, tap `review.checkRecording`,
   assert `validation.reportSheet` appears and `validate.report` renders inside it, dismiss
   (symptom 13b).
10. In the **dashboard leg** (My Productions is already visited): with the seeded project fully
    recorded, assert `dashboard.recordNext` `isEnabled` and that tapping it lands on
    `review.chapter.header.0` (symptom 11).

Existing assertions — including the LibriVox package byte verification
(`verifyExportedLibriVoxPackage`) — stay exactly as they are. Update `recordParagraphs` only where
identifiers changed.

**Runtime budget:** the phone smoke test must stay under **8 minutes** on an iPhone 16 simulator.
Measure before and after; if the additions push past it, drop legs 2 and 9 from the smoke test (they
are also covered by the harness in §4.3) rather than splitting the test.

### 4.3 The development harness — `VoxglassNarrationE2E`

A hosted **unit**-test target (no `XCUIApplication`, therefore not a UI smoke test) that drives the
real `NarrationFlowModel`, the real export pipeline and the real library import, so a whole book can
be narrated and exported without a human at the microphone.

**`project.yml`** — new target, and a scheme that is the *only* place it runs:

```yaml
  VoxglassNarrationE2E:
    type: bundle.unit-test
    platform: iOS
    sources:
      - VoxglassNarrationE2E
    dependencies:
      - target: Voxglass
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: guru.parso.voxglass.narratione2e
        TEST_HOST: "$(BUILT_PRODUCTS_DIR)/Voxglass.app/Voxglass"
        BUNDLE_LOADER: "$(TEST_HOST)"
        CODE_SIGNING_ALLOWED: NO
```

```yaml
  VoxglassNarrationE2E:          # scheme — deliberately NOT in the Voxglass scheme
    build:
      targets:
        Voxglass: all
    test:
      gatherCoverageData: false
      targets:
        - VoxglassNarrationE2E
```

The `Voxglass` scheme's test targets stay `[VoxglassUITests, VoxglassCarPlaySmokeTests]`, so
`scripts/test.sh`, the pre-commit hook and CI are untouched.

**`scripts/narrate_book_e2e.sh`** (new, not called by any hook):

```bash
#!/bin/bash
# narrate_book_e2e.sh — development harness. Narrates a whole fixture book with
# Apple speech synthesis, exports it for Personal Listening, and verifies the
# produced audio is real. NOT a smoke test: not in scripts/test.sh, not in the
# pre-commit hook, not in CI. Run it on demand.
#
# Usage: scripts/narrate_book_e2e.sh [--device "iPhone 16"] [--out /tmp/voxglass-narration-e2e]
set -euo pipefail
# … boot the simulator, xcodebuild test -scheme VoxglassNarrationE2E …
# … then print the output directory and the per-chapter durations.
```

**`VoxglassNarrationE2E/NarrateBookE2ETests.swift`** — one test,
`testNarratesAndExportsAListenableAudiobook`:

1. Build an isolated world: `NarrationProjectRepository(applicationSupport: <temp dir>)` — the init
   already takes the root (`NarrationProjectRepository.swift:27-36`) — plus
   `NarrationFlowModel(repository:fetcher:existing:capture:licenseProvider:)` with
   `capture: TTSAudioCapture()` (W13) and the export directory pointed at the host path from
   `VOXGLASS_E2E_OUTPUT` (default `/tmp/voxglass-narration-e2e`), the same host-shared mechanism the
   UI smoke test already uses via `-uiTestExportDirectory` (`NarrationFlow.swift:1915-1919`).
2. Seed the fixture book (W14) through `NarrationProjectBuilder`, purpose `.personal`.
3. For every paragraph in document order: `stage` the text on the capture,
   `await model.startRecordingParagraph(id)`, `await model.stopRecordingParagraph(id)`,
   `model.acceptParagraph(id)`.
4. Assert `model.readyToAssemble`, run `await model.runValidation()` for `.personalMaster`, assert
   `model.blockingValidationIssues.isEmpty` and that metrics exist for every selected take (proves
   D8).
5. `model.exportScopeChoice = .wholeBook`; `await model.runExport()`; assert `model.exportBundle != nil`
   and `model.exportError == nil`.
6. **Verify the bytes** (this is what "listenable" means as an assertion):
   - one audio file per chapter, ordinals contiguous, names sorted stably;
   - each opens with `AVAudioFile`; measured duration within **5 %** of the sum of that chapter's
     take durations;
   - decoded mean RMS above **−45 dBFS** and true peak below **−0.1 dBFS**
     (`AudioMetricsCalculator.computeRMS` / `.computeTruePeak`, `AudioMetrics.swift:72-128`) — a
     silent take fails this;
   - the first 3 s of chapter 1 is not silence;
   - `checksums.sha256` matches the files on disk;
   - ID3/MP4 tags carry the chapter title and track number (W10.3).
7. **Verify it is listenable in the app**: assert `model.importedBook != nil`, that its chapter count
   equals the project's, that each chapter's `localURL` exists on disk, and — through
   `AppServices.shared.playbackCoordinator` — that `play(book)` advances position past 3 s.
8. Copy the finished package to `VOXGLASS_E2E_OUTPUT` and `print` the absolute paths and durations,
   so a human can open and listen to the same bytes.

**Guard G-8** (`scripts/guard_production.sh:168-185`) requires every UI-test file to launch with
`-uiTestSeed` or seed in-process. Add `VoxglassNarrationE2E` to `ui_dirs` and extend the in-process
pattern to accept `NarrationE2EFixture.seed(` so the harness satisfies the same rule honestly.

### W13 — Speech capture for the harness

**New file:** `Voxglass/Features/Production/Discovery/TTSAudioCapture.swift`, wrapped in `#if DEBUG`
exactly like `UITestAudioCapture.swift`.

```swift
#if DEBUG
/// Scripted `AudioCapturing` that renders the staged paragraph text with Apple's
/// built-in speech synthesis, so a whole book can be narrated in a test with no
/// microphone and no human. DEBUG-only and reachable only from the narration
/// E2E harness; never selected by a release build.
protocol TestCaptureScripting: AnyObject { func stage(text: String) }

final class TTSAudioCapture: AudioCapturing, TestCaptureScripting, @unchecked Sendable { ... }
#endif
```

- `stage(text:)` stores the next utterance. `startRecording(to:)` renders it with
  `AVSpeechSynthesizer.write(_:toBufferCallback:)`, converts to the project's `RecordingDefaults`
  (mono, 48 kHz, 24-bit — `AudiobookProject.swift:13-19`) with `AVAudioConverter`, and writes a WAV
  to the destination URL. Matching the format matters: a mismatch trips `sampleRateMismatch` /
  `bitDepthMismatch` in the rule engine.
- `stopRecording()` returns a `CapturedTake` with the true rendered duration and the measured peak.
- The model stages text without changing the shipping protocol:

  ```swift
  #if DEBUG
  if let scripted = capture as? any TestCaptureScripting,
     let text = project?.allParagraphs.first(where: { $0.id == id })?.text {
      scripted.stage(text: text)
  }
  #endif
  ```
  at the top of `startRecordingParagraph`. `AudioCapturing` itself is untouched.
- Takes ingest through the normal path and therefore carry `origin: .recorded`
  (`NarrationProjectRepository.swift:198`). That is correct: this class substitutes for the
  microphone in a test harness, not for an AI-narration import. The real AI rules
  (`aiOriginInLibriVoxProject`, `undisclosedAINarration`) are untouched, and the harness exports to
  Personal Listening.
- **Guard:** extend the Swift 6 / production guard with a rule asserting `TTSAudioCapture` appears
  only inside a `#if DEBUG` fence and is referenced only from `VoxglassNarrationE2E` — mirroring how
  `UITestAudioCapture` is gated at `NarrationFlow.swift:2186-2194`.

**Spike S1 — do this first, before anything else in §7 phase 0 (budget ~1 hour).** Confirm
`AVSpeechSynthesizer.write(_:toBufferCallback:)` yields buffers on the **iOS simulator** for the
current toolchain, by rendering one utterance to a WAV in a throwaway XCTest and asserting non-zero
RMS. If it does not:

> **Fallback, fully specified so no decision is needed:** generate the fixture audio on the host and
> check it in. `for i in 1..12; do say -v Samantha -o Fixtures/para-$i.aiff --data-format=LEF32@48000 "<paragraph text>"; afconvert -f WAVE -d LEI24@48000 -c 1 Fixtures/para-$i.aiff Fixtures/para-$i.wav; done`
> — twelve mono 48 kHz 24-bit WAVs under `VoxglassNarrationE2E/Fixtures/`, and `TTSAudioCapture`
> copies the fixture matching the staged paragraph's index instead of synthesizing. Every assertion in
> §4.3 step 6 holds unchanged, because they only require real, non-silent speech of a known duration.

### W14 — Deterministic fixture book

**New file:** `VoxglassNarrationE2E/NarrationE2EFixture.swift` + a bundled text resource.

- `NarrationE2EFixture.seed(into:)` builds a **3 chapter × 4 paragraph** public-domain work (Aesop's
  fables — short, unambiguously public domain, no network), plus the LibriVox intro/outro paragraphs
  the script generator inserts. Fixed UUIDs, like `ProductionSmokeSeed`
  (`Voxglass/Features/Production/ProductionSmokeSeed.swift:11-17`), so runs are comparable.
- Paragraphs are 25–40 words each, which renders to roughly 8–12 s of speech: about 2 minutes of
  audio total, and a harness run in the low minutes.
- A second fixture, `NarrationE2EFixture.seedLegacy(into:)`, produces the shape seen in the field —
  recorded takes, empty `metadata.narrator`, `rights.sourceURL == nil`, one flagged and one
  recorded-but-unapproved paragraph — used by the backfill logic test in §4.1.

---

## 5. Exit criteria

Done means all of these, demonstrated in one session, with the evidence pasted into the final report:

1. `scripts/guard_wiring.sh`, `scripts/guard_production.sh` and `scripts/test_logic.sh` pass.
2. `scripts/test.sh` passes — the single phone smoke test (with its new legs) and the single watch
   smoke test — in under 8 minutes for the phone leg.
3. `scripts/narrate_book_e2e.sh` passes, and its output names the produced files.
4. **A real audiobook exists.** The harness reports, for the fixture book: absolute file paths,
   per-chapter durations, measured mean RMS and true peak per chapter, and total runtime. A human can
   open those files and hear the book.
5. That book is present in **My Books** with correct chapter titles, plays from the miniplayer, and
   resumes at its saved position after a relaunch — the never-lose-position rule holds for narrated
   books too.
6. Each of the 17 failures in §0 is closed **and** has a named assertion that fails on `539e495`.
   Verify this by running the new smoke-test legs and logic tests against the baseline first and
   recording which fail; any assertion that passes before the fix is not testing the reported bug.
   Put that before/after table in the final report.
7. Swift 6 language mode, complete concurrency checking, no new warnings, no suppression.

---

## 6. Accessibility identifier registry

New or changed identifiers, in one place, so the smoke test and the views cannot drift:

```
review.chapter.header.<ordinal>      review.chapter.toggle.<ordinal>
review.chapter.counts.<ordinal>      review.chapter.play.<ordinal>
review.chapter.approveAll.<ordinal>
review.row.<index>                   review.row.approve.<index>
review.row.play.<index>              review.row.rerecord.<index>
review.empty                         review.playAll
review.nowPlaying                    review.nowPlaying.label
review.nowPlaying.pause              review.nowPlaying.stop
review.nowPlaying.next               review.checkRecording
review.playbackError
review.toAssemble                    review.toExport            (unchanged ids, new component)

paragraphReview.title                paragraphReview.state
paragraphReview.text                 paragraphReview.play
paragraphReview.pause                paragraphReview.progress
paragraphReview.take.<index>         paragraphReview.compare
paragraphReview.approve              paragraphReview.flag
paragraphReview.rerecord             paragraphReview.import
paragraphReview.previous             paragraphReview.next
paragraphReview.hydrate              paragraphReview.playbackError

dashboard.checkRecording             dashboard.details.<field>
dashboard.prompt.narrator            dashboard.prompt.sourceURL

assemble.checkRecording
validation.reportSheet               validation.reanalyzeAll
validation.continueToExport.reason
submit.playInVoxglass                submit.addedToLibrary
record.transport.previous
```

Unchanged and depended upon by the existing smoke test: `record.transport.record`,
`record.acceptAndNext`, `record.flagAndNext`, `record.take.1`, `assemble.continue`,
`metadata.narrator`, `metadata.sourceURL`, `metadata.attest`, `metadata.toExport`,
`validate.report`, `export.scope.chapter`, `validation.continueToExport`, `export.packageReady`.

---

## 7. Build order

| Phase | Items | Commit message |
|-------|-------|----------------|
| 0 | Spike S1; W14 fixtures; W12 target + scheme + `scripts/narrate_book_e2e.sh` skeleton; W13 TTS capture | `test: narration E2E harness with speech capture` |
| 1 | W2 playback state + logic tests; W11 corrections | `fix: make narration take playback state honest` |
| 2 | W1 `ParagraphReviewView` | `feat: paragraph review screen` |
| 3 | W3 review list rebuild; W4 buttons | `fix: rebuild the narration review list` |
| 4 | W5 backfill + repository repair; W6 dashboard entry | `fix: backfill narration details on every entry point` |
| 5 | W7 destinations; W8 gating; W9 early validation, live fixes, metrics on ingest | `fix: make narration export reachable and checkable` |
| 6 | W10 listenable personal export | `feat: personal narrations land in My Books` |
| 7 | Smoke-test legs (§4.2); harness assertions (§4.3); exit-criteria run; update `docs/RELEASE_PLAN.md` and `docs/iphone-watch-only-revised-mvp/AGENT_BRIEF.md` to record D6/D7 | `test: cover the narration review and export regressions` |

Phases 1–6 each leave the app shippable. Do not batch them.

---

## 8. Risks and their handling

- **Simulator TTS may not render buffers.** Spike S1 decides in the first hour; the checked-in
  `say`-generated fixture path is fully specified and needs no further decision.
- **`ReviewView` is on the existing smoke test's critical path** (`VoxglassUITests.swift:160-176`
  drives `review.toAssemble` and matches a `Re-record ▸` button by *label*). W3 must update that test
  in the same commit and switch it to `review.row.rerecord.<n>`.
- **Harness runtime.** ~2 minutes of synthesized audio plus three chapter encodes. If a run exceeds
  10 minutes, cut the fixture to 2 chapters × 3 paragraphs — no assertion depends on length.
- **Auto-import into My Books** (D4) creates a book the user did not explicitly add. Mitigated by the
  `submit.addedToLibrary` line and by the book being removable like any other local import.
- **The repository backfill writes to existing project packages.** Idempotent, receipted per project,
  never overwrites a non-empty value, covered by `NarrationBackfillTests`.
- **`AppServices.shared` reached from the narration flow** would be a hidden dependency; W10 avoids it
  by injecting `NarrationLibraryImporting` through `DiscoveryEnvironment`, matching how
  `phoneProduction` is already wired (`VoxglassApp.swift:30`).
