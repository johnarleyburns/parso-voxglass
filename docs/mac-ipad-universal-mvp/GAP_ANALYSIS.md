# Gap analysis — Mac + iPad Universal MVP vs. the repository

**Date:** 2026-08-11. **Tree:** `main` @ `495df6f` plus the resurrected `VoxglassMac*` trees (staged, unadapted).
**Spec:** [`SPEC.md`](SPEC.md). **Method:** every row below was checked against the working tree, not inferred from documents.

---

## 0. Executive summary

| | Count |
|---|---:|
| Gaps total | **41** |
| Blocking (nothing else can land until done) | **4** — G1, G2, G3, G4 |
| Already satisfied by shipping code (no work) | **11** — §6 |
| Resurrected files usable with rework | 41 of 58 |
| Resurrected files to delete outright | **6** |
| Genuinely new Core code required | ~5 files (`Merge/`, `Presence/`, `KeyboardShortcutMap`) |
| New Mac UI required | 4 screens (library rework, shortcuts sheet, cross-project queue, conflicts) |
| New iOS code required | 3 areas (adaptive router, split layout, conflict sheet) |

**The shape of the work.** This is not a port. Core is already platform-free and already builds for macOS (`Package.swift` declares `.macOS(.v14)`), and 58 files of Swift-6 macOS UI already exist in `VoxglassMac/`. The three real pieces of work are:

1. **Un-deleting the Mac past the gates.** Four CI gates were written specifically to stop this (§1). They fire in `pre-commit`, so no adaptation commit can land until they are amended.
2. **The two-writer merge model** (§3). The only genuinely novel engineering, and the spec deliberately shrinks it: takes, assets, and review events cannot conflict by construction, so the merge surface is one field on one entity.
3. **Re-pointing 41 resurrected files at a Core that moved +3,823 lines underneath them** (§4). Mostly mechanical, with three files where it is *not* mechanical and one where the compiler will not warn you.

**The one trap to brief the agent about explicitly.** `Take` gained `warning` and `routeClass` **with default values**, so `VoxglassMac/Features/Record/RecordingModel.swift` still compiles and produces takes with `.none` and `nil`. Nothing fails. §7.1 and §7.4 of the revised spec are silently defeated on macOS, and the failure only surfaces at retail-export validation months later. See **G21**.

---

## 1. Blocking gaps — nothing else lands until these are done

These are first because `scripts/guard_production.sh` runs in the pre-commit hook. **A commit that adapts the Mac tree fails today.**

| # | Gap | Evidence | Fix | Stage |
|---|---|---|---|---|
| **G1** | Gate **G-P6** fails on the resurrected tree. It greps `.swift` under `Voxglass VoxglassWatch VoxglassCoreTestSupport VoxglassTests`, greps `project.yml`/`Package.swift`, and checks the three old directories are absent on disk. Adding a `VoxglassMac` target to `project.yml` is fine today, but **10 resurrected source files contain `VoxglassStudio` / `Voxglass Studio` / `voxglass.studio`**, and the moment the grep paths are extended to `VoxglassMac` (which spec §0.6 requires) they fail. | `guard_production.sh:501-522`; `grep -rl` over `VoxglassMac` → 10 files | Extend G-P6's grep paths to `VoxglassMac VoxglassMacTests VoxglassMacUITests`; keep the three old directory names banned; rename `Studio*` → `Mac*` across the tree. Add the failable probe. | **U0** |
| **G2** | Gate **G-P7** fails: `voxglass.studio.pro` appears in `VoxglassMac/Services/StoreKitLicenseProvider.swift`, `Features/Settings/SettingsModel.swift`, and `Resources/VoxglassStudio.storekit`. | `guard_production.sh:528-536` | Extend G-P7's paths to `VoxglassMac`; delete the Mac `.storekit`; read the id from `NarrationProProduct.productID`. Probe. | **U0** |
| **G3** | Gate **G-P5** bans the word `Mac` in `Voxglass/Features/Production/**` and `VoxglassWatch/Production/**`. The conflict UI (*"edited on your Mac"*), the presence pill, and the Universal Purchase copy all need it. | `guard_production.sh:379-388` | Replace with **G-U1**: ban the exact retired-handoff phrases `Record on Mac`, `Continue on Mac`, `Requires a Mac` across `Voxglass/`, `VoxglassMac/`, `VoxglassWatch/`. This preserves N-1's real intent (length/device never gates the record action) while allowing the Mac to be *named*. Probe. | **U0** |
| **G4** | No `VoxglassMac` target exists in `project.yml`, so nothing compiles the tree, `swift test` cannot see it, and no scheme can run it. | `project.yml` — targets are `Voxglass`, `VoxglassWatch`, `VoxglassUITests`, `VoxglassCarPlaySmokeTests`, `VoxglassWatchUITests` | Add `VoxglassMac` (platform macOS, deps `VoxglassCore` + `VoxglassEncoders`, AVFoundation/StoreKit/CloudKit/libsqlite3) and `VoxglassMacUITests`; add the scheme with `storeKitConfiguration: Voxglass/Resources/VoxglassNarration.storekit`; `xcodegen generate`. **`PRODUCT_BUNDLE_IDENTIFIER: guru.parso.voxglass`** — see G5. | **U0** |

