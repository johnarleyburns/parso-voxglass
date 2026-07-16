# Voxglass — Post-Field-Test Improvements

> Supersedes the completed "UI & Backend Cleanup Plan" (shipped in recent commits;
> see git history). This is the current active plan.

> **Status:** §1 (multi-language), §2 (pagination), §3 (dynamic collection artwork),
> and §4 (alphabetical sort) are **shipped**. §5 (on-device recommendation engine)
> closeout is **implemented and unit-tested** (subjects flow into scoring/MMR, taste capture
> is thresholded/delta-based via `taste_signal_state` migration 8, and
> `TasteProfileStoreTests`/`RecommendationEngineTests`/`TasteSignalCaptureTests` pass along with
> the full suite and simulator build). The closeout also fixed a latent `upsertTerm` bug where the
> decay-path SQL had an unbound parameter, so repeat signals silently never updated weights.
> Remaining before marking §5 done: the manual simulator checks listed in step 4 below.
> §6 (monetization / iCloud sync) remains as its own later phase.

## Immediate §5 closeout — coding agent instructions

**Goal.** Close the remaining recommendation-engine gaps without reopening the shipped §1-§4 work:
subjects must reach scoring/MMR, live taste capture must stop over-counting periodic saves, and the
recommendation math must have focused unit coverage. Do not add dependencies or change the public `Book`
model; keep using `book_taste` for imported metadata.

**1. Send Internet Archive subjects through search results into scoring.**
- In `Voxglass/Core/Catalog/InternetArchiveClient.swift`, add `URLQueryItem(name: "fl[]", value: "subject")`
  to `advancedSearchURL` next to the existing `language` field.
- In `Voxglass/Core/Catalog/InternetArchiveModels.swift`, add `subjects: [String]` to
  `InternetArchiveSearchResult` and `InternetArchiveSearchDocument`; decode with
  `decodeStringListIfPresent(forKey: .subject)` and default the public initializer to `subjects: []`.
- Update every seed, fixture, and compile failure caused by the initializer change. Existing bundled seeds
  may keep `subjects: []`; real IA search results must preserve decoded subjects.
- In `RecommendationEngine.extractTokens`, include normalized subject terms in addition to creators and
  languages. Trim, lowercase, drop empties, and ignore `RecommendationConstants.subjectStopList`. Because
  `jaccardSimilarity` already calls `extractTokens`, this also makes MMR diversity subject-aware.
- Add tests proving `advancedSearchURL` requests `subject`, string/array `subject` values decode, and a
  candidate sharing a profile subject outranks a candidate that only has popularity.

**2. Replace periodic-save taste capture with thresholded delta capture.**
- Replace `PlaybackCoordinator.onPositionSaved: ((UUID, Bool) -> Void)?` with
  `onTasteSignal: ((PlaybackTasteSignal) -> Void)?`. Define `PlaybackTasteSignal` in the playback core
  with `bookID: UUID`, `isFavorite: Bool`, `position: TimeInterval`, `duration: TimeInterval?`, and
  `isFinished: Bool`.
- Emit the signal only after `positionStore.save` succeeds. In `PlaybackCoordinator`, gate emission by
  `PositionPersistReason`: emit for `periodic`, `pause`, `background`, `interruption`, `routeChange`,
  `chapterChange`, and all `finished` saves; do not emit for a bare `.seek` or `.skip`.
- Add `RecommendationConstants.meaningfulListenCompletion = 0.20`.
- Append the next `DatabaseMigrations.swift` migration after the current max ID. Add:
  `taste_signal_state(book_id TEXT PRIMARY KEY REFERENCES books(id) ON DELETE CASCADE,
  max_completion REAL NOT NULL DEFAULT 0, applied_increment REAL NOT NULL DEFAULT 0,
  updated_at REAL NOT NULL)`.
