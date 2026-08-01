# S1–S5 spec-conformance follow-on

**For the implementing agent.** Companion to `current_status.md`. That document covers the S5
audio path (ReplayGain, metrics, capture, recording flow) as tasks **T1–T10**. This document
covers everything else needed to bring S1–S5 in sync with
`docs/voxglass-mvp/VOXGLASS_STUDIO_SPEC.md` before S6 starts, numbered **T11 onward** so the two
files form one continuous task list.

**Do T11–T15 first.** They are not "spec drift" — they are the reason the drift went unnoticed.
Until they are fixed, no green signal from this repo means anything.

**In-flight work.** T1/T3 (ReplayGain rewrite + tests) were being edited while this audit ran;
`ReplayGainCalculator.swift`, `ReplayGainCoefficients.swift`, `DirectFormFilter.swift` and
`ReplayGainTests.swift` reflect partial T1/T3 progress. T30 is a correction to that work. Nothing
else in this document overlaps `current_status.md`.

**Audit method.** Findings marked *(measured)* were reproduced by running the code or the tool
named. Findings marked *(read)* come from reading the source against the spec section cited.
Coverage was: §4 (architecture, concurrency, gates), §5 (domain, sampled), §6 (package + asset
store, full), §7 (persistence, full), §8 (lifecycle, wiring), **§9–§10 (text pipeline, line-audited
— see P1b)**, §11 non-audio, §19 (test topology + CI gates).

---

# P0 — Nothing is verified until these are fixed

## T11 — The test target does not compile *(measured)*

`swift test` fails with `error: fatalError`. `swift build --build-tests` shows the cause: **every
error is in one file**, `VoxglassTests/Production/Assembly/SegmentQueueTests.swift`:

```
:29:34  incorrect argument label (have 'chapters:paragraphsPer:records:', expected '…:allRecorded:')
:70:23  cannot find 'makeSceneBreakProject' in scope
:90,112,122  cannot find 'makeProjectWithReviewState' in scope
:112,117,122,127  cannot infer contextual base in reference to member 'flagged' / 'needsPickup'
:135:5  cannot find 'records' in scope        // `records: [Int](0..<(chapters * paragraphsPer))`
:135:12 consecutive statements on a line must be separated by ';'
:138,207,227,248  attribute 'private' can only be used in a non-local scope
:252:1  expected '}' at end of brace statement
```

Line 135 is a fragment of a function call left outside any function, which unbalances the braces
for the rest of the file.

**Consequence: no test in this repository has run.** `swift build` succeeds because it builds the
library only. Every S1–S4 suite listed as passing in the stage plan is unverified.

**Verified:** with that one file moved aside, the rest of the suite compiles and runs, and only
the two in-flight ReplayGain tests fail (T30).

**Do:** `SegmentQueueTests.swift` is an S6 test written ahead of its stage against a
`SegmentQueueBuilder` API that has since changed. Either repair it against the current
`Voxglass/Core/Production/Assembly/SegmentQueueBuilder.swift` signature, or delete it and
re-add it in S6. **Deleting is the better call** — see T29.

**Done when:** `swift test` exits 0 with every suite reported.

## T12 — `scripts/guard_production.sh` always passes *(measured)*

The script prints **23 G-7 violations to stderr and then prints `all guards passed` and exits 0.**

Cause: every check uses

```bash
echo "$matches" | while read -r line; do violate "..."; done
```

The pipe runs the `while` body in a subshell, so `VIOLATIONS=$((VIOLATIONS + 1))` inside
`violate()` increments a copy that is discarded. The counter is always 0 at the exit check.

**All seven implemented gates are decorative.** G-1 (no synthesis symbols), G-2 (Pro-gate
placement), G-3 (no `ObservableObject`), G-4 (no `Hasher` in caching code), G-5 (watch/CloudKit
isolation), G-7 (determinism seams), G-9 (no test support in shipping targets) can all be
violated freely.

**Do:** replace the pipe with a here-string (`while read -r line; do … done <<< "$matches"`) or
a process-substitution redirect, so `violate` runs in the parent shell. Then fix the violations
it starts reporting (T20).

Also: the spec (§19) calls for twelve gates. G-6 is a commented-out placeholder
("Skipped until LibriVoxPackageBuilder exists" — fine for now, but it must be a tracked TODO, not
a silent absence) and **G-8 is absent entirely, with no comment**. Reconcile the script against
the spec's gate list and leave an explicit `# G-N: deferred until S<n>` line for each one not yet
implemented, so absence is visible.

**Done when:** `bash scripts/guard_production.sh` exits non-zero on a deliberately introduced
violation of each implemented gate.

## T13 — Half the S5 Studio code is not in the Xcode project *(measured)*

`xcodegen generate` has not been re-run since these files were added. They appear in no target
and **have never been compiled**:

```
VoxglassStudio/Features/Record/RecordingModel.swift
VoxglassStudio/Features/Record/RecordingMeter.swift
VoxglassStudio/Features/Record/RecordingWorkspaceView.swift
VoxglassStudio/Services/AVAudioEngineCapture.swift
VoxglassStudio/Services/AVMetricsCalculator.swift
```

`project.yml` lists the whole `VoxglassStudio` directory as sources, so regenerating picks them
up; the checked-out `project.pbxproj` is simply stale (it has 419 uncommitted added lines but
predates the Record feature).