---

## 2. Universal Purchase and distribution

| # | Gap | Evidence | Fix | Stage |
|---|---|---|---|---|
| **G5** | The Mac bundle id must be **`guru.parso.voxglass`**, identical to iOS, for Universal Purchase. The deleted target used `guru.parso.voxglass.studio`, and a partial revert would restore it. This is **irreversible after the first sale**. | old `project.yml` at `c0c6712^`; spec §2.1 | Set it in the new target and add gate **G-U3** grepping `project.yml` for it. Cheapest possible guard against the most expensive possible mistake. | **U0** |
| **G6** | Two StoreKit concretes will exist: the shipping iOS one from P8 (`Voxglass/Features/Production/StoreKitLicenseProvider.swift`, `NarrationProStore.swift`, `ProPurchaseView.swift`) and the older resurrected Mac one. | both present in tree | **Delete the Mac copy; share the iOS one.** Universal Purchase grants entitlement per Apple ID across the shared app record, so `Transaction.currentEntitlements` already reports it everywhere — no platform-conditional code is needed. Keep the Mac copy only with a stated reason. | U9 |
| **G7** | `LicenseGatePlacementTests` permits three files. The Mac needs three more (destination picker, export runner, Settings) — and **nothing else**. | `current_status.md` records the test as shipping | Extend the permitted list; do not duplicate the test. Gate **G-U5**. | **U0** |
| **G8** | Universal Purchase is an App Store Connect policy this document's author cannot verify against current Apple documentation. | spec §2.1, open item O-2 | Re-read Apple's current guidance at submission; record in `RELEASE_CHECKLIST.md`. **The bundle-id choice stands regardless** — one record, one id, one purchase. | U9 |
| **G9** | D-2's pricing rationale ($49/$79) was explicitly *"an iPhone-only unlock"*. That premise is void. | revised SPEC §19 D-2 | **Product-owner decision, not code.** Open item O-1. Nothing in code depends on the number. | pre-submission |

---

## 3. The two-writer model — the only genuinely new engineering

