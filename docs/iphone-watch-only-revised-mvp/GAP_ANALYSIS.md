# Gap analysis — revised MVP spec vs. shipped implementation

**Date:** 2026-08-10. **Tree:** `main` @ `ec231de` (clean).
**Spec under review:** [`SPEC.md`](SPEC.md) (2026-08-07).
**Method:** every normative clause in §2, §4, §6–§17 and §19 checked against the
tree. §5's inventory is deliberately *not* used as the yardstick — it describes
the pre-implementation tree and its 🆕 rows are stale by construction.

## Closure record (2026-08-10)

All thirteen gaps were closed per `GAP_FIX_BRIEF.md` F1–F8 (see the commit
history of the `feat/revised-mvp-gap-close` merge):

- **G1** — mockup ids reconciled to the shipped identifiers (D-G1) and
  `AccessibilityAuditTests` repointed to parse the mockup HTML.
- **G2** — `LicenseGatePlacementTests` added to `LicenseGateTests.swift`; the
  `StudioEnvironment` allow-list entry removed from gate G-2.
- **G3** — a failability probe for G-5 added to `test_guards.sh`.
- **G4** — the iPhone smoke test now creates, records (with a flag + re-record
  review leg), validates, and exports a narration, then verifies the produced
  package bytes (128 kbps CBR / 44.1 kHz / mono, ID3, checksums, checklist,
  metadata.json).
- **G5** — Command-R record/stop keyboard shortcut and a scoped media-button
  claim on the armed record screen.
- **G6** — progressive source parsing (`extractProgressively` on EPUB) with a
  live preview and a working cancel on the import screen.
- **G7** — "Save a copy" of the `.voxproject` package on the Submit screen.
- **G8** — the folder share path already existed (ShareLink directory fallback).
- **G9** — `RELEASE_CHECKLIST.md` no longer names the deleted screenshot script.
- **G10** — stale "Mac" prose in `SyncConflictTests` corrected.
- **G11** — the four §13.2 export scopes built and threaded through preflight
  and `ExportOptions.scope`, plus the hydrate/local-only/cancel banner.
- **G12** — a four-way purpose picker on the new-project step; the choice
  persists through SQLite, the LibriVox manifest, and the CloudKit projection.
- **G13** — Audio Setup opens from Settings.

`swift test` is green (1319 tests / 189 suites), all grep gates green with the
new probes, and the extended iPhone smoke test passes locally.

## Verdict

The MVP is substantially implemented. All ten stages P0–P9 landed as commits
(`c0c6712` … `acbb663`), plus a Swift 6 migration and one explicit gap-closure
pass (`1c54a2d`, "ship narration MVP gaps"). Every architectural decision that
the spec called pivotal — the single project model, the sync inversion, the
storage kernel, the Pro rename — is real in code and covered by tests.

**Evidence run today:**

| Check | Result |
|---|---|
| `swift test` | **green** — 1309 tests / 186 suites |
| `scripts/guard_production.sh` | **green** — all guards passed |
| `scripts/test.sh --all` (simulator UI smoke) | **not run** — 25-min local gate, out of scope for this review |

Thirteen gaps remain. Three are meaningful — **G11** (export scopes were never
built, so the primary free LibriVox workflow is unreachable), **G2** (the
mandated license-placement test was never written), and **G1** (the mockup
identifier contract has drifted) — and the rest are small or are process items
that no amount of code can close. None of them contradicts a "hard constraint"
from the agent brief, and none is an engine defect: where features are missing,
Core is already built and the gap is UI + wiring.

---

## Confirmed met

Spot-verified in source, not inferred from commit messages.

### Corrections tables (§0.4–§0.6)

| Item | Evidence |
|---|---|
| R-1 no second app | Narration lives in the 5-tab dock; no second bundle |
| R-2 real paths | No `ProductionStudio` anywhere; gate G-P3 enforces it |
| R-3 app tokens in mockups | `mockups/style.css` carries brass `#E3A44B`; `mockup.js` ships the **Glass / Solid** toggle mirroring `AdaptiveGlass`, and every page includes it |
| R-4 additive schema | `SyncRecords.swift:15` — `case asset = "VGProductionAsset"`; existing record types unrenamed |
| R-7 watch never links CloudKit | guard G-5 (see **G3** for its probe gap) |
| R-8 reuse `.voxproject` | `NarrationProjectRepository.swift:6`; no `.voxmobileproject` anywhere |
| R-9 FLAC free on IA | gate G-P2 green, with a failability probe in `test_guards.sh:139` |
| R-10 evict least-recently-*reviewed* | `WatchProductionStoragePolicy` |
| M-2/M-3 phone is the writer | `PhoneProductionSync`, `ProjectionPublisher` inverted; `SyncConflictTests` proves the conflict branch degrades to adopt-tag/retry-once/phone-wins and never surfaces UI |
| M-4 chunked + cancellable | `Assembly/ChunkedRenderCoordinator.swift`, `ChunkedRenderCancellationTests` |
| N-1 no Mac handoff | `LongWorkHandoffSheet` gone; gate G-P5 green with two probes |

