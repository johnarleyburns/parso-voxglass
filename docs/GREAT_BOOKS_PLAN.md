# Great Books — Complete Coverage & Per-Language Collections

**Status:** proposed, not started
**Date:** 2026-07-21
**Shape:** two phases. Phase 1 is data generation only (nothing in `Voxglass/` changes).
Phase 2 bundles the generated data into the app with full test coverage.
**Audience:** an agentic coder implementing this end to end.

---

## 0. Context — why this is being rebuilt

The Great Books collection ships **90 recordings**. LibriVox holds roughly **1,143** by
Great Books authors, **951 of them in English**. The intent was "every work, with corpus
entries like Sophocles' *Plays* broken out into their individual LibriVox items." That is
not what shipped and could not have been, because the data model cannot express it.

### 0.1 Verified root causes

1. **The CSV schema is one-identifier-per-row.** `rank,author,title,identifier_override`
   → `CuratedManifestEntry` (`Voxglass/Core/Catalog/CuratedManifest.swift:6`). "Sophocles
   — Plays" *must* collapse to one identifier.
2. **Picks came from `sort=downloads desc&rows=1`** (`Tools/CuratedLists/main.swift:88`)
   and whatever returned first was frozen as an override. Hence Sophocles → *Las Siete
   Tragedias* (Spanish), Herodotus → *Libro IV* (Spanish), Tacitus → *Las Germanias*,
   Erasmus → German, Machiavelli → Italian, Plato → *Alcibiades I* not *Republic*,
   Plutarch → *Moralia Bk 2* not *Lives*, Molière → a one-act farce.
3. **`greater-books` loses 332 of 475 rows.** 350 rows carry an override, only **142 are
   unique** — `romeo_and_juliet_librivox` is the override for 37 rows,
   `tale_two_cities_librivox` for 11. Dedup (forced by `greaterBooksIdentifiersAreUnique`)
   collapses to 143.
4. **11 rows drop silently.** Galen, Euclid, Archimedes, Apollonius, Nicomachus, Ptolemy,
   Copernicus, Kepler, Harvey, Lavoisier, Fourier → blank title → creator-only search → no
   hit → `resolveRow` returns `nil` → `print` and skip. 101 in, 90 out. *(Verified
   2026-07-21: these genuinely have no LibriVox recordings. The answer is right; the
   silence is the defect.)* `try? await generateManifest` (`main.swift:151`) swallows every
   throw, so the generator cannot fail.
5. **Creator queries miss authors.** `greatBooksCreators`
   (`Voxglass/Core/Catalog/IACollection.swift:458`) uses exact-phrase `creator:"…"`
   against IA strings that do not match. Verified live:

   | Query | Hits | Actual IA `creator` |
   |---|---:|---|
   | `"Michel de Montaigne"` | 0 | `Michel Eyquem de Montaigne` |
   | `"Baruch Spinoza"` | 0 | `Spinoza, Benedict de` |
   | `"Hippocrates"` | 0 | inside a `Various`-credited collection |
   | `"Montesquieu"` | 2 | `Charles-Louis de Secondat, baron de La Brède et de Montesquieu` |

   Molière is in the CSV (rank 44) but absent from `greatBooksCreators` entirely.
6. **Languages are mixed** with no way to tell before tapping.

### 0.2 The canary — Sophocles

Thirteen LibriVox items exist; all seven surviving plays in English plus alternate
translations. The app ships one, and it is Spanish.

```
oedipus_rex_1008_librivox              eng  Oedipus Rex
oedipusrex_1507_librivox               eng  Oedipus Rex (Murray)
antigone_1009_librivox                 eng  Antigone
antigone_1507_librivox                 eng  Antigone (Plumptre)
oedipusatcolonus_1009_librivox         eng  Oedipus at Colonus
oedipusatcolonus_1507_librivox         eng  Oedipus at Colonus (Jebb)
electra_1012_librivox                  eng  Electra
electra_1506_librivox                  eng  Electra (Storr)
philoctetes_1205_librivox              eng  Philoctetes
philoctetes_campbell_transl…_librivox  eng  Philoctetes (Campbell)
ajax_campbell_translation_…_librivox   eng  Ajax (Campbell)
trachiniai_campbell_transl…_librivox   eng  Trachiniai (Campbell)
tragediassofocles_1606_librivox        spa  Las Siete Tragedias  ← the one that ships
```