| # | Gap | Evidence | Fix | Stage |
|---|---|---|---|---|
| **G10** | `Voxglass/Core/Production/Merge/` does not exist. | tree | New: `ProductionMerger`, `MergeConflict`, `ConflictSet`, `ResolutionPlan`. Implement **exactly** the rules table in spec §4.3.2 and add none. | U1 |
| **G11** | No stable per-install device identity exists in Core, and `Date()`/`UUID()` are only reachable through the `Clock`/`IDGenerator` seams. | `Core/Production/Domain/` | New `DeviceIdentity` seam. **A random per-install UUID; MUST NOT derive from any hardware identifier** (spec §18 privacy). | U1 |
| **G12** | Three merge columns are missing: `revision` on chapter and paragraph, `modified_by_device`, and `synced_text_hash` (the three-way common ancestor). | `Store/ProductionMigration.swift` | One append-only numbered migration, plus the `paragraph_conflict` table so conflicts survive relaunch. | U1 |
| **G13** | `ProductionSyncEngine`'s conflict path is **deliberately degraded** to adopt-server-tag-and-retry-once with the phone always winning (revised §4.2, M-2). | `Sync/ProductionSyncEngine.swift`, diffed at `c0c6712^..HEAD` | Un-degrade to **fetch-merge-push**. `SyncError.serverRecordChanged(recordName, changeTag, revision)` already carries everything the merge needs and does not change. `SyncTransport.fetchRecords` already exists (added post-P0). | U1 |
| **G14** | A shipping test asserts **no conflict UI is reachable**. It will fail the moment U2 lands, and deleting it would lose the coverage. | revised SPEC §4.2: *"A test MUST prove no user-visible conflict UI is reachable"* | **Invert it**, don't delete it: `ConflictReachabilityTests` asserts the surface *is* reachable from a two-device divergence fixture and that **no other** divergence reaches it. The second half is the valuable half. | U2 |
| **G15** | No conflict resolution UI on any platform. | tree | Mac screen (`mac-08`) + the same content as a sheet on iPhone/iPad. Three-way diff, per-side attribution, drift warning when a side has a selected take, Keep this / Keep both / Keep all. | U2 |
| **G16** | `IssueCode` has no `paragraphTextConflict`; `FixAction` has no "open conflict resolution". | `Validation/IssueCode.swift`, `FixAction.swift` | Add both. Severity **blocking-for-export**, not a quality failure — a user may keep recording with conflicts outstanding. | U2 |
| **G17** | No presence signal exists. | tree | `Core/Production/Presence/` + three projection fields. **Advisory only** — MUST NOT block, lock, or warn. 10-minute expiry. Small. | U2 |
| **G18** | Risk of conflating presence with `PackageLock`. They are different: presence is cross-device courtesy; `PackageLock` is a same-machine advisory lock against two processes over one SQLite file. | `VoxglassMac/Services/PackageLock.swift` (resurrected, correct as written) | Keep both, documented as distinct. Do not let one grow into the other. | U3 |

---

## 4. The resurrected macOS tree — per-file disposition

58 source + 19 test + 1 UI-test file, restored verbatim from `c0c6712^`, renamed directories only. Already Swift 6 (the deleted target set `SWIFT_VERSION: "6.0"`), which is why most of this is rework rather than rewrite.

### 4.1 Delete outright — 6 files

| File | Why |
|---|---|
| `Services/CaptureRingBuffer.swift` (219 lines, Swift) | **Superseded.** Core shipped a 57-line lock-free ring over the `VoxglassRing` C target in P4, with release/acquire atomics and a drop-count instead of blocking the real-time thread. Strictly better. |
| `VoxglassMacTests/CaptureRingBufferTests.swift` | Goes with its subject; Core's tests cover the replacement. |
| `Sync/StudioProjectionCoordinator.swift` | **Dead.** Implements Mac-as-sole-writer publishing to read-only consumers (Studio Spec §13). That model is not restored in either direction. |
| `Sync/StudioEventSink.swift` | Dead, same reason. |
| `VoxglassMacTests/StudioEventSinkTests.swift` | Goes with its subject. |
| `Sync/ProxyGenerator.swift` | Dead — proxy generation now lives in the phone-side relay and Core. |

**Recommended, needs confirmation (open item O-3):** `Features/DevicePreview/DevicePreviewModel.swift` + `DevicePreviewView.swift` (302 lines). They previewed how a project would look on phone/watch under Mac-as-writer. With peer writers, the "preview" is just the other device. If kept, they must not become a second read-only projection surface.

### 4.2 Rework — the three that are not mechanical

