# Voxglass — CarPlay Technical Design & Agentic-Coding Handoff

**Status:** ready to build. Apple approved `com.apple.developer.carplay-audio` on 2026-07-16.
**Gating:** CarPlay is **free** for everyone. Pro stays EQ / iCloud sync / stats / offline downloads —
*not* CarPlay. The only Pro touchpoint reachable in-car is the **Download** action (offline download is Pro
everywhere); a free user who taps it gets a graceful "unlock on your iPhone" alert, never a paywalled
transport screen. See the memory `carplay-free-standalone` and `never-lose-playback-position`.
**Companion:** the visual mockups of every view + behavior live in the CarPlay Mockups artifact.

> This document supersedes the "CarPlay — postponed / Pro headline" section of `docs/RELEASE_PLAN.md`.
> That section is now stale (postponed→unblocked, Pro→free). Update it in lockstep when this ships.

---

## 1. Design goals (the "award-winning" bar)

An audiobook head unit is not a music head unit. The listener is mid-book, hands on the wheel, glancing for
<2 seconds at a time. Every decision below optimizes for **one-glance resume** and **zero dead ends**.

1. **Resume is the hero.** Connecting the car and it's already on the "Continue" tab, top row = the book you
   were in, one tap from exactly where you left off. This is Voxglass's whole promise, in the car.
2. **Standalone.** Search, browse, resume, and (Pro) download entirely from the head unit — no phone. This
   includes the **cold-launch-straight-into-CarPlay** path: phone locked, app never foregrounded, user
   connects and plays. (§6.3 — this is the subtle one.)
3. **Never lose the place — in the car too.** Every in-car play routes through
   `PlaybackCoordinator.play(book)`, which already resumes and persists. CarPlay adds *zero* new playback
   paths; it is a new *browse surface* over the existing coordinator.
4. **Safe by construction.** Lists are capped for driving (§4.4). No modal traps. The keyboard is only used
   parked; search is voice-first. Free users never hit a wall — the audio keeps working.
5. **Beautiful, honest, quiet.** Cover art everywhere, progress bars on in-progress books, human detail
   text ("Ch 5 · 18 min left"), and warm empty states — never a spinner with no story.

### What the category leaders get wrong (and we won't)

| App | In-car weakness | Voxglass answer |
|---|---|---|
| **Audible** | Deep menus; resume is 2–3 taps from a "Home" wall of merchandising | "Continue" is the default tab, top row, one tap |
| **LibriVox Audiobooks** (BookDesign) | No first-class CarPlay browse; ads; speed control lost | Full free browse, no ads, speed on Now Playing |
| **Apple Books** | No per-chapter list in car; sleep timer buried | Chapters + sleep + bookmark are Now Playing buttons |
| Generic podcast apps | Streaming-only; useless with no signal | "Downloaded" tab is offline-safe and honors Wi-Fi-only prefetch |

---

## 2. Architecture — extend the seam that already exists

Voxglass already isolates every platform touch behind a **pure value type + protocol** boundary:
`PlaybackCoordinator` (in `VoxglassCore`, host-testable, no UIKit) talks to the app-layer
`SystemPlaybackBridge` only through the `NowPlayingInfo` value type and the `PlaybackRemoteCommand` enum.
**CarPlay is the same pattern applied to a browse tree.**

