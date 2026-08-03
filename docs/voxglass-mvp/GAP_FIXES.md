# Voxglass Studio — MVP gap-closure plan

**Status:** Build-ready remediation plan. Subordinate to `VOXGLASS_STUDIO_SPEC.md`; where the two disagree, the spec governs and this document is wrong.
**Date:** 2026-08-02.
**Audience:** an agentic coding system closing the gaps, plus the human reviewing its commits.
**Basis:** a full audit of the repository at `main` (post-`621b8a7`, with the S12 working tree staged) against `VOXGLASS_STUDIO_SPEC.md` §0–§22.

---

## 0. How to use this document

### 0.1 What this is

The MVP implementation is substantially complete. All 45 domain types from §5 exist, all 59 `IssueCode` cases are both emitted by `ValidationRuleEngine` and individually tested, all five destination profiles match §3's tables constant-for-constant, the LAME/libFLAC/AVFoundation encoder stack is real and round-trip tested, and the CloudKit projection, watch relay, and CarPlay production templates are built. `swift build` is clean and `scripts/guard_production.sh` exits 0.

The gaps that remain cluster in three places:

1. **App-shell wiring** — several finished features are not reachable from their app's navigation.
2. **CI gates that do not fire** — three of the twelve grep gates pass their own canonical violation.
3. **Robustness paths** — capture interruption, export resumption, document locking, undo.

Each gap below has a stable ID (`F-01`…`F-28`), a spec citation, the evidence that established it, and a work package that closes it.

### 0.2 Normative language

Inherited from spec §0.2: **MUST / MUST NOT** (a gate, a test, or a reviewer rejects the change), **SHOULD** (deviate only with a code comment), **MAY**, **DEFERRED**.

One addition specific to this document:

- **RECONCILE** — the implementation is a defensible deviation but is currently undocumented. The fix is to record it in spec §22.4, not to write code.

### 0.3 Reading order

1. §1 — the gap register. Read once end to end; the severities drive sequencing.
2. §2 — work packages, in dependency order. Each is one reviewable commit.
3. §3 — new mockups added alongside this plan.
4. §4 — sequencing, commit plan, and the definition of done for this effort.
5. §5 — spec amendments that MUST land with the code.

### 0.4 Ground rules that do not change

Everything in spec §1.6 (product principles) and §22.9 (anti-patterns) still governs. In particular, while closing these gaps:

- **Never lose a take.** F-11 through F-13 exist precisely because this principle is currently unenforced in the capture path. Do not "simplify" them away.
- **Free must be complete.** No fix in this document may add a `LicenseGate`, `isPro`, `ProFeature`, or `EntitlementState` reference outside the §17.5 allow-list. F-07 exists because the gate that enforces this has a coverage hole; closing that hole may surface pre-existing violations, which MUST be fixed rather than re-exempted.
- **The tool prepares; the human submits.** Nothing here adds an upload path.

---

## 1. The gap register

Severity legend: **S1** blocks the MVP's own definition of done (§0.4). **S2** defeats a stated CI gate. **S3** breaks a normative robustness guarantee. **S4** missing specified surface or behavior, workaround exists. **S5** documentation/hygiene.