| # | File | Gap | Why it is hard |
|---|---|---|---|
| **G19** | `Services/AVAudioEngineCapture.swift` (756 lines) | Conform to today's `AudioCapturing` (gained `currentRouteInfo` and `onInterruption`); push samples through **Core's** ring buffer; feed `CaptureRouteClassifier` and `CaptureRecovery`. | The most valuable single file in the tree and the one with real-time constraints. The tap body must stay allocation-free, lock-free, `Task`-free, `os_log`-free, and `Date()`-free while its downstream changes. |
| **G20** | `Features/Export/ExportModel.swift` (569) + `ExportWizardView.swift` (488) | Predates `ResumableExportRunner`, `ExportPreflight`, `ExportPackageZipper`, export **scopes** (F-series gap closure), and hydration preflight — all of which shipped after the tree was deleted. | Keep the wizard's shape and its gate placement; **replace its engine wholesale**. Attempting to reconcile the old engine with the new one is the expensive wrong path. |
| **G21** | `Features/Record/RecordingModel.swift` (638) | **The silent one.** It constructs `Take(...)`. `warning:` and `routeClass:` now exist **with defaults**, so it compiles clean and records `.none` / `nil` on every Mac take. | Nothing fails, no warning fires, and `routeNotRetailReady` (§7.1) plus the whole interruption matrix (§7.4) are quietly dead on macOS. Surfaces months later at retail validation. **Brief the agent on this one explicitly.** |

### 4.3 Rework — mechanical, but each needs its Core seams re-pointed

| # | Files | What moved underneath them |
|---|---|---|
| **G22** | `App/StudioEnvironment.swift` (487) → `MacEnvironment` | The composition root. Must wire `ProductionAssetRepository`, `SQLiteProductionAssetRepository`, `CloudAssetUploader`, `AssetHydrationExecutor`, `ProductionEvictionExecutor`, `ProductionPowerPolicy`, `ResumableExportRunner`, `ExportPreflight`, `ChunkedRenderCoordinator`, `CaptureRouteClassifier`, `ProductionMerger` — **none of which existed** when it was written. |
| **G23** | `App/StudioApp.swift`, `StudioRootView.swift` | Become `WindowGroup`-per-project plus the full-app source-list sidebar (D-U3: Listen / My Books / Explore / Search / Narration). |
| **G24** | `Features/Assemble/*` | `AssemblySettings` gained `trimSilenceAtEdges` and `normalizeLoudness` (optional-with-computed-default, so again: compiles, silently absent from the UI). Must run under `ChunkedRenderCoordinator` rather than planning whole-book runs. |
| **G25** | `Services/AVChapterRenderer.swift`, `AVSegmentPlayer.swift`, `AVAudioDecoder.swift`, `AVMetricsCalculator.swift`, `ArtworkResizer.swift` | Sound AVFoundation concretes, but iOS grew its own equivalents in P4–P7. **Compare each against the iOS concrete and move what is genuinely identical into Core** — do not ship two copies of the same AVFoundation code. |
| **G26** | `Features/Validate/*`, `Metadata/*`, `Review/*`, `Script/*`, `TakeCompare/*`, `ImportAudio/*`, `SourceImport/*`, `NewProject/*`, `Dashboard/*` | Screen shapes are good and map onto the mockups. Each needs today's seams, `paragraphTextConflict` where relevant, and identifier alignment with `mockups/`. |
| **G27** | `Features/Discovery/*` | Needs ladder is Core and unchanged (N-4). Rename; check `StudioURLSessionFetcher` against the CI network allow-list (`guarded-tests` runs one). |
| **G28** | `Services/RecentsStore.swift` | Writes to `Application Support/guru.parso.voxglass.studio/recents.json`. Unlike the P0 entitlement keys, **this file was really written by local builds** — needs a one-time directory migration, not a bare rename. |
| **G29** | `Support/StudioUndo.swift`, `RenderCounter.swift`, `UITestFakes.swift` | Rename; align fakes with `VoxglassCoreTestSupport` rather than duplicating. `RenderCounter`'s budget was deleted in P0 — restore it **with** a test that asserts on it, or delete both. |
| **G30** | `Services/DiagnosticsBundle.swift` | Rename; verify it collects nothing the privacy note (§18) does not cover. |
| **G31** | `VoxglassMacTests/*` (19 files, incl. `RecordingFlowTests`, `AutosaveRecoveryTests`, `CaptureInterruptionTests`, `UndoTests`, `ExportResumeTests`, `ProjectLibraryModelTests`) | **Re-point these before writing any new test.** They are real coverage of the resurrected models and the cheapest possible check on whether each adaptation was correct. |