- Move the calibration logic into `TasteProfileStore` (or a small recommendations-core helper it owns) so
  SQLite state and profile upserts happen together:
  - Compute `completion = isFinished ? 1.0 : clamp(position / duration, 0...1)`; ignore events with invalid
    duration unless `isFinished`.
  - Ignore events below `0.20` completion unless `isFinished`.
  - Compute `targetIncrement = max(0.5, completion)` and multiply by `RecommendationConstants.favoriteBoost`
    when `isFavorite`.
  - Load the row from `taste_signal_state`; upsert only `delta = targetIncrement - applied_increment` when
    `delta > 0.0001`.
  - Apply that same positive delta to each `(axis, term)` returned by
    `LibraryRepository.fetchBookTasteTerms(for:)`, then update `max_completion`, `applied_increment`, and
    `updated_at`.
- Update `AppServices.captureTasteSignal` to fetch the book's taste terms once per eligible event and call
  the new delta-capture API. Periodic saves after the first threshold crossing must become no-ops unless
  completion/favorite state raises the target increment.
- Leave `TasteProfileStore.historyIncrement(forSeconds:)` unchanged; historical backfill remains
  `min(12, max(0.5, hours))`.

**3. Add the missing recommendation tests.**
- Add `VoxglassTests/TasteProfileStoreTests.swift` if absent, or extend the nearest existing test file:
  decay update matches `prev * exp(-dt / tau) + increment`; subject damping downweights broad/stop-list
  terms; surfaced ring respects `RecommendationConstants.recoSurfacedCap`; `historyIncrement` keeps its
  `0.5` floor and `12.0` cap.
- Add `VoxglassTests/RecommendationEngineTests.swift`: subject tokens influence scoring, MMR diversifies
  near-duplicate same-author/same-subject candidates, and `WorkKey.normalized` collapses reuploads such as
  `"Frankenstein"` vs. `"Frankenstein (version 2)"`.
- Add `VoxglassTests/TasteSignalCaptureTests.swift`: below-20% periodic saves do not upsert; crossing 20%
  upserts once; repeated periodic saves do not change weights; finishing adds only the completion delta;
  favoriting adds only the favorite delta once.
- Use the reference shapes in `../parso-radio-ios-app/ParsoRadio/Core/Tests/` for intent, but adapt names
  and assertions to Voxglass (`author`, `subject`, `language`, `book_taste`, LibriVox books).

**4. Release housekeeping for this closeout.**
- Regenerate the project only if files or project membership require it: `xcodegen generate`.
- Run:
  - `xcodebuild -scheme Voxglass -destination 'platform=iOS Simulator,name=iPhone 16' build`
  - `xcodebuild -scheme Voxglass -destination 'platform=iOS Simulator,name=iPhone 16' test`
- Manual simulator checks: fresh install still shows cold-start seeds; listening past 20% of a subject-rich
  book shifts "Recommended for You" toward that author/subject; leaving playback running for several minutes
  does not inflate profile weights; finished/favorited books influence taste once and are excluded from the
  shelf.
- Before handing back, update this file's §5/Verification wording only if the implementation and tests have
  actually passed. Do not mark §6 complete as part of this closeout.

## Context

Field testing of Voxglass (a privacy-first, LibriVox/Internet-Archive audiobook app —
no accounts, no tracking, no telemetry) surfaced six gaps. This plan addresses each,
plus a monetization review. The competitor feature-gap analysis is intentionally **not**
built here; it lives as a prioritized roadmap in `README.md` (see §7).

Architecture recap (so the executor has the mental model):
- Content comes from the **Internet Archive advancedsearch + metadata API** (`archive.org`),
  scoped to `collection:librivoxaudio`. There is no direct LibriVox API.
- Networking: `Voxglass/Core/Catalog/InternetArchiveClient.swift`.
- Catalog orchestration: `Voxglass/Core/Catalog/CatalogStore.swift`.
- Persistence: raw SQLite (`actor AppDatabase`) under `Voxglass/Core/Database/`; light prefs
  in UserDefaults via `AppPreferencesStore` (`@AppStorage`).
- No third-party dependencies. Xcode project is generated by **XcodeGen** from `project.yml`
  (the `.xcodeproj` is a build artifact — never hand-edit it).
- Reference app for recommendations: `../parso-radio-ios-app` (on-device taste engine).

Decisions locked with the user:
- **Language**: multi-select set, English preselected but fully removable; applies to search,
  browse, and recommendations.