```
┌─────────────────────────── VoxglassCore (pure, `swift test` on Linux) ────────────────────────────┐
│                                                                                                    │
│  CarPlayModels.swift        value types: CarPlayInterface / Tab / Section / Item / Action / …      │
│  CarPlayMenuBuilder.swift   PURE static builders: snapshots ──▶ CarPlayInterface                   │
│  CarPlayNowPlayingModel.swift  PURE: coordinator state ──▶ which custom buttons + their state      │
│  CarPlaySnapshots.swift     DTOs the app fills from live stores (no store refs inside the builder) │
│                                                                                                    │
│  (reuses existing: PlaybackCoordinator.resolveResume, NowPlayingInfo, PlaybackRate, SleepTimer)    │
└────────────────────────────────────────────────────────────────────────────────────────────────────┘
                                  ▲  pure model (Equatable/Sendable)  │  actions (enum)
                                  │                                    ▼
┌─────────────────────────── Voxglass app target (iOS/UIKit/CarPlay) ───────────────────────────────┐
│                                                                                                    │
│  CarPlaySceneDelegate.swift        CPTemplateApplicationSceneDelegate — connect/disconnect         │
│  CarPlayInterfaceController.swift   owns CPInterfaceController; subscribes to store publishers;     │
│                                     calls the builder; renders CP* templates; dispatches actions   │
│  CarPlayTemplateRenderer.swift      MECHANICAL map: CarPlay* value node ──▶ real CP* template       │
│  CarPlayNowPlayingConfigurator.swift  configures CPNowPlayingTemplate.shared buttons + delegate     │
│  CarPlayActionDispatcher.swift      CarPlayAction ──▶ calls on PlaybackCoordinator / stores         │
│                                                                                                    │
│  (reuses existing: AppServices.shared, LibraryStore, HomeRecommendationStore, CatalogStore,        │
│   OfflineDownloadManager, PlaybackCoordinator, SystemPlaybackBridge/MPRemoteCommandCenter)          │
└────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

**Why this split is the whole game:** every interesting decision — which tabs exist, ordering Continue
first, progress text, the driving cap, empty states, dedup, the download-gate branch, search-result mapping
— lives in `CarPlayMenuBuilder` as a pure function of injected snapshots. That is where the *copious* unit
tests go, and they run on Linux CI with no simulator (`ci-no-simulator`). The app layer only does the
mechanical `node → CPListItem` mapping, covered by the **one** simulator smoke test (§8).

**Now Playing is almost free.** CarPlay's `CPNowPlayingTemplate` is driven entirely by
`MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`, both already populated by `SystemPlaybackBridge`
(title, chapter, artwork, elapsed/duration, play/pause, skip±, next/prev chapter, scrub, rate). We add only
the **custom buttons** (speed, sleep, bookmark, chapters) — §5.

---

## 3. The pure model (`VoxglassCore/CarPlay/CarPlayModels.swift`)

All `public`, `Equatable`, `Sendable`. No `import UIKit`, no `import CarPlay`.

```swift
public struct CarPlayInterface: Equatable, Sendable {
    public var tabs: [CarPlayTab]
}

public enum CarPlayTabID: String, Equatable, Sendable, CaseIterable {
    case continueListening, library, downloaded, discover, search
}

public struct CarPlayTab: Equatable, Sendable, Identifiable {
    public var id: CarPlayTabID
    public var title: String            // "Continue", "Library", …
    public var systemImage: String      // SF Symbol name, resolved to UIImage in the app layer
    public var sections: [CarPlaySection]
}

public struct CarPlaySection: Equatable, Sendable {
    public var header: String?          // nil = no section header
    public var items: [CarPlayItem]
}

public enum CarPlayArtwork: Equatable, Sendable {
    case url(URL)                       // cover; app fetches via ArtworkService (bytes)
    case symbol(String)                 // SF Symbol fallback (e.g. "headphones")
    case none
}

public enum CarPlayAccessory: Equatable, Sendable {
    case none
    case disclosure                     // pushes deeper (book → chapters, genre → list)
    case cloud                          // streamable-but-not-downloaded
    case downloaded                     // offline-available checkmark/badge
    case downloading(Double)            // 0…1 live progress
    case nowPlaying                     // the row that is currently playing
}

public struct CarPlayItem: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String?        // author line
    public var detailText: String?      // "Ch 5 of 24 · 18 min left"
    public var artwork: CarPlayArtwork
    public var progress: Double?        // 0…1 progress bar, nil = none
    public var accessory: CarPlayAccessory
    public var isEnabled: Bool          // false → shown greyed, non-tappable
    public var action: CarPlayAction
}

public enum CarPlayBrowseRoute: Equatable, Sendable {
    case favorites
    case finished
    case inProgress
    case playlist(id: UUID, name: String)
    case author(String)
    case narrator(String)
    case genre(collectionID: String, name: String)   // LibriVox/IA collection
    case allPlaylists
    case browseByAuthor
    case browseByNarrator
}