| ID | Sev | Gap | Spec | Evidence |
|---|---|---|---|---|
| F-01 | S1 | Recording workspace unreachable from the app shell | §18.1.7, §11.4 | `VoxglassStudio/App/StudioApp.swift:49-50` routes `.record` to `PlaceholderView` |
| F-02 | S1 | Entire iPhone production surface is dead code | §18.2 | Nothing outside `Voxglass/Features/Production/ProductionViews.swift` references `MyProductionsShelf` or siblings |
| F-03 | S1 | Studio ignores `-uiTestSeed` / `-useTemporaryStore` | §4.3, §19.6 | `StudioApp.swift:6` builds `StudioEnvironment` with defaults; `ProjectLibraryModel.swift:110` seeds only when `isTestEnvironment` |
| F-04 | S1 | Script Editor screen absent; no undo anywhere | §18.1.6, §8.4 | No `ScriptEditorView`/`ScriptEditorModel`; `UndoManager` appears in zero files |
| F-05 | S1 | Export resumption and idempotency not implemented | §16.12 | `export_run` table created at `ProductionMigration.swift:200`, never read or written; no `.partial` directory |
| F-06 | S2 | G-1 does not catch `AVSpeechSynthesizer` or `import CoreML`/`MLX` | §19.9 G-1 | `guard_production.sh:28` filters `grep -v 'Synthesi[sz]er'`; probe file with both passes |
| F-07 | S2 | G-2 never scans `VoxglassStudio/` | §19.9 G-2, §17.5 | `guard_production.sh:43` searches `Voxglass/Core Voxglass VoxglassWatch` only; probe `LicenseGate` in `Features/Record/` passes |
| F-08 | S2 | G-7 whitelists `= UUID()` and `= Date()` | §19.9 G-7 | `guard_production.sh:128-129`; probe `let id = UUID()` in `Core/Production/Domain/` passes |
| F-09 | S2 | G-4 positive half (`SHA256Hex` presence) not implemented | §19.9 G-4 | `check_stable_hashing()` only greps for the banned symbols |
| F-10 | S2 | G-10 allow-list names a file that does not exist | §19.9 G-10 | `guard_production.sh:172` allows `Destinations/DestinationProfiles.swift`; profiles live in `Domain/DestinationTypes.swift:262-368` |
| F-11 | S3 | Capture tap takes locks, dispatches to GCD, may allocate | §4.11, §11.2 r3–r4 | `AVAudioEngineCapture.swift:294-328`; no `RingBuffer` type exists; no overrun counter surfaced |
| F-12 | S3 | No `AVAudioEngineConfigurationChange` handling | §11.2 r6, M-2 | `CaptureError.deviceChanged` declared at `AudioCapturing.swift:79`, never thrown |
| F-13 | S3 | No sleep-notification handling | §11.2 r8 | No `NSWorkspace.willSleepNotification` observer |
| F-14 | S3 | No package advisory lock; single window | §8.3, §4.7 | No `lock.json`; `StudioApp` uses one `WindowGroup` + `NavigationStack` |
| F-15 | S3 | `ProductionStore.withExclusiveWrite` missing | §7.9 | Symbol absent from the repository |
| F-16 | S3 | `global_ordinal` never renumbered | §7.8 | `SQLiteProductionStore.swift:136` assigns `MAX(global_ordinal)+1`; no renumber pass exists |
| F-17 | S4 | Recents carry no summary snapshot; no library sidebar sections, activity feed, or missing-project state | §8.1, §18.1.2 | `RecentsStore.swift` stores URLs + bookmarks only; no `NavigationSplitView` in `VoxglassStudio` |
| F-18 | S4 | No UTType / document-type registration for `.voxproject` | §4.8 | `project.yml` has no `UTExportedTypeDeclarations` or `CFBundleDocumentTypes` |
| F-19 | S4 | New Project wizard has no rights step | §8.2, §18.1.3 | `wizard.sourceURL`, `wizard.editionYear`, `wizard.attest`, `wizard.back` all in `documentedAbsences` |
| F-20 | S5 | No `// verified <date>` comments on destination constants; no verification log | §3 preamble, §21.3 | `grep -c verified DestinationTypes.swift` → 0; `DESTINATION_VERIFICATION_LOG.md` absent |
| F-21 | S5 | Deviations recorded in a test file, not in spec §22.4 | §22.4 | `AccessibilityAuditTests.swift` `documentedAbsences` holds 61 entries the spec does not acknowledge |
| F-22 | S4 | `PlaybackMode.retailSample` case missing | §12.2 | `AssemblyTypes.swift:50-59` has 8 cases; `RetailMasterPackageBuilder` uses a private `sampleSegments` path |
| F-23 | S4 | Validation "Fix Next Issue" not implemented | §15.2, §18.1.14 | `ValidationModel.swift` has no fix-action execution; every issue carries a `FixAction` that nothing consumes |
| F-24 | S4 | Phone queue builder has no "Download queue to Apple Watch" | §18.2.5 | `queueBuilder.downloadToWatch` in `documentedAbsences` |
| F-25 | S4 | Take comparison lacks gapless position-preserving A/B | §11.7 | `compare.playAB` in `documentedAbsences`; single-take playback only |
| F-26 | S4 | Import Audio marker workflow and segment table absent | §18.1.8, §11.5 | `import.audio.addMarker/removeMarker/segment.<n>` in `documentedAbsences` |
| F-27 | S4 | Studio shell: no `Settings` scene, no sidebar, no project tab bar | §18.1.1 | `StudioApp.swift:19-170` is a single `WindowGroup` + flat `NavigationStack` |
| F-28 | S4 | Metadata has no Artwork tab; no 2400 px derivative generation | §18.1.12 | `MetadataRightsView.swift:31` — three tabs; `ArtworkStore` declares `cover2400` but nothing produces it |

### 1.1 What is explicitly NOT in scope

Do not build these while closing the gaps above; they are DEFERRED by spec §1.3 and §22.5 and remain so:

- Any synthesis, forced alignment, multi-narrator, waveform-destructive editing, auto-upload, iPad Studio.
- Punch-in recording (`AudioCapturing.punchIn` stays a reserved protocol method that throws `CaptureError.punchInNotSupported`).
- Chapter deletion and its undo (§8.4 marks it DEFERRED).
- Swift 6 migration of the `Voxglass` and `VoxglassWatch` targets.

---

## 2. Work packages

Eight packages. Each is one reviewable commit (or a short ordered series) with a stated acceptance assertion. **Do not start a package until the previous one's acceptance passes** — later packages assume earlier seams exist.

Commit subject convention, continuing §20's: `fix(studio): WP-<X> — <summary>`, body listing the acceptance criterion and the `F-nn` IDs closed.

---

### WP-A — CI gates that actually fire

**Closes:** F-06, F-07, F-08, F-09, F-10.
**Why first:** every later package adds code to territory these gates police. Fixing them last means auditing all of it twice. This package is also the cheapest and the only one whose acceptance is a shell script.

**Change `scripts/guard_production.sh`:**

**G-1** — replace the banned pattern and drop the self-defeating filter:

```bash
check_no_synthesis() {
  local banned='\bTTS\b|Synthesi[sz]e|Synthesi[sz]er|VoiceModel|Kokoro|Chatterbox|CosyVoice|voiceClone|AVSpeechSynthesizer'
  local banned_imports='^[[:space:]]*import[[:space:]]+(MLX|CoreML|Speech)\b'
  # `isLikelyGeneratedTTSAudio` is the consumer app's *classifier* over catalogue
  # metadata (no synthesis); it is the one permitted match.
  matches=$(grep -rn --include='*.swift' -E "$banned" \
              Voxglass VoxglassWatch VoxglassStudio VoxglassCoreTestSupport 2>/dev/null \
            | grep -v 'isLikelyGeneratedTTSAudio' \
            | grep -v 'synthesis-exempt:' || true)
  # …plus a second sweep for $banned_imports, same reporting.
}
```

The `Synthesi[sz]er` alternative MUST be part of the banned set, not the exclusion set. `import Speech` is added because `SFSpeechRecognizer` is the other way synthesis-adjacent AI enters the product, and §18.2.6 requires the *system dictation keyboard*, not the Speech framework.

**G-2** — add `VoxglassStudio` to the search roots, and switch from content-matching to the spec's filename-matching so the gate means what §17.5 says:

```bash
check_pro_gate_placement() {
  local banned='LicenseGate|\.isPro\b|ProFeature|EntitlementState'
  # §17.5 allow-list, by FILENAME.
  local allowed='Export|Packaging|RetailMaster|Master|License|Settings|StudioEnvironment'
  local forbidden='Recording|Review|Preview|Capture|Assembly|Segment|Sync|Watch|CarPlay|Validation'
  matches=$(find Voxglass/Core Voxglass VoxglassWatch VoxglassStudio -name '*.swift' 2>/dev/null \
            | grep -E "/[^/]*($forbidden)[^/]*\.swift$" \
            | grep -vE "/[^/]*($allowed)[^/]*\.swift$" \
            | xargs grep -nE "$banned" 2>/dev/null || true)
}
```

> Note the allow-list is applied *after* the forbidden list so that a file like `ExportReviewSummary.swift` resolves to allowed, matching §17.5's intent that `Export*` wins.

Expect this to surface pre-existing violations in `VoxglassStudio`. **Fix them by moving the entitlement read, not by widening the allow-list.** The one legitimate consumer outside the list is `StudioEnvironment.swift`, which §17.5 names explicitly.

**G-4** — add the missing positive half:

```bash
for d in Package Packaging Assembly; do
  grep -rq 'SHA256Hex' "Voxglass/Core/Production/$d" \
    || violate "G-4: $d contains no SHA256Hex reference (stable hashing not wired)"
done
```

**G-7** — delete the `= UUID()` and `= Date()` exclusions. Keep only `determinism-exempt:`, `UUIDGenerator`, and `SystemClock`. Annotate any real remaining call site with `// determinism-exempt: <reason>`.

**G-10** — point the allow-list at the file that exists. Either move the profile table to `Voxglass/Core/Production/Destinations/DestinationProfiles.swift` (preferred — it matches §4.1's module topology and §19.9's wording) or amend the allow-list to `Domain/DestinationTypes.swift`. **Choose the move**: `DestinationProfile` is a destination concern, and the current placement is why F-20's `// verified` comments have no natural home. Split `DestinationTypes.swift` into the type declarations (stay in `Domain/`) and the five profile literals plus `profile(for:)` (move to `Destinations/DestinationProfiles.swift`).

**Acceptance (MUST all hold):**

Add `scripts/test_guards.sh` — a self-test that plants each probe, asserts the guard fails, removes it, and asserts the guard passes:

| Probe | Placed in | Guard MUST fail |
|---|---|---|
| `let s = AVSpeechSynthesizer()` | `VoxglassStudio/` | G-1 |
| `import CoreML` | `Voxglass/Core/Production/` | G-1 |
| `let g: LicenseGate? = nil` | `VoxglassStudio/Features/Record/RecordingProbe.swift` | G-2 |
| `let id = UUID()` | `Voxglass/Core/Production/Domain/` | G-7 |
| removing every `SHA256Hex` from `Production/Assembly` | — | G-4 |
| `let b = 192` | `Voxglass/Core/Production/Validation/` | G-10 |

`scripts/test_guards.sh` runs in the `guarded-tests` CI job immediately before `guard_production.sh`. A gate that cannot fail is not a gate.

---

### WP-B — Studio composition root and app shell

**Closes:** F-03, F-27, and the routing half of F-01.
**Depends on:** WP-A (this package adds files under `VoxglassStudio/`, which G-2 now scans).

**B1 — `StudioEnvironment.live` / `.test`.** §4.3 specifies two factories. Implement them and give the environment the service slots it is missing (`capture`, `metrics`, `player`, `transcoder`, `sync`, `clock`, `ids`), so services stop being constructed inline per route in `StudioApp.swift`:

```swift
@MainActor @Observable public final class StudioEnvironment {
    public let capture: any AudioCapturing
    public let metrics: any AudioMetricsCalculating
    public let player: any SegmentPlayer
    public let transcoder: any AudioTranscoding
    public let sync: any ProductionSyncEngine
    public let clock: any Clock
    public let ids: any IDGenerator
    // …existing members…

    public static func live(package: ProjectPackage) throws -> StudioEnvironment
    public static func test(seed: UITestSeed) -> StudioEnvironment
}
```

`.test(seed:)` MUST wire `FakeAudioCapture`, `FakeSyncEngine`, `FakeLicenseProvider`, `FakeTranscoder`, `FixedClock`, and `SequentialIDGenerator`, and set `isTestEnvironment = true`.

`VoxglassStudioKit` (the SwiftPM mirror target) cannot import `VoxglassEncoders`, so keep the existing `encoderAvailabilityProvider` closure seam for `VoxTranscoder`; `.test` supplies `FakeTranscoder` directly and `.live` is called only from `StudioApp`, which can name the encoder.

> `VoxglassCoreTestSupport` MUST NOT be imported by `VoxglassStudio` (gate G-9). The fakes needed by `.test(seed:)` therefore live in `VoxglassStudio/Support/UITestFakes.swift` behind `#if DEBUG`, mirroring the Core fakes. The `UITestSeed` enum itself stays compiled in all configurations so the gate can find it (§19.6).

**B2 — parse the launch arguments.** In `StudioApp.init()`:

```swift
let args = ProcessInfo.processInfo.arguments
if let seed = UITestSeed(arguments: args) {
    env = .test(seed: seed)                    // implies -useTemporaryStore semantics
} else if args.contains("-useTemporaryStore") {
    env = try .live(package: .temporary())
} else {
    env = try .live(package: .lastOpenedOrNone())
}
```

Add `UITestSeed.init?(arguments:)` reading the value after `-uiTestSeed`. Seeding code is `#if DEBUG`; in release the initializer returns `nil` regardless of arguments (§19.6).

**B3 — the shell.** Replace the flat `NavigationStack` with the §18.1.1 structure:

```swift
@main struct StudioApp: App {
    var body: some Scene {
        WindowGroup(for: ProjectReference.self) { $ref in
            StudioRootView(reference: ref)
        }
        .commands { StudioCommands() }

        Settings { SettingsView(model: settingsModel) }
    }
}

enum StudioSection: Hashable { case library, needsReview, readyToExport, archive, settings }
enum ProjectTab: Hashable { case dashboard, script, record, review, assemble, metadata, validateExport }
```

- `ProjectReference` is `Codable, Hashable` — the project UUID plus the security-scoped bookmark, so `WindowGroup(for:)` can restore windows.
- `StudioRootView` renders the library `NavigationSplitView` when `reference == nil`, and the project window (title bar + `ProjectTab` segmented bar) otherwise.
- Every route currently in `StudioRoute` maps onto a `ProjectTab` or a sheet. `PlaceholderView` MUST be deleted in this package — if a tab has no view yet, that is a compile error, not a runtime placeholder.
- `StudioCommands` gains the full §18.1.1 list: ⌘N, ⌘O, ⇧⌘I, ⌘R, ⌘→, ⌘←, ⌘⇧R, ⌘E, Verify Project, Rebuild Caches.

**Acceptance:**

- `StudioSmokeUITests.test_createLibrivoxAudiobook` passes locally via `scripts/test.sh --all` without modification to the test file.
- New `VoxglassStudioTests/StudioEnvironmentTests`: `.test(seed: .empty).isTestEnvironment == true`; the capture, sync, license, and transcoder slots are the fake types; `.live` is never called under any `-uiTestSeed`.
- Grepping `VoxglassStudio` for `PlaceholderView` returns nothing.

---

### WP-C — Recording workspace, Script Editor, and undo

**Closes:** F-01, F-04, F-16.
**Depends on:** WP-B.

**C1 — wire the recording workspace.** `RecordingWorkspaceView`, `RecordingModel`, `RecordingMeter`, and `AVAudioEngineCapture` already exist and are unit-tested. Route `ProjectTab.record` to the real view with the environment's `capture`/`metrics` services. Add the §18.1.7 elements currently absent, each with its §22.1 identifier:

| Element | Identifier | Note |
|---|---|---|
| Takes list with duration, quality flags, selection | `record.take.<n>` | replaces the `documentedAbsences` entry deferring this to Take Comparison |
| Accept take & advance | `record.acceptAndNext` | `Return` per §11.4 |
| Flag & advance | `record.flagAndNext` | `⌘Return`; emits a `.flag` **event**, never a direct state write (§14.1) |
| Play selected take / play in context | `record.transport.playTake`, `record.transport.playInContext` | `⌥Space`, `⇧Space` |
| Import WAV as take | `record.importWAV` | opens Import Audio scoped to this paragraph |
| Quality panel | `record.quality.peak`, `record.quality.noise` | fills in after async metrics |
| Input level chip | `record.inputLevel` | reads `RecordingMeter`, never `RecordingModel` |

The full §11.4 keyboard table MUST work via a local key monitor. `RecordingModel` MUST NOT observe `RecordingMeter` — the existing `PerformanceBudgetTests.teleprompterDoesNotInvalidateWhileMeterUpdates` probe is the regression guard and MUST still pass.

**C2 — Script Editor.** New `VoxglassStudio/Features/Script/{ScriptEditorView,ScriptEditorModel}.swift`, per §18.1.6 and mockup `05-script-editor`:

- Chapter list, paragraph list with state chips (`Recorded` / `Text changed` / `Unrecorded` / `Needs pickup`), inspector (direction note, pronunciation, review status, Split, Merge).
- Inline text editing with 400 ms debounce; `script.save` flushes immediately via `ProductionStore.updateParagraphText`.
- Drift banner (`script.driftBanner`) when `TextDriftDetector` classifies `.minor` or `.semantic`, with **Re-record** and **Keep take**.
- ⌘F find with match highlighting and next/previous.
- **The list MUST virtualize.** Render from `ProductionStore.paragraphSummaries(chapterID:)`, never from `load()`. A 10,000-paragraph project must not build all rows eagerly (§7.5 performance requirement).
- Generated paragraphs (`role` in `.libriVoxIntro`, `.libriVoxOutro`, `.retailOpeningCredits`, `.retailClosingCredits`) render a "Generated" chip and are read-only until "Edit anyway" is confirmed.

**C3 — Undo.** Introduce `StudioUndo`, a thin wrapper over `UndoManager` registered at the view-model level, implementing the §8.4 table: edit text, split, merge, select take, archive take, reorder chapters. Chapter deletion stays DEFERRED.

Split and merge MUST follow §8.4's identity rules exactly — split keeps the original ID for the **first** half; merge keeps the **first** paragraph's ID and moves the second's takes on as archived takes labelled with their origin. `SplitMergeTests` already asserts the Core behavior; extend it to assert undo restores exactly.

**C4 — `global_ordinal` renumbering (F-16).** Add to `ProductionStore`:

```swift
func renumberGlobalOrdinals() async throws   // one pass, ordered by (chapter.ordinal, paragraph.ordinal)
```

Implement in `SQLiteProductionStore` as a single transaction over a `ROW_NUMBER()`-equivalent update; ~10 ms for 10,000 rows. Call it after **import, split, merge, chapter reorder, and script application**. Replace the `MAX(global_ordinal)+1` assignment at `SQLiteProductionStore.swift:136` with a renumber call at the end of the enclosing mutation.

This is a correctness fix, not a polish item: every "¶ 218 of 2,884" label on every surface — Mac, phone, watch, CarPlay — reads this column, and today a single split silently corrupts all of them downstream.

**Acceptance:**

- `VoxglassStudioTests/ScriptEditorModelTests`: debounce flush writes exactly one `updateParagraphText`; drift banner appears for `.minor`/`.semantic` and not for `.none`/`.cosmetic`; generated paragraphs are read-only by default.
- `VoxglassStudioTests/UndoTests`: each §8.4 row round-trips; recording is never undoable (undo after record reselects the previous take and destroys nothing).
- `VoxglassTests/Production/Store/GlobalOrdinalTests`: after `split(paragraph:at:)` on a 1,000-paragraph fixture, `paragraphSummaries` global ordinals are `0..<1001` contiguous and in document order.
- `PerformanceBudgetTests` still green, including the render-count probe.

