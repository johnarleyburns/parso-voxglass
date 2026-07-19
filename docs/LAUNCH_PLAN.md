# Voxglass Launch Plan — Blocker Fix + Final Polish (agentic coding handoff)

## Context

Voxglass is release-ready competitively (see `docs/RELEASE_READINESS.md`) except for one show-stopper:
**"Recommended for You" always shows the bundled popular titles on startup** even with 12+ items in
Jump Back In, occasionally flashing the personalized list before reverting. The equivalent feature works
in `../parso-radio-ios-app`. Root cause is confirmed (below). Alongside the fix, this plan covers the
remaining pre-launch items: README refresh, accessibility sweep, porting the radio app's animated splash,
and the physical-device checklist.

Repo ground rules apply (from `docs/RELEASE_PLAN.md`): falsification-first tests,
`xcodegen generate` after adding files, no code comments unless non-obvious,
pure/static decision functions over coordinator-buried logic.

---

## P0 — Recommended for You (RELEASE BLOCKER)

### Confirmed root cause (file:line verified)

- **H1 — no persistence, network-gated recompute every launch.** `HomeRecommendationStore.init`
  always seeds `bundledPopularSeeds` (`HomeRecommendationStore.swift:16`); no cached personalized list
  is ever saved or read. A fresh store is built each launch (`AppServices.swift:61`). The only
  personalized fetch requires the full bootstrap chain plus live archive.org queries whose
  errors/timeouts are swallowed into popular fallback (`RecommendationEngine.swift:84-93, 122-124`).
  → Cold start always shows popular; slow/failed network stays popular.
- **H2 — the "flashes then reverts" race.** The overwrite guard (`HomeRecommendationStore.swift:48-51`)
  blocks only `.popularFallback` from replacing a visible `.personalized` shelf — **not**
  `.popularColdStart`. A `load()` fired on Now-Playing dismissal (`ListenView.swift:48-57`) races the
  taste rebuild's DELETE→INSERT transaction (`TasteProfileStore.swift:168-186`, actor-reentrant at each
  `await`), reads an empty profile mid-rebuild (`RecommendationEngine.swift:52-61` → `.popularColdStart`),
  and lines 53-54 clobber the personalized list.
- **H3 — taste source mismatch.** Jump Back In reads `playback_positions` directly
  (`LibraryRepository.swift:128-143`); the taste rebuild starts `FROM book_taste`
  (`TasteProfileStore.swift:286-327`), and `backfillBookTasteIfNeeded` (`LibraryRepository.swift:326-354`)
  seeds terms only from `authors_json`. Played books without `book_taste` rows are invisible to taste.

### Fix — port the radio pattern (`MadeForYouShelfStore.swift:99-147`): persist snapshot, hydrate instantly, never clobber good content

**1. `Voxglass/Core/Catalog/HomeRecommendationStore.swift`**
- Add a persisted shelf snapshot (UserDefaults, key `guru.parso.voxglass.recommendationShelfSnapshot`,
  matching the house key style): Codable payload of `results: [InternetArchiveSearchResult]`,
  `source: RecommendationShelfSource`, `savedAt: Date`. Confirm `InternetArchiveSearchResult` is
  Codable; add conformance if only Decodable. Inject `UserDefaults` for testability.
- `init`: hydrate `recommendations` + `visibleShelfSource` from the snapshot when present; fall back to
  `bundledPopularSeeds` only when nothing is persisted (true first run).
- `load(...)`: replace the guard at :48-51 with: if `visibleShelfSource == .personalized` and
  `shelf.source != .personalized` → return (a visible personalized shelf is never replaced by ANY
  popular source). When a `.personalized` shelf lands, save the snapshot.
- Keep `isRefreshing` semantics; hydrated content shows instantly with background refresh (radio's
  "no spinner over good content" rule, `MadeForYouShelfStore.swift:100-110, 138-146`).

**2. `Voxglass/Core/Catalog/Recommendations/TasteProfileStore.swift` — atomic rebuild.**
`rebuildFromListeningHistory` (:152-192) issues BEGIN/DELETE/INSERT/COMMIT as separate `await
database.execute` calls; actor reentrancy lets `fetchProfile()` read empty mid-transaction. Collapse the
rebuild into a single database call (one statement batch executed in one actor hop, BEGIN
IMMEDIATE…COMMIT inside), so no read can interleave.

**3. Close the H3 mismatch.** Ensure every book in `playback_positions` contributes taste terms:
extend `backfillBookTasteIfNeeded` to seed terms from title/subjects/creator when `authors_json` is
empty, and/or drive `buildListeningHistoryEntries` from `playback_positions LEFT JOIN book_taste`
rather than `FROM book_taste`. Verify bootstrap order in `AppServices.bootstrap` (:110-118) is
backfill → taste rebuild → `markEngineReady()` → initial `load()`, awaiting completion in that order.