### 0.3 Target behaviour

- **Flat listing.** One row per distinct LibriVox recording. *Oedipus Rex*, *Antigone*,
  *Electra* are each their own browsable item; alternate translations are sibling rows.
  No grouping UI, no collapsing.
- **One Great Books collection per language.** Each contains only recordings in that
  language — originals and translations into it, never mixed. The app switches between
  hardcoded per-language collections at runtime as the language selection changes, and
  resolves the correct one on cold start before first paint.

### 0.4 Existing assets

`great_books_librivox_batch_10_completed_through_row13.xlsx` holds an `Audited Matches`
sheet (183 normalized GBWW work rows) and a `Recording Versions` sheet (29 hand-verified
LibriVox→IA rows, works 2–13 only). Phase 1 mines both. After extraction the workbook and
`codex_handoff_great_books_librivox.md` are **superseded provenance** — the ten-rows-per-
batch research loop is replaced by full enumeration. Keep both files; stop working them.

---

# PHASE 1 — Data generation

**Goal:** produce checked-in, validated, per-language manifests plus a coverage report.
**Constraint:** no file under `Voxglass/` is modified in this phase. The app continues to
ship the old 90-entry manifest until Phase 2.
**Definition of done:** `swift run curated-lists` runs clean from a cold cache, emits the
manifests and report, and exits non-zero if anything is wrong.

## 1.1 Extract the GBWW work list

Write `Tools/CuratedLists/extract_workbook.py` (one-shot, checked in for reproducibility)
reading the workbook via `openpyxl`. Emit `Tools/CuratedLists/gbww-works.json`:

```json
[
  {
    "workID": "sophocles-plays",
    "row": 5,
    "author": "Sophocles",
    "title": "Plays",
    "constituents": ["Oedipus Rex", "Oedipus at Colonus", "Antigone",
                     "Electra", "Ajax", "Philoctetes", "Trachiniae"]
  }
]
```

- `workID` is a stable slug: `<author-slug>-<title-slug>`. Never regenerate these once
  checked in — Phase 2 tests and any future grouped UI key on them.
- `row` is the `Audited Matches` row number, preserving traceability to the workbook.
- `constituents` is empty for atomic works. For corpus entries (`Plays`, `Dialogues`,
  `Works`, `Essays`) it lists the actual constituent titles in the Great Books edition.
  The workbook does not always enumerate these; where it does not, fill them from the
  GBWW second-edition contents and record the source in a `constituentsSource` field.

Expect ~183 rows. **Assert the count matches the workbook's `Coverage Summary`
"Normalized works" cell (183); fail the extraction if not.**

## 1.2 Extract the verified seed

From the `Recording Versions` sheet, emit `Tools/CuratedLists/verified-seed.json` — the 29
researched rows, each with `workID`, `identifier`, `librivoxURL`, `matchClass`. These are
hand-verified LibriVox→IA links.

**These become a correctness oracle, not input.** In §1.5 the generator must independently
rediscover every seed identifier through enumeration. Any seed identifier the enumeration
fails to find, or assigns a different `workID`, is a generator bug and **fails the run**.
Do not merge seed rows into the output to paper over a miss.

Two seed rows are `No exact match` / `No exact completed recording located`
(Plato — *The Seventh Letter*, and the corpus no-match rows). These assert the *absence*
of a recording; they are checked the same way, in reverse.

## 1.3 Resolve creator aliases

Root cause 5 suppresses whole authors — French worst of all. Build
`Tools/CuratedLists/creator-aliases.json` before enumerating.

For each of the ~130 GBWW authors:

1. Query `collection:(librivoxaudio) AND creator:"<canonical name>"`.
2. If 0 hits, probe loosely: `collection:(librivoxaudio) AND creator:(<surname>)`, plus
   known variants (inverted `Surname, Given`; with/without middle names; endonym forms
   such as `Aristoteles`, `Platon`, `Sofocles`).
3. Collect every distinct `creator` string in the results.
4. Emit canonical author → `[observed creator strings]`.

