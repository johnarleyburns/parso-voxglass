# Recommendations & Explore Fix Plan — coding agent instructions

> Written 2026-07-16 after a code investigation of three user-reported problems.
> Scope: (1) a real, unit-tested Recommended for You; (2) featured-collection book
> counts bundled at build time; (3) Explore sort tabs must not reset scroll.
> `docs/RELEASE_PLAN.md` (playback position) is a separate work stream — do not touch it.

## Investigation findings (read before coding)

The user has 12 books of listening history (2 finished, 1 mostly finished) plus
onboarding picks, yet Recommended for You shows only the default bundled popular
seeds. Root causes, confirmed in code:

1. **No `book_taste` backfill.** Taste terms are captured only at import time
   (`LibraryRepository.importInternetArchiveItem`, added in `4766a63` on
   2026-07-11). Books imported before that date have **zero** `book_taste` rows, so:
   - `TasteProfileStore.rebuildFromListeningHistory` (which `JOIN`s
     `book_taste`) rebuilds an **empty** profile from their listening events, and
   - `AppServices.captureTasteSignal` early-returns (`fetchBookTasteTerms` is
     empty), so live listening signals are dropped too.
   The rebuild also **deletes** all `taste_profile_terms` first, so it actively
   wipes anything onboarding once seeded if the current prefs can't regenerate it.

2. **Onboarding-only profiles are deliberately ignored.** `TasteProfileStore.
   hasMeaningfulProfile()` returns false unless there is a durable listen /
   signal / favorite; `RecommendationEngine.fetchRecommendations` then returns
   `bundledPopularSeeds` without a single query. The test
   `testOnboardingOnlyProfileKeepsBundledPopularSeedsWithoutNetworkRefresh`
   (RecommendationEngineTests.swift:153) locks this behavior in. This is the
   opposite of what the user wants: onboarding must tune recommendations.

3. **Curated onboarding picks contribute nothing.** Onboarding offers
   `IACollectionStore.allSelectableCollections` = 21 browse categories + 3
   curated collections (`great-books`, `greater-books`, `ancient-greece`).
   Both `seedOnboardingPicks` and `rebuildFromListeningHistory` map picks via
   `LibriVoxBrowseCategory.category(withID:)`, which is `nil` for the curated
   IDs — a user who picked only curated collections seeds an empty profile.

4. **Featured-collection counts are fetched at startup.** `BrowseView.task`
   (DiscoverView.swift:32-37) calls `CollectionCoverStore.resolveCounts` for all
   25 collections; on a fresh install/stamp change that is 25 `rows: 0` searches
   at launch.

5. **Sort-tab scroll reset.** `CatalogStore.runSearch` keeps old `results` while
   `isSearching` is true, but `BrowseView.catalogResults` replaces the whole
   results list with a small "Searching LibriVox" panel whenever
   `catalogStore.isSearching` — content height collapses, so the outer
   `VoxglassScreen` scroll view snaps to the top on every sort change.

The user's data lives on their **phone** (the only simulator DB is empty), so
nothing can be fixed by poking a local database — the fixes must handle the
upgrade path in-app (backfill + rebuild at bootstrap).

---

## Part 1 — Recommended for You: pure pipeline + fixes

**Architecture requirement (from the user):** the recommendation logic must be a
pure, logic-level function — listening history (and onboarding picks, favorites,
candidates) in → recommendations out — unit-testable with many variations, no
database, no network, no UI. Persistence (`TasteProfileStore`) and fetching
(`RecommendationEngine`) become thin shells around it.

### 1.1 New file `Voxglass/Core/Catalog/Recommendations/RecommendationPipeline.swift`

Two public types:

```swift
/// One book of listening history, described purely at the logic level.
public struct ListeningHistoryEntry: Equatable {
    public var authors: [String]
    public var subjects: [String]
    public var languages: [String]
    public var listenedSeconds: Double        // Σ listening_events.seconds for the book
    public var capturedSignalIncrement: Double // taste_signal_state.applied_increment (0 if none)
    public var isFavorite: Bool
    // memberwise public init with defaults ([], [], [], 0, 0, false)
}

public enum RecommendationPipeline { ... }
```