public enum CarPlayAction: Equatable, Sendable {
    case resumeCurrent                                  // the live/last session
    case playBook(bookID: UUID)                         // resume-aware (resolveResume)
    case openBook(bookID: UUID)                         // push chapter list
    case playChapter(bookID: UUID, chapterID: UUID)
    case openTab(CarPlayTabID)
    case openRoute(CarPlayBrowseRoute)                  // push a nested browse list
    case playCatalogItem(identifier: String)            // import-then-play a Discover/Search result
    case openCatalogItem(identifier: String)            // push detail for a not-yet-imported item
    case download(bookID: UUID)                         // Pro; free → showProUpsell
    case removeDownload(bookID: UUID)
    case beginSearch
    case runSearch(query: String)
    case setSleepTimer(SleepTimer.Mode)
    case addBookmark
    case showChapters
    case setRate(Float)
    case showProUpsell(ProFeature)                      // download-while-free info alert
    case none
}
```

`CarPlaySnapshots.swift` — the DTOs the app fills from live stores so the builder never imports a store:

```swift
public struct CarPlayBookSnapshot: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var authorLine: String
    public var coverURL: URL?
    public var chapterCount: Int
    public var isFavorite: Bool
    public var lastPlayedAt: Date?          // for Continue/recent ordering
    public var progress: CarPlayProgress?   // resume detail, nil = never started
    public var download: CarPlayDownloadState
}

public struct CarPlayProgress: Equatable, Sendable {
    public var chapterIndex: Int            // 0-based
    public var chapterCount: Int
    public var chapterTitle: String
    public var position: TimeInterval       // within the chapter
    public var chapterDuration: TimeInterval?
    public var bookRemaining: TimeInterval? // across chapters, if known
    public var isFinished: Bool
}

public enum CarPlayDownloadState: Equatable, Sendable {
    case notDownloaded          // streamable
    case downloading(Double)    // 0…1
    case downloaded
}

public struct CarPlayCatalogSnapshot: Equatable, Sendable, Identifiable {
    public var id: String                   // IA identifier
    public var title: String
    public var authorLine: String
    public var coverURL: URL?
    public var alreadyInLibrary: UUID?      // bookID if imported, else nil
}
```

---

## 4. The pure builder (`VoxglassCore/CarPlay/CarPlayMenuBuilder.swift`)

Pure `enum` with `static` functions — the repo's established doctrine (cf. `resolveResume`,
`pinCount(states:)`, `nowPlayingInfo`). No I/O.

```swift
public enum CarPlayMenuBuilder {
    /// CarPlay truncates long lists while the car is moving. We cap ourselves so
    /// the tail is never silently dropped by the system mid-book.
    public static let drivingItemCap = 12

    public static func root(_ state: CarPlayState) -> CarPlayInterface
    public static func continueTab(_ state: CarPlayState) -> CarPlayTab
    public static func libraryTab(_ state: CarPlayState) -> CarPlayTab
    public static func downloadedTab(_ state: CarPlayState) -> CarPlayTab
    public static func discoverTab(_ state: CarPlayState) -> CarPlayTab
    public static func searchTab(_ state: CarPlayState) -> CarPlayTab

    // Nested pushes:
    public static func chapterList(book: CarPlayBookSnapshot,
                                   chapters: [CarPlayChapterSnapshot],
                                   nowPlayingChapterID: UUID?) -> [CarPlaySection]
    public static func routeList(_ route: CarPlayBrowseRoute, _ state: CarPlayState) -> [CarPlaySection]
    public static func searchResults(_ results: [CarPlayCatalogSnapshot]) -> [CarPlaySection]