This is why `xcodebuild -scheme VoxglassStudio` reports **BUILD SUCCEEDED** while
`RecordingModel.swift:36` calls `store.loadProject(projectID)` — **a method that exists on no
type in the repository.** `ProductionStore` declares `load()`; the only `loadProject` is a
`private` method on `SQLiteProductionStore` with a different signature.

**Do:** run `xcodegen generate`, then fix the compile errors that surface. Expect
`store.loadProject(projectID)` to be the first of several. Add a CI step that runs
`xcodegen generate` and fails if `project.pbxproj` changes, so this cannot recur.

Note: `VoxglassTests/Production/**` is *correctly* absent from the pbxproj — `VoxglassTests` is
the SwiftPM test target (`Package.swift`, `path: "VoxglassTests"`) and runs under `swift test`.
Only the `VoxglassStudio` files above are orphaned.

**Done when:** `xcodebuild -scheme VoxglassStudio build` succeeds *with* those five files
compiled, and a clean `xcodegen generate` leaves the working tree unchanged.

## T14 — `upsertChapter` and `upsertParagraph` delete data and write nothing *(read)*

`Voxglass/Core/Production/Store/SQLiteProductionStore.swift:99-108`:

```swift
public func upsertChapter(_ chapter: ProductionChapter) async throws {
    try await db.prepare()
    try await db.execute("DELETE FROM chapter WHERE id = ?", [.string(chapter.id.uuidString)])
    try await db.prepare()          // ← and that is the whole method
}

public func upsertParagraph(_ paragraph: Paragraph) async throws {
    try await db.prepare()
    try await db.execute("DELETE FROM paragraph WHERE id = ?", [.string(paragraph.id.uuidString)])
}
```

Both delete the row and never insert. With `ON DELETE CASCADE` from `paragraph` → `chapter` and
`take` → `paragraph`, **`upsertChapter` destroys every paragraph and every take in that chapter**,
and `upsertParagraph` destroys every take on that paragraph.

These are the spec's designated hot-path mutations (§7.5: "granular … must not rewrite the whole
project"), so the moment any editing UI is wired to them, saving a chapter title deletes the
chapter's recordings.

`ProductionStoreTests` contains **zero** references to `upsert` — which is why this survived.

**Do:** implement both as real upserts (`INSERT … ON CONFLICT(id) DO UPDATE SET …`), covering
every column in the §7.3 schema. Add tests: upsert an existing chapter with a changed title and
assert paragraph count and take count are unchanged.

**Done when:** a test that records a take, upserts its chapter and paragraph, and re-reads
`counts()` shows the take still present.

## T15 — The library, wizard, and source import never touch a `.voxproject` *(read)*

`VoxglassStudio/Features/Library/ProjectLibraryModel.swift:69-79`:

```swift
let storeJSON = url.appendingPathComponent("Store").appendingPathComponent("project.json")
guard fm.fileExists(atPath: storeJSON.path) else { throw ProjectLibraryError.projectJSONNotFound(url) }
return try JSONDecoder().decode(AudiobookProject.self, from: data)
```

There is no `Store/project.json` anywhere in the §4.7 package layout. A project created by
`ProjectPackage.create` has `manifest.json` and `project.sqlite`. **`openProject` therefore throws
for every real project**, and `seedIfNeeded` (lines 88-106) writes the same fictional file, so the
UI-test seed does not produce a real package either.

Compounding it:

- `newProject` (line 46) builds an `AudiobookProject` in memory and **never calls
  `ProjectPackage.create`**. Nothing is written to disk. `NewProjectModel.createProject` just
  forwards to it. The S4 acceptance criterion — "a project created by the wizard opens cleanly
  after relaunch" — cannot pass.