### The pivotal decision (§4.3)

`AudiobookProject` in SQLite is the one model. `NarrationProjectStore` is
deleted; `Core/Production/Store/NarrationMigration.swift` holds
`LegacyNarrationProject` et al. as decode-only types, and
`Features/Production/Discovery/NarrationProjectRepository.swift` is the new
`.voxproject`-backed repository. `NarrationMigrationTests` present and green.

### Pro rename (§2.2 / D-1) — all four rows moved

- `LicenseTypes.swift:48` → `guru.parso.voxglass.narration.pro`
- `EntitlementCache.swift:19–20` → `voxglass.narration.pro.since` / `.transaction`
- `Voxglass/Resources/VoxglassNarration.storekit` exists
- `voxglass.studio.pro` returns zero hits outside `docs/`; gate G-P7 with probe

D-2 pricing ($49 / $79) is carried in `APP_STORE_METADATA.md:12,86` and correctly
absent from code.

### Storage kernel (§6) and D-5

`production_asset` lands as migration `id: 2` with columns matching
`ProductionAssetRecord` **one-for-one** (`ProductionMigration.swift:223–234`).
`isEvictable` (`ProductionStoragePolicy.swift:54`) is the single authority and
`ProductionEvictionExecutor` calls it rather than re-deriving. D-5's first-run
clamp is real: `ProductionCacheLimits.firstRunWorkingCache(freeBytes:)` at
`ProductionStoragePolicy.swift:81` (`freeBytes * 15 / 100`), wired at
`ProductionCacheSettings.swift:24`. Production and listener caches are separate
rows in `StorageSettingsView` (`storage.workingCache` vs `storage.audiobookCache`).

### Capture (§7)

`Core/Production/Audio/CaptureRingBuffer.swift` exists and
`AudioSessionCapture.tap(_:)` (line 348) does exactly what §7.2 demands — push
into the lock-free ring, signal, return. No allocation, no `Task`, no `os_log`,
no `Date()` in the tap body; all of that is in the detached writer task
(line 358). `CaptureRouteClassifier` + `CaptureRouteInfo` exist and the route
class is persisted per take (migration `id: 3`, `take_capture_fields`), so
`routeNotRetailReady` reads history exactly as §7.1 requires.

### Validation (§12.2) and watch remote (§14.3)

All four new codes exist in `IssueCode.swift:86–96`, are constructed in
`ValidationRuleEngine.evaluatePreflight()` / `evaluateRouteReadiness()`, and each
carries its mandated `FixAction` (`.hydrateAssets`, `.manageStorage`,
`.backupNow`, `.openAudioSetup`). `RecordingRemoteCommand {sessionID, sequence,
action}` is at `WatchLink/RecordingRemote.swift:27` with documented idempotency
and state gating; `RecordingRemoteTests` present.

### Test files (§16.2)

All nine named files exist under `VoxglassTests/Production/` — see
`CloudAssets/`, `Audio/`, `Packaging/`, `WatchLink/`, `Store/`, `Assembly/`.

### Screens (§15.4)

Every 🆕 screen shipped: `ProjectDashboardView`, `ScriptEditorView`,
`AudioSetupView`, `ImportAudioView`, `TakeComparisonView`, `StorageSettingsView`,
`ProPurchaseView`, plus the 14b export-run/resume view and `WatchRecordingRemoteView`.
Pro entry points are exactly the two spec'd: the destination picker
(`NarrationFlowScreens.swift:1357`) and Settings (`SettingsView.swift:192`).

---

## Gaps

Numbered in **discovery order**, not severity — G11–G13 were found late, during
the G1 triage, and are appended rather than interleaved so the numbering stays
stable. For severity see the verdict above and "Suggested order" below: the three
that matter are **G11**, **G2**, **G1**.

