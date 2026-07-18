# Reco fix: split semicolon subjects, un-jam the surfaced ring, JSON backups

Self-contained implementation plan for a coding agent. Diagnosis was verified
empirically on 2026-07-17 by replaying the full pipeline (real user backup →
`RecommendationQueryBuilder` logic → live archive.org queries → `rank`
exclusion logic). No speculation below; every root cause was reproduced.

## Symptom

"Recommended For You" permanently shows the bundled popular seeds (Pride and
Prejudice, Sherlock Holmes, Dracula…) even for a user with 13 books, 18
playback positions, and 21 healthy `taste_profile_terms` (aristophanes w=3.28,
sun tzu w=0.76, language eng w=6.5). The cold-start gate (`profile.isEmpty`)
is NOT the problem — the shelf falls back because **zero candidates survive
ranking** (`RecommendationEngine.swift:122` → `.popularFallback`).

## Verified root causes

### RC1 — subject taste terms are whole semicolon-joined strings (subject axis 100% dead)

LibriVox item **metadata** returns `subject` as ONE string, e.g.
`"librivox; audiobooks;greek drama; aristophanes; greek comedy"`.
`decodeStringListIfPresent` (`Voxglass/Core/Catalog/InternetArchiveModels.swift:448-460`)
never splits on `;`, so every `book_taste` subject row and every subject
taste term is a whole semicolon string. (All 9 subject terms in the field
backup are like this — one literally contains uploader typos
`"libivox;audiobook;drama;athens;women;pelopennesian war"`, proving they are
raw single-string metadata.) Consequences, both confirmed against live
archive.org:

- Every EXPLORE / SERENDIPITY / fallback-subject Solr query
  (`subject:"librivox; audiobooks;greek dra…"`, built at
  `RecommendationQueryBuilder.swift:61,70,86` and
  `RecommendationEngine.buildFallbackQueries`) returns **0 rows**.
- Subject affinity in `RecommendationPipeline.scoreCandidates`
  (`RecommendationPipeline.swift:201-203`) is an exact dictionary-key lookup;
  the **search** API returns candidate subjects as individual array elements
  (`"greek drama"`, `"aristophanes"`), so no candidate token ever matches a
  whole-string profile key. The recommender silently degrades to creator-only.

### RC2 — permanent surfaced-ring exclusion burns out the tiny creator-only pool

With subjects dead, generated queries can reach only ~25 unique books
(5 `topCreators` × top-N by downloads, deterministic `downloads desc` sort,
minus library/listened WorkKeys). Every successful personalized shelf pushes
ALL ranked results into `reco_surfaced`
(`RecommendationEngine.swift:126-127` → `TasteProfileStore.pushSurfaced`,
`TasteProfileStore.swift:213-228`), which is capped at 500 rows and has **no
time-based expiry**. Live simulation: load 1 → personalized (25 items, all
pushed); load 2 → **zero survivors → `.popularFallback` forever** (a 25-item
pool can never displace a 500-cap ring).

### RC3 — why the UI shows popular seeds instead of a stale personalized shelf

`HomeRecommendationStore` persists only `.personalized` snapshots
(`HomeRecommendationStore.swift:79-84`, added in commit 616a013). The device's
ring burned out before that shipped, so no snapshot exists; every launch shows
`bundledPopularSeeds` and every refresh returns `.popularFallback`.

### Contributing defects

- Exploit queries request only `rows: 2` per creator
  (`kTarget` 24 → `exploitAlloc` 13 → `13/5 = 2`, `RecommendationQueryBuilder.swift:38`).
- `"anonymous"` passes the author filter (`RecommendationPipeline.normalizedTerm`
  drops only unknown/various), so Beowulf/Arabian Nights rank as "same creator
  you love".
- After splitting, generic tokens `audiobook`/`audiobooks` would appear on
  nearly every book; they are NOT in `RecommendationConstants.subjectStopList`.

---

## Fix 1 — split subjects on `;` everywhere

Add one helper (suggested: `RecommendationPipeline.splitSubjectTokens(_ raw: String) -> [String]`
or a tiny `SubjectTokenizer` enum next to it): split on `;`, trim whitespace,
lowercase, drop empties.

Apply it at:

1. **Decode** — `decodeStringListIfPresent` in
   `Voxglass/Core/Catalog/InternetArchiveModels.swift:448`: after cleaning,
   expand any element containing `;` into multiple elements. This fixes both
   the metadata-import side and any search-result elements that carry
   semicolons, keeping both sides of the match consistent. (Do NOT split on
   `,` — author names and subjects like "Classics (Greek & Latin Antiquity)"
   would be mangled; `;` is the LibriVox convention.)
