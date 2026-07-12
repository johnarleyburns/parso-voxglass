# Voxglass — Field-Test Fixes + Offline Downloads

## Context

Field testing of the Voxglass audiobook app (SwiftUI/iOS, streaming LibriVox/Internet Archive audio
with passive on-disk caching) surfaced six issues, plus a new feature request: **explicit offline
availability** for a whole book. This plan fixes each issue at its root cause (reusing existing
services — `NetworkMonitor`, `CollectionCoverStore`, `StreamCacheStore`, `ArtworkService`,
`download_records` table, `ProFeature`) and adds a Pro-gated, background offline-download capability.

Product decisions confirmed with the user:
- **Cellular:** current-chapter streaming **and** next-chapter prefetch **always** run on cellular
  (prefetch is required to avoid playback gaps). The new toggle gates **only full-book offline
  caching**. Settings must avoid the word "Download" — use **"Cache"** (toggle: **"Cache full books
  on cellular data"**, default OFF).
- **Offline** is a **Pro feature**; free tier = stream + passive cache only.
- Offline downloads run as **true background downloads** (background `URLSession`).
- Collection counts: **approximate, cached** (live IA `numFound`).
- Delete affordance: **both** the library list and Book Detail, each behind confirmation, labeled
  **"Remove from My Books"**.

---

## 1. Featured Collections cards — asymmetric right margin

**Root cause:** In `ExploreCollectionCard` the artwork and text are `width: 190`, but the enclosing
`VStack` is `.frame(width: 210, alignment: .topLeading)` → 20 pt of dead space on the right before
the symmetric `.padding(10)`.

**Fix:** `Voxglass/Features/Discover/DiscoverView.swift` `ExploreCollectionCard` (~line 200): change
`.frame(width: 210, ...)` → `190` (or drop the width). Same bug in
`Voxglass/Features/Onboarding/OnboardingPreferencesView.swift` `OnboardingCollectionCard` (content
170 vs frame 190 → set frame 170).

---

## 2. Approximate book count per Featured Collection

Reuse the live IA total (`numFound`), already returned by `searchAdvancedPage(...) ->
InternetArchivePage.numFound` (`InternetArchiveClient.swift:78`).

- Extend `Voxglass/Core/Catalog/CollectionCoverStore.swift`: add `@Published private(set) var counts:
  [String: Int]` + `resolveCounts(for:languages:)` calling
  `client.searchAdvancedPage(query: collection.archiveQuery + languageClause, rows: 0, page: 1)` and
  storing `.numFound`. Cache to UserDefaults keyed by collection id + language stamp, mirroring the
  existing cover-cache pattern (`persist`, `languageStampChanged`, `loadCache`). Refresh only on
  language change; `rows: 0` keeps each query cheap (~24 total, cached).
- Trigger alongside `resolveCovers` (Discover `BrowseView` `.task`).
- Display a small "~N books" caption in `ExploreCollectionCard` (grouped `NumberFormatter`, `~`
  prefix, rounded to ~2 significant figures so it reads as approximate). Render only when non-nil.

---

## 3. Search state blanks after leaving/returning to the Search tab

**Root cause:** `RootView` uses a plain `switch selectedTab` (not `TabView`), so `SearchView` is
recreated on every tab change, resetting its local `@State query`. Results survive in the shared
`CatalogStore`, but the `normalizedQuery.isEmpty` gate hides them once `query` resets.

**Fix:** Promote query text to the store that outlives the view.
- `Voxglass/Core/Catalog/CatalogStore.swift`: add `@Published var query: String = ""`; set it in
  `searchLibriVox`/`searchAdvanced`, clear it when results clear.
- `Voxglass/Features/Search/SearchView.swift`: bind the `TextField` to `$catalogStore.query` and
  derive `normalizedQuery` from it. Returning to the tab restores both text and `catalogStore.results`.
  Only run a search on submit (not on re-appear), so the empty-query clear path isn't retriggered.

---

## 4. Wrong artwork ("white Greek temple") + card overflow

**Root cause:** `Book.coverURL` = `archive.org/services/img/<identifier>`
(`InternetArchiveModels.swift:184`). For coverless items, IA serves its **default placeholder — the
Internet Archive logo (a Greek-temple façade)** — larger than the current heuristics reject
(`isIAUnwantedPlaceholder` only catches ≤200px & <8 KB, or exact 180²/120²), so it displays instead
of the intended `GeneratedBookCover`.

**Fix A — reject the IA default** in `Voxglass/DesignSystem/ArtworkService.swift`
(`validatedImage`/`isIAUnwantedPlaceholder`): during implementation, fetch a known coverless
identifier to capture the default's exact dimensions/byte-size (and/or content hash); add an
exact-match rejection, and check the **final `response.url`** after redirects against IA's stable
not-found asset path. On rejection the intended generated cover renders. Add a case to
`VoxglassTests/ArtworkServiceUnifiedTests.swift`.

**Fix B — defensive clipping** in `Voxglass/DesignSystem/BookArtworkView.swift`: in `BookCoverView`
(and `CollectionArtworkView`) apply an explicit `.frame` + `.clipped()` in addition to `.clipShape`
so a wide image can never bleed into adjacent cards regardless of `.aspectRatio(1, .fill)`.

---

## 5. Cellular policy + Settings wording ("Cache", not "Download")

**Semantics (confirmed):** streaming + next-chapter prefetch always run on cellular (no change to
`PlaybackCoordinator` prefetch). The new toggle gates **only** the §7 full-book offline download.

- **Preference key:** add `static let cacheFullBooksOnCellular = "voxglass.cacheFullBooksOnCellular"`
  to `AppPreferencesStore.Keys` (`Voxglass/App/AppPreferencesStore.swift`). `@AppStorage` Bool
  defaults to `false` (OFF).
- **Settings UI** (`Voxglass/Features/Settings/SettingsView.swift`): rename the "Downloads & Cache"
  section to **"Storage & Cache"** (remove "Download" wording throughout), and add a SwiftUI `Toggle`
  **"Cache full books on cellular data"** bound to that key. First real `Toggle` in Settings — match
  card styling.
- **Wire up `NetworkMonitor`** (`Voxglass/Core/Services/NetworkMonitor.swift`, currently unused
  singleton with `isCellular`/`isWiFi`) — consumed by the §7 offline manager for the cellular gate.

---

## 6. Remove/delete a book from My Books (and purge its cache)

FK cascade is ON (`AppDatabase.swift:85`), so `DELETE FROM books WHERE id = ?` cascades to chapters,
playback_positions, bookmarks, playlist_books, book_taste.

1. **`StreamCacheStore`** (`.../StreamCacheStore.swift`): add public `func remove(keys: [String])`
   (wraps the private `remove(_:)`). Also needed by §7: `func isComplete(_ key: String) -> Bool`,
   and pin/unpin (below).
2. **Stable audio cache keys:** `CachingResourceLoader.key(for:)` (`CachingResourceLoader.swift:45`)
   uses `Hasher`, **randomly seeded per process** — not stable across launches. Switch to SHA256 of
   `url.absoluteString` (mirroring `ArtworkService.cacheKey`) so key-based deletion **and** offline
   completeness checks are reliable across launches. (Pre-existing files under old keys orphan → LRU
   reclaims them.) This is a prerequisite for both §6 and §7.
3. **`LibraryRepository`** (`.../LibraryRepository.swift`): add `deleteBook(_ bookID: UUID)` →
   `DELETE FROM books WHERE id = ?`; then delete the orphaned `Source` if no remaining book
   references it (each IA import creates its own source via `ensureInternetArchiveSource`). Also
   delete any `download_records` for the book (see §7).
4. **`LibraryStore`** (`.../LibraryStore.swift`): add `delete(book:) async` that:
   - cancels any in-flight §7 background downloads for the book;
   - purges cache: per chapter `CachingResourceLoader.key(for: chapter.remoteURL)` (+ `opusURL`),
     plus `ArtworkService.cacheKey(for: book.coverURL)` → `StreamCacheStore.shared.remove(keys:)`
     (and unpin);
   - `repository.deleteBook(...)`; updates `books`/`recentlyPlayed` in place;
   - clears the book from `RecentlyViewedBooksStore` (`AppPreferencesStore.swift:53–80`);
   - if it's the current/last session, stops playback (`PlaybackCoordinator.currentSession`) and
     clears `LastPlaybackSnapshotStore`.
5. **UI (both, confirm, label "Remove from My Books"):** `LibraryView.swift` context menu / `List
   .onDelete` → confirm → `delete(book:)`; `BookDetailView.swift` — the disabled "Download" slot in
   `actionGrid` (line 118) is replaced by the §7 offline control, and a destructive "Remove from My
   Books" action is added (button or overflow menu) → confirm → delete → dismiss.
6. **Cloud-sync caveat:** `VoxglassCloudSync.pullPlaybackPositions` re-inserts positions from iCloud
   KVS with no tombstones; `fetchRecentlyPlayed` joins to `books` so orphaned positions shouldn't
   resurface as cards — verify in testing. Full tombstone design out of scope unless requested.
7. **Tests:** extend `VoxglassTests/LibraryRepositoryTests.swift` (cascade + source cleanup) and
   `VoxglassTests/StreamCacheUnifiedTests.swift` (`remove(keys:)` targets only given keys).

---

## 7. Offline downloads (Pro, background)

**Goal:** In Book Detail, a "Make available offline" control that downloads **all chapters'** full
audio into our cache (pinned, never evicted), with live progress; on completion the control becomes a
non-interactive **"Cached for offline use"** indicator. Gated behind Pro; cellular handled per the §5
toggle with a prompt.

### 7a. New `ProFeature` case
Add `case offlineDownloads` to `Voxglass/Core/Services/Pro/ProFeature.swift`. Gate the offline action
with `ProFeature.isEnabled(.offlineDownloads)`; if not entitled, present the existing
`ProPaywallView` instead of starting a download.

### 7b. `StreamCacheStore` — pinning + full-file ingest
`Voxglass/Core/Services/Playback/StreamCacheStore.swift`:
- **Pinning:** persist a `Set<String> pinnedKeys` (JSON alongside `metaDir`); `pin(_ keys:)` /
  `unpin(_ keys:)`. `evictToFit` and `garbageCollectStalePartials` **skip pinned keys** so offline
  content is never evicted. (Pinned bytes are excluded from streaming-budget eviction.)
- **Full-file ingest** (background downloads deliver a complete file, not streamed ranges): add
  `func ingestCompleteFile(at tempURL: URL, key: String, totalBytes: Int64) async` that moves the
  file to `fileURL(for: key)`, sets `totalBytes`, records the full range, marks `complete = true`,
  and pins the key. Add `isComplete(_ key:) -> Bool` for state derivation.

### 7c. `OfflineDownloadManager` (background `URLSession`)
New `Voxglass/Core/Services/Playback/OfflineDownloadManager.swift` — a `@MainActor ObservableObject`
owning an `NSURLSession` background configuration (`URLSessionConfiguration.background(withIdentifier:
"guru.parso.voxglass.offline")`) with a `URLSessionDownloadDelegate`.
- **Per-book state** `@Published var state: [UUID: OfflineState]` where `OfflineState = notCached |
  downloading(progress: Double) | cached | failed`. Derive initial state at load from
  `download_records` + `StreamCacheStore.isComplete` per chapter.
- **`makeAvailableOffline(book:)`:**
  1. If `!ProFeature.isEnabled(.offlineDownloads)` → signal UI to present paywall; return.
  2. If `NetworkMonitor.shared.isCellular && !cacheFullBooksOnCellular` → signal UI to present the
     **cellular prompt** (see 7d); do not start.
  3. Else enqueue a background `downloadTask` per chapter (`chapter.resolvedPlayableURL()` /
     `remoteURL`), keyed by `CachingResourceLoader.key(for:)`. Persist a task registry
     (bookID + chapter key ↔ task identifier) so completions survive app relaunch. Write a
     `download_records` row per book/chapter with `DownloadState`.
- **Delegate callbacks:** `didWriteData` → update per-book progress (aggregate across chapters);
  `didFinishDownloadingTo` → `StreamCacheStore.ingestCompleteFile(...)`, mark that chapter's record
  `.complete`; when all chapters complete → set book `.cached`. `didCompleteWithError` → `.failed`
  (allow retry).
- **App relaunch / background completion:** implement
  `application(_:handleEventsForBackgroundURLSession:completionHandler:)` (via `UIApplicationDelegate`
  adaptor in `VoxglassApp` / `AppServices`) to store and later call the system completion handler
  after the session flushes events. Reattach the persisted registry on launch.
- **`removeOffline(book:)`:** cancel in-flight tasks, unpin + `StreamCacheStore.remove(keys:)`,
  delete `download_records`, set state `.notCached`. (Keeps the book in the library; distinct from §6
  "Remove from My Books" which deletes the book and also calls this purge.)
- Register the manager in `AppServices` and inject via `.environmentObject`.

### 7d. Book Detail UI
`Voxglass/Features/Library/BookDetailView.swift` — replace the disabled "Download" slot (line 118)
with an offline control driven by `offlineManager.state[book.id]`:
- `.notCached` → **"Make available offline"** button (`arrow.down.circle`).
- `.downloading(p)` → progress indicator with percentage (e.g. `ProgressView(value: p)` + "Caching… N%"),
  optional cancel.
- `.cached` → non-interactive **"Cached for offline use"** with a filled check
  (`checkmark.circle.fill`); expose "Remove offline copy" via overflow/long-press → `removeOffline`.
- **Paywall:** if not Pro, tapping presents `ProPaywallView` (existing).
- **Cellular prompt** (confirmationDialog / alert): title notes the user is on cellular; actions:
  **"Cache now on cellular"** → set `cacheFullBooksOnCellular = true` and start the download; and
  **"Wait for Wi-Fi"** → cancel. (Matches the requested behavior: change the setting there and begin,
  or defer to Wi-Fi.)
- Optional: a small offline badge (`checkmark.circle.fill`) on `CompactBookRowView` in `LibraryView`
  when `state == .cached`, reinforcing the indicator in the list.

### 7e. Tests
- `download_records` read/write + the now-functional `.downloaded` library filter
  (`LibraryRepository.downloadedBookIDs()`).
- `StreamCacheStore` pin/unpin excludes keys from eviction; `ingestCompleteFile` marks complete;
  `remove` unpins. Extend `VoxglassTests/StreamCacheUnifiedTests.swift`.
- Offline state derivation (all-chapters-complete → `.cached`) and the cellular-gate decision.

---

## 8. Improve search relevance (thematic / subject queries)

**Problem (empirically confirmed against the live IA API):** `InternetArchiveClient.libriVoxQuery`
(`InternetArchiveClient.swift:49–64`) requires **every** token to match, and forces a mandatory
**title-or-creator anchor** (`(title:"x" OR creator:"x")`). Subject/description are never allowed to
anchor, so thematic queries collapse:
- `"greek plays"` → **1 result** (current) — the anchor fails because neither "greek" nor "plays"
  is in any title/creator.
- `"aristophanes"` → 21 results (works, because the author is the creator).

**Validated fix (candidate "D", tested live):** broaden each token's field set and drop the
title/creator-only anchor, with a full-phrase boost clause. Results verified:
- `"greek plays"` → 29 (Oedipus Rex, Antigone, The Oresteia, The Persians — correct Greek tragedies).
- `"aristophanes"` → 28 (The Clouds, Lysistrata… correct).
- `"pride and prejudice"` → precision retained (all Austen editions on top).

Rewrite `libriVoxQuery(for:)` to build (keeping the existing `scopeClause` and quote-stripping, and
sanitizing the phrase of Lucene-reserved characters):
```
mediatype:audio AND (
  ( title:"<phrase>"^8 OR subject:"<phrase>"^6 OR description:"<phrase>"^4 )   // whole-phrase boost
  OR
  ( <perToken1> AND <perToken2> AND … )                                        // all concepts present
) <scopeClause>
```
where each `<perTokenN>` is
`(title:"tok"^4 OR creator:"tok"^3 OR subject:"tok"^2 OR description:"tok"^1)`.
Key changes vs. today: **add `subject` + `description` to the per-token fields**, **remove the
mandatory title/creator anchor**, **add the whole-phrase OR clause**. Keeping token-AND preserves
precision (both concepts required); the broadened fields let subject/description satisfy them.

Notes: the search sort stays `downloads desc` (surfaces canonical popular editions first, which
tested well). Under that sort the `^` boosts don't affect ordering — they aid inclusion via the
phrase clause; keep them (harmless) or note we could switch search to relevance sort later. Update
the query-shape assertions in `VoxglassTests/InternetArchiveCatalogTests.swift` (and add a
regression asserting the new query for a two-word thematic input contains a `subject:`-anchored path
and no title/creator-only mandatory clause).

---

## 9. Now Playing — "Time left in book"

**Request:** show remaining time for the **whole book** between the two existing (chapter-level)
time labels in the scrubber row.

**Current:** `NowPlayingView.scrubber` (`NowPlayingView.swift:125–129`) is `HStack { elapsed; Spacer;
-chapterRemaining }`, both derived from `session.position` / `session.duration` (current chapter only).

**Fix:**
- Add a computed helper on `PlaybackSession` (`Voxglass/Core/Playback/PlaybackSession.swift`), e.g.
  `var bookRemaining: TimeInterval?`: `elapsedBefore = chapters[..<chapterIndex].compactMap(\.duration).reduce(0,+)`;
  `bookElapsed = elapsedBefore + position`; `bookRemaining = totalBookDuration - bookElapsed`, where
  `totalBookDuration = chapters.compactMap(\.duration).reduce(0,+)` (same logic as
  `BookWithChapters.totalDuration`, `BookModels.swift:118`). Return `nil` if durations are unavailable.
- Insert a centered middle label in the scrubber `HStack`:
  `HStack { elapsed; Spacer(); if let r = session.bookRemaining { Text("\(TimeFormatting.compactDuration(r)) left in book") }; Spacer(); chapterRemaining }`.
  Reuse `TimeFormatting.compactDuration` (`TimeFormatting.swift:16`) for an "Xh Ym" style; hide the
  middle label when `bookRemaining == nil`. Match the existing 11pt muted styling.

---

## Verification

Build/run in the iOS simulator (XcodeGen: `xcodegen` then build `Voxglass`), plus `xcodebuild test`
for the touched suites.

1. **#1/#2:** Explore → Featured Collections: equal L/R margins; each card shows "~N books"; changing
   language refreshes counts/covers.
2. **#3:** Search → results → switch tab → return: query text and results persist.
3. **#4:** A coverless book (e.g. "The Adventures of Sherlock Holmes") on Jump Back In / Recommended
   shows the generated cover, not the IA temple, and nothing bleeds into neighbors; new unit test passes.
4. **#5:** Settings → Storage & Cache shows "Cache full books on cellular data" OFF by default; no
   "Download" wording remains. Streaming + prefetch still work on cellular (unchanged).
5. **#6:** From My Books and Book Detail, "Remove from My Books" → confirm → book gone from My Books /
   Jump Back In / Recently Added; cached audio + cover removed from `Caches/Voxglass/StreamCache*`;
   still gone after relaunch.
6. **#7:** As Pro, Book Detail → "Make available offline": progress shows, then "Cached for offline
   use". Enable Airplane Mode → all chapters play from cache. On cellular with the toggle OFF, tapping
   shows the prompt; "Cache now on cellular" flips the setting and starts; "Wait for Wi-Fi" cancels.
   Start a download, background the app → it completes via the background session (verify state on
   return / relaunch). As non-Pro, tapping presents the paywall. "Remove offline copy" frees the
   cache but keeps the book.
7. **#8:** Search "greek plays" → returns Greek tragedies/plays (not empty); "aristophanes" and
   "pride and prejudice" still return correct, clean results. Query-shape tests pass.
8. **#9:** Open Now Playing on a multi-chapter book → a centered "Xh Ym left in book" label sits
   between the chapter elapsed and chapter-remaining labels, and counts down across chapter
   boundaries; it hides when chapter durations are unavailable.
