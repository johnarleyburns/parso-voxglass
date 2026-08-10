# Agent brief — close the revised-MVP gaps (F1–F8)

Paste the block below as the opening prompt for a coding agent working in
`/Users/arley/github/parso-voxglass`.

---

## The prompt

You are closing a set of identified gaps in an existing Swift/SwiftUI repository.
The MVP is already implemented and shipping: stages P0–P9 all landed, `swift test`
is green (1309 tests / 186 suites), and `scripts/guard_production.sh` passes. Your
job is **not** to rebuild anything. It is to close thirteen specific, already-
diagnosed gaps, stage by stage, without re-deriving decisions.

### Source of truth

Two documents, in this order:

1. **`docs/iphone-watch-only-revised-mvp/GAP_ANALYSIS.md`** — the diagnosis. Each
   gap **G1–G13** carries its spec citation, the evidence, and file:line
   references. This is what you are fixing.
2. **`docs/iphone-watch-only-revised-mvp/SPEC.md`** — normative for *what correct
   looks like*. When the analysis cites §13.2 or §16.4, read that section before
   writing code.

`docs/iphone-watch-only-revised-mvp/AGENT_BRIEF.md` is the original build brief.
Its **"Repository conventions"** and **"Hard constraints"** sections still bind
you in full — re-read both before your first edit. In particular: XcodeGen from
`project.yml` (never hand-edit the `.xcodeproj`); no GRDB; `@Observable` only;
`Date()`/`UUID()` only through the `Clock`/`IDGenerator` seams; Core stays free of
CloudKit and StoreKit; the watch never links CloudKit; Swift 6 language mode with
complete strict concurrency and **no** new warnings, suppressions, or escape
hatches (`CLAUDE.md`).

### Two decisions already taken — do not reopen

- **D-G1 — for the identifier drift (G1), the mockups follow the app.** Regenerate
  the mockup `id` attributes from the shipped `.accessibilityIdentifier` values.
  Do **not** rename shipping identifiers to match the mockups. Rationale: the
  original brief states that shipping identifiers "are preserved deliberately
  because the UI smoke tests key on them", and its conflict rule is that when
  spec and repository disagree on a *fact* (a name), the repository wins. The one
  exception is a mockup id whose control does not exist at all — that is a
  missing control (G11/G12/G13), not a naming problem, and it gets built.
- **D-G2 — the coarse Pro gate stays.** Only `.retailPresets` has a call site,
  guarding any retail destination; the other `ProFeature` cases are transitively
  gated because they are reachable only through a retail destination. The
  "Observation" section of the analysis explains why this is correct. Do not add
  per-feature gate call sites — §2.2 caps `LicenseGate` at three locations.

### Working method

**One stage per commit. Stop after each stage and report.** Do not chain F1 → F8
in one run. Imperative commit subject; the body names the gap(s) closed and the
acceptance criterion met.

For each stage: read the gap entry in `GAP_ANALYSIS.md` → read the cited spec
section → read the existing code at the cited file:line → make the change → run
the gates → commit → report what passed and what you chose.

If a stage's acceptance criterion cannot be met, **stop and report**. Do not
weaken it, do not mark the stage done, do not proceed.

If the analysis and the repository disagree on a fact, the **repository wins** —
report the discrepancy in your stage report. The analysis was written against
`ec231de`; if HEAD has moved, re-verify before trusting a line number.

### Verifying your work

```
swift test                        # Core suites — what CI runs
scripts/test_logic.sh             # Core + performance budgets
scripts/guard_production.sh       # CI grep gates
scripts/test_guards.sh            # proves each gate can fail
scripts/test.sh --all             # UI smoke tests: LOCAL pre-commit gate only
```

**CI runs no simulator.** Do not add anything to CI that needs one.

**Git hook timeouts (`CLAUDE.md`):** allow **at least 25 minutes (1500 s)** for
`git commit` — the pre-commit hook runs the wiring guards, logic tests, and
simulator UI smoke tests. Allow ~2 minutes for `git push`.

Watch UI test gotchas that have already cost this repo time: row taps need
`.contentShape`; sheets are **not** `NavigationPath` destinations; the simulator
must be pre-booted; build first then `test-without-building`; seeders must be
idempotent.

Do not push and do not open a PR unless asked.

---

## The stages

Ordered so that stages which create new identifiers land **before** the stage that
reconciles identifiers (F3). Do not reorder F1 and F3.

### F1 — Export scopes and the hydration choice (**G11**)