### G1 — The mockup identifier contract has drifted out of sync with the shipped UI

**Spec:** §15.3 rule 2 — "the mockups carry the identifiers as HTML `id`
attributes so the two stay in sync". §17 P9 acceptance — "this spec and its
mockups are synchronized with the shipped UI". Agent brief — "HTML `id`
attributes are the `.accessibilityIdentifier` values you must use".

**Measurement** (three passes, because the first two overcounted — the numbers
below are the corrected ones):

| Matching method | unmatched, of 221 |
|---|---:|
| literal `.accessibilityIdentifier("<id>")` only | 143 |
| any `"<id>` anywhere in source (the audit test's own method) | 94 |
| …plus template-prefix credit (`script.row.1204` ← `"script.row."`) | **36** |

The third row is the honest number. Eight pages — 04, 06b, 06c, 08, 09, 14c,
watch-04 — are **perfectly clean**. The drift is concentrated, not uniform.

Of the 36, the triage that matters is *why* each is unmatched:

**Class A — naming drift, the control exists.** The bulk. Fixing these is
renaming on one side or the other, no new UI:

- `watch-02` declares `watch.playPause` / `watch.approve` / `watch.flag` /
  `watch.pickup` / `watch.addNote`; the watch ships the same controls in the
  `player.*` namespace, via `ProductionWatchAccessibility` constants.
- Screen 12 declares `storage.limit`; `StorageSettingsView.swift:77` ships
  `storage.workingCacheLimit`. Same control, different name.
- Screen 06 declares `record.compareTakes` / `record.importAudio`;
  `NarrationFlowScreens.swift:476,489` ship `record.take.compare` /
  `record.take.import`, and both sheets are wired (lines 191, 194).
- Row templates use a different scheme: mockups say `needs.row.0` /
  `myNarrations.row.0`, the app builds `needs.card.\(needSlug(need))` /
  `myNarrations.project.\(…)`.

**Class B — the control genuinely does not exist.** These are not naming
problems and are broken out as their own gaps below: `export.scope.*` → **G11**,
`wizard.purpose.*` and the rest of the `wizard.*` set → **G12**,
`settings.audioSetup` → **G13**.

**Why nothing caught the Class A drift:** `AccessibilityAuditTests` does enforce
a registry — but it is the **Studio-era §22.1 registry** inherited from
`VOXGLASS_STUDIO_SPEC.md`, not the revised MVP's mockup ids. So the audit is
green while the stated visual contract has drifted.

**Collateral:** the three §16.6 walkthroughs cite identifiers that no longer
match the app. `W1-LibriVox-free.md` names `export.destination.librivox`,
`validation.destination.librivox`, and `import.acceptStructure`; the app ships
`validation.destination` and no per-destination or accept-structure identifier.
The walkthroughs are executed by a human tapping visible UI, so this degrades
rather than blocks them — the screens exist — but the identifier citations are
wrong and should be re-derived once G1 is settled.

**Fix — decided: the mockups follow the app** (`GAP_FIX_BRIEF.md` D-G1). Regenerate
the mockup ids from the shipped `.accessibilityIdentifier` set; do not rename
shipping identifiers. Then repoint `AccessibilityAuditTests` at the revised-MVP
mockup ids so the two can never diverge silently again, and re-derive the
walkthrough identifier citations from the result.

---

### G2 — `LicenseGatePlacementTests` was never written

**Spec:** §2.2, verbatim — "**Test:** `LicenseGatePlacementTests` — greps the
built source set for `LicenseGate`/`isPro` references outside the three permitted
files and fails on any other occurrence. This test already has a home in the
validation/licensing suite; extend it rather than adding a new one." This is the
enforcement for hard constraint #3 in the agent brief.

**Actual:** no such test. `VoxglassTests/Production/License/` contains only
`LicenseGateTests.swift`, which tests gate *semantics* (`require`/`isUnlocked`
per entitlement), not placement. Its own doc comment defers placement proof to
"`ExportModelTests` (Studio)" — a suite deleted in P0.

The substitute is shell gate G-2 in `guard_production.sh`, which is
**filename-pattern** based:

```
forbidden='Recording|Review|Preview|Capture|Assembly|Segment|Sync|Watch|CarPlay|Validation'
allowed='Export|Packaging|RetailMaster|Master|License|Settings|StudioEnvironment'
```

That is a different rule from "outside the three permitted files". The two files
that actually carry gate references today —
`Discovery/NarrationFlowScreens.swift` and `Discovery/NarrationFlow.swift` —
match neither list, so G-2 never looks at them. Placement happens to be correct
right now (destination picker + export runner), but it is unenforced: a new
`NarrationSomethingView.swift` could add an `isPro` check and every gate stays
green. G-2's `allowed` list also still names `StudioEnvironment`, a P0 casualty.

**Fix:** add the grep-based placement test to
`VoxglassTests/Production/License/LicenseGateTests.swift` keyed on the three
permitted paths, and drop `StudioEnvironment` from G-2's allow-list.

---

### G3 — Gate G-W1 has no failability probe

**Spec:** §16.4 lists G-W1 as a gate this MVP adds, and closes with "Every gate
MUST have a matching entry in `scripts/test_guards.sh` proving it can fail."

**Actual:** the rule is enforced by the pre-existing G-5 (`guard_production.sh:117`,
"Watch isolation (no CloudKit in watch target)") — which is the right call given
R-7 explicitly frames G-W1 as restating an existing invariant. But
`test_guards.sh` has probes for G-1, G-2, G-4, G-7, G-10, G-15, G-P2, G-P3, G-P4,
G-P5, G-P6, G-P7 and **not** for G-5. G-5 also greps only `import CloudKit`,
narrower than the spec's "MUST NOT reference `CloudKit`" (in practice a
`CKRecord` reference without the import wouldn't compile, so the narrowing is
harmless — the missing probe is the real gap).

