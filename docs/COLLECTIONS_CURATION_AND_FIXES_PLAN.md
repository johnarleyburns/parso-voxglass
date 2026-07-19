# Collections Quality, Curated Lists, EQ, Backup & Sync — Fix Plan

**Date:** 2026-07-19 · **Status:** awaiting review · **Implementation:** phase-per-branch, agentic handoff at end

This plan addresses, at the root:

1. Equalizer shows only ~2 of 10 bands (Now Playing sheet and More → Audio).
2. Collection "bleed": fiction in Science & Nature, *The Art of War* topping General
   Fiction, *Anthem* in Essays & Ideas, biographies/*Little Women*/"Short Nonfiction
   Collection" in War & Military — plus category restructuring (remove Literary
   Fiction, merge Ancient Greece into Ancient World, new War & Military cover).
3. Curated collections (Great Books, Greater Books): "Curated" banner + a
   "Curation Order" sort that is the default, ordered from the GBWW volume list and
   the greaterbooks.com shortlist.
4. More → Backup & Restore → Export shows a blank page.
5. More → Sync: remove "for free" copy; add an on/off toggle.

---

## Root-cause findings (verified in code / against archive.org)

### F1 — EQ "2 channels" is a SwiftUI layout bug, not a gating bug

`Voxglass/Features/Player/EQView.swift` (`bandSlider`, ~line 120):

```swift
Slider(...)
    .rotationEffect(.degrees(-90))
    .frame(width: 150, height: 28)   // ← applied AFTER rotation
```

`rotationEffect` is purely visual — it does **not** change layout bounds. Each of the
10 sliders therefore still occupies **150 pt of layout width**; ten of them in an
`HStack` need ~1500 pt, so all but the first ~2 are clipped off-screen inside the
card. The EQ engine itself is fine (`EQEngine.isoBands` = 10 ISO bands,
`BiquadFilter.swift:99`), and the entry points from Now Playing
(`NowPlayingView.swift:440`) and More → Audio (`SettingsView.swift` `EQSettingsRow`)
both open the same `EQView`. Nothing here is Pro-gated.

**Fix shape:** size the track *before* rotating, then give the rotated view its true
footprint:

```swift
Slider(...)
    .frame(width: 150)                 // track length
    .rotationEffect(.degrees(-90))
    .frame(width: 28, height: 150)     // layout footprint (swapped)
```

### F2 — Collection bleed comes from overbroad Lucene clauses + no per-collection precision filter

All category queries live in `Voxglass/Core/Catalog/LibriVoxBrowseCategory.swift`.
Three distinct defects compound:

1. **Bare (unquoted) subject terms match tokens inside any multi-word subject.**
   `subject:Science` matches "Science *Fiction*"; `subject:Fiction` matches
   "*Non*-fiction"; `subject:War` matches any item tagged with the single word
   "war" regardless of genre. archive.org's `subject` field is tokenized text, not
   an exact-match facet.
2. **Some queries deliberately include wrong-genre subjects.** Science & Nature
   includes `subject:"Nature & Animal Fiction"` (fiction, verbatim). General
   Fiction includes `subject:Literature`, `title:novel`, `title:stories`. Essays &
   Ideas includes `subject:"Philosophy"` (guaranteeing Philosophy & Mind overlap)
   plus `title:letters`, `title:lectures`.