**4. Tests — falsification first** (each must FAIL on today's tree before the fix), new
`VoxglassTests/RecommendationShelfPersistenceTests.swift` + additions:
- `testColdLaunchHydratesPersistedPersonalizedShelf` — seed snapshot in injected defaults, fresh store
  shows personalized (not bundled seeds) with zero network.
- `testPopularColdStartDoesNotReplaceVisiblePersonalizedShelf` — the H2 guard gap.
- `testPersonalizedShelfIsPersistedWhenLoaded`.
- `testConcurrentFetchDuringRebuildNeverSeesEmptyProfile` (TasteProfileStore atomicity).
- `testPositionOnlyBookContributesTasteTerms` (H3).
- Existing guards to keep green: `RecommendationEngineTests` :463/:491 preserve-shelf tests.

**AC (device):** cold-launch with 12+ Jump Back In items → Recommended for You is personalized
immediately, no popular flash; repeat in airplane mode → still personalized (from snapshot); finish a
book while on Listen tab → shelf never reverts to popular.

---

## P1 — All features are free (no gates)

All previously Pro-gated features are now free. No paywall updates needed.

---

## P2 — Accessibility sweep (App Review risk)

Follow the established pattern (`NowPlayingView.swift:175-176, 235, 331-332;
VoxglassComponents.swift:123-128` — labels on icon-only controls, `accessibilityValue` on stateful
ones, `.combine` on composite rows, `accessibilityHidden` on decorative art). Add:

| File:line | Control | Label |
|---|---|---|
| `SearchView.swift:45` | clear-query xmark button | "Clear search" |
| `PlaylistsView.swift:39` | toolbar plus button | "New playlist" |
| `PlaylistsView.swift:79` | playlist book play button | "Play" + book title |
| `SettingsView.swift:476` | add-source plus button | "Add source" |
| `SettingsView.swift:122` | Settings cell | label + `accessibilityIdentifier("settings.cell")` |
| `DiscoverView.swift:59` | ExploreCollectionCard button | collection title |
| `ListenView.swift:142` | HorizontalCatalogCard button | "Title by Author" |
| `BookDetailView.swift:371` | Bookmarks disclosure row | "Bookmarks" |

`MiniPlayerView`/`BookRowView` are already complete (reference implementations). No CI guard exists
for labels — manual VoiceOver spot-check is the verification.

---

## P3 — Animated splash (ported from radio, Voxglass-branded)

Radio's `ParsoRadio/Views/SplashView.swift` is pure SwiftUI, dependency-free: spring fade-in
(`.spring(response: 0.5, dampingFraction: 0.7)`, opacity 0→1, text scale 0.82→1, icon 0.7→1),
1.5 s hold, 0.35 s ease-out dismissal via `@Binding isPresented`
(wired `ParsoRadioApp.swift:119-122` as a `ZStack` overlay, `zIndex(10)`).

- New file `Voxglass/Features/Onboarding/AnimatedSplashView.swift` (Voxglass already has a
  `SplashView` — it's the "Get Started" welcome screen; do NOT rename/replace it). Port the radio
  view verbatim, swapping brand: background `VoxglassTheme.libraryBackground` (no `splash.png`
  needed); icon SF Symbol `books.vertical.fill` (size 80, light) tinted `Palette.brass` — placeholder
  until a logo imageset exists (only `AppIcon` today, unusable in-app); title `Text("Voxglass")`
  (38, bold, rounded); subtitle "Public-domain audiobooks, private by default." (`Palette.ink2`).
- Wire in `Voxglass/App/RootView.swift`: `@State private var showSplash = true`, `ZStack` overlay
  above the existing `hasCompletedSplash`/onboarding chain, shown every launch. Suppress under UI-test
  launch arguments (mirror radio `ParsoRadioApp.swift:68-77`; add a launch arg to
  `VoxglassUITests.swift` setup so the boot smoke test isn't delayed 1.5 s).
- Run `xcodegen generate` (new file); `git diff --exit-code Voxglass.xcodeproj` clean rule applies.

---

## P4 — README refresh (`README.md`)

- Flip CarPlay from "Near-term ☐" to Shipped (`README.md:56`).
- Competitive section: BookDesign is now subscription ($1.99/mo / $9.99/yr / $24.99-lifetime ad
  removal); add Lex Reader (free text+audio sync over LibriVox, $9.99/mo premium, no CarPlay/player
  depth) — names read-along as the v1.1 differentiator, per `docs/RELEASE_READINESS.md`.
- Note the new animated splash + reco caching under Highlights if touched sections warrant.

---

## P5 — Physical device checklist (human-run, before submission)

The nine checks in `docs/RELEASE_PLAN.md` §Verification (force-quit/crash resume matrix, reinstall
restore on a free build, book-switch resume, next-chapter rollover, upgrade migration, airplane-mode
restore, skip-silence on a real LibriVox recording, VoiceOver over Now Playing), plus three new:
10. Cold launch with history → Recommended for You personalized instantly, no popular flash.
11. Airplane-mode cold launch → personalized shelf still shown (snapshot hydrate).
12. Splash: animates in ~1.5 s, hands off cleanly to welcome/onboarding/tabs; VoiceOver reads it.

---

## Sequencing

| Order | Work | Notes |
|---|---|---|
| 1 | **P0 reco fix** | The blocker. Falsification tests first. |
| 2–4 | P1, P2 accessibility, P3 splash | Independent, parallelizable. |
| 5 | P4 README | Last, so it describes what shipped. |
| 6 | P5 device pass | Human; after all code lands. |

## Verification

- `scripts/test.sh` (simulator, local gate) and `scripts/guard_wiring.sh` green; the five new P0
  falsification tests confirmed failing pre-fix; `xcodegen generate` diff clean.
- Simulator VoiceOver spot-check over Search/Playlists/Settings/Discover/Listen.
- P5 device checklist run on hardware (user).