- **Monetization**: expand the one-time Pro bundle **and** add iCloud/CloudKit sync as a Pro anchor.
- **Competitor gaps**: prioritized roadmap goes in the README; this plan stays on the six items.

---

## 1. Multi-language search & browse

**Problem.** Everything is implicitly English. Search (`libriVoxQuery`) sends no `language`
clause; the 21 browse categories and `popular` have none; only `CuratedQueries.greatBooks` /
`greaterBooks` hardcode `language:eng` (and `ancientGreece` inconsistently omits it). No user
setting for language exists.

**Approach — inject a single `language:(...)` clause centrally; never per-query-string.**

1. **Preference store.** Add to `Voxglass/App/AppPreferencesStore.swift`:
   - `Keys.selectedLanguages = "voxglass.selectedLanguages"`, default `"eng"`.
   - `selectedLanguages: Set<String>` computed accessor + `encode/decodeLanguages` helpers,
     mirroring the existing `selectedCollectionIDs` CSV pattern (lines 14-30).
2. **Language catalog.** New `Voxglass/Core/Catalog/LibriVoxLanguage.swift`: a curated list of the
   top LibriVox languages, each with a display name and its archive.org query token(s). Because
   the IA `language` field is inconsistent (codes vs. full names), each entry's clause should OR
   the forms, e.g. English → `(language:eng OR language:English)`, German →
   `(language:ger OR language:deu OR language:German)`. Seed ~15: English, German, French, Dutch,
   Spanish, Italian, Portuguese, Russian, Chinese, Japanese, Latin, Greek, Polish, Finnish, Hebrew.
   **The executor must verify accepted `language:` values against a live archive.org query before
   finalizing tokens** (see Verification).
3. **Central clause builder.** In `LibriVoxLanguage` add
   `static func clause(for codes: Set<String>) -> String` returning
   `" AND (\(perLanguage joined by OR))"`, or `""` when the set is empty/represents "all".
4. **Injection point.** `CatalogStore` is the chokepoint. Give it a `selectedLanguages: Set<String>`
   property (kept in sync from `AppPreferencesStore`) and append `LibriVoxLanguage.clause(...)` to the
   query in `searchLibriVox`, `searchAdvanced`, and `searchCollection` before delegating to the client.
   Do the same for recommendation queries (§5) and collection-cover resolution (§3).
5. **Remove now-redundant hardcoding.** Strip `AND language:eng` from `CuratedQueries.greatBooks`
   and `greaterBooks` in `IACollection.swift:268-272` so the central injection is the single source
   of truth (leaves `ancientGreece` consistent too).
6. **Return the field.** Add `language` to the `fl[]` list in
   `InternetArchiveClient.advancedSearchURL` (line 119-132) and decode it on
   `InternetArchiveSearchDocument`/`InternetArchiveSearchResult` (`InternetArchiveModels.swift`),
   using the existing `decodeStringListIfPresent` flexible helpers. Needed for §5 metadata and display.
7. **UI.** Add a languages multi-select:
   - Onboarding: extend `Features/Onboarding/OnboardingPreferencesView.swift` (a step or inline section),
     defaulting English checked.
   - Settings: a new `LanguagesCard` in `Features/Settings/SettingsView.swift`, same visual language as
     `CacheSettingsCard`. Changing selection re-runs the current Explore query and reloads Home recs.

**Key files:** `AppPreferencesStore.swift`, new `LibriVoxLanguage.swift`, `CatalogStore.swift`,
`InternetArchiveClient.swift`, `InternetArchiveModels.swift`, `IACollection.swift` (CuratedQueries),
`OnboardingPreferencesView.swift`, `SettingsView.swift`.

---

## 2. "See more" pagination in Explore Results

**Problem.** `catalogResults` in `DiscoverView.swift:55-91` renders a flat `ForEach(catalogStore.results)`
capped at 25 rows; the request always sends `page=1` (`InternetArchiveClient.advancedSearchURL:123`)
and there is no load-more path.

**Approach — add real paging through the client → store → view.**