3. **Popularity sort amplifies every false positive.** Verified live: the
   `art_of_war_librivox` item's subjects are `librivox; audiobook; literature; war;
   Sun Tzu; …` — it matches General Fiction via `subject:Literature` and
   War & Military via bare `subject:War`, and since it is LibriVox's most-downloaded
   item, it lands at **rank 1** of both. *Anthem*, *Little Women*, and the
   "Short Nonfiction Collection" volumes (grab-bag subject lists) get in the same way.

There is already a client-side post-filter hook — `CatalogStore.filteredResults(_:for:)`
(`CatalogStore.swift:148`) currently applies only a strict-LibriVox-candidate check.
That is the right seam to add **per-collection precision rules** (server query =
recall, client rules = precision).

### F3 — Export "blank page" is the classic `.sheet(isPresented:)` + optional-state race

`SettingsView.swift` `LibraryBackupRow` (~line 913):

```swift
.sheet(isPresented: $showShare, onDismiss: { exportURL = nil }) {
    if let url = exportURL { ShareSheet(items: [url]) }   // ← nil at first render
}
```

`showShare = true` and `exportURL = url` are set together, but the sheet's content
closure can be evaluated with the *stale* nil `exportURL`, rendering an empty sheet.
Additionally, if `exportToFile()` returns nil, the failure is silent.
**Fix shape:** `.sheet(item:)` with an `Identifiable` wrapper — structurally
race-free — plus an error alert on nil.

### F4 — Sync is hard-wired always-on

`Voxglass/Core/Services/Sync/VoxglassCloudSync.swift` (comment at line ~61:
"iCloud sync is always enabled") — only `isAvailable` (iCloud signed-in) gates it.
No user preference exists. The copy at `SettingsView.swift:559` says "for free",
which is now meaningless since everything is free.

### F5 — Curation order needs a client-side ordering mechanism

archive.org cannot sort by an arbitrary editorial order. `CatalogSort`
(`InternetArchiveClient.swift:39`) maps every case to server sort fields. Curation
order must therefore be: bundled ordered manifest of archive identifiers → fetch by
identifier batch → reorder client-side. Sources captured 2026-07-19:

- **Great Books** — Wikipedia "Great Books of the Western World", 1st edition
  (1952, 54 volumes; the fully documented ordering). Content volumes 4–54, in
  volume order (≈ historical order): Homer · Aeschylus/Sophocles/Euripides/
  Aristophanes · Herodotus/Thucydides · Plato · Aristotle (2 vols) ·
  Hippocrates/Galen · Euclid/Archimedes/Apollonius/Nicomachus ·
  Lucretius/Epictetus/Marcus Aurelius · Virgil · Plutarch · Tacitus ·
  Ptolemy/Copernicus/Kepler · Plotinus · Augustine · Aquinas (2 vols) · Dante ·
  Chaucer · Machiavelli/Hobbes · Rabelais · Montaigne · Shakespeare (2 vols) ·
  Gilbert/Galileo/Harvey · Cervantes · Bacon · Descartes/Spinoza · Milton · Pascal ·
  Newton/Huygens · Locke/Berkeley/Hume · Swift/Sterne · Fielding ·
  Montesquieu/Rousseau · Adam Smith · Gibbon (2 vols) · Kant · American State
  Papers/Federalist/Mill · Boswell · Lavoisier/Fourier/Faraday · Hegel · Goethe ·
  Melville · Darwin · Marx · Tolstoy · Dostoevsky · William James · Freud.
- **Greater Books** — greaterbooks.com/shortlist.html (HTTP only — the HTTPS cert
  is broken; the generator must fetch over plain HTTP), in exact page order: four
  period sections (Prehistory–700 · 700–1650 · 1650–1900 · 1900–present), each
  ranked by tally descending. Starts: Odyssey, Iliad, Aeneid, Herodotus, Oedipus
  the King, Confessions, The Republic… Note most 1900–present entries are still in
  copyright and will simply not resolve to LibriVox recordings — skipped, not errors.

---

## Phased implementation

Each phase is one branch + PR, independently shippable. Order below is suggested
priority; Phases 1–3 are independent of each other and of 4–5. Phase 5 depends on
Phase 4 (it touches the same files: `IACollection`, `CatalogSort`, `BrowseView`).

| Phase | Branch | Scope |
|---|---|---|
| 1 | `fix/eq-ten-bands` | EQ band layout |
| 2 | `fix/backup-export-sheet` | Export blank sheet + error surfacing |
| 3 | `feat/sync-toggle` | Sync copy + on/off preference |
| 4 | `feat/collection-precision` | Query rewrite, precision rules, category removal/merge, covers/subtitles/counts |
| 5 | `feat/curated-collections` | Curated manifests, Curation sort, banner UI |

---

## Phase 1 — EQ: render all 10 bands

**Files:** `Voxglass/Features/Player/EQView.swift`

**Changes**
1. Rework `bandSlider(_:)` with the size-then-rotate-then-refoot pattern (F1).
   Track length should adapt: use the card's available height (the existing
   220 pt `frame(height: 220)` container) rather than hard-coded 150 where easy;
   fixed `width: 28` per column, `.frame(maxWidth: .infinity)` on the column so 10
   columns share the card width evenly (≈33 pt each on a 393 pt screen — fits).
2. Keep gain label + Hz label; verify no clipping at Dynamic Type XL (labels may
   need `minimumScaleFactor`).
3. Verify both entry points visually (Now Playing sliders sheet; More → Audio).

**Tests**
- UI test (append to `VoxglassUITests`): open EQ from More → Audio, assert
  `eq.band.0` … `eq.band.9` all `exists && isHittable`, drag `eq.band.9` and assert
  no crash. This is the regression test that would have caught the clipping —
  layout bugs are invisible to unit tests.
- Existing `EQStoreTests` / `EQTapRegistryTests` stay green (no engine changes).

**Acceptance:** all 10 sliders visible and draggable on iPhone SE-class width and
iPhone 16, both entry points.

---

## Phase 2 — Backup Export: fix blank sheet, surface failures

**Files:** `Voxglass/Features/Settings/SettingsView.swift` (`LibraryBackupRow`),
possibly `Voxglass/Core/Services/Backup/LibraryBackupService.swift` (error out-param).

**Changes**
1. Introduce `struct ExportedBackup: Identifiable { let id = UUID(); let url: URL }`;
   replace `showShare: Bool` + `exportURL: URL?` with a single
   `@State private var exportedBackup: ExportedBackup?` and `.sheet(item:)`.
2. On `exportToFile()` returning nil, show an alert ("Export Failed — could not
   write the backup file") instead of silently doing nothing. If
   `LibraryBackupService` can distinguish causes (disk, encode), have it return a
   `Result`/throw so the alert can say which; keep the change minimal.
3. While exporting, show a `ProgressView` state on the row/dialog (export walks the
   whole library; today the UI gives zero feedback until the share sheet appears).

**Tests**
- Unit (`VoxglassTests/BackupPayloadTests.swift` or new
  `LibraryBackupExportTests.swift`): `exportToFile()` produces a file that exists,
  is non-empty, and round-trips through the backup decoder (import-count matches).
  If coverage already exists, extend it to assert the file is non-empty (a blank
  share sheet with a 0-byte file would also read as "blank" to a user).
- UI smoke: tap Backup & Restore → Export Backup → assert the share sheet appears
  (`app.otherElements["ActivityListView"]` or dismissible presentation exists).

**Acceptance:** Export always produces either a populated share sheet or an explicit
error alert — never a blank page.

---

## Phase 3 — Sync: neutral copy + user on/off toggle

**Files:** `SettingsView.swift` (`SyncSettingsCard`),
`Voxglass/Core/Services/Sync/VoxglassCloudSync.swift`, the preferences store
(`AppPreferencesStore`).

**Changes**
1. Copy: replace
   *"Your playback position syncs across devices for free. Bookmarks and favorites
   sync using your private iCloud account. No app account required."*
   with
   *"Your playback position, bookmarks, and favorites sync across devices using
   your private iCloud account. No app account required."*
2. New preference `AppPreferencesStore.Keys.iCloudSyncEnabled`, **default `true`**
   (sync stays on for existing users; privacy-sensitive users can switch it off).
3. `VoxglassCloudSync` gains `public var isEnabled: Bool` backed by that preference.
   Guard **every** entry point — `sync()`, `pushPlaybackPositions()`, all pull
   paths, and the KVS `NotificationCenter` observer registered in `init` (the
   observer should early-return when disabled; don't rely only on UI gating).
   Update the stale "iCloud sync is always enabled" comment.
4. `SyncSettingsCard`: add a `Toggle("Sync with iCloud")` (accessibility id
   `sync.enabled`) above the status text. When off: hide Sync Now / last-sync rows,
   show one line "Sync is off. Your listening data stays only on this device."
   Turning it back on triggers one immediate `sync()`.

**Tests** (`VoxglassTests`, alongside `BookmarkSyncTests`)
- With `testForceAvailable = true` but `isEnabled = false`: `sync()` and
  `pushPlaybackPositions()` write nothing to the KVS backing store and
  `lastSyncDate` stays nil.
- Re-enabling and calling `sync()` performs the round-trip (reuse the existing
  local-KVS seam).
- Preference default test: fresh defaults → `isEnabled == true`.

**Acceptance:** no "for free" text anywhere in Settings (`grep -R "for free"
Voxglass/Features` is clean); toggle off verifiably stops all KVS traffic.

---

## Phase 4 — Collection precision: strict queries + client rules + category restructure

This is the root fix for all the bleed reports. Two layers, both in
`Voxglass/Core` so everything is `swift test`-able.

### 4a. Server-side query rewrite (`LibriVoxBrowseCategory.swift`)

Principles (enforced by tests, see below):

- **No bare genre-ambiguous subject tokens.** Kill `subject:Fiction`,
  `subject:Science`, `subject:Nature`, `subject:War`, `subject:Military`,
  `subject:Literature`, `subject:Novel(s)`, `subject:Romance` → replace with quoted
  LibriVox genre phrases (`subject:"General Fiction"`, `subject:"War & Military
  Fiction"`, `subject:"Astronomy, Physics & Mechanics"`, …). Single-word subjects
  that are genre-unambiguous (e.g. `subject:Poetry`) may stay.
