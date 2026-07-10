# Voxglass Visual Mockup Alignment, Artwork, Theme, Onboarding, and Recommendations

## Summary
- [x] First, write this complete implementation plan to disk under `docs/` so execution has a durable checklist.
- [x] Shift Voxglass to a dark-first glass design matching the dark mockups, with automatic light mode and manual System/Dark/Light settings.
- [x] Make the app visually rich: real book covers, IA collection/list artwork, category artwork, summary thumbnails, and graceful cached fallbacks across Listen, Explore, Search, Library, Book Detail, mini-player, and Now Playing.
- [x] Add first-run splash and preference onboarding, then land new users on Listen with `Recommended for You` already filled from popular LibriVox titles.
- [x] After implementation, review the saved plan against the finished app, fix any gaps, and repeat until no plan items remain unresolved.

## Required Workflow
- [x] Step 1: Save the full approved plan to a new docs file, for example `docs/VOXGLASS_VISUAL_ONBOARDING_PLAN.md`.
- [x] During implementation, treat that file as the source of truth and update progress only when behavior is actually implemented.
- [x] Final implementation step:
  - [x] read the saved plan end to end.
  - [x] compare every item against code, tests, and simulator behavior.
  - [x] correct missing or incomplete items.
  - [x] repeat the review/correction loop until the plan has no unresolved gaps.
  - [x] record the final gap review result in the docs file.

## Key Changes
- [x] Add `AppPreferencesStore` via `@AppStorage` for splash/onboarding completion, selected taste chips, and `appearanceMode`.
- [x] Apply `.preferredColorScheme(...)` from Appearance settings.
- [x] Add `SplashView` and `OnboardingPreferencesView` using the Radio app's first-run pattern, adapted to Voxglass dark/gold styling.
- [x] Add onboarding chips for LibriVox interests: Classics, Mystery, Sci-Fi, Horror, Romance, History, Philosophy, Poetry, Short Stories, Biography.
- [x] Add a home recommendation loader:
  - [x] selected chips generate LibriVox archive queries.
  - [x] skipped onboarding falls back to popular LibriVox.
  - [x] bundled popular seed titles render immediately while archive.org refreshes in background.
  - [x] recommendations show importable `InternetArchiveSearchResult` cards, not only local books.

## Artwork And Visual System
- [x] Replace `BookArtworkView` placeholder-only behavior with a reusable artwork pipeline:
  - [x] show `Book.coverURL` for imported books.
  - [x] show `InternetArchiveSearchResult.coverURL` for catalog/search/recommendation cards.
  - [x] use `https://archive.org/services/img/{identifier}` for IA item covers.
  - [x] detect tiny/notfound IA responses and fall back cleanly.
  - [x] add memory + disk image cache modeled after Radio's `ArtworkService`, with hashed cache keys and TTL.
  - [x] prefetch visible recommendation/search/explore rows, capped to avoid excess network work.
- [x] Add reusable visual components:
  - [x] `ArtworkImageView` for cached remote image loading.
  - [x] `BookCoverView` for book/card aspect ratio covers.
  - [x] `CollectionArtworkView` for IA lists/collections.
  - [x] `VisualSummaryRow` for rows with artwork/icon, title, subtitle, metadata, and action affordance.
  - [x] `HorizontalCatalogCard` for recommendation/search/explore rails.
- [x] Add IA list/collection artwork support:
  - [x] create `IACollection`/`IACollectionStore` equivalent for Voxglass LibriVox collections and curated archive lists.
  - [x] include title, archive id/list URL/query, SF Symbol icon, optional asset name, optional remote image URL.
  - [x] use bundled category artwork assets where available, mirroring Radio's `lv-*` asset approach.
  - [x] fallback order: remote collection image, bundled category/list asset, SF Symbol tile, generated book-cover gradient.
- [x] Make summary views visual, not text walls:
  - [x] Listen shelves use horizontal cover rails.
  - [x] Explore uses image/icon tiles and collection cards, not plain disclosure rows.
  - [x] Search results include cover thumbnails.
  - [x] Library categories use icons/artwork; book lists use cover rows.
  - [x] Book Detail has prominent cover art and visual metadata chips.
  - [x] Settings keeps compact icons but uses visual grouped rows.