---

### WP-D — Capture robustness

**Closes:** F-11, F-12, F-13.
**Depends on:** WP-C (the workspace must be reachable to surface these states).
**Mockup:** `17-capture-interruptions.html` (new — see §3).

This is the package that makes "never lose a take" true rather than aspirational.

**D1 — Ring buffer.** Add `VoxglassStudio/Services/CaptureRingBuffer.swift`: single-producer/single-consumer, power-of-two capacity sized to 4 seconds at the record format, preallocated at `prepare(device:format:)`. The tap block MUST do exactly three things — copy floats in, update `atomic` peak/RMS accumulators, return:

```swift
inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [ring, meters] buffer, _ in
    ring.write(buffer)               // no allocation, no lock, no dispatch
    meters.accumulate(buffer)        // atomics only
}
```

Remove from the tap: `stateLock.withLock`, `snapshotLock.withLock`, `writerQueue.async`, and the `pool.acquire() ?? AVAudioPCMBuffer(...)` allocation fallback (`AVAudioEngineCapture.swift:294-328`). The writer becomes a detached `.userInitiated` task that drains the ring, converts via `AVAudioConverter`, and writes to `AVAudioFile` — the conversion stays out of the tap, as §11.2 rule 1 already requires.

**Overrun handling (§11.2 rule 4):** a full ring increments an overrun counter. After the take completes, a non-zero counter surfaces as a warning **with the take preserved**. Never discard audio because the writer was starved.

**D2 — Device change (§11.2 rule 6).** Observe `AVAudioEngineConfigurationChange`. On fire, while recording: stop the engine, finalize the file as a complete take, ingest it, then throw `CaptureError.deviceChanged(name:)`. The UI shows the banner from mockup `17` — *"Your input device changed. The take was saved."* — with **Reveal Take** and **Resume Recording**. `CaptureError.deviceChanged` is currently declared at `AudioCapturing.swift:79` and never thrown; that MUST change.

**D3 — Sleep (§11.2 rule 8).** Observe `NSWorkspace.willSleepNotification`; stop cleanly through the same finalize-and-preserve path.

**D4 — Disk full.** `CaptureError.diskFull` exists; wire it to the writer task's write failure and surface the mockup `17` copy. Existing audio MUST be intact (manual test M-4).

**D5 — Microphone denied.** `AVCaptureDevice.requestAccess` is already called (`AVAudioEngineCapture.swift:85`). Add the pre-permission explanation sheet and the §18.5 denied copy with an "Open System Settings" button.

**Acceptance:**

- `VoxglassStudioTests/CaptureRingBufferTests`: writer starvation produces overruns without data loss for the frames that fit; wraparound is correct; the buffer never allocates after `prepare`.
- `VoxglassStudioTests/CaptureInterruptionTests` with `FakeAudioCapture`: each of device-change, sleep, and disk-full finalizes and preserves the in-flight take, and reports the specific error.
- Manual matrix M-2, M-3, M-4 (§19.10) executable and recorded in `RELEASE_CHECKLIST.md`.

> **Real-time-safety review note.** The tap runs on a real-time thread. Any reviewer of this package MUST verify by reading, not by testing, that the tap body contains no allocation, no lock, no `Task`, no `os_log`, and no `Date()`. A test cannot prove this; only the code can.

---

### WP-E — Document lifecycle

**Closes:** F-14, F-15, F-17, F-18, F-19.
**Depends on:** WP-B.
**Mockups:** `18-project-lock-and-missing.html`, `19-reimport-summary.html` (new — see §3).

**E1 — Package advisory lock (§8.3).** On open, write `Autosave/lock.json` containing `{ pid, deviceName, openedAt }`.

- Present, pid alive on this machine → focus the existing window instead of opening a second.
- Present, stale (different `deviceName`, or pid gone) → the "Open anyway" dialog from mockup `18`, with the explicit iCloud-Drive data-loss warning. SQLite WAL tolerates it; the user should still be told.
- Remove the lock on window close and on `NSApplication.willTerminate`.

**E2 — `withExclusiveWrite` (§7.9).**

```swift
func withExclusiveWrite<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T
```

Serializes long operations (import, script application, full save) against UI-driven mutations, and lets the UI show a progress state. Also call `checkpoint()` after any write batch larger than 1,000 rows so the WAL does not grow unbounded during import.

**E3 — Recents with snapshots (§8.1).** Replace `RecentsStore`'s URL+bookmark list with the specified record:

```swift
public struct RecentProject: Codable, Sendable, Identifiable {
    public var id: UUID
    public var bookmark: Data
    public var lastKnownURL: URL
    public var manifest: PackageManifest
    public var summarySnapshot: ProjectSummary?
    public var lastOpenedAt: Date
}
```

Refresh `summarySnapshot` when a project is opened or closed and after any sync fetch. A bookmark that fails to resolve renders as **"Missing — locate…"** (mockup `18`), never disappears.

**E4 — Library shell (§18.1.2).** `NavigationSplitView` with the sidebar sections **All Projects / Needs Review / Ready to Export / Archive / Settings**, each a filter over cached snapshots — `library.section.<case>`. "Ready to Export" = every non-synthetic paragraph has a selected take, zero `needsPickup`, and the last validation run for the intended destination had no blocking issues. **Compute from the snapshot; never open all databases to render the sidebar.** Add the Production Activity feed (`library.activity.<n>`) showing the last 10 cross-device events, and project card chips per mockup `01-project-library`.