1. **Client.** Add a `page` parameter to `searchAdvanced(query:rows:page:)` and thread it into
   `advancedSearchURL` (replace the hardcoded `page=1`). Decode `response.numFound` from the
   advancedsearch response (add to `InternetArchiveSearchResponse` in `InternetArchiveModels.swift`)
   so the store can compute `hasMore`.
2. **Store.** In `CatalogStore`, retain the active query, current `page`, and `numFound`; add
   `loadMore()` that fetches the next page and **appends** (dedup by identifier, reuse the pattern in
   `HomeRecommendationStore.uniqueResults`). Expose `hasMore` and an `isLoadingMore` flag distinct from
   the initial `isSearching`.
3. **View.** In `catalogResults`, after the last row, render either an infinite-scroll trigger
   (`.onAppear` on the final `InternetArchiveResultRow` calling `catalogStore.loadMore()`) or an explicit
   "See More" button, gated on `hasMore`, with a trailing `ProgressView` while `isLoadingMore`. Prefetch
   artwork for appended results (extend the existing `.onChange(of:)` prefetch at `DiscoverView.swift:28-30`).

**Key files:** `InternetArchiveClient.swift`, `InternetArchiveModels.swift`, `CatalogStore.swift`,
`DiscoverView.swift`.

---

## 3. Every featured collection must have artwork

**Problem.** Collection covers are static, hand-typed archive.org identifiers
(`IACollection.coverURL(for:)`, lines 162-209). Some 404 or resolve to the archive.org "notfound"
placeholder — Science Fiction (`time_machine_librivox`) and Mystery & Crime
(`adventuresofsherlockholmes_1110_librivox`) among them. When `ArtworkService.validatedImage`
(`ArtworkService.swift:116-138`) rejects them, the card falls back to an SF-Symbol gradient (no image).

**Approach — derive each cover from the most-downloaded item in the collection that has valid artwork,
and cache the result.**