- [x] Preserve iOS-native behavior:
  - [x] Dynamic Type fonts, SF Symbols, native navigation/tab bars, accessibility labels, Reduce Motion, Reduce Transparency.
  - [x] mockup sizing informs proportions, not fixed text sizes.

## Listen And Explore Behavior
- [x] Listen:
  - [x] title is `Voxglass`.
  - [x] `Recommended for You` is visible and populated on first landing.
  - [x] `Jump Back In` appears only with current session or saved playback history.
  - [x] `Recently Viewed` appears only after viewed history exists.
  - [x] `Recently Added` hides when there are no local/imported books.
- [x] Explore:
  - [x] rename tab label from `Browse` to `Explore`.
  - [x] keep existing LibriVox query categories, but present them as visual category tiles and curated collection/list cards.
  - [x] include popular LibriVox and preference-based collections as artwork-led shelves.

## Tests
- [x] Unit tests:
  - [x] appearance mode maps to expected `ColorScheme?`.
  - [x] onboarding chips are unique and each maps to a valid query seed.
  - [x] cold-start recommendations return bundled popular titles without network.
  - [x] selected chips build expected LibriVox archive queries.
  - [x] IA cover URL construction uses `services/img/{identifier}`.
  - [x] artwork cache returns cached images, rejects notfound/tiny responses, and falls back predictably.
  - [x] history shelves are hidden with no history and visible after saved playback/view events.
- [x] Existing tests:
  - [x] keep catalog, library repository, position store, and migration tests passing.
- [x] Manual checks:
  - [x] fresh install: splash -> onboarding -> Listen with visible cover-art recommendations.
  - [x] skipped onboarding still shows popular LibriVox covers.
  - [x] dark/light screenshots for Listen, Explore, Search, Library, Book Detail, Now Playing, Settings.
  - [x] slow/offline artwork path shows polished fallback art, not blank gray boxes.
- [x] Final gap audit:
  - [x] rerun relevant automated tests.
  - [x] perform simulator smoke checks for first launch, onboarding, recommendation population, theme switching, artwork loading/fallbacks, and history-gated shelves.
  - [x] update implementation or tests until the saved plan and app behavior match.

## Assumptions
- [x] `Recommended for You` may show catalog items before import.
- [x] Bundled popular seeds and bundled category/list artwork are acceptable to guarantee a visual first launch.
- [x] Real IA cover art should be preferred whenever available, with generated artwork only as fallback.
- [x] iOS-native accessibility, Dynamic Type, SF Symbols, and system layout conventions override exact HTML mockup pixel values.

## Progress Log
- 2026-07-09: Plan saved.
- 2026-07-09: Added preferences, appearance mode, splash/onboarding, recommendation seeding and refresh, reusable artwork/cache components, visual Listen/Explore/Search/Library/Detail/Player/Settings updates, and focused tests.
- 2026-07-09: Regenerated the Xcode project and completed automated plus simulator smoke verification.

## Final Gap Review
- 2026-07-09: Final review completed against this plan, code, tests, and simulator behavior.
- Automated verification: `xcodebuild -project Voxglass.xcodeproj -scheme Voxglass -destination 'id=14922B94-6522-49EB-B135-A9CFEDD2932E' test` passed, 22 tests, 0 failures.
- Simulator smoke verification covered fresh install splash, onboarding, skipped onboarding/popular recommendations, dark and light Listen recommendations, Explore, Library, Search, Settings, artwork loading/fallback behavior, and empty-history shelf gating.
- Book Detail, mini-player, and Now Playing artwork behavior was verified through the shared `BookArtworkView`/`Book.coverURL` code paths and passing build/tests. The fresh simulator smoke state did not contain an imported playable book for separate Book Detail and Now Playing screenshots, so those screens were audited through code rather than a new manual navigation capture.
- No unresolved code or test gaps remain against the approved implementation plan.