- `openProject` decodes the project and then discards it: `_ = project` (line 40).
- Spec §6.3 requires the library list to read **only `manifest.json`** ("Listing 200 projects must
  not open 200 SQLite databases", budget < 500 ms). There is no listing at all — only a recents
  array.
- `SourceImportModel.applyToProject` (line 35) assigns `updated.chapters = result.chapters` and
  calls `env.setProject(updated)`. It **never calls `store.save`**, never writes the source blob
  to `Text/source/<sha>.<ext>` or the extracted text to `Text/extracted/<sha>.json` (§4.7), and
  never sets `project.source`. Import results exist only in memory until the window closes.
- Because `applyToProject` replaces `chapters` wholesale, **re-import destroys every stable
  paragraph ID and every take attached to them** — exactly what §9.4 forbids and what S3's
  acceptance criterion tests. `ParagraphReidentifier` exists but is called only from
  `Segmenter.swift`, never from the import path.

**Do:**

1. `newProject` → `ProjectPackage.create(...)`, open the resulting `SQLiteProductionStore`, and
   `save(project)`.
2. `openProject` → `ProjectPackage.open(...)` (see T16), then `SQLiteProductionStore` on
   `package.databaseURL`.
3. Replace `loadProjectFromPackage` with `ProjectPackage.readManifest` for listing and the store
   for loading. Delete the `Store/project.json` path entirely.
4. `applyToProject` → persist through the store; store both source blobs; set `project.source`;
   and route re-import through `ParagraphReidentifier` rather than replacing `chapters`.

**Done when:** create a project in the wizard, import a `.txt`, quit, relaunch, reopen from
recents — chapters and paragraphs are still there with the same IDs.

---

# P1 — Spec conformance

## T16 — `ProjectPackage.open` skips three required steps *(read)*

Spec §6.4: "`open` performs: read manifest → if `packageFormatVersion > current` throw
`schemaTooNew` → **open DB and migrate** → **shallow `ProjectIntegrity.check`** → **check for
`Autosave/session.json` and surface recovery**."

`ProjectPackage.swift:64-91` does the first two and none of the last three. Related: `create`
(§6.4: "…set the package flag, **`fsync` the directory**") does not fsync.

`ProjectIntegrity` and `StorageAnalyzer` both exist in Core and are called from **nowhere**
*(measured)* — `open` is their intended caller.

**Do:** implement the three missing steps. The autosave step is the Core half of `current_status.md`
T8; build the `session.json` reader here and let T8 supply the writer and the recovery sheet.

## T17 — `FileAssetStore` routes by file extension, so renders and proxies land in `Audio/Original` *(read)*

`FileAssetStore.swift:150-157`:

```swift
private func fileSubdirectory(for ext: String) -> AssetSubdirectory {
    case "wav", "mp3", "flac", "m4a", "caf": return .original
    ...
}
```

`put`/`ingest` derive the destination subdirectory from the extension, so a `.caf` chapter render
and an `.m4a` proxy are both written to `Audio/Original`. That breaks two §4.7 rules at once:
`Audio/Original` is append-only and must never receive derived output, and `Render`/`Proxy` must
be deletable caches. It also means "Rebuild caches" can never work and `StorageAnalyzer` counts
renders as originals.

Three consequences fall out of the same root:

- The backup-exclusion block (`FileAssetStore.swift:46-50`) tests
  `[.render, .proxy].contains(fileSubdirectory(for: ext))`, which **can never be true** — it is
  dead code, and nothing is ever excluded from Time Machine.
- `PackageError.diskFull(needBytes: 0)` — `needBytes` is hardcoded to 0 in both throw sites
  (lines 74, 82), so the UI cannot say how much space is needed.
- `put` does not map `NSFileWriteOutOfSpaceError` at all; only `ingest` does.

**Do:** add an explicit `subdirectory: AssetSubdirectory` parameter to `put` and `ingest` and
delete `fileSubdirectory(for:)`. Spec §6.2's protocol signature omits it — **this is a spec bug;
fix the spec too.** S6 is the first consumer (render cache), so this must land before S6.

## T18 — `ProductionStore` is missing the review-queue query *(read)*

Spec §7.5 declares:

```swift
func paragraphIDs(matching predicate: ReviewPredicate, order: QueueOrder) async throws -> [UUID]
```

It is absent from `Voxglass/Core/Production/Store/ProductionStore.swift` and from both
implementations. `ReviewPredicate` and `QueueOrder` exist (`Review/ReviewTypes.swift:3,14`) but no
store method consumes them.

This is the hot query behind the review queue, and §19.3 requires
`ProductionStoreTests` to assert it agrees with `ReviewQueueResolver.resolve`. **S6 needs it.**

## T19 — Other `SQLiteProductionStore` defects *(read)*

| Line | Defect |
|---|---|
| 117 | `insertTake` calls `saveTake(…, projectID: UUID())` — writes a **random project id** onto every take row |
| 217-221 | `cachedProxy(forTake:bitrateKbps:)` ignores `bitrateKbps` in the `WHERE` clause — returns a proxy at the wrong bitrate |
| 205, 217 | `cachedRender`/`cachedProxy` reconstruct `AudioAssetReference` with `byteCount: 0`, discarding the stored `asset_bytes` |
| 143 | `insertNote` binds `.null` for `project_id` |
| 172-177 | `paragraphSummaries` has no `ORDER BY` (spec implies ordinal order) and no `project_id` filter |
| 179-190 | `counts()` omits the `WHERE project_id = ?` the §7.5 example specifies |

The last two are latent while one database holds one project, but the schema carries `project_id`
and the spec's SQL uses it.

## T20 — Real G-7 determinism violations *(measured, 23 of them)*

Once T12 makes the gate bite, these fail. Triage:

**Genuine — persisted values from a bare clock (fix by injecting `Clock`):**
- `SQLiteProductionStore.swift:162` — `setReviewState` writes `Date()` into `updated_at`
- `SQLiteProductionStore.swift:212, 224` — `storeRender`/`storeProxy` write `Date()` into `created_at`
- `ProjectDatabase.swift:185` — migration timestamp
- `SilenceSegmenter.swift:74` — `SegmentBoundary(id: UUID())`; take an `IDGenerator`

**Code smell — a random UUID used as an error payload (fix by changing the error case):**
- `InMemoryProductionStore.swift` ×10 and `SQLiteProductionStore.swift:16, 85` —
  `throw StoreError.notFound(UUID())`. The thrown ID is meaningless; add a `.projectNotFound`
  case or pass the real ID.

**Defensible but should be exempted explicitly, not silently:**
- `SQLiteProductionStore.swift:439, 440, 457` — `UUID(uuidString:) ?? UUID()` decode fallbacks.
  A malformed row should throw, not fabricate an ID.
- `FileAssetStore.swift:34` — temp filename. Mark `// determinism-exempt:` with a reason.

## T21 — Missing protocol-boundary seams (spec §4.2) *(measured)*

The catalogue in §4.2 is normative ("If an implementation needs a capability not on this list,
that is a design change"). Missing entirely:

| Protocol | Missing piece |
|---|---|
| `ContentAddressedStore` | fake `InMemoryAssetStore` |
| `AudioMetricsCalculating` | fake `FixtureMetricsCalculator` |
| `AudioDecoding` | concrete `AVAudioDecoder` (Studio) **and** fake `FixtureDecoder` |
| `SegmentPlayer` | fake `FakeSegmentPlayer` |
| `ArtworkStore` | **the protocol, `FileArtworkStore`, and `InMemoryArtworkStore` — none exist** |
| `AudioCapturing` | fake `FakeAudioCapture` (already `current_status.md` T4) |

`VoxglassCoreTestSupport` currently contains only `FixedClock`, `SequentialIDGenerator` and
`ProjectFixtures`.

Note `AudioDecoding`'s concrete implementation is a live gap, not just a missing fake:
`PlaceholderAudioDecoder` (`AudioMetricsCalculator.swift:233-243`) throws
`CoreAudioDecodeError.notAvailable` from both methods, and `AVMetricsCalculator` sidesteps it with
its own private `decodeFile`. So `AudioMetricsCalculator.metrics(for url:)` — the Core entry point
— **always throws**.

## T22 — Components that exist but are wired to nothing *(measured)*

Present in Core, referenced from no call site outside their own file and tests:

- `ProjectIntegrity` — intended caller is `ProjectPackage.open` (T16)
- `StorageAnalyzer` — and its `orphanBytes` is never computed, so it always reports 0 despite
  §6.5 defining it as "assets referenced by nothing"
- `ScriptApplier`, `ScriptGenerator` / `LibriVoxScriptGenerator` (§10) — no UI, no caller
- `ParagraphSplitter` (§9.6) — no caller

Not wrong on its own, but S6/S7 assume these are reachable. Either wire them or record them as
deferred with the stage that will do it.

## T23 — `WAVHeaderRepair` does not exist *(measured)*

Spec §20 lists it in **S2** scope, and §7.7 makes it load-bearing for crash recovery: "A WAV
written by `AVAudioFile` that was never closed has a stale header length; the recovery path MUST
repair the RIFF/data chunk sizes from the actual file length before decoding." §19.4 requires
`RecordingFlowTests` to assert it against a truncated WAV.

Pairs with `current_status.md` T8 (autosave) and T16.

## T24 — Missing maintenance actions (§6.5) *(read)*

"Rebuild caches", "Vacuum unused assets", "Verify project" are specified in §6.5 and have no
implementation. `FileAssetStore.trash` exists; there is no un-trash, no empty-trash, no orphan
scan. Blocked on T17 (nothing is currently *in* the cache directories to rebuild).

## T25 — Naming drift from the spec *(read)*

Harmless individually; they make the spec unusable as a map:

| Spec | Code |
|---|---|
| `Chapter` (§5.3) | `ProductionChapter` |
| `Package/ContentAddressedStore.swift` (§4.2) | protocol lives elsewhere |
| `Audio/AudioMetrics.swift` (§4.2) | `Audio/AudioMetricsCalculator.swift` |
| `Assembly/SegmentPlayer.swift` (§4.2) | `Assembly/SegmentPlayerProtocol.swift` |

`ProductionChapter` is probably deliberate (collision with the consumer app's `Chapter`). **Amend
the spec** for that one and rename the files for the rest — the spec is normative and should not
be left wrong.

---

# P1b — Text pipeline (§9–§10)

Line-audited after the first pass of this document. §9 opens by naming its own hardest
requirement: *"stable paragraph identity across re-import, because a narrator who has recorded
1,200 paragraphs and then re-imports a corrected EPUB must not lose the mapping between text and
audio."* **That requirement is not met** (T31), and chapter formation — the unit of work for
every downstream stage — is broken for three of the four importers (T32).

Reminder: none of these files has ever been compiled into a running test (T11), so the existing
`VoxglassTests/Production/Text/` suites have never executed.

## T31 — `Segmenter` computes reidentification and then throws it away *(read)* — blocks S3 acceptance

`Segmenter.swift:159-165` builds a `ReidentificationReport` when `existing:` is passed and puts it
in the result. But paragraph IDs are minted unconditionally at line 116:

```swift
id: UUID(uuidString: ids.next().uuidString) ?? ids.next(),
```

The report is **never applied**. `segment(existing:)` does not preserve a single ID — it only
reports which ones *could* have been preserved. S3's acceptance criterion ("Re-importing an
edited EPUB preserves IDs for unchanged paragraphs, marks semantic edits `needsPickup`, and never
silently loses a recorded paragraph") fails at the first clause.

Worse, even a caller who wanted to apply the report could not: line 163 feeds the matcher

```swift
let incomingBlocks = doc.sections.flatMap(\.blocks)
```

— the **raw** block list, including `.sceneBreak` and empty blocks that are skipped when building
paragraphs (lines 99-109), and ignoring the `bodySections` partitioning used for the actual
output. So `report.assignments` is keyed by indices into a different array than the paragraphs it
is supposed to identify. The indices do not line up.

**Do:** build the paragraph list and the matcher input from the same filtered sequence, then apply
`assignments` (reuse ID), `newIndices` (mint), `retiredIDs` (§9.4's non-destructive retirement —
"Keep as orphaned" into a synthetic `Orphaned Recordings` chapter with `role = .backMatter`) and
`driftedIDs` (emit `needsPickup` events for `.semantic`).

**Done when:** a test segments a document, edits one paragraph, re-segments with `existing:`, and
asserts every unchanged paragraph kept its ID and its takes.

## T32 — Chapter formation is broken for TXT, DOCX and Markdown *(read)*

§9.2: "a new chapter begins at each `.heading` block whose level is 1 or 2 (or at each
`ExtractedSection` boundary…)".

`Segmenter.partitionSections` (lines 181-219) only ever regroups **whole sections**; it never
splits a section at an interior `.heading` block. It tests `section.blocks.first?.kind == .heading`
— the first block only. So the chapter count is entirely determined by how many
`ExtractedSection`s the importer produced:

| Importer | Sections produced | Result |
|---|---|---|
| `TXTImporter.swift:78` | `[ExtractedSection(blocks: classifiedBlocks, …)]` — **one** | A 30-chapter novel becomes **one** chapter |
| `DOCXImporter.swift:36` | `[ExtractedSection(blocks: extractedBlocks, …)]` — **one** | Same |
| `MarkdownImporter` | one per H1/H2 ✓ | but see below |
| `EPUBImporter.swift:51` | one per spine item ✓ | correct |

For TXT and DOCX the `.heading` blocks the importers correctly detect are then narrated as
ordinary paragraphs inside a single mega-chapter titled "Front Matter" (because
`Segmenter.swift:141-149` keys the title and `.frontMatter` role off `secIndex == 0 &&
section.heading == nil`, and TXT/DOCX sections always have `heading == nil`).

Chapters are the unit of rendering, export, validation and the LibriVox per-section file layout.
This breaks S3, and everything downstream of it.

Two further defects in the same area:

- **Markdown drops the chapter title from the script.** `MarkdownImporter.parseSections` treats an
  H1/H2 as a section boundary and `continue`s (lines 87-95) — the heading text becomes
  `currentHeading` and is **never emitted as a block**. §9.2 requires headings to become
  paragraphs with `role = .chapterHeading` when `treatHeadingsAsParagraphs` (default `true`) —
  "narrator usually reads 'Chapter Two'". H3–H6 *are* emitted, so the behavior is also
  inconsistent by level.
- **EPUB titles can be arbitrary prose.** `EPUBImporter.swift:238` sets
  `ParsedXHTML(heading: blocks.first?.text, …)` regardless of whether the first block is a
  heading. A spine item that opens with a paragraph gets that whole paragraph as its chapter
  title.

**Do:** make `Segmenter` split sections at interior `.heading` blocks. That needs a heading level,
which `ExtractedBlock` does not carry — see T33.

## T33 — `ExtractedBlock` has no heading level; the spec is self-contradictory *(read)*

§9.1's `ExtractedBlock` is `{ kind, text, sourceRange }` with no level, but §9.2 requires "each
`.heading` block whose **level is 1 or 2**", and §9.1's Markdown rules say "ATX headings `#`–`######`
→ `.heading` **with level**". `MarkdownImporter` tracks level internally (`classifyBlock` returns
`headingLevel`) and then discards it at the `ExtractedBlock` boundary.

**Do:** add `headingLevel: Int?` to `ExtractedBlock`, populate it in all four importers, and
**amend §9.1 in the spec**. T32 depends on this.

## T34 — `identityKey` strips digits, not just punctuation *(read)*

Spec §9.3: "Aggressive form for identity matching: normalize + lowercase + **strip all
punctuation**."

`TextNormalizer.identityKey` filters to `CharacterSet.letters ∪ CharacterSet.whitespaces`, which
excludes `decimalDigits`. So **all digits are deleted**:

```
identityKey("Chapter 3")  ==  identityKey("Chapter 4")  ==  "chapter"
```

Consequences:

- `ParagraphReidentifier` matches on `identityKey`, so numerically distinct paragraphs collide in
  pass 1 and are assigned the same ID.
- `TextDriftDetector.tokenize` runs on `identityKey`, so the word-level Levenshtein distance is
  blind to every numeric change. It compensates with a separate `extractDigits` comparison
  (lines 18-22), which works — but only for **digits**.
- **Number words are unhandled.** §9.5 step 4: "if the only difference is the addition or removal
  of a **number word or digit**, always `.semantic`". §19.3 names the exact case:
  `"three" → "four" → .semantic`. In the current code that is a one-token substitution: for a
  paragraph of ≥ 20 tokens, `d = 1` and `d/n ≤ 0.05`, so it classifies **`.minor`** — the
  paragraph keeps its take and never gets `needsPickup`.

  `TextDriftTests.numberChangeIsAlwaysSemantic` tests `5 → 3` (digits), which the digit path
  catches. The spec's named case is untested.

**Do:** include `decimalDigits` in the `identityKey` character set; add a number-word list
(`zero`…`twenty`, `thirty`…`ninety`, `hundred`, `thousand`, `million`, `billion`, plus ordinals)
to the step-4 check; add the `"three" → "four"` test.

Note the code also reorders the spec's steps, running the number check *before* the cosmetic
check. That ordering is **better** than the spec's (step 4 says "always"), so amend §9.5 rather
than the code.

## T35 — `ParagraphReidentifier`: pass-1 drift is always `.none`, and pass 3 is dead code *(read)*

**Drift is lost on every pass-1 match.** Lines 44-48 (and identically 60-64, 74-78):

```swift
if exHashes[exIdx] != inHashes[inIdx] {
    report.driftedIDs[existing[exIdx].id] = d.classify(
        recorded: exKeys[exIdx], current: inKeys[inIdx])      // ← identityKeys, not texts
}
```

The branch is entered only when `exKeys[exIdx] == inKeys[inIdx]`, so `classify` is handed **two
identical strings** and returns `.none` every time. The exact situation being detected — same
identity key, different hash — *is* the definition of `.cosmetic` (§9.5 step 2), and it gets
recorded as `.none`. Passes 2 and 3 pass the real texts and are correct; only the fast path is
wrong, which is the path that fires for the overwhelming majority of paragraphs.

**Pass 3 never runs.** Line 122:

```swift
let stillIn = remainingIn.filter { report.assignments[$0] == nil && !report.newIndices.contains($0) }
```

Every `j` in `remainingIn` was already either assigned or appended to `newIndices` by the pass-2
loop (lines 96-120), so `stillIn` is always empty. §9.4's third pass — first/last-60-character
anchoring, "this catches 'the editor fixed a typo in the middle'" — is unreachable.

**Pass 2 does not use anchors.** §9.4: "For unmatched runs **between two matched anchors**, match
within the window". Line 97 uses raw index proximity instead: `abs($0 - j) <= windowSize`,
comparing an *existing* index against an *incoming* index. Insert 500 paragraphs early in the book
and the two sequences drift apart by more than the 400 window, so every later paragraph falls out
of range. The spec's "a window larger than 400 paragraphs on either side is split at the midpoint"
is not implemented either.

**Dead code:** `assignMatch` (lines 149-162) is never called — and it is the only version that
passes the real texts to `classify`. It looks like the correct implementation that was left
behind.

## T36 — Performance: the 10,000-¶ budget will not be met *(read)*

§19.3 budgets a 10,000-paragraph re-import at **< 2 s**. Four separate super-linear costs:

| Location | Cost |
|---|---|
| `Segmenter.swift:124` | `sourceFileHash: TextNormalizer.hash(doc.plainText)` — **the entire document is normalized and SHA-256'd once per paragraph.** For a 2 MB book × 10,000 paragraphs that is ~20 GB of hashing. Hoist it out of the loop. |
| `MarkdownImporter.swift:79-83` | For every block, re-scans all preceding blocks to compute a char offset — O(n²) string comparisons |
| `TXTImporter.swift:165-172` | `range(of:)` searches the whole document for each block's text — O(n·m) |
| `ParagraphReidentifier.swift:96-107` | `remainingEx.filter` per incoming index, with `jaccardSimilarity` rebuilding both 3-gram `Set`s on every comparison and no memoization — O(n²) with a large constant |

`ReidentificationTests.large10KParagraphReimport` exists but has never run (T11). There is **no**
10,000-¶ test for `Segmenter` itself, which is where the worst offender lives.

## T37 — `sourceRange` is wrong or empty almost everywhere *(read)*

`Paragraph.sourceRange` (§5.3, offsets into the extracted source text) is what makes "jump to the
source" and re-import source mapping possible.

- **TXT:** `range(of: needle, in: haystack)` looks up the *joined* block text. Soft-wrapped lines
  are joined with `" "` (line 92) but appear in the original with `"\n"`, so `range(of:)` returns
  `nil` and the code falls back to **`0..<0`** for every multi-line block. Where it does match, an
  identical repeated block resolves to the first occurrence.
- **Markdown:** offsets are computed by summing `element.text.count + 2` over preceding blocks
  compared **by text equality** (line 81), so duplicate blocks share an offset; and they are
  offsets into the *stripped block sequence*, not into `plainText`.
- **Markdown `plainText`** is rebuilt from stripped block text joined with `"\n\n"`
  (`MarkdownImporter.swift:19`), so it is not the source document. §9.1 defines `plainText` as
  "the normalized full text, for hashing + source map". `SourceRange.sourceFileHash` is therefore
  a hash of something that never existed on disk.
- **DOCX:** `sourceStart: 0` for the single section.

**Do:** have each importer build `plainText` first and emit `sourceRange` as offsets into it,
computed during the scan rather than by post-hoc search.

## T38 — `ParagraphSplitter.split` copies every take onto *both* halves *(read)*

§9.6, normative: "**Takes stay with the first half.** The second half gets a new ID."

`ParagraphSplitter.swift:43-47` gives the second half the same takes:

```swift
takes: paragraph.takes.map { take in
    var t = take
    t.isArchived = false
    return t
},
```

Take IDs are not regenerated, so after a split the same `Take.id` exists on two paragraphs — a
primary-key collision the moment either is persisted through `insertTake`, and a double-count in
`counts()` and every duration total.

`SplitMergeTests` covers `splitPreservesFirstID`, direction notes, pronunciation refs and
`splitSecondHalfIsUnreviewed` — but **nothing asserts where the takes went**.

Two smaller items in the same file:

- `merge` does not re-point `b`'s notes to `a` (§9.6). Notes live in the store, so the splitter
  cannot do it alone — the (missing) caller must. Document the contract.
- Neither operation renumbers the chapter's ordinals contiguously (§9.6, "Both operations
  renumber…"); `split` only sets `second.ordinal = first.ordinal + 1`. Again a caller
  responsibility with no caller (T22).

## T39 — Importer deviations from §9.1 *(read)*

**`TXTImporter`**
- Heading detection ignores two of the three spec conditions. §9.1 requires "≤ 80 characters, has
  **no terminal** `.`/`?`/`!`, **and** matches `^(CHAPTER|BOOK|…)`". Lines 142-146 apply only the
  regex, so a paragraph opening "Chapter meetings were held every Tuesday, and the vicar…" is
  classified as a heading. The all-uppercase branch (line 148) checks `!contains(".")` but not
  `?` or `!`.
- `.verse` is never produced. `detectVerse` works, but a verse file still emits `.paragraph`
  blocks with lines joined by `"\n"` (line 92). §9.1: "each line is a block of kind `.verse`".
- The ISO-8859-1 fallback is unreachable — `String(data:encoding:.windowsCP1252)` accepts any byte
  sequence, so the CP1252 branch always wins. Harmless; worth a comment rather than dead code.

**`SourceImporterRegistry`** — §9.1 specifies "by UTType, then extension, **then sniffing**".
Sniffing is not implemented, so an extensionless or mislabeled file returns `nil`.

**`MarkdownImporter.parseFrontMatter`** — the offset computation (lines 50-52) mixes `NSString`
UTF-16 ranges with `String.distance`, then feeds the result to `raw.index(offsetBy:)`. Non-ASCII
front matter will slice at the wrong offset or trap.

## T40 — §9/§10 test gaps *(measured)*

- `ImporterTests` has **zero EPUB and zero DOCX coverage** — grep for `epub|docx` returns 0.
  §19.3 requires "one fixture document per format (`.txt`, `.md`, `.epub`, `.docx`) with a known
  expected chapter/paragraph shape; malformed EPUB falls back without throwing." The two most
  complex importers, and the only one that currently produces correct chapters, are untested.
- `SegmenterTests` never passes `existing:` — grep returns 0 occurrences. **The S3 acceptance
  criterion has no test.** Also missing: the heading-detection table, verse mode, and the
  10,000-¶ re-import budget (§19.3).
- `TextDriftTests` is missing the spec's named `"three" → "four"` case (T34).
- `SplitMergeTests` never asserts take placement after a split (T38), and there is no undo test
  ("undo restores exactly", §19.3).
- `ReidentificationTests` has no test for a moved paragraph (pass 2), none for
  first/last-sentence anchoring (pass 3 — which cannot pass, T35), and none asserting that "a
  paragraph edited beyond threshold becomes new + retired, not silently matched" (§19.3).

---

# P2 — Test suite

## T26 — Suites the spec requires that do not exist *(measured)*

From §19.3/§19.4, absent from the repo:

- `StorePerformanceTests` — `paragraphSummaries` on the 10,000-¶ fixture < 120 ms; `counts()` < 20 ms
- `RenderCacheKeyTests` — key stable **across process launches** (this is the whole reason G-4
  exists; it is the defect class the codebase has hit before)
- `TakeManagementTests` — multiple takes, select-newest
- `ReviewEventFoldTests`, `ReviewQueueResolverTests` — S6, but `ReviewEventFolder` and
  `ReviewQueueResolver` are already written and untested

Plus, from `current_status.md`: `RecordingFlowTests`, `ImportAssignmentTests`, `AIOriginLabelTests`,
`RenderCountProbeTests`.

## T27 — Coverage holes in suites that do exist *(measured)*

- `ProductionStoreTests` — **0 references to `upsert`** (why T14 survived); nothing asserts
  "granular mutations do not rewrite the project" (§19.3)
- `MetricsCalculatorTests` / `ReplayGainTests` — see `current_status.md` T3
- `ProjectPackageTests` — does not cover `schemaTooNew`, missing-asset findings, or autosave
  recovery, all named in §19.3

## T28 — Fixtures required by §19.2 *(read)*

`ProjectFixtures` exists. Confirm it provides all seven named in the S1 stage plan — `tiny`,
`typical`, `stress` (10,000-¶), `aiTainted`, `aiUnselected`, `drifted`, `brokenIntegrity` — and
add `VoxglassCoreTestSupport/Fixtures/Schemas/v1.sql` (§7.4 rule 4: migration tests must build the
*old* schema from a captured DDL snapshot). Not yet audited in detail.

## T29 — S6 code written ahead of its stage *(measured)*

`Voxglass/Core/Production/Assembly/**` (`SegmentQueueBuilder`, `RenderPlan`, `AssemblyTypes`,
`SegmentPlayerProtocol`) and `Voxglass/Core/Production/Review/**` (`ReviewEventFolder`,
`ReviewQueueResolver`, `ReviewTypes`) are S6 scope per spec §20, already written, wired to
nothing, and — via `SegmentQueueTests.swift` — currently breaking the entire test suite (T11).

The stage plan's rule is "Do not start a stage until the previous stage's acceptance passes."

**Recommend:** delete `SegmentQueueTests.swift` now (T11) and leave the Assembly/Review source in
place as a starting point for S6, but treat it as unreviewed draft — do **not** count it as done.
Get a decision from the human before S6 begins.

## T30 — Correction to `current_status.md` T3: the pink-noise fixture is wrong *(measured)*

Two ReplayGain tests currently fail:

```
✘ pinkNoiseAtMinus20dBFS_gainInRange — (gain > 3.0 → true) && (gain < 6.0 → false)
✘ pinkNoiseAtMinus26dBFS_gainInRange — (gain > 9.0 → true) && (gain < 12.0 → false)
```

**The implementation is right; the fixture is wrong.** The `pinkNoise` helper in
`ReplayGainTests.swift` runs a Voss-McCartney generator, scales by `0.11`, and then multiplies by
`10^(dBFS/20)`. That final multiply is treated as if the generator produced unit-RMS noise. It
does not: measured RMS of the generator before scaling is **0.2207**, i.e. **−13.12 dB**. So
"−20 dBFS" is actually −33.1 dBFS RMS, and the correct gain for it is ~17 dB — above the
`< 6.0` bound. Both failures are exactly this offset.

Two fixes, both needed:

1. **Normalize.** Generate, measure RMS, divide by it, *then* scale by `10^(dBFS/20)`.
2. **Make it deterministic.** The helper calls `UInt32.random(in:)`, which uses the system RNG —
   the test is flaky by construction and violates the determinism principle the `Clock`/
   `IDGenerator` seams exist to uphold. Use a fixed-seed LCG, or better, follow
   `current_status.md` T3 and commit the WAV fixtures rather than generating signals in the test.
   Committed golden vectors would have made this failure impossible.

---

# Definition of ready for S6

Do not start S6 until all of these are true:

- [ ] `swift test` exits 0, all suites reported (T11)
- [ ] `bash scripts/guard_production.sh` exits non-zero on a planted violation (T12)
- [ ] `xcodegen generate` leaves the tree unchanged; `VoxglassStudio` builds with the Record
      feature compiled (T13)
- [ ] `upsertChapter`/`upsertParagraph` are upserts, with a take-survival test (T14)
- [ ] Create → import → quit → reopen preserves chapters, paragraphs and IDs (T15)
- [ ] `ProjectPackage.open` migrates, integrity-checks, and offers autosave recovery (T16)
- [ ] `put`/`ingest` take an explicit `AssetSubdirectory` (T17) — **S6's render cache depends on this**
- [ ] `paragraphIDs(matching:order:)` exists and is tested against `ReviewQueueResolver` (T18)
- [ ] A TXT and a DOCX import produce one chapter **per heading**, not one chapter total (T32)
- [ ] Re-import preserves IDs and takes for unchanged paragraphs, with a test (T31)
- [ ] `split` leaves takes on the first half only, with a test (T38)
- [ ] `current_status.md` T1–T5 and T7 are done

# Suggested order

1. **T11, T12, T13** — restore the signal. Nothing below is trustworthy first.
2. **T14, T19, T18** — the store, in one pass.
3. **T16, T17, T23** — package and asset store, in one pass.
4. **T33 → T32 → T31** — the text pipeline's spine, in that order: heading level, then chapter
   formation, then ID stability. T31 is the S3 acceptance criterion and depends on both.
5. **T34, T35, T38** — correctness in the matcher, drift detector and splitter.
6. **T36, T37, T39** — performance and importer conformance.
7. **T15** — the Studio wiring, which depends on 2, 3 and 4.
8. **T20, T21, T22, T25** — conformance cleanup.
9. **T26, T27, T28, T30, T40** — tests.
10. **T24, T29** — decisions, then S6.

# Not audited

Stated plainly so the gaps are known rather than assumed clean:

- **The script generators (§10).** `ScriptGenerator` / `LibriVoxScriptGenerator` /
  `RetailScriptGenerator` and `ScriptApplier` were read only far enough to confirm they are
  unwired (T22). The generated disclaimer and credit **strings** must be checked verbatim against
  §3.6 (legal-safety strings, marked normative-exact) and §10.2/§10.3 before S7 — a wrong
  disclaimer is a LibriVox rejection, not a bug report.
- **The ZIP reader** (`Text/ZIP/ZipReader.swift`) and the EPUB/DOCX XML parsing internals. Only
  their section/heading output was checked (T32). Malformed-input behavior is untested (T40) and
  unaudited.
- The §7.3 SQL schema column-by-column against the domain types.
- §5 domain types beyond `AudiobookProject`, `RecordingDefaults`, `ProductionProfile`,
  `PackageManifest` and the store DTOs.
- Everything in §12–§18 (S6 onward), except where already-written S6 code intrudes (T29).

**A note on the existing §9 tests.** All seven `VoxglassTests/Production/Text/` suites have never
executed (T11). Several assert behavior that this audit shows to be wrong —
`TextDriftTests.oneWordEditOnLongTextIsMinor` and `twoWordEditsOnLongTextIsMinor` encode the
`d ≤ 2 && d/n ≤ 0.05` rule that swallows the `"three" → "four"` case (T34), and
`SegmenterTests.frontMatterChapterWhenNoHeading` passes precisely *because* TXT collapses to a
single front-matter chapter (T32). **Do not treat a green run of these suites as validation.**
Fix the code first, then update the tests to match the spec.