**Fix:** add a G-5 probe to `test_guards.sh` following the existing pattern.

---

### G4 — The iPhone UI smoke test is narrower than §16.3 specifies

**Spec:** §16.3 test 1 — "Narration tab → create a project from a need → record
**two** paragraphs with the fake capture → review → validate → LibriVox export
path."

**Actual:** `VoxglassUITests.swift` (206 lines,
`testAppBootsVisitsAllTabsEQAndProductions`) reaches the Narration tab, opens a
featured need, records **one** paragraph, asserts `record.take.1` exists and
`record.acceptAndNext` is enabled, then closes the flow (line 160) and proceeds
to Search and the EQ. What is covered:

- ✅ "Folds in My Narrations reachability" — lines 72–95 reach
  `shelf.myProductions` → seeded card → `detail.playWholeBook` /
  `detail.reviewFlagged`. Note this is the **seeded** `ProductionSmokeSeed`
  project and the review action is asserted *existent*, not tapped; it is not
  the project the test just created through the flow.
- ❌ Second paragraph, the review leg on the created project, validate, and the
  LibriVox export path — none reached.

Since CI runs no simulator (M-7), this local gate is the only automated coverage
of that path.

**And the export leg must verify the produced files, not merely reach the
export screen.** Nothing in the automated suite checks that *the app, driven
through its own UI*, writes a conformant package. The Core suite verifies
artifacts thoroughly — `ExportEndToEndTests.swift:49` asserts
`MP3FrameParser.verifies(data:expectedKbps: 128, sampleRateHz: 44_100, mono: true)`,
plus ID3 tags, `checksums.sha256`, the checklist, and `metadata.json` — but it
does so by calling `LibriVoxPackageBuilder().build(…)` **directly**, with
`ExportOptions` constructed in the test.

That is precisely the blind spot **G11** fell through. `ExportEndToEndTests.swift:99`
`singleChapterScopeExportsOneFile` passes `scope: .chapters([chapterID])` straight
into the builder and proves the builder honors it — while the app never passes
anything but `.wholeBook`, and every test stayed green. Core tests prove the
*engine*; the wiring layer between the UI and the engine — scope, options,
hydration, destination, output location — has no artifact-level coverage at all.
That layer is where the defects in this analysis actually are.