The highest-value gap: `ExportScope` exists in Core but is never referenced in
`Voxglass/Features/`, so every export is whole-book. LibriVox's real workflow
posts one section at a time — `Packaging/ExportTypes.swift:7` says so in its own
doc comment — which makes single-chapter export a requirement of the *free*
primary lane, not a nicety.

Build, per **§13.1 step 1** and **§13.2**:

- A scope picker on the export wizard (mockup `14-export-wizard-free.html`) with
  the four spec'd scopes: current chapter · selected chapters · whole book ·
  review-queue range. Map each onto the existing `ExportScope` — `.wholeBook` or
  `.chapters([UUID])`. **Do not add cases to `ExportScope`** unless a scope
  genuinely cannot be expressed; if you believe one cannot, stop and report
  rather than widening the Core enum.
- Thread the chosen scope into `ExportOptions.scope` at
  `NarrationFlow.swift:1739` and into **both** preflight call sites, which
  currently hardcode `scope: .wholeBook` (`NarrationFlow.swift:1663` and `:1692`).
- The three-way hydration choice §13.2 requires: export only local chapters ·
  hydrate all · cancel. Byte totals must be stated (§13.2's "12 chapters are in
  iCloud. Download 3.4 GB to export."). `ProductionHydrationPlanner` already
  builds the plan and `paragraphList.hydrate` already exists as a per-paragraph
  affordance — this is the export-level equivalent.

Constraints: free destinations MUST NOT touch `LicenseGate` at any step (§13.1,
gate G-P2). Scope selection is not a Pro feature.

**Acceptance:** a fixture project exports a single chapter to LibriVox and the
package contains exactly that section; a whole-book export is unchanged from
today's output; preflight byte estimates reflect the chosen scope, not the whole
book; `swift test` and all guards green. Add scope coverage to the export tests.

---

### F2 — Restore the two missing test/gate enforcements (**G2**, **G3**)

Both are mandated by the spec and both are mechanical.

**G2 — `LicenseGatePlacementTests`.** §2.2 specifies it verbatim: grep the source
set for `LicenseGate`/`isPro` references outside the permitted files and fail on
any other occurrence. §2.2 also says **extend the existing suite, do not add a new
one** — so it goes in `VoxglassTests/Production/License/LicenseGateTests.swift`.
Today that file's doc comment defers placement proof to "`ExportModelTests`
(Studio)", a suite deleted in P0; fix the comment too. The permitted set is the
export destination picker, the export runner, and Settings — as of `ec231de`
that is `Discovery/NarrationFlowScreens.swift`, `Discovery/NarrationFlow.swift`,
`Features/Settings/SettingsView.swift`, plus the StoreKit concrete
(`StoreKitLicenseProvider.swift`, `NarrationProStore.swift`, `ProPurchaseView.swift`).
Encode the permitted list explicitly so a new file cannot silently join it.

Do not stop and report over the count. §2.2 says "three permitted files" and the
list above has six; that is not a contradiction. §2.2 was written before any
StoreKit concrete existed (§13.5 adds it in P8), and the provider/purchase files
are the entitlement *mechanism* — they supply the entitlement rather than consult
a gate to gate a feature. The three *surfaces* §2.2 names are unchanged.

While here: gate **G-2** in `scripts/guard_production.sh` still names
`StudioEnvironment` in its `allowed` filename list — a P0 casualty. Remove it.

**G3 — a failability probe for the watch/CloudKit gate.** §16.4 requires "Every
gate MUST have a matching entry in `scripts/test_guards.sh` proving it can fail."
G-W1 is satisfied by the pre-existing **G-5** (`guard_production.sh:117`), which
has no probe. Add one following the existing `expect_guard_fails` /
`expect_guard_passes` pattern.

**Acceptance:** the placement test fails when a `LicenseGate` reference is added
to a non-permitted production file and passes on the clean tree; `test_guards.sh`
green with the new G-5 probe; `guard_production.sh` still green after the G-2
allow-list edit.

---

### F3 — Reconcile the mockup identifier contract (**G1**)

Per **D-G1: the mockups move, the app does not.**

Method — for each of the 24 mockup pages, walk every `id` attribute and classify:

1. **Matches a shipped identifier** (literally, or as an instance of a template
   prefix such as `script.row.`) → leave it alone. Eight pages (04, 06b, 06c, 08,
   09, 14c, watch-04, and after F1 likely 14) are already clean.
2. **Naming drift — the control exists under a different name** → rewrite the
   mockup `id` to the shipped name. Verified examples in the analysis: mockup
   `storage.limit` → `storage.workingCacheLimit`; `watch.playPause` →
   `player.playPause` (the watch names come from the
   `ProductionWatchAccessibility` constants, not literals — resolve through that
   file); `record.compareTakes` → `record.take.compare`; `record.importAudio` →
   `record.take.import`.
3. **Template-scheme drift** → rewrite the mockup to the app's scheme. Mockups use
   positional rows (`needs.row.0`, `myNarrations.row.0`, `import.chapter.0`); the
   app builds slugs (`needs.card.\(needSlug(need))`,
   `myNarrations.project.\(…)`). Show a representative rendered instance in the
   mockup and note the template form in a comment.
4. **No such control exists** → do **not** invent a mockup id and do **not**
   silently delete it. These belong to F1 (`export.scope.*`, `export.hydrateAll`,
   `export.localOnly`), F5 (`wizard.*`, `settings.audioSetup`), or are genuine
   findings you should report. `validation.exportReport`, `assemble.renderChapter`,
   `metadata.replaceArtwork`, `import.resegment`, `import.markSceneBreak`,
   `import.ignoreWarnings`, `storage.downloadAll`, `storage.clearWatch`,
   `storage.offloadVerified`, `storage.chapters`, `watch.cache`, `watch.outbox`,
   `watch.retrySync` were **not** individually triaged by the analysis — classify
   each yourself and report which turned out to be class 2 versus class 4. Do not
   assume.

Then close the loop so this cannot recur: repoint
`VoxglassTests/Production/AccessibilityAuditTests.swift` at the revised-MVP
mockup ids. Today it enforces the **Studio-era §22.1 registry** inherited from
`VOXGLASS_STUDIO_SPEC.md`, which is why the drift went unnoticed while the suite
stayed green. Prefer parsing the mockup HTML over hand-copying a list — a
hand-copied registry is the thing that just failed.

Finally, re-derive the identifier citations in the three walkthroughs
(`walkthroughs/W1-LibriVox-free.md`, `W2`, `W3`). W-1 currently names
`export.destination.librivox`, `validation.destination.librivox`, and
`import.acceptStructure`; the app ships `validation.destination`. These documents
are executed by a human tapping visible UI, so they are imprecise rather than
blocked — but they cannot be signed off while they cite names that do not exist.

**Acceptance:** every mockup `id` either resolves to a shipped identifier or is
explicitly listed as pending a named stage; the repointed audit test fails when a
mockup id is changed without the app changing; all guards green. Do not modify
any `.accessibilityIdentifier` in app source during this stage.

---

### F4 — Bring the iPhone smoke test up to its specified scope, and make it verify exported files (**G4**)

§16.3 test 1 specifies: "Narration tab → create a project from a need → record
**two** paragraphs with the fake capture → review → validate → LibriVox export
path. Folds in My Narrations reachability."

`VoxglassUITests.swift` today records **one** paragraph, asserts `record.take.1`
and that `record.acceptAndNext` is enabled, then closes the flow (line 160) and
moves on to Search and the EQ. The My Narrations leg (lines 72–95) is present but
runs against the **seeded** `ProductionSmokeSeed` project and only asserts
`detail.reviewFlagged` *exists* rather than exercising it.

Extend it to cover the second paragraph, the review leg on the project the test
just created, validation, and the LibriVox export path. Since CI runs no
simulator, this local gate is the only automated end-to-end coverage of that path.

#### The export leg must verify the produced files

Reaching the export screen is not enough, and this is the most important part of
the stage. **The test must drive a real LibriVox export through the UI and then
assert on the bytes the app actually wrote.**

Understand why before you implement it. The Core suite already verifies artifacts
thoroughly — `ExportEndToEndTests.swift:49` asserts
`MP3FrameParser.verifies(data:expectedKbps: 128, sampleRateHz: 44_100, mono: true)`,
plus ID3 tags, `checksums.sha256`, the checklist and `metadata.json` — but it does
so by calling `LibriVoxPackageBuilder().build(…)` **directly**, with `ExportOptions`
constructed inside the test. Line 99 of that file,
`singleChapterScopeExportsOneFile`, passes `scope: .chapters([chapterID])` straight
into the builder and proves the builder honors scope — while the shipped app never
passes anything but `.wholeBook`, and every test stayed green. That is exactly how
**G11** survived. Core tests prove the engine; nothing covers the wiring between
the UI and the engine, which is where the real defects are.

Minimum assertions on the exported package, mirroring §16.5 M-9 and the Core
suite's own bar:

- one MP3 per exported section, named per the LibriVox filename rules;
- each verifies as **128 kbps CBR / 44.1 kHz / mono** via `MP3FrameParser.verifies`;
- ID3 tags carry the project's title / author / album / track numbers;
- `checksums.sha256` is present and its digests match the files on disk;
- the generated checklist and `metadata.json` are present.

After **F1**, extend this to the scope dimension: export a **single chapter** and
assert the package contains exactly that section. This is the assertion that would
have caught G11, so do not skip it.

Mechanism is your call — report which you chose and why:

- **Preferred:** the test reads the written package and parses it itself. Note
  `VoxglassUITests` currently depends only on the `Voxglass` app target
  (`project.yml`), so using `MP3FrameParser` means adding `VoxglassCore` as a
  dependency — via `project.yml` + `xcodegen generate`, **never** by hand-editing
  the `.xcodeproj`. Getting the file to a location both processes can see will
  likely need a launch-argument hook that redirects the export destination; the
  app already has this pattern (`-uiTestResetNarrations`, `-uiTestSeed`,
  `-uiTestExerciseArtworkOffMain` — see `AppServices.swift:175–190`).
- **Acceptable fallback:** if cross-process file access proves unworkable on the
  simulator, have the app verify its own output under a UI-test launch argument
  and surface the result through an accessibility element the test asserts on.
  If you take this path, it **MUST** parse the actual output bytes with
  `MP3FrameParser` — echoing back the requested encoder settings is not
  verification and will be rejected.
- **Not acceptable:** asserting only that an export completed, a success screen
  appeared, or a file exists at a path.

Respect the watch/UI-test gotchas listed above, and keep the target at exactly one
test — the repo deliberately has one smoke test per device. Any new launch
argument must be inert in normal runs and must not alter the export path's
behavior beyond where output is written.

**Acceptance:** `scripts/test.sh --all` green with the extended path, including
the artifact assertions above; deliberately corrupting the export (e.g. forcing
192 kbps) makes the test fail — demonstrate this once, as the guard probes do,
and state it in your report. Budget real time: the pre-commit hook runs this
suite, so the commit itself takes ~25 minutes.

---

### F5 — Project purpose and the Settings entry point (**G12**, **G13**)

**G12 — purpose is hardcoded.** `ProjectPurpose`
(`Domain/AudiobookProject.swift:5`) has three cases; the only creation site,
`NarrationFlow.swift:555`, writes `.publicDomainCommunity` unconditionally, and
no UI ever sets it. Mockup `02-new-project.html` specifies the picker
(`wizard.purpose.librivox` / `.internetArchive` / `.commercial` / `.personal`)
alongside `wizard.title`, `wizard.author`, `wizard.narrator`, `wizard.sourceURL`,
`wizard.attest`, `wizard.continueToImport` — none of which exist as identifiers
today, though the flow does collect title/author somewhere. Reconcile the new-
project step against that mockup: collect the fields, let the user choose the
purpose, and persist it.

Note what this does **not** do: `purpose` does not gate destinations (it appears
nowhere in `EligibilityProfile`), and the retail gate is `rights.isAttested` plus
the `.retailPresets` license check. **Do not** make `purpose` gate anything —
that would be a new product rule, and per D-G2 the gate count is fixed at three.
This stage makes a dead field honest; it does not change eligibility.

**G13 — Audio Setup from Settings.** §15.4 row 06b names the entry points as
"recording toolbar, Settings". `AudioSetupView` is presented from the recording
screen (`NarrationFlowScreens.swift:188`) and the destination picker (line 1354),
but the Narration group in `SettingsView.swift:36` has only `NarrationProCard` and
`StorageSettingsView`. Add the row, with the identifier mockup 15 declares.

**Acceptance:** a project created through the flow carries the purpose the user
chose and it round-trips through SQLite, the package manifest, and the CloudKit
projection; Audio Setup opens from Settings; the smoke test still passes.

---

### F6 — External recording controls and project portability (**G5**, **G7**)

**G5 — §9.3 external controls.** Two of three bullets are unimplemented. The
watch remote ships; these do not:

- Hardware keyboard shortcuts when a keyboard is connected. `keyboardShortcut`,
  `KeyEquivalent`, `UIKeyCommand`, and `onKeyPress` currently return **zero** hits
  across `Voxglass/`.
- Bluetooth media button / headset stem mapped to Record/Stop — and **only when
  armed**, so a stray press cannot start a take. `MPRemoteCommandCenter` is
  currently claimed only by consumer playback and CarPlay
  (`PlaybackPlatformBridge`, `CarPlayReviewController`).

Hard constraint from the original brief: **do not degrade listening.** Whatever
you do with the remote command centre must not disturb the consumer player's
claim on it outside an armed recording session, and must restore it cleanly.
Losing a user's playback position is a hard product failure.

**G7 — §4.4 "Save a copy".** The project tree is unbrowsable by design and
portability is specified to run through Files: "Save a copy" writes the
`.voxproject` package, zipped on iOS. No such action exists anywhere. Export zip
+ `ShareLink` already works (`ExportPackageZipper.zipContents` →
`NarrationFlowScreens.swift:1953`) — reuse that machinery for the *project*
package. Today there is no user-facing route to a project backup or to moving a
project between devices outside iCloud.

**Acceptance:** a take can be started and stopped from a connected keyboard and
from a headset stem while armed, and a stem press while idle does nothing;
consumer playback still owns the remote commands before and after a session; a
saved `.voxproject` copy re-imports into a working project.

---

### F7 — Progressive source parsing (**G6**)

The largest single item; it needs a new Core API, so treat it as its own stage.

§8.2: "Large documents parse **progressively**, with a preview available before
the parse completes. The import screen MUST NOT block on a full parse of a
400-page EPUB."

Today `NarrationFlow.swift:2191 importFile(_:)` sets `model.isImporting = true`,
awaits `importer.extract(from: url)` to completion, then builds the project — no
incremental yield, no preview, and no cancel. The cancel-less spinner also brushes
§15.3 rule 3 ("no screen may show an indefinite spinner without a cancel or
retry"). `Core/Production/Text/` exposes no streaming API — no `AsyncStream`, no
`yield` — so this is a Core + UI change.

Add the streaming seam in `Core/Production/Text/` and consume it in the import
screen with a live preview and a working cancel. Keep the existing synchronous
`extract(from:)` working — other call sites and tests depend on it.

**Acceptance:** a large fixture EPUB shows chapter structure before the parse
finishes, cancel actually stops the work, and the resulting project is identical
to what the synchronous path produces for the same input. Existing
`ImporterTests` stay green.

---

### F8 — Documentation trivia (**G8**, **G9**, **G10**)

Small, independent, one commit.

- **G8** — §13.4 says prefer `.zip` but *also* support "Save folder to Files"
  where the system destination accepts directories. Only the zip path exists.
- **G9** — `docs/voxglass-mvp/RELEASE_CHECKLIST.md:68` still requires
  `scripts/capture_studio_screenshots.sh`, deleted with the Mac tree in P0. The
  checklist line is currently unsatisfiable. Remove or replace it.
- **G10** — stale "Mac" doc comments outside G-P5's guarded directories, e.g.
  `VoxglassTests/Production/Sync/SyncConflictTests.swift:16` ("A competing Mac
  already published revision 2"). The behavior under test is the correct
  phone-as-writer degradation; only the prose is stale. Consider whether G-P5's
  scope should widen to `VoxglassTests/Production/**` — if you widen it, add the
  matching `test_guards.sh` probe (§16.4).

**Acceptance:** all guards green; no reference to a deleted script or a deleted
platform survives in the docs you touched.

---

## Out of scope

Do not attempt these; they are human/process gates, recorded in the analysis so
they are not mistaken for code gaps:

- The §16.5 manual hardware matrix (M-1…M-14) — human-executed on device.
- Executing the three §16.6 walkthroughs on real hardware. F3 fixes their
  identifier citations; a human still runs them.
- The encoder build from a clean checkout with iOS device + simulator + watchOS
  slices.
- D-2 pricing ($49 / $79) — an App Store Connect value, correctly absent from
  code.

Destination re-verification is **already done** (`DESTINATION_VERIFICATION_LOG.md`
carries a 2026-08-09 row covering items 1–6); do not redo it.

### Start here

Begin with **F1**. Before editing, reply with:

- your reading of how the four §13.2 scopes map onto the existing `ExportScope`
  cases, and whether any of them cannot be expressed without widening the enum;
- how you intend to thread scope through the two hardcoded preflight call sites;
- where the hydrate / local-only / cancel choice belongs in the existing wizard;
- anything in `GAP_ANALYSIS.md` you believe is wrong, now that you have read the
  code yourself.

Then implement it, run the gates, commit, and stop.