    // Pure helpers (each independently unit-tested):
    public static func progressDetail(_ p: CarPlayProgress) -> String
    public static func bookItem(_ b: CarPlayBookSnapshot, action: CarPlayAction) -> CarPlayItem
    public static func downloadAction(for b: CarPlayBookSnapshot, isDownloadsPro: Bool) -> CarPlayAction
    public static func applyCap(_ items: [CarPlayItem], limit: Int = drivingItemCap) -> [CarPlayItem]
    public static func emptyState(_ tab: CarPlayTabID) -> CarPlaySection
}
```

`CarPlayState` is the single injected snapshot bag (library books, recently-played, favorites, playlists,
downloaded set, recommendations, latest search results, `isDownloadsPro`, `hasCurrentSession`,
`currentBookID`). The controller rebuilds it from live stores and hands it in — pure in, pure out.

### 4.1 Tabs (5 — the CarPlay maximum)

| Tab | `systemImage` | Contents |
|---|---|---|
| **Continue** | `arrow.clockwise.circle.fill` | "Now Playing" row (if a session exists) → resumeCurrent; then in-progress books newest-first (progress bars + resume detail); then "Recently finished". Empty → warm CTA to Discover. |
| **Library** | `books.vertical.fill` | Your imported books (title A–Z or recent). Header rows push routes: Favorites, Playlists, Browse by Author, Browse by Narrator. Book → chapter list. |
| **Downloaded** | `arrow.down.circle.fill` | Only `.downloaded` books — safe with no signal. Empty → "Download books on Wi-Fi to listen offline." |
| **Discover** | `sparkles` | Recommendations (from `HomeRecommendationStore`), then Featured Collections / Genres (from `CatalogStore`/`LibriVoxBrowseCategory`). Item → import-then-play, disclosure → detail. |
| **Search** | `magnifyingglass` | A launcher row that pushes `CPSearchTemplate`. Voice-first (keyboard disabled while moving). Results → import-then-play. |

Playlists & Favorites fold into Library (as routes) rather than spending scarce tab slots — everything stays
reachable within the 5-tab limit.

### 4.2 `progressDetail` rules (unit-tested exhaustively)

| Condition | Output |
|---|---|
| finished | `"Finished"` |
| within 60s of chapter end **and** known duration | `"Finishing Ch N"` |
| known `bookRemaining` | `"Ch N of M · \(formatted bookRemaining) left"` |
| known chapter duration only | `"Ch N of M · \(chapter remaining) left in chapter"` |
| nothing known | `"Ch N of M"` |

Reuse `DesignSystem/TimeFormatting`-style formatting, but the pure builder needs a Core-side formatter —
add `CarPlayTimeFormat.compact(_:)` in Core (`"2h 14m"`, `"18 min"`, `"48s"`) so the builder stays pure and
host-testable. (Do **not** reach into the app-layer `TimeFormatting`.)

### 4.3 The download gate (the one Pro branch)

```swift
static func downloadAction(for b: CarPlayBookSnapshot, isDownloadsPro: Bool) -> CarPlayAction {
    switch b.download {
    case .downloaded:            return .removeDownload(bookID: b.id)
    case .downloading:           return .none                       // row shows live progress, not tappable
    case .notDownloaded:         return isDownloadsPro ? .download(bookID: b.id)
                                                       : .showProUpsell(.offlineDownloads)
    }
}
```

`isDownloadsPro = ProFeature.isEnabled(.offlineDownloads)` is read by the controller and passed in (keeps
the builder pure and lets tests drive both branches). This is the **only** place Pro appears in CarPlay, and
it matches the existing invariant that offline download is Pro everywhere.

### 4.4 Driving cap

CarPlay dynamically truncates lists while moving. Rather than let the system drop the tail silently, we
`applyCap` to 12 and, when truncated, keep the **most relevant head** (in-progress before not-started;
recent before old — the ordering the builder already applies) so what survives is what a driver wants. No
"show more" row (there is no safe deep-scroll while moving; the full list is on the phone).

---

## 5. Now Playing (`CarPlayNowPlayingModel.swift` + `CarPlayNowPlayingConfigurator.swift`)

The screen itself is the system's `CPNowPlayingTemplate.shared`, fed by the existing `MPNowPlayingInfoCenter`
/ `MPRemoteCommandCenter` wiring. Transport (play/pause, skip ±15/30, next/prev chapter, scrub, rate) is
**already done** by `SystemPlaybackBridge`. We add the extras.

### 5.1 Pure config (Core)

```swift
public struct CarPlayNowPlayingConfig: Equatable, Sendable {
    public var showsRateButton: Bool          // always true when a session exists
    public var rateTitle: String              // "1.5×"
    public var sleepActive: Bool              // filled moon when armed
    public var sleepTitle: String             // "Ch. end" / "30 min" / "Sleep" (armed mode, else default)
    public var showsBookmark: Bool            // true iff bookmarkStore + session present
    public var showsChapters: Bool            // true iff chapterCount > 1
    public var isUpNextChapters: Bool         // wire the built-in Up Next button to "Chapters"
}