2. **book_taste import** — `Voxglass/Core/Library/LibraryRepository.swift:483-490`:
   split each subject before inserting rows (idempotent with #1, cheap safety).
3. **Defensively in the pipeline** — `RecommendationPipeline.termWeights`
   (subject branch, ~line 67) and `extractTokens` (~line 231): split any token
   containing `;` before normalization, so pre-existing rows and odd payloads
   still work.
4. **One-time local migration** — existing `book_taste` rows already hold the
   strings, so no network is needed. Add
   `LibraryRepository.resplitBookTasteSubjectsIfNeeded()` following the
   existing `backfillBookTasteIfNeeded` pattern (UserDefaults version flag):
   for every `book_taste` row with `axis='subject' AND term LIKE '%;%'`,
   delete it and insert one row per split token (INSERT OR IGNORE to dedupe).
   Call it from `AppServices.bootstrap` right after
   `backfillBookTasteIfNeeded()` (`Voxglass/App/AppServices.swift:109`).
   The existing launch-time `rebuildTasteHistory()` then regenerates
   `taste_profile_terms` correctly with no extra work.
5. **Stop list** — add `"audiobook"`, `"audiobooks"` to
   `RecommendationConstants.subjectStopList`.

Note: `distinctSubjectCount` dampening (`RecommendationPipeline.swift:97-100`)
will see more, finer-grained subjects after the split. That is expected and
correct — dampening exists exactly for this.

## Fix 2 — un-jam the surfaced ring

In `Voxglass/Core/Catalog/Recommendations/TasteProfileStore.swift` and
`RecommendationEngine.swift`:

1. **TTL**: add `RecommendationConstants.recoSurfacedTTL: Double = 14 * 86400`.
   In `pushSurfaced` and `fetchSurfacedIdentifiers`, run
   `DELETE FROM reco_surfaced WHERE ts < ?` (now − TTL) before the existing
   logic.
2. **Push only what is shown**: in `fetchRecommendationShelf`
   (`RecommendationEngine.swift:126`), compute the shelf slice first and push
   surfaced keys for `filtered.prefix(18)` only, not all filtered results.
3. **Graceful degradation instead of burnout**: in `fetchRecommendationShelf`,
   if `filtered` is empty after both rounds, re-run
   `RecommendationPipeline.rank` with `excludeKeys` MINUS the surfaced ids
   (keep library/listened exclusions — never recommend owned/finished books).
   Only if that is still empty, return `.popularFallback`. This makes the
   worst case "repeat older recommendations", never "lose personalization".
4. **One-time recovery**: inside the Fix 1 migration (same version flag),
   `DELETE FROM reco_surfaced` so affected installs recover on first launch.

## Fix 3 — small hardening (same PR)

- `RecommendationPipeline.normalizedTerm` author branch and
  `TasteProfileStore.seedAuthor`: also reject `anonymous`.
- `RecommendationQueryBuilder.generateQueries:38`:
  `perCreator = max(4, exploitAlloc / exploitCreators.count)`.

## Fix 4 — backup files become plain `.json`

The payload is already pretty-printed, sorted-key JSON
(`LibraryBackupService.swift:81-83`); only the extension hides it. Note
`UTType("guru.parso.voxglass.backup")` resolves to nil today (no Info.plist
UTI declaration) and falls back to `.json` (`LibraryBackupService.swift:30`).

1. **Export** — `LibraryBackupService.exportToFile()`
   (`Voxglass/Core/Services/Backup/LibraryBackupService.swift:86`): change the
   file name suffix from `.voxglassbackup` to `.json`, i.e.
   `"Voxglass Backup \(date).json"`. Optionally add
   `.withoutEscapingSlashes` to `encoder.outputFormatting` so URLs read
   cleanly.
2. **Import keeps accepting legacy files** — declare the legacy type in
   `Voxglass/Resources/Info.plist` via `UTImportedTypeDeclarations`:
   identifier `guru.parso.voxglass.backup`, conforms to `public.json`,
   extension `voxglassbackup`. With that declared, the existing
   `fileImporter(allowedContentTypes: [.json, BackupPayload.utType])`
   (`Voxglass/Features/Settings/SettingsView.swift:1209`) accepts both new
   `.json` and legacy `.voxglassbackup` files. The decode path is untouched
   (it already just reads JSON from any URL).
3. **Copy** — update the helper text at `SettingsView.swift:1178` to
   "Select a Voxglass backup file (.json, or legacy .voxglassbackup)…".

## Unit tests (XCTest, `@testable import VoxglassCore`, in `VoxglassTests/`)

Add to the existing files where noted; follow their in-memory `AppDatabase`
setup style (see `TasteProfileStoreTests.swift`, `LibraryRepositoryTests.swift:351`).

`RecommendationPipelineTests.swift`:
- `testTermWeightsSplitsSemicolonSubjects` — history entry with subject
  `"librivox; audiobooks;greek drama; aristophanes; greek comedy"` yields
  distinct subject terms `greek drama`, `aristophanes`, `greek comedy` and NO
  term containing `;`; `librivox`/`audiobooks` are dropped by the stop list.
- `testExtractTokensSplitsSemicolonSubjects` — a search result whose
  `subjects` contains one semicolon-joined element produces individual tokens.
- `testScoreCandidatesMatchesSplitSubjects` — profile built from a
  semicolon-subject history scores a candidate exposing `"greek drama"` with
  affinity > 0 (this fails on current code — the regression test for RC1).

`RecommendationQueryBuilderTests` (new file or alongside pipeline tests):
- `testGeneratedSubjectQueriesUseSingleTerms` — no generated `iaQuery`
  contains `;` inside a `subject:"…"` clause when the profile came from
  semicolon metadata.
- `testExploitRowsFloor` — per-creator `requestedCount >= 4`.

`TasteProfileStoreTests.swift`:
- `testSurfacedRingExpiresByTTL` — insert a `reco_surfaced` row with
  `ts = now − (TTL + 1 day)` directly, call `fetchSurfacedIdentifiers`,
  assert it is gone; a fresh row survives.
- `testNormalizedTermRejectsAnonymousAuthor`.

`LibraryRepositoryTests.swift`:
- `testResplitBookTasteMigration` — insert a `book_taste` subject row
  containing `;`, run `resplitBookTasteSubjectsIfNeeded()`, assert the row is
  replaced by split rows and `reco_surfaced` is empty; assert the migration is
  idempotent (second run is a no-op). Then run
  `rebuildFromListeningHistory` and assert `taste_profile_terms` holds split
  terms.

`RecommendationEngineTests.swift` (has a mock client already — extend):
- `testFullySurfacedPoolStillReturnsPersonalized` — mock client returns a
  fixed candidate set; pre-populate `reco_surfaced` with all of them; engine
  must return `.personalized` (surfaced-ignoring re-rank), not
  `.popularFallback`. Library-owned books must still be excluded.

`BackupPayloadTests.swift`:
- `testExportFileNameUsesJSONExtension` — `exportToFile()` URL ends in
  `.json` (gate Pro check via existing test hooks if needed; if
  `ProFeature.isEnabled` blocks unit tests, assert on the filename format
  helper instead — check how existing backup tests handle Pro gating).
- `testImportReadsLegacyVoxglassbackupFile` — write a valid payload to a
  temp file named `x.voxglassbackup`, import, assert books restored.

## Verification

1. `xcodebuild test` on the local simulator for the files above (CI is
   Linux-only source checks — simulator tests are the local gate, see
   docs/RELEASE_PLAN.md conventions).
2. Live query spot-check: `subject:"greek drama" AND collection:librivoxaudio
   AND mediatype:audio` on archive.org advancedsearch returns rows (verified
   2026-07-17), while the old whole-string query returns 0.
3. End-to-end: build & run, import the field backup
   (`Voxglass Backup 2026-07-17 at 20.45.14.voxglassbackup` — legacy
   extension exercises Fix 4's import path), relaunch, confirm the shelf is
   `.personalized` with Aristophanes-adjacent titles (The Frogs, The Birds,
   Peace…), then reload the Listen tab several times and relaunch again to
   confirm the shelf does NOT degrade to popular (RC2 regression).
4. Export a backup, confirm the share sheet produces
   `Voxglass Backup ….json` and that it opens readably in a text editor.

## Constraints

- Playback positions are sacred (never lose them); nothing here may touch
  `playback_positions` write paths. The migration only rewrites `book_taste`
  subject rows and clears `reco_surfaced` — both derived, rebuildable data.
- Keep import of legacy `.voxglassbackup` files working indefinitely.