**E5 — Wizard rights step (§8.2, §18.1.3).** Restore the four-step wizard from mockup `02-new-project`. Step 3 gains `wizard.rightsBasis.<case>`, `wizard.sourceURL`, `wizard.editionYear`, `wizard.attest`, and the `legal.noCopyrightDetermination` footnote. `wizard.back` becomes reachable.

Validation: title/author/narrator non-empty (trimmed); **if purpose is `publicDomainCommunity`, source URL is required before Continue on step 3**; attestation required to finish. Cancelling before finish creates nothing on disk.

> The smoke tests key on `wizard.title`, `wizard.author`, `wizard.narrator`, `wizard.destination`, and `wizard.continueToImport`. Re-introducing steps MUST NOT rename or reorder those five, or `StudioSmokeUITests` breaks. Keep them all on step 1 except `wizard.destination`, and have `wizard.continueToImport` remain the finish action.

**E6 — Re-import summary sheet (§18.1.4).** Mockup `19`. After a re-import, show *"Reusing 2,871 paragraphs · 13 new · 12 no longer in source (4 have recordings) · 6 changed text"* with Keep/Discard for orphans. `ParagraphReidentifier` already produces the `ReidentificationReport`; this surfaces it. Orphan retirement MUST stay non-destructive (§22.6 risk row).

**E7 — UTType registration (F-18, §4.8).** Add to the `VoxglassStudio` target in `project.yml`, then `xcodegen generate`:

```yaml
UTExportedTypeDeclarations:
  - UTTypeIdentifier: guru.parso.voxglass.project
    UTTypeDescription: Voxglass Audiobook Project
    UTTypeConformsTo: [com.apple.package]
    UTTypeTagSpecification:
      public.filename-extension: [voxproject]
CFBundleDocumentTypes:
  - CFBundleTypeName: Voxglass Audiobook Project
    LSItemContentTypes: [guru.parso.voxglass.project]
    CFBundleTypeRole: Editor
    LSHandlerRank: Owner
```

**Acceptance:**

- `VoxglassStudioTests/PackageLockTests`: a live lock blocks a second open; a stale lock offers "Open anyway"; the lock is removed on close.
- `VoxglassStudioTests/RecentsStoreTests`: an unresolvable bookmark yields a `.missing` row rather than removal; snapshots survive a store round-trip.
- `VoxglassStudioTests/NewProjectModelTests` extended: LibriVox purpose without a source URL cannot advance past step 3; cancel writes nothing to disk.
- Manual: `.voxproject` shows the Voxglass Studio icon in Finder and opens on double-click.

---

### WP-F — Export resumption

**Closes:** F-05, F-22.
**Depends on:** WP-B.
**Mockup:** `16-export-run-resume.html` (new — see §3).

**F1 — Populate `export_run`.** The table exists (`ProductionMigration.swift:200`) and is inert. Add store methods to open a run (`status = 'running'`), record each produced file's SHA-256, and close it (`succeeded` / `cancelled` / `failed` with the error code).

**F2 — `.partial` directory.** Builders write to `Exports/<Destination>/<slug>.partial/` and rename to `<slug>/` only on success. A cancelled or failed export leaves the partial directory and its `export_run` row for diagnosis.

**F3 — Skip-unchanged.** On re-export with `overwriteExisting == false`, a planned output whose content hash already matches the recorded hash is skipped and reported as **"unchanged"** in `ExportBundle.warnings` and in the run log. Because chapter renders are content-cached, re-exporting after changing one paragraph re-encodes exactly one chapter — assert this.

**F4 — Resume UI.** Per mockup `16`: on entering the wizard with a `running` run for this destination, offer **Resume** / **Start Over**. The run view lists per-file rows with status (`unchanged` / `re-encoded` / `pending` / `failed`), a live log, and Cancel. Completion shows file count, total duration, total size, checklist link, "Reveal in Finder", and `legal.userSubmits`.

**F5 — `PlaybackMode.retailSample` (F-22).** Add the missing case from §12.2:

```swift
case retailSample(startParagraph: UUID, maxDuration: TimeInterval)
```

Handle it in `SegmentQueueBuilder` and refactor `RetailMasterPackageBuilder`'s private `sampleSegments` to call through it, so sample construction obeys the same segment rules as every other queue. Extend `SegmentQueueTests` with the new mode.

**Acceptance:**

- `VoxglassTests/Production/Packaging/ExportResumeTests`: cancel mid-export leaves `.partial` plus a `running` row; resuming completes and skips files whose hashes match; the final directory has no `.partial` suffix.
- Re-export after changing one paragraph re-encodes exactly one chapter (assert transcoder call count with `FakeTranscoder`).
- `ExportEndToEndTests` still green — it remains the highest-value test in the suite (§19.4).

---

### WP-G — iPhone production surface

**Closes:** F-02, F-24.
**Depends on:** WP-B (not technically, but the seed plumbing pattern is shared).

The seven screens in `Voxglass/Features/Production/ProductionViews.swift` are built and unreachable. The backend already runs: `AppServices.swift:141-153` registers the watch transport and pulls projections on launch. This package connects them.

**G1 — Entry point (§18.2.1).** Add **My Productions** to the Library tab's filter chip row (Books / Playlists / Downloads / My Productions), identifier `shelf.myProductions`; cards get `production.<slug>`. Empty state: *"Productions you preview from Voxglass Studio on your Mac appear here."* — with **no** call to action, because the phone cannot create one.

**G2 — Navigation graph.** Wire shelf → `ProductionBookDetailView` → `ProductionReviewPlayerView` / `ProductionParagraphListView` / `ReviewQueueBuilderView`, plus `AddReviewNoteSheet` and `ProductionSyncStorageView`. Hand each its model from `AppServices.productionEnvironment`.

**G3 — Player requirements (§18.2.3).** Verify and fix as needed: actions debounced so a double-tap emits one event; haptic per action; queue label and position always visible; background playback with the paragraph as the lock-screen title.