public enum CarPlayNowPlayingModel {
    public static func config(hasSession: Bool,
                              chapterCount: Int,
                              rate: Float,
                              sleepMode: SleepTimer.Mode,
                              sleepRemaining: TimeInterval?,
                              hasBookmarkStore: Bool) -> CarPlayNowPlayingConfig
}
```

### 5.2 App-layer buttons (`CPNowPlayingButton`)

- **Rate** — `CPNowPlayingPlaybackRateButton`. Cycles `PlaybackRate.systemLadder` via the already-wired
  `changePlaybackRateCommand`. Label from `config.rateTitle`.
- **Sleep** — `CPNowPlayingImageButton(moon)`. In the car this is really a *"stop at a clean break"*
  control, so **"End of chapter" leads** and the duration list is trimmed to the two that survive a driving
  context. Tap → `CPActionSheetTemplate`, in this order: **End of chapter** · 30 min · 60 min · Off.
  (The full 15/30/45/60 ladder stays on the phone; a driver wants fewer glances, and the granular durations
  are the weakest case behind the wheel — "end of chapter" is the one they actually reach for: arriving,
  handing off the car, or a dozing passenger.) Selection → `coordinator.setSleepTimer(_:)`. Glyph filled
  amber when `config.sleepActive`; the button label shows the armed mode (`"Ch. end"` / `"30 min"`, else
  `"Sleep"`).
- **Bookmark** — `CPNowPlayingImageButton(bookmark)`. Tap → `coordinator.addBookmark()`, then a 1.2s
  confirmation (transient title flash or a `CPAlertTemplate` auto-dismissed).
- **Chapters** — wire the **built-in Up Next button** (`isUpNextButtonEnabled`, `upNextTitle = "Chapters"`)
  to push the chapter list (`chapterList(...)`), current chapter marked `.nowPlaying`. Selecting a chapter →
  `coordinator.play(book, chapter:)`.

`updateNowPlayingButtons([rate, sleep, bookmark])`; chapters via Up Next. The configurator is a
`CPNowPlayingTemplateObserver`; it re-reads `CarPlayNowPlayingModel.config(...)` on every coordinator
`objectWillChange` and re-applies buttons.

---

## 6. App-layer wiring

### 6.1 Entitlement + Info.plist + project.yml

**`Voxglass/Resources/Voxglass.entitlements`** — add:
```xml
<key>com.apple.developer.carplay-audio</key>
<true/>
```

**`Voxglass/Resources/Info.plist`** — add a scene manifest declaring the CarPlay scene. Leave the phone
window scene to SwiftUI (do **not** declare a `UIWindowSceneSessionRoleApplication` config — SwiftUI's
`WindowGroup` still owns it):
```xml
<key>UIApplicationSceneManifest</key>
<dict>
    <key>UIApplicationSupportsMultipleScenes</key>
    <true/>
    <key>UISceneConfigurations</key>
    <dict>
        <key>CPTemplateApplicationSceneSessionRoleApplication</key>
        <array>
            <dict>
                <key>UISceneConfigurationName</key>
                <string>CarPlay</string>
                <key>UISceneClassName</key>
                <string>CPTemplateApplicationScene</string>
                <key>UISceneDelegateClassName</key>
                <string>$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate</string>
            </dict>
        </array>
    </dict>
</dict>
```

**`project.yml`** — the entitlement is picked up from the file above; no dependency change is strictly
required (CarPlay is part of UIKit, already linked transitively, but add it explicitly for clarity):
```yaml
        dependencies:
          - package: VoxglassCore
          - sdk: CarPlay.framework      # NEW
          - sdk: AudioToolbox.framework
          - …