The §16.5 manual matrix does specify this check (M-9: "LibriVox export | MP3s
verify as 128 kbps CBR / 44.1 kHz / mono"), but it is human-executed and
unrecorded — see "Not verifiable from the repository".

---

### G5 — §9.3 external controls: two of three bullets not implemented

**Spec:** §9.3 — hardware keyboard shortcuts when a keyboard is connected;
Bluetooth media button / headset stem mapped to Record/Stop **when armed**; watch
remote.

**Actual:** only the watch remote ships. `keyboardShortcut`, `KeyEquivalent`,
`UIKeyCommand`, and `onKeyPress` return **zero** hits across `Voxglass/`.
`MPRemoteCommandCenter` appears only in consumer playback and CarPlay
(`PlaybackPlatformBridge`, `CarPlayReviewController`) — nothing in
`Features/Production` or `Core/Production` claims the media button while armed.
Neither is DEFERRED in the spec; both are unqualified §9.3 statements.

---

### G6 — §8.2 progressive parse not implemented

**Spec:** §8.2 — "Large documents parse **progressively**, with a preview
available before the parse completes. The import screen MUST NOT block on a full
parse of a 400-page EPUB."

**Actual:** `NarrationFlow.swift:2191 importFile(_:)` sets `model.isImporting =
true`, awaits `importer.extract(from: url)` to completion, then builds the
project. No incremental yield, no preview, and no cancel — which also brushes
§15.3 rule 3 ("no screen may show an indefinite spinner without a cancel or
retry"). `Core/Production/Text/` importers expose no streaming API
(no `AsyncStream`/`yield`), so this is a Core + UI change, not a UI-only one.

---

### G7 — §4.4 "Save a copy" of the `.voxproject` package is not offered

**Spec:** §4.4 — "Users never browse this tree. Portability is through **Files**:
'Save a copy' writes the `.voxproject` package (zipped on iOS…)."

**Actual:** no such action exists in any production surface. Export packages *do*
zip and share correctly (`ExportPackageZipper.zipContents` →
`ShareLink`, `NarrationFlowScreens.swift:1953`), but that is the export
artifact, not the project package. With the tree unbrowsable by design, there is
currently no user-facing route to a project backup or to moving a project
between devices outside iCloud.

---

### G8 — §13.4 "Save folder to Files" not offered

Only the `.zip` path exists. The spec prefers zip and says to "also support 'Save
folder to Files' where the system destination accepts directories". Low severity
given the stated preference. `export.evictAfterSave` (offer to evict staging
after save) **is** implemented.

---

### G9 — `RELEASE_CHECKLIST.md` still requires a script P0 deleted

`docs/voxglass-mvp/RELEASE_CHECKLIST.md:68` reads "Screenshots for all screens
shipped — `scripts/capture_studio_screenshots.sh`". That script was removed with
the Mac tree; `scripts/` no longer contains it. The agent brief flagged this
exact item as something the spec doesn't mention. The checklist line is currently
unsatisfiable.

---

### G10 — Stale "Mac" references outside the guarded directories

G-P5 covers `Voxglass/Features/Production/**` and `VoxglassWatch/Production/**`
only, so doc comments elsewhere still describe the deleted writer model — e.g.
`VoxglassTests/Production/Sync/SyncConflictTests.swift:16`, "A competing Mac
already published revision 2". Cosmetic; the *behavior* under test is the
correct phone-as-writer degradation.

---

### G11 — Export scopes were never built; every export is whole-book

**Spec:** §13.1 pipeline step 1 is "Choose scope". §13.2 — "Scopes: current
chapter · selected chapters · whole book · review-queue range" and "The user can
export only local chapters, hydrate all, or cancel."

**Actual:** `ExportScope` exists in Core (`Packaging/ExportTypes.swift:7`) with
`.wholeBook` and `.chapters([UUID])`, and `ExportOptions.scope` defaults to
`.wholeBook` (line 56). But **`ExportScope` is never referenced anywhere in
`Voxglass/Features/`** — zero hits. The export path never sets it, so it takes
the default, and both preflight call sites hardcode it
(`NarrationFlow.swift:1663` and `:1692`, `scope: .wholeBook`). Mockup 14's
`export.scope.chapter` / `.selected` / `.whole` / `.queue` and its
`export.hydrateAll` / `export.localOnly` choice have no counterpart in the app.

**Why this matters more than it looks:** `ExportTypes.swift`'s own doc comment
says it — "LibriVox's actual workflow posts one section at a time, so
single-chapter export is required." A LibriVox volunteer on the free lane cannot
produce a single-section package through the shipped UI, which is the primary
free workflow the MVP exists to serve. It also makes `ProFeature.batchExport`
meaningless — there is nothing to batch — which is why that case has no call site.

Core is ready; this is a UI + wiring gap, not an engine gap.

---

### G12 — Project purpose is hardcoded; screen 02's wizard fields don't exist

**Spec:** mockup `02-new-project.html` declares `wizard.title`, `wizard.author`,
`wizard.narrator`, `wizard.sourceURL`, `wizard.attest`, `wizard.continueToImport`,
and a four-way `wizard.purpose.*` picker (librivox / internetArchive /
commercial / personal).

**Actual:** none of those identifiers exist. `ProjectPurpose`
(`Domain/AudiobookProject.swift:5`) has three cases, and the **only** creation
site in the app writes one of them unconditionally —
`NarrationFlow.swift:555`, `purpose: .publicDomainCommunity` (the smoke seed does
the same at `ProductionSmokeSeed.swift:53`). No UI ever sets it.

Severity is moderate, not high: `purpose` does not gate destinations (it appears
nowhere in `EligibilityProfile`), so the retail lane is still reachable — the
gate is `rights.isAttested` plus the `.retailPresets` license check
(`NarrationFlow.swift:1716,1724`). The consequence is that `purpose` is dead
metadata that ships in every project, package manifest, and CloudKit record with
a value the user never chose.

---

### G13 — Audio Setup is not reachable from Settings

**Spec:** §15.4 row 06b lists the entry points as "recording toolbar, Settings".

**Actual:** `AudioSetupView` is presented from the recording screen
(`NarrationFlowScreens.swift:188`) and from the destination-picker screen
(line 1354), but not from Settings. The Narration group in `SettingsView.swift:36`
contains `NarrationProCard` and `StorageSettingsView` only; mockup 15's
`settings.audioSetup` has no counterpart. Trivial to close.

---

## Observation — the seven `ProFeature` cases are gated coarsely, not individually

Not a gap, recorded so it isn't re-litigated. §2.2 says Pro unlocks seven
`ProFeature` cases. Only `.retailPresets` has an actual call site
(`NarrationFlow.swift:1724`), guarding *any* retail destination. Because
mastering, M4B, commercial metadata, and validation-report export are reachable
only through a retail destination, they are transitively gated and the boundary
holds. `.batchExport` is the exception, and it is unreachable for the reason in
**G11**. The spec requires the features be Pro, not that each have its own gate —
and §2.2's "LicenseGate is consulted only in three places" actively favors the
coarse form.

---

## Not verifiable from the repository

These are process gates, not implementation gaps. Listing them so they are not
mistaken for either.

| Item | Spec | State |
|---|---|---|
| Manual hardware matrix M-1…M-14 | §16.5 | The P9 commit body says outright these "remain human-executed on device". No sign-off record in the tree. |
| Walkthroughs W-1/W-2/W-3 on real hardware | §16.6 | Documents exist and are thorough; `RELEASE_CHECKLIST.md:22,26,29` boxes unchecked. Their identifier citations are stale — see **G1** collateral. |
| Encoder build from clean checkout, iOS device + simulator + watchOS slices | §16.6 | Not attempted here. |
| Destination re-verification | §16.6 | **Done** — `DESTINATION_VERIFICATION_LOG.md` carries a 2026-08-09 P9 row covering items 1–6. |
| `ThirdPartyNotices.md` current | §16.6 | Present at `Voxglass/Resources/ThirdPartyNotices.md` with LGPL content; currency is a human judgment. |
| $49 / $79 in App Store Connect | D-2 | Correctly absent from code by design; set at submission. |
| Simulator UI smoke suite | §16.3 | Not run in this review (25-min local pre-commit gate). See **G4** for its stated scope gap. |

---

## Suggested order if these are closed

1. **G11** — highest product cost: single-section export is the LibriVox
   workflow. Core is ready; this is scope UI + wiring plus the hydrate/local-only
   choice. Do it first because it creates the identifiers G1 then has to match.
2. **G2** and **G3** — small, mechanical, and they restore the enforcement the
   spec asked for. Do them together with the G-2 allow-list cleanup.
3. **G1** — after G11, so the export screen's identifiers settle once. Decide
   direction first (mockups follow code, or code follows mockups), then repoint
   `AccessibilityAuditTests` at the revised-MVP ids and re-derive the walkthrough
   citations.
4. **G4** — extend the existing smoke test, and make its export leg **verify the
   produced package** (128 kbps CBR / 44.1 kHz / mono, tags, checksums). After
   G11 lands, add the single-chapter scope assertion — that is the one that would
   have caught G11. Cheap once G1 fixes the identifiers.
5. **G12**, **G13**, **G5**, **G7** — real but contained feature work.
6. **G6** — largest single item; needs a streaming importer API in Core.
7. **G8**, **G9**, **G10** — trivial.