`RecommendationPipeline` static functions (all pure, deterministic, no actor
isolation):

- `termWeights(history: [ListeningHistoryEntry], onboardingSelectionIDs: Set<String> = []) -> [TermWeight]`
  where `TermWeight` is a small public struct `{axis, term, weight}`.
  Per entry: `contribution = max(historyWeight, capturedSignalIncrement, favoriteWeight)`
  with `historyWeight = listenedSeconds > 0 ? historyIncrement(forSeconds:) : 0`
  and `favoriteWeight = isFavorite ? RecommendationConstants.favoriteBoost : 0`;
  skip entries with contribution ≤ 0; add the contribution once per **distinct**
  normalized term of the entry (`Set` the axis arrays first). Then append
  onboarding seeds from `OnboardingTasteSeeds.seeds(for:)` (§1.2). Term
  normalization/junk-filtering: move `normalizedTerm(axis:term:)` and
  `isCollectionLikeSubject(_:)` (and the `knownCollectionIDs` set) from
  `TasteProfileStore` here, `public static`.

- `buildProfile(history:onboardingSelectionIDs:) -> ProfileBucket` =
  `profile(fromRawTerms: termWeights(...))`.

- `profile(fromRawTerms: [TermWeight]) -> ProfileBucket` — the subject-dampening
  read logic lifted verbatim from `TasteProfileStore.fetchProfile` (damp divisor
  `1 + log(distinctSubjects + 1)` computed over all raw subject terms, stop-list
  terms ×0.05, collection-like subjects dropped, authors/languages undamped,
  each axis sorted by weight desc).

- `historyIncrement(forSeconds:) -> Double` — moved from `TasteProfileStore`
  (floor `RecommendationConstants.minListenIncrement`, cap 12.0).
  `TasteProfileStore.historyIncrement` is deleted; update its callers/tests.

- `rank(candidates: [InternetArchiveSearchResult], profile: ProfileBucket, excludeKeys: Set<String> = [], k: Int = RecommendationConstants.kTarget, lambda: Double = RecommendationConstants.lambdaMMR) -> [InternetArchiveSearchResult]`
  — the engine's current filter→dedup→score→MMR body: drop non-
  `isStrictLibriVoxCatalogCandidate`, drop excluded, dedup by `identityKeys`,
  `scoreCandidates`, `greedyMMR`.

- `recommendations(history:onboardingSelectionIDs:candidates:excludeKeys:k:) -> [InternetArchiveSearchResult]`
  — the end-to-end pure function the user asked for: build profile; if
  `profile.isEmpty` → `filterExcluded(HomeRecommendationStore.bundledPopularSeeds, ...)`;
  else `rank(...)`; if rank comes back empty → filtered bundled seeds.

- Move from `RecommendationEngine` (as `public static`, updating the engine and
  all tests to call the pipeline): `scoreCandidates`, `extractTokens`,
  `greedyMMR`, `jaccardSimilarity`, `identityKeys(for:)`,
  `filterExcluded(_:excludeKeys:)` (order-preserving, for bundled seeds), and an
  `isExcluded(_:excludeKeys:)` helper.

### 1.2 New file `Voxglass/Core/Catalog/Recommendations/OnboardingTasteSeeds.swift`

```swift
public enum OnboardingTasteSeeds {
    public struct Seed: Equatable { public let axis, term: String; public let weight: Double }
    public static func seeds(for selectedCollectionIDs: Set<String>) -> [Seed]
}
```

Iterate `selectedCollectionIDs.sorted()` (determinism): a browse category
(`LibriVoxBrowseCategory.category(withID:)`) contributes its
`representativeSubjects` as `subject` seeds at
`RecommendationConstants.onboardingSeedWeight`; otherwise the ID goes to
`CuratedQueries.representativeCreators(forCollectionID:)` and contributes
`author` seeds at the new `onboardingAuthorSeedWeight`. `popular-librivox`
maps to neither → contributes nothing (it carries no taste information).