```
New source files under `Voxglass/` are auto-picked by XcodeGen. **Run `xcodegen generate` before building**
and commit the `.xcodeproj` drift (CI guards it). Never hand-edit the `.xcodeproj`.

### 6.2 Shared services (required refactor)

The CarPlay scene and the SwiftUI window run in the **same process** but are different scenes. Today
`AppServices` is a `@StateObject` owned by `VoxglassApp` — unreachable from the CarPlay scene. Promote it to
a process singleton so both scenes share one coordinator/library/audio engine:

```swift
@MainActor
final class AppServices: ObservableObject {
    static let shared = AppServices()          // NEW
    // bootstrap must be idempotent + once-only, callable from either scene:
    private var didBootstrap = false
    func bootstrapOnce() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        await bootstrap()
    }
}
```

`VoxglassApp` uses the shared instance and both scenes trigger bootstrap:
```swift
@StateObject private var services = AppServices.shared
// RootView().task { await services.bootstrapOnce() }
```

### 6.3 Cold-launch straight into CarPlay (the subtle one)

If the user gets in the car with the phone locked and the app not running, iOS launches the app **directly
into the CarPlay scene** — `RootView.task` may never fire, so the library would be empty and nothing could
play. Therefore `CarPlaySceneDelegate.templateApplicationScene(_:didConnect:)` must **also** call
`await AppServices.shared.bootstrapOnce()` before building the interface (show a "Loading your library…"
`CPListTemplate` placeholder while it runs). `bootstrapOnce()`'s guard makes the double-trigger safe.
Audio-session activation and `MPRemoteCommandCenter` wiring already happen in `PlaybackCoordinator.init` /
`SystemPlaybackBridge.init`, which run as soon as `AppServices.shared` is first touched — so playback works
with no phone UI ever shown.

### 6.4 Scene delegate + controller

```swift
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var carController: CarPlayInterfaceController?

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        Task { @MainActor in
            await AppServices.shared.bootstrapOnce()
            carController = CarPlayInterfaceController(
                interfaceController: interfaceController,
                services: .shared
            )
            carController?.start()
        }
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        carController?.stop()
        carController = nil
    }
}
```

`CarPlayInterfaceController` (`@MainActor`):
- Holds the `CPInterfaceController` + `AppServices`.
- On `start()`: builds `CarPlayState` from the stores, calls `CarPlayMenuBuilder.root`, renders via
  `CarPlayTemplateRenderer` into a `CPTabBarTemplate`, `setRootTemplate`.
- Subscribes (Combine) to `LibraryStore.$books`, `$recentlyPlayed`, `$progressByBook`,
  `PlaybackCoordinator.$currentSession`, `OfflineDownloadManager` state, `HomeRecommendationStore.$recommendations`.
  On change → rebuild the affected tab's template and update in place (CarPlay supports live
  `updateSections` on a pushed `CPListTemplate`). **Debounce** rebuilds (~0.3s) — progress ticks at 1 Hz and
  must not thrash the head unit.
- Owns a `CarPlayNowPlayingConfigurator` that keeps `CPNowPlayingTemplate.shared` buttons current.
- Routes every `CarPlayItem.action` through `CarPlayActionDispatcher`.

`CarPlayActionDispatcher` (`@MainActor`) — the thin glue (each case a 1–3 line call):
```swift
case .resumeCurrent, .playBook: coordinator.play(book)          // resume-aware; persists
case .openBook:                 push chapterList template
case .playChapter:              coordinator.play(book, chapter:)
case .playCatalogItem:          Task { importThenPlay(identifier) }   // libraryStore.importInternetArchiveItem → coordinator.play
case .download:                 offlineDownloadManager.download(book:)
case .showProUpsell:            present CPAlertTemplate("Downloads are a Voxglass Pro feature. Unlock on your iPhone.")
case .setSleepTimer:            coordinator.setSleepTimer(mode)
case .addBookmark:              coordinator.addBookmark()
case .beginSearch:              push CPSearchTemplate
case .runSearch:                Task { results = try await libriVoxClient.search(query) }
…
```

### 6.5 Renderer (`CarPlayTemplateRenderer.swift`) — mechanical, one smoke test

Pure translation with no decisions:
- `CarPlayInterface` → `CPTabBarTemplate(templates:)` (one `CPListTemplate` per tab; `tabTitle`,
  `tabImage = UIImage(systemName:)`).
- `CarPlaySection` → `CPListSection(items:header:)`.
- `CarPlayItem` → `CPListItem(text:detailText:)` with:
  - `item.artwork` → `setImage(_:)` (cover bytes via `ArtworkService`, else `UIImage(systemName:)`).
  - `item.progress` → `playbackProgress`.
  - `item.accessory` → `.disclosureIndicator` / `.cloud` / custom badge / `isPlaying = true` for `.nowPlaying`.
  - `item.isEnabled == false` → `isEnabled = false`.
  - `item.handler = { dispatcher.dispatch(item.action) }`.
- Cover fetch is async and best-effort; set a symbol immediately (never a blank row), swap in the cover when
  bytes arrive (same "never blank" discipline as `updateArtwork`).

---

## 7. Unit tests — copious, host-run, Linux CI-safe (`VoxglassTests/`)

All in the `VoxglassCoreTests` target (`swift test`, no simulator, per `ci-no-simulator`). Follow the repo's
falsification discipline where a test targets a bug, but most of these are green-from-birth behavior locks.
Style matches `PlaybackResumeTests` (pure inputs, `XCTAssertEqual`, `@MainActor` only where needed).

### `CarPlayMenuBuilderTests.swift`
- `testRootHasFiveTabsInCanonicalOrder` — Continue, Library, Downloaded, Discover, Search.
- `testContinueTabListsInProgressBooksNewestFirst`
- `testContinueTabTopRowIsNowPlayingWhenSessionExists` — action `.resumeCurrent`.
- `testContinueTabEmptyStateWhenNothingPlayed` — warm CTA item, action `.openTab(.discover)`.
- `testContinueTabExcludesFinishedBooksFromInProgress`
- `testLibraryTabBookRowPushesChapterList` — action `.openBook`.
- `testLibraryTabExposesFavoritesRouteOnlyWhenFavoritesExist`
- `testLibraryTabExposesPlaylistsRouteOnlyWhenPlaylistsExist`
- `testDownloadedTabIncludesOnlyDownloadedBooks`
- `testDownloadedTabEmptyStateCopy`
- `testDiscoverTabMapsRecommendationsToPlayCatalogItem`
- `testDiscoverTabDedupsByIdentifier`
- `testDiscoverItemAlreadyInLibraryUsesPlayBookNotImport`
- `testSearchResultsMapToCatalogItems`
- `testChapterListMarksCurrentChapterAsNowPlaying`
- `testChapterListDisabledWhenNoPlayableURL` (isEnabled == false)

### `CarPlayProgressDetailTests.swift` (pure formatting — every row of the §4.2 table)
- finished → `"Finished"`; near-end → `"Finishing Ch 5"`; bookRemaining known; chapter-remaining only;
  nothing-known → `"Ch 5 of 24"`; `CarPlayTimeFormat.compact` cases (`2h 14m`, `18 min`, `48s`, `0s`).

### `CarPlayDownloadGateTests.swift`
- `testNotDownloadedProYieldsDownloadAction`
- `testNotDownloadedFreeYieldsProUpsell` (`.showProUpsell(.offlineDownloads)`)
- `testDownloadedYieldsRemoveAction`
- `testDownloadingYieldsNoneAndProgressAccessory`

### `CarPlayDrivingCapTests.swift`
- `testApplyCapTruncatesToTwelve`
- `testApplyCapKeepsHeadOrdering` (most-relevant survive)
- `testApplyCapNoOpUnderLimit`

### `CarPlayNowPlayingModelTests.swift`
- `testRateTitleReflectsCurrentRate` (`1.5×`)
- `testSleepButtonActiveWhenTimerArmed` + title (`Ch. end`, `30 min`, `Sleep`)
- `testCarPlaySleepOptionsLeadWithEndOfChapterAndTrimDurations` — order is `[.endOfChapter, 30m, 60m, .off]`
- `testChaptersHiddenForSingleChapterBook`
- `testBookmarkHiddenWithoutBookmarkStore`
- `testNoConfigWithoutSession`

### `CarPlayActionModelTests.swift`
- `CarPlayAction` / `CarPlayInterface` `Equatable` round-trips (guards accidental payload drift the renderer
  relies on).

**Coverage intent:** every branch of the builder + now-playing model is asserted with zero UIKit. Target
~40–50 focused assertions across the six files.

---

## 8. The single UI smoke test

CarPlay cannot be driven by XCUITest (no CarPlay harness in `XCUIApplication`). The honest single smoke test
instantiates the **real `CP*` template objects** from a representative model and asserts the wiring — this is
the minimal proof that the app-layer renderer produces a valid CarPlay UI. `CPTabBarTemplate` / `CPListTemplate`
/ `CPListItem` construct fine in a host-app unit test; no connected car needed.

Add a minimal iOS unit-test target `VoxglassCarPlaySmokeTests` (host app = `Voxglass`) in `project.yml` with
**exactly one** test — it is a simulator/local gate, not a CI gate (`ci-no-simulator`; CarPlay is iOS-only so
it can never run on Linux):

```swift
import XCTest
import CarPlay
@testable import Voxglass
@testable import VoxglassCore