**This file requires human review before Phase 1 completes.** Loose surname probes produce
false positives — the existing `excludedCreators` list (`William John Locke`,
`Homer Greene`, `Homer Eon Flint`) exists precisely because of this class of error, and
commit `75850ff` was a namesake fix. Add an `excluded` array to the file and populate it
during review. Namesake contamination silently corrupts everything downstream.

Also add authors missing from `greatBooksCreators` entirely — Molière is the known one;
audit the full 183-row list for others.

## 1.4 Enumerate the catalog

For each resolved creator string, page through **all** matching LibriVox items:

```
collection:(librivoxaudio) AND creator:"<string>"
fl[]=identifier,title,creator,language,downloads,date,subject
rows=100, paginated to exhaustion
```

- Cache every response to `Tools/CuratedLists/.cache/` (gitignored) keyed by query+page,
  so reruns are cheap and reviewable.
- ≥ 1s between uncached requests.
- Dedup by `identifier` across creator strings — an item credited to two authors appears
  once.

Expect ~1,143 items. This is the universe; everything downstream is classification.

## 1.5 Partition by language

Assign each item to a language using the token sets in `LibriVoxLanguage.all`
(`Voxglass/Core/Catalog/LibriVoxLanguage.swift:28`). Read the tokens from that Swift file
or mirror them in a shared JSON — **do not retype them**, drift here is silent.

- An item whose `language` matches no known token set goes to a `review` bucket and is
  **never silently dropped**.
- An item listing multiple languages goes to `review` — decide per case; do not guess.

Measured 2026-07-21, pre-alias-resolution:

| Language | id | Items | Ship? |
|---|---|---:|---|
| English | `eng` | 951 | **yes** |
| Spanish | `spa` | 56 | **yes** |
| German | `deu` | 38 | **yes** |
| Greek | `grc` | 36 | **yes** |
| Italian | `ita` | 11 | **yes** |
| French | `fre` | 7 | **yes** — alias-suppressed, expect 15–25 after §1.3 |
| Dutch | `nld` | 7 | borderline |
| Russian | `rus` | 7 | borderline |
| Latin | `lat` | 4 | no |
| Finnish | `fin` | 3 | no |
| Polish | `pol` | 1 | no |
| Portuguese / Chinese / Japanese / Hebrew | | 0 | no |

**Ship threshold: ≥ 10 items after alias resolution.** Re-measure; let the fresh data
decide `nld` and `rus`. Do not hardcode this table — it is a pre-fix snapshot.

## 1.6 Map recordings to works

Join each item onto `gbww-works.json` to assign `workID`:

1. Normalize titles (case-fold, strip diacritics, strip parenthetical translator/version
   suffixes such as `(Murray Translation)`, `(Version 2)`, `, Vol. 1`).
2. Match against the work title, then against each `constituents` entry, then against a
   `titleAliases` map for known variants (*Trachiniae* / *Trachiniai* / *The Women of
   Trachis*; *The Peloponnesian War* / *History of the Peloponnesian War*).