- **No `title:` shotgun clauses** (`title:novel`, `title:stories`, `title:essay`,
  `title:letters`, `title:lectures`, `title:mystery`, …) in any category. Titles
  are not genres.
- Creator anchors stay only where the creator is genre-unambiguous (Conan Doyle in
  Mystery: yes; Mark Twain in General Fiction: yes; Burroughs in Science & Nature:
  gone).

Per-category edits requested:

| Category | Query change |
|---|---|
| **Science & Nature** | Remove `subject:"Nature & Animal Fiction"`, bare `Science`/`Nature`. Use quoted nonfiction genres: "Life Sciences", "Astronomy, Physics & Mechanics", "Earth Sciences", "Mathematics", "Chemistry", "Medicine", "Natural History", "Animals", "Gardening" + creators Darwin, Faraday, Huxley, John Muir, Jean-Henri Fabre, John Burroughs (the naturalist). |
| **General Fiction** | Remove `subject:Literature`, bare `subject:Fiction`, `subject:Novels/Novel`, `title:novel`, `title:stories`. Keep quoted fiction genres + unambiguous novelist creators. |
| **Literary Fiction** | **Deleted** (see 4c). |
| **Essays & Ideas** | Remove `subject:"Philosophy"` (that's Philosophy & Mind's territory), `title:essay/essays/letters/lectures`. Keep "Essays & Short Works", "Literary Criticism", "Political Science", "Social Science", Economics, Education + essayist creators. |
| **War & Military** | Rebuild from quoted phrases: `"War & Military Fiction"`, `"World War, 1914-1918"`, `"World War I"`, `"Napoleonic Wars"`, `"Civil War"` (US), `"Strategy & Tactics"`, plus military-classic creators (Sun Tzu, Clausewitz, Caesar, Mahan). Drop bare `War`, `Military`, `Espionage`, `Thrillers`. |
| **Ancient World** | Absorb the curated Ancient Greece creator list (mostly already present). Remove `title:ancient/greece/greek/rome/roman` shotgun; keep quoted subjects + the classical-author creator anchors. |