final class VoxglassCarPlaySmokeTests: XCTestCase {
    @MainActor
    func testRendererBuildsFiveTabsAndResumeRowFromModel() {
        // A representative pure model: one in-progress book on the Continue tab.
        let state = CarPlayState.fixtureWithOneInProgressBook()
        let interface = CarPlayMenuBuilder.root(state)

        let tabBar = CarPlayTemplateRenderer.render(interface,
                                                    dispatcher: .noop,
                                                    artwork: .noop)

        XCTAssertEqual(tabBar.templates.count, 5)
        let continueList = try XCTUnwrap(tabBar.templates.first as? CPListTemplate)
        XCTAssertEqual(continueList.tabTitle, "Continue")
        let firstItem = try XCTUnwrap(continueList.sections.first?.items.first as? CPListItem)
        XCTAssertEqual(firstItem.text, state.recentlyPlayed.first?.title)
        XCTAssertNotNil(firstItem.handler)   // tapping it reaches the dispatcher
    }
}
```

`project.yml` addition:
```yaml
  VoxglassCarPlaySmokeTests:
    type: bundle.unit-test
    platform: iOS
    sources: [VoxglassCarPlaySmokeTests]
    dependencies:
      - target: Voxglass
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: guru.parso.voxglass.carplaysmoke
        TEST_HOST: "$(BUILT_PRODUCTS_DIR)/Voxglass.app/Voxglass"
        BUNDLE_LOADER: "$(TEST_HOST)"