3. Unmatched items → `review` bucket. These are same-author non-GBWW works (Tolstoy's
   short fiction, Shakespeare's sonnets where not in the set). **Excluded from manifests**,
   listed in the report.

Non-English matching needs the translated title, not the English one — *Las Siete
Tragedias de Sófocles* must map to `sophocles-plays`. Populate `titleAliases` per language.
Where a single non-English item covers several constituents (as that one does), emit **one
entry per item**, with `workID` set to the corpus work.

## 1.7 Emit

**Manifests** — `Tools/CuratedLists/out/great-books-<lang>.json`, one per shipped language.
Phase 2 copies them into `Voxglass/Core/Resources/CuratedLists/`; Phase 1 does not.

```json
[
  {
    "rank": 41,
    "workID": "sophocles-plays",
    "title": "Oedipus Rex",
    "author": "Sophocles",
    "identifier": "oedipus_rex_1008_librivox",
    "language": "eng"
  }
]
```

Ordering: `rank` follows GBWW/Syntopicon work order; recordings of the same work are
numbered **consecutively**, so Sophocles' plays occupy a contiguous run with each
translation immediately after its play. Ranks are dense and ascending within each file.

**Report** — `Tools/CuratedLists/out/great-books-report.json`, one row per GBWW work ×
language: covered yes/no, recording count, identifiers. For zero-coverage rows, the
searches performed. The 11 silent drops become explicit report rows. Include the `review`
buckets (unknown language, unmatched title, multi-language) in full.

## 1.8 Rewrite the generator

Replace `Tools/CuratedLists/main.swift` wholesale — the top-hit search is the origin of
causes 2, 3 and 4 and none of it is salvageable. The target `curated-lists` already exists
in `Package.swift:23`.

`greater-books` generation is **out of scope**. Leave
`Voxglass/Core/Resources/CuratedLists/greater-books.json` untouched and keep its source CSV
in place; §5 covers the follow-up.

**Fail loudly** — the single most important change:

- Delete `try?` at `main.swift:151`. Any throw exits non-zero.
- Exit non-zero if: any manifest is empty; any seed identifier was not rediscovered (§1.2);
  a language file's count regressed >10% vs. the checked-in version; any emitted entry has
  a `workID` absent from `gbww-works.json`; any `identifier` appears twice within a file.
- Print a summary table: per language, item count, works covered / 183, review-bucket size.

## 1.9 Phase 1 checklist

- [ ] `gbww-works.json` — 183 rows, count asserted against workbook
- [ ] `verified-seed.json` — 29 rows extracted
- [ ] `creator-aliases.json` — generated **and human-reviewed**, `excluded` populated
- [ ] Enumeration caches ~1,143 items
- [ ] Ship list finalized from post-alias counts
- [ ] Manifests in `Tools/CuratedLists/out/`, English ≥ 600 entries
- [ ] All 29 seed rows independently rediscovered
- [ ] Report emitted; review buckets triaged
- [ ] Generator exits non-zero on every failure condition
- [ ] **No file under `Voxglass/` modified**

---

# PHASE 2 — App integration

**Goal:** the generated manifests are bundled, the Great Books collection switches language
at runtime, is correct on cold start, and is covered by tests.
**Definition of done:** §2.8 checklist green, full test suite passing.

## 2.1 Critical constraint — the collection id stays `great-books`

Do **not** mint per-language collection ids. `great-books` is load-bearing in four places:

- `AppPreferencesStore.selectedCollectionIDs` persists ids to `@AppStorage`
  (`AppPreferencesStore.swift:6`). New ids would silently deselect the collection for every
  existing user and require a migration in `migrateCollectionIDs`.
- `OnboardingPreferencesView.swift:128` renders `allSelectableCollections` as pickable
  tiles — per-language ids would show six Great Books tiles during onboarding.
- `RecommendationPipeline.swift:332` hardcodes `"great-books"` in `knownCollectionIDs`.
- `InternetArchiveCatalogTests.swift:140` asserts `IACollectionStore.curated.count == 2`.

Instead: **one stable collection whose backing manifest, query, title and copy are derived
from the active language.** This delivers the required behaviour (one collection per
language, switching at runtime) with zero persistence migration.

## 2.2 Language reduction

`selectedLanguages` is a `Set<String>` — multi-select chips
(`SettingsView.swift:112`), default `["eng"]`, **empty means "all languages"**
(`LibriVoxLanguage.clause(for:)` returns `""` for empty). So "the user's language" needs a
deterministic reduction. Add to `LibriVoxLanguage`:

```swift
/// Languages with a bundled Great Books manifest, in preference order.
/// Populated from the Phase 1 ship list.
public static let greatBooksLanguages: [String] = ["eng", "spa", "deu", "grc", "ita", "fre"]

/// The language whose Great Books manifest backs the collection right now.
public static func greatBooksLanguage(for selected: Set<String>) -> String {
    // 1. Empty selection ("all languages")        → "eng"
    // 2. Exactly one selection, manifest shipped  → that language
    // 3. Multiple selections                      → first greatBooksLanguages entry
    //                                                present in the set
    // 4. No selection has a shipped manifest      → "eng"
}
```

Rules 1 and 4 mean the collection is never empty and never disappears. Rule 3 is order-
stable, so the shelf does not reorder unpredictably as chips toggle. `greatBooksLanguages`
order is the tie-break and must match the Phase 1 ship list exactly.

Add `endonym` to `LibriVoxLanguage`: `English`, `Español`, `Deutsch`, `Ἑλληνικά`,
`Italiano`, `Français`.

## 2.3 Schema and loader

Extend `CuratedManifestEntry` (`CuratedManifest.swift:6`):

```swift
public let language: String   // ISO id, matches LibriVoxLanguage.id
public let workID: String     // stable GBWW work key
```

**Both must decode with a default** (`decodeIfPresent` → `""`) so the untouched
`greater-books.json` still loads. `workID` is not used for grouping — the UI stays flat.
It exists so coverage is computable, ranks keep constituents adjacent, and a future
grouped UI needs no data regeneration.

`CuratedManifest.load(named:bundle:)` needs no change; it already resolves by filename.

## 2.4 Per-language collection factory

Replace the `IACollectionStore.greatBooks` constant (`IACollection.swift:82`) with:

```swift
public static func greatBooks(for language: String) -> IACollection
```

returning `id: "great-books"` always, and varying:

- `curatedListName` → `"great-books-\(language)"`
- `archiveQuery` → `CuratedQueries.greatBooks(for: language)`, the creator clause **AND**
  that language's token clause
- `title` → `"Great Books"` for `eng`; `"Great Books (\(endonym))"` otherwise
- `summaryLine` → generated with the real count, replacing today's hardcoded
  "90 essential works"
- `remoteImageURL` → a cover from that language's manifest, not the hardcoded
  `iliad_popetranslation_1506_librivox`

Keep a `public static var greatBooks: IACollection { greatBooks(for: "eng") }` shim so
`CuratedManifestTests.swift:132` and `:142` keep compiling.

Thread language through:

- `IACollectionStore.collections(for:languages:)` and `allSelectableCollections` — the
  latter is used by onboarding, which should show the English variant (onboarding runs
  before any language choice exists).
- `CuratedQueries.greatBooks` → `greatBooks(for:)`.
- `CatalogStore.searchAdvanced` (`CatalogStore.swift:57`) resolves the manifest via
  `allSelectableCollections.first(where: { $0.id == id })?.curatedListName`. Because the id
  is now stable but the manifest is not, **this lookup must use the language-aware
  collection list**, or it will always load English. This is the single highest-risk line
  in Phase 2.

## 2.5 Cold-start and switching correctness

`BrowseView.task` (`DiscoverView.swift:31`) already reads `@AppStorage` before resolving
covers and counts, so the ordering is right. Three things must become language-aware:

- **Collection list.** All three `IACollectionStore.collections(for:)` call sites
  (`DiscoverView.swift:33, 40, 59`) must pass the language.
- **Cover/count cache.** `CollectionCoverStore.stamp(for:query:)`
  (`CollectionCoverStore.swift:173`) is `"\(languages)|\(query)"` — since `archiveQuery`
  now varies by language, **the stamp already varies correctly**. No change needed. Verify
  with a test rather than assuming.
- **First curation search.** If a curated collection is the restored selection at launch,
  the manifest must load before `runCurationSearch` issues its identifier query.

Fix while here: `loadMoreCuration` (`CatalogStore.swift:143`) skips `filteredResults`,
which page 1 applies — pages 2+ are filtered differently from page 1.

## 2.6 Counts and copy

- `CollectionBundledCounts.counts` (`CollectionBundledCounts.swift:7`) has
  `"great-books": 632` from the creator query, while the badge shows the manifest count
  (90). Neither survives. Regenerate via `swift run collection-counts` with per-language
  keys `great-books-eng`, `great-books-spa`, … and have `resolveCounts`
  (`CollectionCoverStore.swift:93`) look up the language-specific key.
- Rewrite the Great Books `description` (`IACollection.swift:88`). It currently claims
  "90 essential works", describes hand-picked identifiers favouring "readable
  translations", and tells users to "search the broader Great Books collection for
  alternate versions" — all obsolete once alternates are listed inline. Add a per-language
  coverage note.

## 2.7 Tests

All in `VoxglassTests/`, swift-testing style matching `CuratedManifestTests.swift`. Per
`ci-no-simulator` these are Linux-only source checks and run in CI; manifest regeneration
stays a manual local step, with CI validating the checked-in files.

### Manifest integrity — parameterized across every shipped language

```swift
@Test(arguments: LibriVoxLanguage.greatBooksLanguages)
func manifestIsNonEmpty(_ lang: String)

@Test(arguments: LibriVoxLanguage.greatBooksLanguages)
func manifestRanksAscending(_ lang: String)

@Test(arguments: LibriVoxLanguage.greatBooksLanguages)
func manifestIdentifiersUniqueWithinFile(_ lang: String)

@Test(arguments: LibriVoxLanguage.greatBooksLanguages)
func everyEntryDeclaresItsOwnLanguage(_ lang: String)   // entry.language == lang, all rows

@Test(arguments: LibriVoxLanguage.greatBooksLanguages)
func everyWorkIDExistsInWorkList(_ lang: String)

@Test(arguments: LibriVoxLanguage.greatBooksLanguages)
func manifestMeetsShipThreshold(_ lang: String)          // >= 10 entries
```

`everyEntryDeclaresItsOwnLanguage` is the no-mixing guarantee and the most important test
in the suite.

### Cross-language

- `identifiersDoNotRepeatAcrossLanguages` — an identifier in two files means a partition
  bug. Assert none.
- `englishManifestIsSubstantial` — ≥ 600 entries; guards against silent enumeration
  regression.
- `everyShippedLanguageHasABundledManifest` — every id in `greatBooksLanguages` resolves to
  a loadable file. Catches a ship-list/resource mismatch.
- `noBundledManifestIsUnshipped` — the inverse; a `great-books-*.json` in resources with no
  entry in `greatBooksLanguages` is dead weight.

### The Sophocles canary

```swift
@Test func sophoclesPlaysAreBrokenOutInEnglish() {
    let m = CuratedManifest.load(named: "great-books-eng")
    let soph = m.filter { $0.author.contains("Sophocles") }
    #expect(soph.count >= 7)
    #expect(Set(soph.map(\.workID)).count >= 1)
    let titles = Set(soph.map { $0.title.lowercased() })
    for play in ["oedipus", "antigone", "electra", "philoctetes", "ajax"] {
        #expect(titles.contains { $0.contains(play) })
    }
}

@Test func spanishManifestHasNoEnglishSophocles() {
    let m = CuratedManifest.load(named: "great-books-spa")
    #expect(!m.contains { $0.identifier == "oedipus_rex_1008_librivox" })
    #expect(m.allSatisfy { $0.language == "spa" })
}
```

This is the direct regression test for the original complaint.

### Language reduction — all four rules

```swift
@Test func emptySelectionFallsBackToEnglish()          // [] → eng   (rule 1)
@Test func singleShippedLanguageSelected()             // ["spa"] → spa (rule 2)
@Test func singleUnshippedLanguageFallsBackToEnglish() // ["jpn"] → eng (rule 4)
@Test func unshippedBorderlineFallsBack()              // ["lat"] → eng (rule 4)
```

**The combined-selection test the requirement calls for:**

```swift
@Test func englishAndSpanishSelectedResolvesDeterministically() {
    let sel: Set<String> = ["eng", "spa"]
    let resolved = LibriVoxLanguage.greatBooksLanguage(for: sel)
    #expect(resolved == "eng")                       // eng precedes spa in ship order

    // Stable across invocations — Set iteration order must not leak through.
    for _ in 0..<50 {
        #expect(LibriVoxLanguage.greatBooksLanguage(for: sel) == "eng")
    }

    // And the resolved collection is purely English — no Spanish leakage.
    let m = CuratedManifest.load(named: "great-books-\(resolved)")
    #expect(m.allSatisfy { $0.language == "eng" })
}

@Test func spanishAndGermanSelectedPicksShipOrderWinner() {
    #expect(LibriVoxLanguage.greatBooksLanguage(for: ["deu", "spa"]) == "spa")
    #expect(LibriVoxLanguage.greatBooksLanguage(for: ["spa", "deu"]) == "spa")
}

@Test func mixedShippedAndUnshippedIgnoresUnshipped() {
    #expect(LibriVoxLanguage.greatBooksLanguage(for: ["jpn", "ita"]) == "ita")
}
```

The 50-iteration loop is not padding: `Set<String>` iteration order varies per process, so
a reduction implemented with `.first` over the set rather than over `greatBooksLanguages`
passes once and fails intermittently. Assert stability explicitly.

### Collection wiring

```swift
@Test(arguments: LibriVoxLanguage.greatBooksLanguages)
func collectionIDIsStableAcrossLanguages(_ lang: String) {
    #expect(IACollectionStore.greatBooks(for: lang).id == "great-books")
}

@Test(arguments: LibriVoxLanguage.greatBooksLanguages)
func collectionPointsAtItsOwnManifest(_ lang: String) {
    #expect(IACollectionStore.greatBooks(for: lang).curatedListName == "great-books-\(lang)")
}

@Test(arguments: LibriVoxLanguage.greatBooksLanguages)
func collectionQueryConstrainsToItsLanguage(_ lang: String)   // archiveQuery contains the tokens

@Test func nonEnglishCollectionTitleCarriesEndonym() {
    #expect(IACollectionStore.greatBooks(for: "spa").title.contains("Español"))
    #expect(IACollectionStore.greatBooks(for: "eng").title == "Great Books")
}

@Test func curatedCollectionCountUnchanged() {
    #expect(IACollectionStore.curated.count == 2)   // guards the §2.1 constraint
}

@Test func coverStampDiffersBetweenLanguages() {
    // archiveQuery varies by language, so the cover/count cache invalidates on switch.
    #expect(IACollectionStore.greatBooks(for: "eng").archiveQuery
         != IACollectionStore.greatBooks(for: "spa").archiveQuery)
}
```

### Catalog store

```swift
@Test func curationSearchLoadsLanguageSpecificManifest()  // ["spa"] → Spanish identifiers
@Test func loadMoreCurationAppliesSameFilteringAsPageOne() // the CatalogStore.swift:143 fix
```

## 2.8 Phase 2 checklist

- [ ] Manifests copied to `Voxglass/Core/Resources/CuratedLists/`, bundled via
      `Package.swift:14` `.process("Resources/CuratedLists")` (no manifest change needed —
      verify they actually appear in `.module`)
- [ ] `CuratedManifestEntry` gains `language` + `workID`, both defaulted;
      `greater-books.json` still loads
- [ ] `LibriVoxLanguage`: `greatBooksLanguages`, `greatBooksLanguage(for:)`, `endonym`
- [ ] `IACollectionStore.greatBooks(for:)` factory; `id` stays `"great-books"`
- [ ] All three `collections(for:)` call sites language-aware
- [ ] `CatalogStore.searchAdvanced` manifest lookup language-aware (§2.4, highest risk)
- [ ] `loadMoreCuration` filtering fixed
- [ ] `CollectionBundledCounts` regenerated per language
- [ ] Great Books `description` and `summaryLine` rewritten
- [ ] All §2.7 tests written and passing
- [ ] Existing suite green — especially `InternetArchiveCatalogTests.swift:140` and
      `CuratedManifestTests.swift:132`
- [ ] Manual: launch with `spa` selected, confirm Spanish Great Books on **first paint**;
      toggle to `eng`, confirm switch without relaunch; relaunch, confirm it sticks

---

## 5. Out of scope / follow-ups

1. **`greater-books`** has the identical defects — 475 rows → 143, duplicate overrides,
   top-hit picks, mixed languages — and the Phase 1 generator applies almost unchanged.
   Deliberately deferred until the generator is proven on Great Books.
2. **Same-author fallbacks.** Enumeration surfaces many recordings by GBWW authors that
   are not GBWW works. Excluded from manifests, listed in the report. If they should be
   browsable, that is a "More by this author" surface, not this collection.
3. **Borderline languages.** Dutch (7) and Russian (7) sit under the threshold pre-alias.
   Decide from Phase 1 post-alias numbers.
4. **Grouped UI.** The listing is flat by decision. `workID` is in the schema so a future
   "4 versions" affordance needs no data regeneration.