In `IACollection.swift`, add to `CuratedQueries`:

```swift
public static func representativeCreators(forCollectionID id: String) -> [String]
```

returning a **spread sample of 8** (deterministic stride over the full list —
`index = Int(Double(i) * Double(count) / 8.0)`) from `greatBooksCreators` /
`greaterBooksCreators` / `ancientGreeceCreators` for the three curated IDs,
`[]` otherwise. (Stride, not `prefix`, so Great Books isn't seeded as
ancient-Greece-only.)

In `RecommendationConstants` add, with doc comments stating the invariant:

```swift
/// Smallest increment any meaningful listen can contribute (applySignal floors
/// at max(0.5, completion); historyIncrement floors at 0.5).
public static let minListenIncrement: Double = 0.5
/// Onboarding author seeds must stay BELOW minListenIncrement so one real
/// listen always outranks onboarding picks in the creator ranking.
public static let onboardingAuthorSeedWeight: Double = 0.4
```

Use `minListenIncrement` as the floor inside `applySignal`
(`max(0.5, completion)` → `max(RecommendationConstants.minListenIncrement, completion)`)
and in `historyIncrement`.

### 1.3 `TasteProfileStore` becomes a persistence shell

- `rebuildFromListeningHistory(version:selectedCollectionIDs:)`: keep the SQL
  (it already returns per-book `axis/term/listened_seconds/applied_increment/is_favorite`
  rows) but **group rows by `book_id` into `[ListeningHistoryEntry]`**, call
  `RecommendationPipeline.termWeights(history:onboardingSelectionIDs:)`, and
  persist the result in the existing DELETE-then-INSERT transaction. Net effect
  identical for browse picks; curated picks now seed authors.
- `seedOnboardingPicks(from:)`: replace the body with a loop over
  `OnboardingTasteSeeds.seeds(for:)` calling `upsertTerm` with each seed's
  weight (drop the hardcoded `onboardingSeedWeight` + subject-only mapping).
- `fetchProfile()`: keep the DB read (`fetchRawTerms`) but delegate the
  dampening to `RecommendationPipeline.profile(fromRawTerms:)`.
- **Delete** `hasMeaningfulProfile()`, `hasDurableTasteSignal()`, and the legacy
  author/language special-case (the engine no longer gates on it, §1.4).
  Keep `hasProfile()` only if something still calls it; otherwise delete.
- Delete the private `normalizedTerm` / `isCollectionLikeSubject` /
  `knownCollectionIDs` (now in the pipeline).

### 1.4 `RecommendationEngine` — use the profile whenever it exists

New `fetchRecommendations` flow:

1. `excludeKeys = buildExcludeKeys()` (unchanged).
2. `profile = await profileStore.fetchProfile()`.
3. `guard !profile.isEmpty else { return RecommendationPipeline.filterExcluded(bundledPopularSeeds, excludeKeys) }`
   — **no more `hasMeaningfulProfile` gate**. `fetchProfile` already filters
   legacy junk terms, so junk-only tables still fall back safely.
4. Build queries with `RecommendationQueryBuilder.generateQueries` (unchanged)
   and fetch candidates for `queries.prefix(6)` (unchanged, with timeout).
5. `ranked = RecommendationPipeline.rank(candidates:profile:excludeKeys:k:)`.
6. If `ranked.count < RecommendationConstants.minShelf`, fetch the fallback
   queries (unchanged `buildFallbackQueries`) and re-rank once over
   primary + fallback candidates combined.
7. Empty → filtered bundled seeds. Otherwise `pushSurfaced` + `prefix(18)`
   (unchanged).

Delete the engine's private copies of everything moved to the pipeline.

### 1.5 `book_taste` backfill (the app-upgrade path — this is what fixes the phone)