---

## 5. New surfaces — Mac, iPad, and the keyboard

| # | Gap | Fix | Stage |
|---|---|---|---|
| **G32** | No keyboard map. The deleted `StudioCommands.swift` had **10 shortcuts** and dispatched by `NotificationCenter` broadcast. Spec §8.2 specifies ~40, and a broadcast cannot address the right window when four books are open — which is the whole point of the Mac app. | `KeyboardShortcutMap` as **one declarative table in Core** (plain values, no AppKit/SwiftUI), a typed `MacCommand` enum routed to the focused window, key-repeat guard (`NSEvent.isARepeat`), and text-field-focus rules. `MacKeyboardMapTests` asserts no duplicate pair, no reserved-key collision, and a binding for every action in revised §9.2. | U4 |
| **G33** | Project library is Mac-as-writer shaped. | Rework `ProjectLibraryModel`/`View`: merge `RecentsStore` bookmarks with iCloud-registered projects, add per-project progress / blocking issues / conflicts / backup state / presence, Download for projects not local. | U7 |
| **G34** | No cross-project review queue. | New. One queue across stores; approving writes a `ReviewEvent` into that project's store through the existing fold. **Free** (§2.2). | U7 |
| **G35** | No batch export. `ProFeature.batchExport` exists and is unused. | New, sequential, union preflight before the Pro gate, failure isolated per project. **The batch runner is not a seventh gate site** — it routes each project's destination decision through `ExportModel` (SPEC §2.3), so a free lane cannot become gated by being run in a batch, and `LicenseGatePlacementTests` still permits exactly six files. | U7 |
| **G36** | No shortcut reference sheet. | Generate it from `KeyboardShortcutMap` so it cannot drift from the real bindings. | U4 |
| **G37** | **iPad**: no size-class routing. The app already *runs* on iPad (`TARGETED_DEVICE_FAMILY: "1,2"`, all four orientations, `UIApplicationSupportsMultipleScenes: true`) — **this is a layout gap, not an availability gap.** | `Adaptive/NarrationLayoutRouter`: compact → the shipping iPhone flow unchanged; regular → `NavigationSplitView`. **One** decision point, not a per-screen fork. A size-class change MUST NOT interrupt an in-flight take. | U8 |
| **G38** | iPad has no regular-width layout and no hardware-keyboard handling. | Sidebar / content / detail; apply the non-`menuOnly` entries of the shared map via `.keyboardShortcut`. | U8 |

---

## 6. Already satisfied — no work required

Confirmed present in the tree. Listed so the agent does not rebuild them.

| Area | Evidence |
|---|---|
| Core builds for macOS | `Package.swift`: `platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10)]` |
| iPad availability | `project.yml`: `TARGETED_DEVICE_FAMILY: "1,2"`, four orientations, multiple scenes enabled |
| Mac entitlements | Restored `.entitlements` already has sandbox, `device.audio-input`, `files.user-selected.read-write`, `files.bookmarks.app-scope`, `network.client`, `icloud-services: CloudKit`, container `iCloud.guru.parso.voxglass` |
| iCloud offload, upload/verify/hydrate, eviction | Whole `CloudAssets/` area shipped post-deletion — repository, SQLite repository, uploader, hydration executor, eviction executor, power policy. **The Mac gets this for free.** |
| Resumable export, preflight, zipping, scopes | `ResumableExportRunner`, `ExportPreflight`, `ExportPackageZipper` + F-series scope work |
| Chunked cancellable rendering | `Assembly/ChunkedRenderCoordinator.swift` |
| Route classification, capture warnings, recovery | `Audio/CaptureRouteClassifier`, `CaptureRouteInfo`, `CaptureWarning`, `CaptureRecovery`, `WAVFormatReader`; `Take.warning` / `Take.routeClass` columns |
| Lock-free capture ring | `Audio/CaptureRingBuffer.swift` over the `VoxglassRing` C target |
| Pro product identity | `NarrationProProduct.productID` / `.displayName`, single source; price correctly absent from code |
| Transport primitives the merge needs | `SyncTransport.fetchRecords`, `SyncError.serverRecordChanged(_, _, revision)`, `SyncError: LocalizedError` |
| Watch companion | Unchanged; D-U4 means no Mac↔Watch work at all |