```
(Add it to the `Voxglass` scheme's `test.targets` alongside `VoxglassUITests`.)

---

## 9. Device acceptance (CarPlay Simulator: Xcode ▸ I/O ▸ External Displays ▸ CarPlay)

1. Connect car with a book in progress → **Continue** tab is default; top row is that book with a progress
   bar and "Ch 5 of 24 · 18 min left"; one tap resumes at exactly 12:30 (not chapter 1).
2. **Cold launch into CarPlay:** kill the app, lock the phone, connect car → library loads, tap Continue →
   plays. Phone UI never shown.
3. Now Playing: play/pause, +30/−15, next/prev chapter, scrub, **speed** cycles, **sleep** arms (moon fills),
   **bookmark** confirms, **Chapters** (Up Next) lists chapters with the current marked, selecting jumps.
4. **Library → book → chapter list → chapter** plays that chapter.
5. **Downloaded** tab shows only offline books; airplane mode → they still play; streaming rows show cloud.
6. **Discover** → tap a recommendation → imports and plays (spinner row while importing, then Now Playing).
7. **Search** → parked, type; moving, dictate → results → tap → imports + plays.
8. **Download (Pro)** a book from Library detail → row shows live % → "Downloaded ✓"; it appears in Downloaded.
9. **Download (free)** → `CPAlertTemplate` "unlock on your iPhone"; audio unaffected.
10. Interruptions: a phone call pauses and resumes (existing interruption handling, unchanged).
11. Sleep timer "End of chapter" stops cleanly at the boundary (existing behavior via the same coordinator).
12. Long list (>12 books) is capped to 12 with the most-relevant head; full list still on phone.

**Definition of done:** all unit tests green in `swift test`; the one smoke test green on simulator;
`scripts/guard_wiring.sh` + `xcodegen generate` drift check green; the 12 device checks pass; RELEASE_PLAN.md
CarPlay section updated; paywall/IAP copy unchanged (CarPlay is free — nothing new to advertise, and the
download upsell reuses the existing offline-downloads Pro bullet).

---

## 10. Ground rules carried over (binding)

- In-car play **only** through `PlaybackCoordinator.play(...)` — never a new playback path. Position
  persistence + resume are non-negotiable (`never-lose-playback-position`).
- All Pro checks flow through `ProFeature.isEnabled(_:)`; the only in-car one is `.offlineDownloads`.
- `import CarPlay` **only** under the app layer (`Voxglass/App/CarPlay/`), never in `VoxglassCore`. The
  builder/model/config compile and test on Linux.
- No new network endpoints beyond `archive.org` / `librivox.org` / `parso.guru` (CI-guarded) — CarPlay reuses
  the existing clients.
- Prefer pure, static, injectable decision functions — the builder is the model citizen of this rule.
- `xcodegen generate` before building; never hand-edit the `.xcodeproj`; no code comments unless non-obvious.

## 11. Suggested sequencing

| Step | Work | Independently shippable? |
|---|---|---|
| 1 | `AppServices.shared` + `bootstrapOnce()` refactor | yes (no behavior change) |
| 2 | Core: `CarPlayModels` + `CarPlaySnapshots` + `CarPlayTimeFormat` + `CarPlayMenuBuilder` + all §7 tests | yes (pure, no app wiring) |
| 3 | Core: `CarPlayNowPlayingModel` + tests | yes |
| 4 | App: entitlement + Info.plist scene + `project.yml` + `CarPlaySceneDelegate` + empty controller (renders Continue only) | needs 1–2; first on-device light-up |
| 5 | App: full `CarPlayTemplateRenderer` + `CarPlayInterfaceController` (all tabs, live updates) + dispatcher | needs 4 |
| 6 | App: `CarPlayNowPlayingConfigurator` (speed/sleep/bookmark/chapters) | needs 5 |
| 7 | App: Discover + Search (import-then-play) + Download gate | needs 5 |
| 8 | The single smoke test; device pass; update RELEASE_PLAN.md | last |