**G4 — Download queue to Watch (F-24, §18.2.5).** Add `queueBuilder.downloadToWatch` with the size estimate, calling the existing `WatchTransport.sendAudio` path. The watch side (`WatchProductionStoragePolicy`, 200 MB cap with least-recently-queued eviction) is already implemented.

**G5 — Extend the iPhone smoke test.** `VoxglassUITests` currently asserts no production surface. Add: launch with `-uiTestSeed onePreviewProject`, tap `shelf.myProductions`, assert a `production.<slug>` card, open it, assert `detail.playWholeBook` and `detail.reviewFlagged` exist.

> `AccessibilityAuditTests` proves identifiers *exist in source*; it cannot prove a screen is reachable. That is exactly how F-02 survived. The smoke-test extension is the reachability proof and is the acceptance criterion for this package.

**Acceptance:**

- Extended `VoxglassUITests` passes locally on the iOS simulator.
- `AccessibilityAuditTests.documentedAbsences` loses its `queueBuilder.downloadToWatch` and `player.autoAdvance` entries.

---

### WP-H — Remaining specified surfaces

**Closes:** F-19 residue, F-23, F-25, F-26, F-28.
**Depends on:** WP-C, WP-E.

Smaller, independent items. Each MAY be its own commit.

**H1 — Validation "Fix Next Issue" (F-23, §15.2).** Every `ValidationIssue` already carries a `FixAction`; nothing consumes it. Add `ValidationModel.fixNext()` walking blocking issues in document order and performing or navigating the action, plus per-issue `validate.goToParagraph.<n>`. Wire all fourteen `FixAction` cases — `applyMastering` is the only one that touches entitlement, and it is invoked from the Export path, so **`ValidationModel` MUST NOT read entitlement** (§17.5, §15.7): the validation screen offers every destination unconditionally.

**H2 — Take comparison A/B (F-25, §11.7).** Gapless, position-preserving switching: from take A at t=3.2 s, start take B at `min(3.2, B.duration)` with a 15 ms crossfade, via two prepared player nodes. Show metrics side by side with differences highlighted, and mark the recommended take **"Suggested"** — a heuristic label, never an automatic selection. Identifiers `compare.takeA`, `compare.takeB`, `compare.playAB`, `compare.useSelected`.

**H3 — Import Audio markers (F-26, §18.1.8, §11.5).** Waveform with draggable markers, `import.audio.addMarker` / `import.audio.removeMarker`, and the segment→paragraph→confidence table (`import.audio.segment.<n>`). `SilenceSegmenter` already produces boundaries and confidence; this is the editing surface over it. Keep the §22.4 deviation: the second assignment method stays **"Split file across this chapter"**, never a spanning take.

**H4 — Metadata Artwork tab (F-28, §18.1.12).** Fourth tab (`metadata.tab.<case>`, `metadata.artwork`): validates size and aspect against the destination's `ArtworkRule` and generates the 2400 px derivative. `ArtworkStore` already declares the `cover2400` role and stores it; nothing currently produces the image. Add the resize in the Studio target (Core stays image-framework-free). This also makes the `artworkTooSmall` and `artworkNotSquare` rules meaningful — they are implemented and tested but currently have no UI that can satisfy them.

**H5 — Import surface residue.** `import.warningCount`, `import.resegment`, `import.paragraph.<n>`, `import.splitHere.<n>`, `import.mergeNext.<n>`, `import.markSceneBreak` per mockup `03-source-import`. `Segmenter` emits `ImportWarning` values that are currently discarded by the UI.

**Acceptance:** every entry removed from `documentedAbsences` has a control in source and, where it is on a smoke path, an assertion in the corresponding smoke test. `AccessibilityAuditTests` passes with the shrunken absence list.

---

### WP-I — Documentation and verification hygiene

**Closes:** F-20, F-21.
**Depends on:** all of the above (it records what actually shipped).

**I1 — `// verified <date>` comments (§3 preamble).** Add a `///` citation with a verification date next to every constant in the relocated `Destinations/DestinationProfiles.swift`. Today `grep -c verified` returns 0, which means §21.3's re-verification checklist has nothing to update and the "executable copy of the research" (`DestinationProfileTests`) has no human-readable provenance beside it.

**I2 — `DESTINATION_VERIFICATION_LOG.md`.** Create `docs/voxglass-mvp/DESTINATION_VERIFICATION_LOG.md` with one dated row per §21.3 item (LibriVox tech specs / disclaimer / AI policy, ACX requirements, IA metadata, Apple Books intake) recording who checked, when, and the outcome.

**I3 — Reconcile §22.4 (F-21).** `AccessibilityAuditTests.documentedAbsences` is a well-maintained, honest inventory of unshipped controls — but it lives in a test file, while §22.4 is where the spec says deviations belong. After WP-C through WP-H, most entries disappear. For each that legitimately remains, add a row to spec §22.4 with the reason. The test's dictionary then becomes the *enforcement* of §22.4 rather than a private ledger, and the spec stops claiming features that do not exist.

**I4 — Update `RELEASE_CHECKLIST.md`.** Re-tick the gates section once WP-A through WP-H land, and check the boxes that this effort makes checkable (five UI smoke tests, destination re-verification).

---

## 3. New mockups

Four new mockups ship with this plan, in `docs/voxglass-mvp/voxglass-macos-view-mockups/`, matching the existing set's single-file dark-theme HTML convention. They cover the surfaces this plan requires that the original fifteen do not depict. Everything else already has a mockup — notably `05-script-editor` (WP-C), `02-new-project` (WP-E5), `01-project-library` (WP-E4), `07-import-audio` (WP-H3), `08-take-comparison` (WP-H2), `11-metadata-rights` (WP-H4), and `13-validation-report` (WP-H1) — and those remain the visual contract.