### 4b. Client-side precision rules — new `CollectionContentRules`

New file `Voxglass/Core/Catalog/CollectionContentRules.swift`:

```swift
public struct CollectionContentRules: Sendable {
    public var requireAnySubjects: Set<String>   // normalized exact match; empty = no requirement
    public var excludeSubjects: Set<String>
    public var excludeCreators: Set<String>
    public var excludeTitlePatterns: [String]    // case-insensitive substring
    public func allows(subjects: [String], creator: String?, title: String) -> Bool
}
public enum CollectionRulesRegistry {
    public static func rules(forCollectionID id: String) -> CollectionContentRules?
    /// Applied to every collection: LibriVox grab-bag compilation volumes.
    public static let globalExcludeTitlePatterns = [
        "short nonfiction collection", "short story collection",
        "coffee break collection", "short poetry collection"
    ]
}
```

Normalization: lowercase, trim, compare whole subject strings (never substrings),
so `"non-fiction"` ≠ `"fiction"` and `"science fiction"` ≠ `"science"` — exactly
the distinction Lucene loses.

Wiring:
- `CatalogStore.searchAdvanced`/`loadMore` learn the active collection id
  (`BrowseView.search(_:)` passes `collection.id`; nil for free-text search keeps
  today's behavior). `filteredResults` then applies
  strict-LibriVox-candidate ∧ rules.
- **Prerequisite check:** ensure `InternetArchiveSearchResult` carries `subject`
  and `creator` (add to the `fl[]` field list in
  `InternetArchiveClient.advancedSearchURL` and the model/decoder if missing).
- Filtered pages may hold <25 rows; the existing `hasMore` logic
  (`results.count < numFound`) already tolerates this. If a page filters to zero,
  auto-advance one extra page (bounded, max 3 chained fetches) so a heavily-filtered
  collection doesn't render as empty when matching items exist deeper.

Rules per category (initial; expected to be tuned):
- Nonfiction categories (Science & Nature, History, Biography, Essays & Ideas,
  Philosophy & Mind, Travel, Religion): `excludeSubjects` gets every LibriVox
  fiction genre ("general fiction", "literary fiction", "science fiction",
  "historical fiction", "romance", "nature & animal fiction", "war & military
  fiction", …, plus "novels", "short stories").
- Essays & Ideas additionally excludes philosophy subjects ("philosophy",
  "epistemology", "metaphysics", "ethics", "stoicism", …) → no overlap with
  Philosophy & Mind (which already excludes essays-adjacent noise).
- War & Military: `requireAnySubjects` = the war/military subject set from 4a
  (so *Little Women* — no war subject — can never qualify via a stray token) and
  `excludeSubjects` = {"biography & autobiography", "biography", "autobiography",
  "memoirs"} (drops *A Short Life of Abraham Lincoln*; genuine war memoirs tagged
  with a war subject AND biography are a known trade-off — record as decision D3).
- General Fiction: `requireAnySubjects` = explicit fiction genre set;
  excludes "non-fiction". (*The Art of War* — subjects `literature; war` — fails
  the requirement.)

### 4c. Category restructure

1. **Delete Literary Fiction** (`.literaryFiction`): remove from
   `LibriVoxBrowseGroup.all`, `IACollection.authorSubtitle`/`coverURL` maps, the
   `collection-lv-literary-fiction` asset can be deleted, `CollectionBundledCounts`
   regenerated. Sweep the repo for the literal `lv-literary-fiction` (onboarding
   picks, taste-profile seeds) and add a **migration** in
   `AppPreferencesStore.decodeCollectionIDs`: drop `lv-literary-fiction`, so users
   who had it selected don't carry a ghost id.
2. **Merge Ancient Greece → Ancient World**: delete the curated `ancientGreece`
   `IACollection` + `CuratedQueries.ancientGreece`; `curated = [greatBooks,
   greaterBooks]`. Same migration hook maps `"ancient-greece"` →
   `"lv-ancient-world"`. Delete/repurpose the `collection-ancient-greece` asset.
3. **War & Military cover**: replace `art_of_war_librivox` in the `coverURL` map
   (Art of War already fronts Popular LibriVox). Pick the *next most-downloaded
   genuinely military* item at implementation time — query the rebuilt War &
   Military query sorted `downloads desc` and take the first non-Art-of-War row
   (expected: Clausewitz *On War* or *The Red Badge of Courage*; verify the
   identifier resolves to real cover art).
4. **Regenerate `authorSubtitle` lists** for every touched category from the new
   queries (top creators by downloads), so e.g. Science & Nature stops advertising
   Edgar Rice Burroughs. Then rerun `swift run collection-counts` to refresh
   `CollectionBundledCounts`.

### Phase 4 tests (all headless `swift test`, `VoxglassCoreTests`)

- **Query-hygiene tests** (new `CollectionQueryHygieneTests.swift`): for every
  `LibriVoxBrowseCategory.archiveQuery`, assert via regex that no *bare* denylisted
  token appears (`subject:(Fiction|Science|Nature|War|Military|Literature|Novels?)`
  outside quotes) and no `title:` clause appears in nonfiction categories. This is
  the guard that keeps future edits from reintroducing bleed.
- **Rules fixture tests** (new `CollectionContentRulesTests.swift`) using real
  metadata captured as fixtures:
  - *The Art of War* (`literature; war`) → rejected by General Fiction, accepted by
    War & Military.
  - *Anthem* → rejected by Essays & Ideas.
  - *A Short Life of Abraham Lincoln* (biography subjects) → rejected by
    War & Military.
  - *Little Women* → rejected by War & Military (no required subject).
  - "Short Nonfiction Collection 012" → rejected everywhere (global title pattern).
  - *On the Origin of Species* → accepted by Science & Nature; *Dracula* → rejected.
  - Normalization: `"Non-fiction"` does not match exclude/require entry `"fiction"`.
- **Migration tests**: `decodeCollectionIDs` drops `lv-literary-fiction`, maps
  `ancient-greece` → `lv-ancient-world`, is idempotent.
- **Update existing** `LibriVoxBrowseCategoryTests` (subject extraction & genre
  mapping no longer include Literary Fiction; War & Military mapping still resolves).
- **CatalogStore test**: filtered page of fixtures keeps order and drops rule
  violations; empty-after-filter page triggers bounded auto-advance.

**Acceptance:** manual spot-check on device — Science & Nature top-50 contains no
fiction; General Fiction no longer contains *The Art of War*; Essays & Ideas
contains neither *Anthem* nor philosophy monographs; War & Military top-50 contains
no pure biographies, *Little Women*, or "Short * Collection" volumes; Explore shows
neither Literary Fiction nor Ancient Greece; War & Military shows the new cover.

---

## Phase 5 — Curated collections: banner + Curation Order (depends on Phase 4)

### 5a. Data: curated-order manifests

- New checked-in source lists (human-editable, order = curation order):
  `Tools/CuratedLists/great-books-source.csv`, `greater-books-source.csv` with
  columns `rank,author,title,identifier_override`. Great Books rows come from the
  GBWW 1st-edition volume order in F5 (multiple works per author ordered by
  LibriVox popularity within the author's slot); Greater Books rows from the
  shortlist page order in F5.
- New Tools executable **`curated-lists`** (same pattern as the existing
  `collection-counts` target in `Package.swift`): for each row without an
  override, queries archive.org advancedsearch
  (`collection:librivoxaudio AND creator:"…" AND title:"…"`, `downloads desc`) and
  takes the best match; rows with no LibriVox recording are *skipped and reported*
  (expected for most of Greater Books' 1900–present section). Emits bundled
  manifests `Voxglass/Resources/CuratedLists/great-books.json` /
  `greater-books.json`: `[{rank, title, author, identifier}]`, committed to the
  repo (no runtime scraping; greaterbooks.com is HTTP-only and Wikipedia is not an
  API — the generator run is a dev-time step).
- `IACollection` gains `curatedListName: String?` (+ computed `isCurated`); set for
  Great Books and Greater Books only. Designed so future curated collections are
  "add a CSV, run the tool, set the field".

### 5b. Sort: `CatalogSort.curation`

- Add case `curation` ("Curated"). It has no server sort; `CatalogStore` handles it
  specially: page *N* = manifest identifiers `[25·(N−1) ..< 25·N]`, one IA query
  `identifier:(a OR b OR …)`, results reordered client-side to manifest rank
  (missing/dark items skipped). `numFound` = manifest count. Language filtering
  does not apply to explicit identifiers (curated entries are already
  English-recording picks).
- New pure helper (testable): `CuratedPager.slice(manifest:page:size:)` and
  `CuratedPager.order(results:by:manifest)`.
- `BrowseView`: extract `defaultSort(for collection: IACollection) -> CatalogSort`
  (curated → `.curation`, else `.popularity`) into `VoxglassCore` so it's unit
  tested. `sortPicker` shows the "Curated" segment **only** for curated
  collections; selecting a curated collection defaults to Curation order, and the
  user can still switch to Popularity/Title/Author/Date (which run the existing
  creator-based `CuratedQueries` archive query, unchanged).

### 5c. UI: curated banner

- `ExploreCollectionCard`: for `isCurated`, a banner strip across the top of the
  artwork — small laurel/`rosette` icon + "CURATED" in caps, brass-on-dark,
  accessibility id `collection.curatedBadge`, VoiceOver label "Curated collection".
- Above the results list when a curated collection is selected: a one-line banner
  "Hand-picked list · shown in curation order" (updates to "sorted by popularity"
  etc. when the user changes sort). Dynamic Type + VoiceOver per app conventions.

### Phase 5 tests

- Manifest validity (`CuratedManifestTests`): both JSONs decode, are non-empty,
  ranks strictly increasing, identifiers unique; Great Books rank 1 resolves to a
  Homer item; Greater Books rank 1 to *The Odyssey*.
- `CuratedPager` unit tests: slicing math (exact, partial, out-of-range pages);
  reorder-by-rank with unknown identifiers dropped; stable for duplicate ranks.
- `defaultSort(for:)` tests: curated → curation, browse → popularity.
- `CatalogSort` tests: `.curation` excluded from server-sort field mapping;
  picker-visibility helper (`availableSorts(for collection)`) returns curation only
  for curated collections.
- UI smoke: select Great Books → curated badge exists, sort control shows
  "Curated" selected, first row is Homer.

**Acceptance:** Great Books opens in GBWW volume order by default; Greater Books in
shortlist order; both show the Curated banner; switching to Popularity still works;
non-curated collections are visually and behaviorally unchanged.

---

## Decisions taken (flagging for your review)

- **D1 — Sync default ON** after the toggle ships (existing users keep current
  behavior; opt-out, not opt-in). Flip to default-off if you prefer privacy-first.
- **D2 — GBWW 1st edition (54 vol)** as the Great Books order source — it's the
  fully documented ordering on the Wikipedia page; the 2nd edition's 20th-century
  additions are mostly in-copyright (no LibriVox recordings) anyway.
- **D3 — War & Military excludes anything tagged biography**, accepting that a
  war memoir tagged both ways is dropped. Precision over recall, per your ask.
- **D4 — War & Military stays in the "Fiction" browse group** (it mixes fiction
  and military nonfiction); only its contents are tightened. Say the word if you
  want it moved to Ideas & Nonfiction.
- **D5 — Curated manifests are build-time artifacts** committed to the repo, not
  fetched at runtime (greaterbooks.com serves HTTP-only with a broken cert — not
  something the app should ever talk to).
- **D6 — Popularity/Title/Author/Date sorts on curated collections keep the
  existing broad creator queries**; only Curation order uses the manifest. The two
  memberships differ slightly (creator query returns more items than the list).

## Verification commands

```bash
cd /Users/arley/github/parso-voxglass
swift test                       # VoxglassCore — the reliable headless gate
xcodebuild -project Voxglass.xcodeproj -scheme Voxglass \
  -destination 'platform=iOS Simulator,name=iPhone 16' build test
swift run collection-counts      # after Phase 4 (regenerate bundled counts)
swift run curated-lists          # after Phase 5 (regenerate manifests)
```

---

## Agentic coding handoff

Run each phase as its own agent session, in order 1 → 5 (1–3 in any order; 5 after
4). Per-phase prompt template:

> You are implementing **Phase N** of
> `docs/COLLECTIONS_CURATION_AND_FIXES_PLAN.md` in
> `/Users/arley/github/parso-voxglass`. Read that phase's section fully first, then
> read every file it names before editing. Work on branch `<branch from the phase
> table>`. Implement exactly the phase scope — do not pull in later phases. Write
> the tests listed for the phase; they must fail against the pre-fix behavior where
> applicable (fixture tests) and pass after. Verify with `swift test` and an
> `xcodebuild` build before declaring done; report which tests are new. Do not
> reintroduce any denylisted bare Lucene token (see Phase 4 query-hygiene tests).
> Commit with a conventional message referencing the plan
> (e.g. `fix: render all 10 EQ bands [collections-plan phase 1]`), push the branch,
> and open a PR titled `[Phase N] <summary>`; do not merge.

Phase-specific notes for the agent:
- **Phase 1:** the bug is modifier *order*; do not touch the EQ engine. Test on the
  narrowest supported simulator width.
- **Phase 2:** `.sheet(item:)` is the fix; do not "fix" it by delaying with
  `DispatchQueue.asyncAfter`.
- **Phase 3:** the KVS observer in `VoxglassCloudSync.init` must respect the
  toggle; UI-only gating is a rejection-worthy incomplete fix.
- **Phase 4:** capture the fixture metadata (subjects arrays) from live
  archive.org `metadata/<id>/metadata` responses into test fixtures *first* — the
  fixtures in the plan's test list are mandatory. If `InternetArchiveSearchResult`
  lacks `subject`, adding it to `fl[]` + model is in scope. Choose the new War &
  Military cover by running the rebuilt query `downloads desc` and record the
  chosen identifier in the PR description.
- **Phase 5:** build the CSVs from the orderings embedded in this plan (F5);
  `curated-lists` must print a resolution report (matched / overridden / skipped)
  so curation quality is reviewable in the PR.