- `LibraryRepository`: add

  ```swift
  /// Books imported before taste capture existed (2026-07-11) have no
  /// book_taste rows, so their listening history is invisible to the
  /// recommendation profile. Seed author terms from the locally stored
  /// authors for any book with zero book_taste rows. Idempotent.
  @discardableResult
  public func backfillBookTasteIfNeeded() async -> Int
  ```

  Implementation: one query for books with no `book_taste` rows
  (`SELECT b.id, b.authors_json FROM books b LEFT JOIN book_taste bt ON
  bt.book_id = b.id WHERE bt.book_id IS NULL`); for each, decode authors and
  `INSERT OR IGNORE` lowercase `author` terms, skipping
  empty/"Unknown"/"Various" exactly like `importInternetArchiveItem` does.
  Return the number of books backfilled. Only authors — subjects/languages are
  not stored locally and must not trigger network at startup.
- `AppServices.bootstrap()`: call `await libraryRepository.backfillBookTasteIfNeeded()`
  immediately **before** `rebuildTasteHistory()` (which then folds the new
  author terms into the profile weighted by each book's listened seconds).

### 1.6 `HomeRecommendationStore` — remove the dead path, fix launch ordering

- Delete the legacy no-engine network branch in `load(...)` (lines 44-69): when
  `engine == nil`, show `coldStartRecommendations` and return. If
  `LibriVoxRecommendationQueryBuilder` (LibriVoxTaste.swift:81) then has no
  remaining callers, delete that enum (only it — keep the rest of the file).
- Launch ordering: `ListenView.task` fires before `AppServices.bootstrap()` has
  backfilled/rebuilt, so the first engine load can read a stale profile. Add a
  readiness gate:
  - `private var engineReady = false`; new `public func markEngineReady()`.
  - `load(...)`: if `engine == nil || !engineReady`, set cold-start
    recommendations (if empty) and return without fetching.
  - `AppServices.bootstrap()`, after `rebuildTasteHistory()`:
    `homeRecommendationStore.markEngineReady()` then
    `await homeRecommendationStore.load(selectedCollectionIDs: <decoded from
    UserDefaults, same as rebuildTasteHistory>, selectedLanguages:
    AppPreferencesStore.decodeLanguages(...))`. This gives exactly one engine
    fetch per launch, after the profile is correct.
  - Existing store tests must call `markEngineReady()` after `configure(...)`.

### 1.7 Tests

Run with `swift test` (macOS, CI "Logic Tests" job) and the full simulator gate
`scripts/test.sh` locally before finishing. New test files land in
`VoxglassTests/` (picked up by the SPM test target path glob; no xcodegen run
needed for test/Core files).

**New `VoxglassTests/RecommendationPipelineTests.swift`** — the pure suite the
user asked for. Helper `entry(author:subject:...)` builds
`ListeningHistoryEntry`; helper `candidate(...)` mirrors
RecommendationEngineTests'. Cases (assert on `buildProfile`,
`RecommendationQueryBuilder.generateQueries(profile:...)`, and
`RecommendationPipeline.recommendations(...)`):

1. **Empty everything** → `recommendations` returns bundled popular seeds in
   curated order; excluded seeds are dropped.
2. **Early listener, one meaningful listen** (one entry, 20% of a 10h book =
   7200s, no onboarding): profile's top creator is that author;
   `generateQueries` contains a `creator:"<author>"` exploit query;
   `recommendations` with a candidate pool returns author-matched candidates
   ranked above unrelated popular ones and never the bundled fallback.
3. **One listen + onboarding**: entry with 30-min listen (floors at
   `minListenIncrement`) plus `onboardingSelectionIDs = ["great-books"]`;
   assert the listened author outranks every onboarding-seeded author in
   `profile.creatorTerms` (this pins the `onboardingAuthorSeedWeight <
   minListenIncrement` invariant behaviorally) and both influence the profile.
4. **Onboarding-only, browse pick** (`lv-mystery-crime`): profile non-empty
   with the category's representative subjects; queries non-empty (subject
   explore queries); `recommendations` returns candidate-pool books, not
   bundled seeds.
5. **Onboarding-only, curated pick** (`ancient-greece`): profile has 8 author
   terms; queries include `creator:` clauses; tuned results.
6. **`popular-librivox`-only onboarding** → empty profile → bundled seeds
   (no taste information).