1. **Resolver.** New `Voxglass/Core/Catalog/CollectionCoverStore.swift` (`@MainActor ObservableObject`
   or an actor + published map). For a collection: run its `archiveQuery` sorted `downloads desc`
   (the client's default sort) at `rows: ~10`, then walk results and pick the first identifier whose
   `ArtworkService.shared.loadImage(for:)` succeeds (validation already rejects notfound/tiny images).
   Use that item's `InternetArchiveMetadata.coverURL(for:)` as the collection cover.
2. **Cache.** Persist resolved `collectionID → identifier` in UserDefaults so covers are stable across
   launches and don't re-resolve every time. Invalidate when the language selection changes (§1), since
   the top item can differ by language.
3. **Wiring.** On Explore appear, resolve covers for any collection whose static cover is missing or
   fails validation; feed the resolved `remoteImageURL` into `ExploreCollectionCard`
   (`DiscoverView.swift:124-158` → `CollectionArtworkView`). Keep the current hardcoded identifier as a
   first guess (fast path) and the SF-Symbol gradient only as a genuinely-last resort.
4. **Immediate mitigation.** Also correct the two known-bad identifiers in `coverURL(for:)` so the fast
   path is healthy even before dynamic resolution runs.

**Guarantee.** Because `popular` and every browse/curated query returns hundreds of illustrated items,
dynamic resolution will find a valid cover for all collections; the gradient fallback should never show
in practice. A lightweight test asserts every `IACollectionStore` collection yields a non-nil resolved
cover (mock the client).

**Key files:** new `CollectionCoverStore.swift`, `IACollection.swift`, `DiscoverView.swift`,
reuse `ArtworkService.swift` + `InternetArchiveMetadata.coverURL(for:)`.

---

## 4. Sort featured collections alphabetically

**Problem.** `IACollectionStore.collections(for:)` (`IACollection.swift:94-100`) returns
`popular → 21 browse (group order) → 3 curated`, with user-selected IDs floated to the front.

**Approach.** Return the full list sorted alphabetically by `title` (case-insensitive, localized).
This supersedes both the group ordering and the selected-float behavior — per the explicit requirement
that the list be "all sorted alphabetically by name." (If a pinned "Popular LibriVox" is later desired,
that's a deliberate exception to revisit; default here is pure alphabetical.)

**Key files:** `IACollection.swift` (`collections(for:)`). Update any test asserting the old order.

---

## 5. Intelligent, on-device "Recommended for You"

**Problem.** `HomeRecommendationStore` recommends off onboarding-selected collection IDs + hardcoded
seeds (`HomeRecommendationStore.swift:16-52`). It ignores listening history entirely, even though
playback history exists (`playback_positions` via `PositionStore`; recently-played via
`LibraryRepository.fetchRecentlyPlayed`). Also, `Book` stores no subject/genre/language, so there's no
per-book metadata to key off.

**Approach — port the `parso-radio` content-based taste engine (decayed term-frequency profile +
cosine scoring + MMR diversification), adapted for audiobooks.** No ML, no accounts — pure SQLite +
arithmetic, consistent with the privacy stance. Reference implementation:
`../parso-radio-ios-app/ParsoRadio/Core/Services/` (`Storage/TasteProfileStore.swift`,
`API/RecommendationQueryBuilder.swift`, `API/RecommendationConstants.swift`,
`Playback/RecommendationsController.swift`, `Utilities/WorkKey.swift`).

**5a. Persist per-book taste metadata.**
- At import (`LibraryRepository.importInternetArchiveItem`), capture `subjects` and `language` from the
  IA item metadata. Extend `InternetArchiveItemMetadata` decoding (`InternetArchiveModels.swift`) to
  read `subject` (flexible string/array) and `language`.
- Store them via a new `book_taste(book_id, axis, term)` table (axes: `author`, `subject`, `language`)
  — a schema-3 migration in `Voxglass/Core/Database/DatabaseMigrations.swift`. A side table avoids
  altering the `Book` model surface and keeps terms multi-valued.

**5b. Taste profile store (new SQLite tables, schema-3 migration).**
- `taste_profile_terms(axis, term, weight, last_ts)` indexed `(axis, weight DESC)`.
- `reco_surfaced(identifier, ts)` ring buffer (cap ~500) so recommendations don't repeat.
- New `Voxglass/Core/Catalog/Recommendations/TasteProfileStore.swift`. Port the **lazy exponential
  decay** upsert verbatim (`decayed = prevWeight * exp(-dt/tau)` then `+ increment`, `tau = 21 days`) —
  see `parso-radio .../DatabaseService.swift` upsert. On read, apply subject damping
  `÷ (1 + log(distinctSubjectCount + 1))` so broad genres don't swamp specific authors; leave author
  weights undamped.

**5c. Signal capture (audiobook-aware improvement over the reference).**
- Hook `PositionStore.save` / the playback coordinator: when a book crosses a meaningful-listen
  threshold (e.g. > ~20% listened) or `isFinished` flips true, upsert its author/subject/language terms
  with `increment = 1.0`; use `~3.0` for `isFavorite`; `~1.75` for onboarding genre picks. Scale the
  increment by completion so quickly-abandoned books contribute little (the one signal parso-radio omits).

**5d. Query builder + scorer + diversifier.**
- New `RecommendationQueryBuilder.swift`: exploit (`creator:"<top author>"`) / explore
  (loved-subject × adjacent co-occurring subject) / serendipity (date-seeded random sibling subject),
  each scoped `collection:librivoxaudio` + the §1 language clause. Port the `classMix`
  (exploit 0.55 / explore 0.35 / serendipity 0.10) and adjacency logic.
- New `RecommendationEngine.swift`: fan out queries via `CatalogStore`/client, then score candidates —
  cosine affinity of `{author, subject, language}` tokens against the profile vector + small popularity
  prior (`downloads`) — then **MMR** (Jaccard, `lambda 0.5`, `kTarget ~24`). Port
  `RecommendationConstants.swift` (wAffinity 0.55, wPop 0.10, minShelf 10).
- **Exclusion:** filter out books already in the library / finished and anything in `reco_surfaced`;
  push final picks into the ring. Reuse a `WorkKey`-style `author·title` normalizer (port
  `parso-radio/.../WorkKey.swift`) so re-uploads of the same work don't slip through.

**5e. Wire into Home.**
- Rework `HomeRecommendationStore.load` to call the engine when a taste profile exists; keep the current
  `bundledPopularSeeds` / collection-keyed `bundledTasteSeeds` as the **cold-start** path for empty
  profiles. Show the cached previous shelf instantly, refresh in the background after playback events
  (mirror parso-radio's snapshot + rebuild pattern). Rendered by `ListenView.recommended`
  (`ListenView.swift:111-147`) — no view change required beyond binding to the new results.

**Key files (mostly new):** `Core/Catalog/Recommendations/{TasteProfileStore,RecommendationConstants,
RecommendationQueryBuilder,RecommendationEngine,WorkKey}.swift`; edits to `DatabaseMigrations.swift`,
`LibraryRepository.swift`, `PositionStore.swift`/playback coordinator, `InternetArchiveModels.swift`,
`HomeRecommendationStore.swift`. This is the largest item — land it after 1–4.

---

## 6. Monetization: expand one-time Pro + iCloud/CloudKit sync anchor

**Current state.** One-time non-consumable "Voxglass Pro" ($9.99) via StoreKit 2
(`Core/Services/Pro/`). Gates today: cache presets, EQ. Declared-but-unwired: `prefetchDepth`,
`folderWatch`, `carplay`. No subscription, no ads, no analytics — an explicit product stance
("no accounts, no tracking, no telemetry"). Free-tier guarantees pinned by
`VoxglassTests/FreeTierRegistryTests.swift`.

**Direction (user-selected): keep the lifetime unlock and grow its value; add iCloud sync as the anchor.**

1. **Grow the Pro bundle** (no subscription, privacy intact):
   - Wire the already-declared `ProFeature.prefetchDepth`, `.folderWatch`, `.carplay` to real gates as
     those features ship.
   - Add the highest-value new Pro features from the roadmap (§7) — notably **listening stats** and the
     **Apple Watch app** — behind the existing single unlock.
2. **iCloud/CloudKit sync (the anchor, its own phase).** Cross-device sync of playback position,
   bookmarks, and favorites via the **user's own iCloud** — CloudKit *private* database (or
   `NSUbiquitousKeyValueStore` for the smaller position/bookmark set). This adds **no app account and no
   server of ours**, so it stays consistent with the privacy stance: data lives in the user's iCloud, not
   telemetry. Add `ProFeature.icloudSync`; gate the sync engine behind it. This directly closes the #1
   monetizable competitor gap (cross-device position sync) without compromising positioning.
   - Sync layer plugs into the SQLite stores (`PositionStore`, bookmarks table, `books.is_favorite`);
     design it as a mirror/merge with last-writer-wins on `updated_at`.
3. **Keep free-tier promises.** Never gate formats, near-gapless playback, sources/import, offline
   listening, or privacy. Update `FreeTierRegistryTests` and the paywall copy
   (`ProPaywallView.swift`) to reflect the expanded bundle. Update the design note under
   `docs/opus-pro-unlock/`.
4. **Explicitly not doing now:** subscriptions and a tip jar (not selected).

**Key files:** `Core/Services/Pro/{ProFeature,StoreManager}.swift`, new sync module (e.g.
`Core/Services/Sync/`), `Features/Settings/{SettingsView,ProPaywallView}.swift`,
`VoxglassTests/FreeTierRegistryTests.swift`, `Resources/Pro.storekit` (unchanged price),
`docs/opus-pro-unlock/`.

---

## 7. Competitor roadmap → README (not built here)

The competitor feature-gap analysis lives as a prioritized backlog in `README.md` under **Roadmap**,
beyond the already-planned CarPlay. It is documentation only — nothing in §7 ships as part of this plan.
See `README.md` for the ranked list with table-stakes / differentiator / premium tags.

---

## Verification

Build/test (regenerate the project first — it's XcodeGen-managed):
```
cd /Users/arley/github/parso-voxglass
xcodegen generate
xcodebuild -scheme Voxglass -destination 'platform=iOS Simulator,name=iPhone 16' build
xcodebuild -scheme Voxglass -destination 'platform=iOS Simulator,name=iPhone 16' test
```
Use the `/run` skill to launch the app in the simulator and drive each change end-to-end.

Per-item checks:
1. **Language.** Before coding the token table, run a live probe, e.g.
   `https://archive.org/advancedsearch.php?q=collection:librivoxaudio AND language:ger&rows=1&output=json`
   for each language to confirm the accepted `language:` value; adjust `LibriVoxLanguage` tokens
   accordingly. Then in-app: select German only → search and browse return German titles; add English
   back → both appear; recommendations respect the set.
2. **Pagination.** Open a collection with > 25 items, scroll/tap "See More", confirm additional distinct
   results load and `hasMore` turns off at the end.
3. **Artwork.** Every Featured Collection card shows a real cover (specifically verify Science Fiction and
   Mystery & Crime); no SF-Symbol gradient. Add a unit test asserting resolved covers are non-nil for all
   collections (mocked client).
4. **Sorting.** Featured Collections render A→Z by title.
5. **Recommendations.** Fresh install → cold-start seeds. Listen to/finish a few books by one author/genre
   → after refresh, "Recommended for You" skews to that author/adjacent subjects and excludes already-heard
   titles. Add unit tests for the decay upsert, subject damping, scorer, and MMR diversification (port the
   parso-radio test shapes).
6. **Monetization.** Free build hits paywall on new Pro features; purchase/restore unlocks; iCloud sync
   round-trips position between two simulators signed into the same iCloud; `FreeTierRegistryTests` pass.

Run the existing guard tests (import/network guards in CI) and `/security-review` on the sync + StoreKit
changes before opening a PR.

---

## Agentic coding handoff instructions

For the engineer/agent executing this plan:

**Ground rules**
- **No third-party dependencies.** SwiftPM config is intentionally empty; use only Apple frameworks
  (Foundation, SwiftUI, AVFoundation, StoreKit, CloudKit, libsqlite3). Do not add SPM packages.
- **Never edit `Voxglass.xcodeproj` by hand.** Add/rename files, then edit `project.yml` if needed and run
  `xcodegen generate`. New Swift files under `Voxglass/` are picked up by the existing source globs.
- **Persistence conventions:** SQLite via `actor AppDatabase`; schema changes go through the next numbered
  migration in `DatabaseMigrations.swift` after the current max ID. Light prefs via `@AppStorage` in
  `AppPreferencesStore`. Stores that publish to SwiftUI are `@MainActor ObservableObject`.
- **Privacy is a hard constraint.** No analytics, logging SDKs, `print`/`os_log`, accounts, or outbound
  traffic except to `archive.org` (and the user's own iCloud for §6). Keep it that way.
- Match surrounding style: value types for models, small focused files, existing naming
  (`lv-*` collection IDs, `voxglass.*` UserDefaults keys, `Palette`/`glassSurface` design system).

**Suggested execution order** (independent → dependent; land as separate PRs/commits):
1. §4 alphabetical sort (tiny, self-contained).
2. §1 language support (touches the query chokepoint many later items rely on).
3. §2 pagination.
4. §3 collection artwork resolution.
5. §5 recommendation engine (largest; depends on §1's language clause and the metadata capture).
6. §6 monetization — bundle wiring first, then the iCloud sync phase.
7. README roadmap (docs; already written — keep it current as items ship).

**Reuse, don't reinvent** — the code these build on already exists:
- Central query injection point: `CatalogStore` methods → `InternetArchiveClient.searchAdvanced`.
- Dedup helper: `HomeRecommendationStore.uniqueResults`.
- Artwork validation/caching: `ArtworkService.shared.loadImage/validatedImage/prefetch`.
- Cover URL: `InternetArchiveMetadata.coverURL(for:)`.
- CSV-set pref pattern: `AppPreferencesStore.encode/decodeCollectionIDs`.
- Recently-played/history: `LibraryRepository.fetchRecentlyPlayed`, `PositionStore`.
- Recommendation math to port: `../parso-radio-ios-app/ParsoRadio/Core/Services/` (see §5 for exact files).

**Definition of done per item:** the change builds, the relevant unit tests (existing + new) pass, the
behavior is verified in the simulator via `/run`, and free-tier guarantees remain green. Commit only when
asked; branch off `main` (do not commit directly to `main`). End commit messages with the required
`Co-Authored-By` trailer.
