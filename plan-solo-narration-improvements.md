# Per-Chapter Narrator & Solo Narration UX Improvements

> HTML mockup: `docs/mockups/solo-narration-per-chapter.html`

## Summary

Four changes that make per-chapter narration visible and the Solo Narration preference sticky.

---

## 1. Per-chapter narrator on Now Playing chapter line

**Problem.** `BookPageView.chapterLine()` (line 327) shows the current chapter title but never the narrator. For multi-narrator books like Dracula (v2 dramatic reading), the user needs to scroll to the chapter list below to see who reads each chapter.

**Fix.** In `BookPageView.chapterLine()`, when `isActiveSession` is true and the book has multiple narrators, render the per-chapter narrator below the chapter title using `NarratorDisplay.chapterLine()`.

**File:** `Voxglass/Features/Player/BookPageView.swift`
- Lines 327-344, `chapterLine(_:)` method

---

## 2. Reserve vertical space for Solo Narration badge

**Problem.** `SoloNarrationBadge()` is conditionally rendered (`if narrationKind == .solo`) in `ListenBookCard`, `HorizontalCatalogCard`, and `BookListRow`. This causes vertical layout shift between solo and non-solo cards — the card height changes.

**Fix.** Always render `SoloNarrationBadge()` but apply `.opacity(narrationKind == .solo ? 1 : 0)` to make it invisible while preserving its frame, keeping card heights identical.

**Files:**
- `Voxglass/Features/Listen/ListenView.swift` — `ListenBookCard` (lines 244-247)
- `Voxglass/DesignSystem/BookArtworkView.swift` — `HorizontalCatalogCard` (lines 230-233)
- `Voxglass/DesignSystem/VoxglassComponents.swift` — `BookListRow` (lines 198-201)

---

## 3. Persist Solo Narration preference (default ON)

**Problem.** `soloOnly` is a local `@State` variable in every view, resetting to `false` on each view recreation. User must re-enable it every time.

**Fix.** Add `soloOnlyEnabled` to `AppPreferencesStore` (persisted via `@AppStorage`, default `true`). Replace all local `@State private var soloOnly = false` with `@AppStorage(AppPreferencesStore.Keys.soloOnlyEnabled)`.

**Files:**
- `Voxglass/Core/AppPreferencesStore.swift` — add key and `@AppStorage` property
- `Voxglass/Features/Listen/ListenView.swift` — line 13
- `Voxglass/Features/Library/LibraryView.swift` — line 12
- `Voxglass/Features/Discover/DiscoverView.swift` — line 17
- `Voxglass/Features/Search/SearchView.swift` — line 11
- `Voxglass/Features/Player/CatalogDiscoveryView.swift` — line 20

---

## 4. Filter recommendations to solo-only, keeping same count

**Problem.** When solo-only is on, the UI filter in ListenView reduces visible recommendations below the intended 18-card shelf because collaborative/dramatic results are hidden. The engine should fetch more results so the visible shelf stays at full count.

**Fix.** Pass `soloOnly` through to `RecommendationEngine.fetchRecommendationShelf()`. When true, multiply query row counts by 2x (to compensate for ~50% of results being filtered out), then post-ranking filter to solo-only before taking the top 18.

**Files:**
- `Voxglass/Core/Catalog/HomeRecommendationStore.swift` — accept `soloOnly` parameter in `load()`, pass to engine
- `Voxglass/Core/Catalog/Recommendations/RecommendationEngine.swift` — accept `soloOnly` in `fetchRecommendationShelf()`, double requested counts, filter post-rank
- `Voxglass/Features/Listen/ListenView.swift` — pass persisted `soloOnlyEnabled` to `load()` and `refresh()`

---

## Verification

```bash
cd /Users/arley/github/parso-voxglass
xcodegen generate
xcodebuild -scheme Voxglass -destination 'platform=iOS Simulator,name=iPhone 16' build
xcodebuild -scheme Voxglass -destination 'platform=iOS Simulator,name=iPhone 16' test
```