---

## 7. Testing, CI, and process

| # | Gap | Fix | Stage |
|---|---|---|---|
| **G39** | `AccessibilityAuditTests` parses **only** `docs/iphone-watch-only-revised-mvp/mockups` as the identifier contract. The new Mac/iPad mockups are therefore a design contract but not a test-enforced one. | Extend it to `docs/mac-ipad-universal-mvp/mockups`, resolving Mac ids against `VoxglassMac/` and iPad ids against `Voxglass/Features/Production/`. **Do this in U0**, before the ids have a chance to drift. | **U0** |
| **G40** | CI has no macOS build. The `build-mac` job was deleted in P0; the `compile` job builds iOS and watchOS only. | Add a macOS build step to `compile` (`runs-on: macos-latest`). **Needs no simulator and no signing** — it is the cheapest catch for the most common breakage. CI still boots no simulator. | **U0** |
| **G41** | Two UI smoke tests (iPhone, Watch), both local pre-commit. No Mac smoke test. | Add a third. Its distinguishing requirement: **drive the record loop from the keyboard only** (`⌘R`, `⌘⏎`, `⌘→`) — a Mac smoke test that clicks buttons tests nothing this MVP added. Stays local (signing). Gotchas: terminate the app between runs or `PackageLock` reports the project already open; `NSOpenPanel` cannot be driven from a UI test, so the fixture path must be injectable; seeders idempotent. | U9 |

---

## 8. Sequencing and risk

**Dependency order.** U0 unblocks everything. U1 → U2 are the merge chain. U3 → U4 → U5 → U6 → U7 are the Mac chain and depend on U0 only. U8 (iPad) depends on U2 for the conflict sheet and on U4 for the shared map, and is otherwise independent. U9 closes.

**The three stages worth reviewing closely:**

| Stage | Why |
|---|---|
| **U0** | Touches every gate in the repo. A gate weakened as a side effect is a silent loss of a real invariant. Every amended gate needs its `test_guards.sh` probe re-proven, not just re-run. |
| **U1** | The merge model is where a wrong turn is most expensive to unwind, because it writes to users' CloudKit records. The self-merge-is-a-no-op property test catches most merge bugs and should be written first, not last. |
| **U5** | G21 — the silent `Take` defaults. This is the stage where "it compiles and the tests pass" is not evidence of correctness. Require the agent to show a Mac-recorded take with a non-nil `routeClass`. |

**Risks not covered by any gate:**

- **A platform-conditional tier.** "Free on iPhone, Pro on Mac" for the same lane cannot be grepped for. It is stated in spec §1.4 and §2.3 and must be caught in review.
- **Duplicate AVFoundation code** (G25). Two copies will compile happily and drift silently.
- **Scope creep in the merge table.** Spec §4.3.2 says implement exactly those rules and add none. Every additional "smart" merge rule is a new conflict case and a new test matrix.

---

## 9. What is explicitly *not* a gap

- **Mac↔Watch anything.** Decision D-U4. Watch review of Mac-recorded work already flows iCloud → phone → watch.
- **Production CarPlay.** M-5, unchanged.
- **iPhone→Mac handoff.** N-1 stands: length and device never gate the record action. Gate G-U1 enforces the phrasing.
- **A second project model, package format, or CloudKit record type.** R2-1, R2-2, R2-3.
- **iPad multiple scenes, Apple Pencil notes, customizable shortcuts.** All MAY or DEFERRED (spec §19.2).