| File | Guides | Why it was needed |
|---|---|---|
| `16-export-run-resume.html` | WP-F | `14-export-wizard` stops at destination selection; nothing depicted the run, the per-file unchanged/re-encoded/pending states, the resume prompt, or the completion summary carrying `legal.userSubmits` |
| `17-capture-interruptions.html` | WP-D | No mockup existed for any capture failure surface. §18.5 supplies the copy; this supplies the placement, and the "take was saved" reassurance that makes principle 1 legible to the user |
| `18-project-lock-and-missing.html` | WP-E1, WP-E3 | The already-open focus, the stale-lock "Open anyway" warning, and the "Missing — locate…" library row are specified in prose only |
| `19-reimport-summary.html` | WP-E6 | `03-source-import` shows first import only; the re-import reconciliation sheet is the screen where a narrator can lose 1,200 recordings if it is built carelessly |

Each mockup is a static HTML file with no external assets, openable directly in a browser, using the same CSS custom properties as the existing set so the four sit alongside the original fifteen without restyling.

---

## 4. Sequencing and definition of done

### 4.1 Order

```
WP-A ─┬─▶ WP-B ─┬─▶ WP-C ─▶ WP-D
      │         ├─▶ WP-E ─┐
      │         └─▶ WP-F  ├─▶ WP-H ─▶ WP-I
      └─────────▶ WP-G ───┘
```

- **WP-A first, always.** It is the cheapest package and every later one adds code the gates should be policing.
- **WP-B unblocks the most.** F-03 alone makes three of the five UI smoke tests meaningful.
- **WP-G is independent** of C/D/E/F and can run in parallel if two agents are working.
- **WP-I last**, because it records what actually shipped.

### 4.2 Per-package gate

Before a package is considered complete:

```bash
swift build
swift test --no-parallel --skip VoxglassPerformanceTests
VOXGLASS_TIMING_TESTS=1 swift test --no-parallel --filter VoxglassPerformanceTests
bash scripts/test_guards.sh          # new in WP-A — proves the gates can fail
bash scripts/guard_production.sh
bash scripts/guard_wiring.sh
xcodebuild build -project Voxglass.xcodeproj -scheme VoxglassStudio \
  -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Plus, for packages touching UI: `scripts/test.sh --all` locally. CI never runs simulators (§19.9).

### 4.3 Definition of done for this effort

The gap closure is complete when all of the following hold simultaneously:

1. Every `F-nn` in §1 is either closed by code or RECONCILE'd into spec §22.4 with a stated reason.
2. `scripts/test_guards.sh` demonstrates each of G-1, G-2, G-4, G-7, G-10 failing on a planted probe and passing without it.
3. All five UI smoke tests pass locally via `scripts/test.sh --all`, with the iPhone test asserting a reachable production surface and the three macOS tests running unmodified against the seeded environment.
4. `AccessibilityAuditTests.documentedAbsences` contains only entries that also appear in spec §22.4.
5. The three §20.13 acceptance walkthroughs have been executed by a human on real hardware with a real microphone, and W-1 in particular has been executed **without observing a purchase prompt** (spec §2.2 principle 4).
6. `RELEASE_CHECKLIST.md` and `DESTINATION_VERIFICATION_LOG.md` are current.

### 4.4 Risks this plan introduces

| Risk | Impact | Mitigation |
|---|---|---|
| WP-A's G-2 fix surfaces many pre-existing entitlement violations in `VoxglassStudio` | WP-A balloons in scope | Triage first: count violations before fixing. If more than a handful, split into WP-A (gate) and WP-A2 (violations), keeping the gate red on a branch until A2 lands |
| WP-D rewrites the tap on a working capture path | Regressed recording — the one thing that must never break | Land WP-D behind no flag but with M-1 (100 sequential paragraphs, real interface) executed before merge; the ring buffer is additive and the old path is deleted only after M-1 passes |
| WP-B's `WindowGroup(for:)` change breaks the smoke tests' launch assumptions | Local gate goes red | The smoke tests only key on identifiers, not window structure; verify `library.newAudiobook` is present in the split-view sidebar's detail pane |
| WP-C's Script Editor over 10,000 paragraphs regresses the open budget | §19.7 "project open to Dashboard interactive < 1.5 s" | Render from `paragraphSummaries`, never `load()`; add the 10,000-¶ fixture to the editor's model test |
| Renumbering global ordinals (WP-C4) rewrites rows on every split | Import/edit slowdown | One transaction, indexed; assert ~10 ms for 10,000 rows in `GlobalOrdinalTests` |

---

## 5. Required spec amendments

These MUST land with the code, not after. The spec is the contract; leaving it describing a different product is how F-21 happened.

| Spec § | Amendment |
|---|---|
| §4.1 | Module topology: note that `DestinationProfile` **literals** live in `Destinations/DestinationProfiles.swift` while the **types** stay in `Domain/DestinationTypes.swift` (WP-A, G-10) |
| §14.3 | Record that `ReviewQueueResolver.sql(for:)` is implemented as `ProductionStore.paragraphIDs(matching:order:)` rather than a free function; the "both forms MUST agree" requirement is unchanged and is asserted by `ProductionStoreTests` |
| §19.2 | Note that `.test(seed:)` fakes live in `VoxglassStudio/Support/UITestFakes.swift` under `#if DEBUG`, because gate G-9 forbids `VoxglassCoreTestSupport` in a shipping target |
| §19.9 | Add gate **G-13: the gates can fail.** `scripts/test_guards.sh` MUST plant a probe for each grep gate and assert it is caught. Update the "twelve grep gates" wording throughout (§0.4, §21.4) to thirteen |
| §22.4 | Add a row for every entry remaining in `documentedAbsences` after WP-H (WP-I3) |
| §22.6 | Add a risk row: *"A grep gate silently stops matching" → the product's defining rules go unenforced → G-13 self-test* |

---

*End of plan.*