7. **The user's exact shape — long-time listener**: 12 entries; 2 finished
   (~8h each), 1 mostly (70% of 10h), 9 barely touched (300s each); plus
   onboarding. Assert: top creators are the finished/mostly books' authors, in
   that order ahead of barely-touched authors; `recommendations` over a mixed
   candidate pool is tuned (contains same-author and same-subject candidates,
   excludes already-listened identity keys, never equals bundled seeds).
8. **Upgrade/backfill shape — author-only terms**: entries with only `authors`
   populated (no subjects/languages, as the backfill produces): profile
   non-empty, exploit queries generated, tuned results.
9. **Favorites**: unlistened favorite entry contributes `favoriteBoost`.
10. **Junk resistance**: stop-list subjects damped ×0.05; `lv-*`/curated-ID
    subject terms dropped; "Unknown"/"Various" authors dropped.
11. **Determinism**: same inputs → identical output (call twice, compare).

**Updates to existing tests:**

- `RecommendationEngineTests`:
  - Replace `testOnboardingOnlyProfileKeepsBundledPopularSeedsWithoutNetworkRefresh`
    with `testOnboardingOnlyProfileFetchesTunedRecommendations`: same setup,
    but assert the fake client **was** queried, queries contain the category's
    subjects, and the returned recs are the fake's personalized results.
  - Point moved statics at `RecommendationPipeline`
    (`extractTokens`/`scoreCandidates`/`greedyMMR`/`jaccardSimilarity`).
  - Add `testEngineTunesAfterSingleMeaningfulListen`: `seedListenedBook` (which
    writes `book_taste` + `listening_events`), `rebuildFromListeningHistory`,
    then assert the engine's first query set includes
    `creator:"<listened author>"` and the result comes from the fake client.
- `TasteProfileStoreTests`:
  - Delete `testOnboardingOnlySeedsAreNotMeaningfulRecommendationProfile` and
    `testFavoriteBookContributesMeaningfulProfileWeight`'s
    `hasMeaningfulProfile` assertion (keep its weight assertion).
  - Add `testRebuildSeedsCuratedOnboardingPicksAsAuthors` (rebuild with
    `["great-books"]` → author rows at `onboardingAuthorSeedWeight`).
  - Add `testHistoryIncrementFloorsAndCaps` moved to pipeline tests; update
    callers of `TasteProfileStore.historyIncrement`.
  - Add `testOnboardingAuthorSeedWeightStaysBelowMinListenIncrement`:
    `XCTAssertLessThan(RecommendationConstants.onboardingAuthorSeedWeight,
    RecommendationConstants.minListenIncrement)`.
- New `LibraryRepositoryTests` case (or new file `BookTasteBackfillTests.swift`):
  insert a book + listening event with **no** `book_taste` rows (copy
  `seedHistoryBook` minus the taste inserts), run `backfillBookTasteIfNeeded()`
  (returns 1), run it again (returns 0, no duplicate rows), then
  `rebuildFromListeningHistory` → profile contains the book's author. This is
  the end-to-end app-upgrade test.
- `TasteSignalCaptureTests`: unchanged semantics; fix compile breaks only.

---

## Part 2 — Bundle featured-collection counts at build time

### 2.1 Generator tool (SPM executable, zero query drift)

Add to `Package.swift`:

```swift
.executableTarget(
    name: "collection-counts",
    dependencies: ["VoxglassCore"],
    path: "Tools/CollectionCounts"
)
```

`Tools/CollectionCounts/main.swift`: for every collection in
`IACollectionStore.collections(for: [])` (all 25: popular + 3 curated + 21
browse), request
`https://archive.org/advancedsearch.php?q=<archiveQuery + LibriVoxLanguage.clause(for: ["eng"])>&rows=0&output=json`
(URL-encode via `URLComponents`; reuse the query strings from the imported
`VoxglassCore` types — that is the whole point of the executable target),
decode `response.numFound`, and **regenerate**
`Voxglass/Core/Catalog/CollectionBundledCounts.swift`:

```swift
// Generated by `swift run collection-counts` — do not edit by hand.
// Approximate archive.org numFound per featured collection for the default
// English language selection, captured at generation time.
public enum CollectionBundledCounts {
    public static let languages: Set<String> = ["eng"]
    public static let counts: [String: Int] = [
        "popular-librivox": <numFound>,
        ...
    ]
}
```

Sorted keys for stable diffs. Any request failure aborts the run with a nonzero
exit (never write partial data). Verified live: the `rows=0` numFound query
returns HTTP 200 with `response.numFound` for these queries. Run the tool once
and commit the generated file. CI note: the macOS `swift test` job will build
the executable target — `URLSession` is fine there; the Ubuntu job only runs
shell guards, so no Linux portability work is needed.

### 2.2 `CollectionCoverStore` serves bundled counts without network

In `resolveCounts(for:languages:force:)`, before the in-flight/network path for
each collection: if `languages == CollectionBundledCounts.languages` and
`CollectionBundledCounts.counts[collection.id]` exists, set
`counts[collection.id]` to the bundled value, record the stamp, persist, and
`continue` — **no query**. Non-default language selections keep the existing
live `rows: 0` path (counts genuinely differ per language and only refresh on
language change). `count(for:)` and `BrowseView` call sites stay unchanged.

### 2.3 Tests (`CollectionCoverStoreTests` + new assertions)

- Default English selection: after `resolveCounts` for a browse collection with
  a `FakeCoverClient`, `count(for:)` equals the bundled value and the fake
  client received **zero** queries (extend `FakeCoverClient` with a query
  counter).
- Non-default language (`["ger"]`): fake client **is** queried; `count(for:)`
  reflects the fake `numFound`.
- Completeness: every ID in `IACollectionStore.collections(for: [])` has a
  bundled count > 0 (catches a forgotten regeneration after adding a
  collection).

---

## Part 3 — Explore: sort tabs must not reset scroll position

`Voxglass/Features/Discover/DiscoverView.swift`, `catalogResults`:

- Show the "Searching LibriVox" progress panel **only when
  `catalogStore.results.isEmpty`**. When results already exist and
  `catalogStore.isSearching` is true (re-sort or new-collection tap), keep the
  current list rendered — apply `.opacity(0.5)` (or similar dim) and disable
  row buttons, with a small trailing `ProgressView` next to the section title
  or overlaid `topTrailing` like ListenView's refresh indicator.
- `CatalogStore.runSearch` already retains old `results` until the new page
  arrives, so nothing in Core changes. When the new results land the list swaps
  in place and the outer scroll view keeps its offset.
- No unit test is practical for scroll offset; verify manually via `/run`:
  open Explore → pick a collection → scroll down a bit → switch
  popularity/title/author/date and confirm the viewport does not jump, and that
  a brand-new collection tap still works (content near top anyway).

---

## Sequencing & ground rules

Order: **1.1→1.2 (pipeline + seeds) → 1.3/1.4 (store/engine refactor) →
1.5/1.6 (backfill + wiring) → 1.7 (tests green) → Part 2 → Part 3.**
Parts 2 and 3 are independent of Part 1 and of each other.

Binding rules from `plan.md` (unchanged): no third-party dependencies; never
edit `Voxglass.xcodeproj` by hand (new Core/test files are picked up by
existing globs; the only project-file-adjacent change here is `Package.swift`);
schema changes via numbered migrations (none are needed — `book_taste` backfill
is data, not schema); no logging/analytics; only `archive.org` traffic; match
existing style. **Never lose playback position** — nothing here touches
playback persistence; keep it that way.

Definition of done: `swift build` and `swift test` pass; `scripts/test.sh`
(simulator) passes locally; the generated counts file is committed; manual
simulator checks — (a) Listen tab shows tuned recommendations after a listen,
(b) onboarding picks visibly change Recommended for You on a fresh install,
(c) Explore sort tabs preserve scroll, (d) no count queries fire at startup
with default language (verify via absence of `rows=0` requests, e.g.
breakpoint/temporary assertion during the check, then removed).
