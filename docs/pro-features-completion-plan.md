# Voxglass — Pro Features Completion Plan

## Context & current state

Audit findings: the paywall (`ProPaywallView.swift`) advertises 8 features but only **Cache Presets** works end-to-end. `iCloud Sync` works except its "Sync Now" button is a stub; `EQ` has a complete DSP engine (`EQAudioProcessor`/`BiquadFilter`) but **no UI and is never engaged**; `Offline Downloads` is fully built (`OfflineDownloadManager`) but **not advertised**; `Prefetch Depth`, `Folder Watch`, `Listening Stats`, `CarPlay`, `Apple Watch` are enum-only stubs. Separately, **Now Playing has no favorite control**.

**Ground rules (from `docs/opus-pro-unlock/2026-07-09/03-handoff.md`, still binding):**
- All Pro gating flows through `ProFeature.isEnabled(_:)`. Never gate formats, near-gapless, IA sources, local import, or privacy.
- `import StoreKit` only under `Voxglass/Core/Services/Pro/` and paywall views (CI-guarded in `.github/workflows/ios.yml`).
- No new network endpoints beyond `archive.org`, `librivox.org`, `parso.guru` (CI-guarded).
- XcodeGen-managed: any new file just needs to live under `Voxglass/`; run `xcodegen generate` before building. Deployment target iOS 17.
- No comments in code unless non-obvious.

**Shared UI pattern to standardize (item 8 requirement):** every Pro feature entry point, when `!ProFeature.isEnabled(...)`, must render with a `lock.fill` badge and, on tap, present `ProPaywallView` in a `NavigationStack` sheet. Model on the existing `CacheSettingsCard.presetButton` (`SettingsView.swift:215`) and `SyncSettingsCard` (`SettingsView.swift:549`) locked patterns. We'll extract a reusable `ProLockBadge` view + `.proLocked(_:onTapLocked:)` modifier in `DesignSystem/VoxglassComponents.swift` so all gates behave identically.

---

## 1. iCloud "Sync Now" + entitlements

**Problem:** `SyncSettingsCard` (`SettingsView.swift:537-542`) only sets `lastSync = Date()`; it never calls `cloudSync.sync()`. The card also has no access to the `VoxglassCloudSync` instance (it's constructed in `AppServices` but not injected into the environment).

**Changes:**
- `VoxglassApp.swift:9-24` — add `.environmentObject(services.cloudSync)` to `RootView`.
- `SettingsView.swift` `SyncSettingsCard` — add `@EnvironmentObject private var cloudSync: VoxglassCloudSync`. Replace the stub button body with `Task { await cloudSync.sync() }`; drive `isSyncing`/`lastSync`/error from the store's `@Published isSyncing`, `lastSyncDate`, `syncError` instead of local `@State`. Show `cloudSync.syncError` inline when non-nil, and surface `!cloudSync.isAvailable` ("Sign in to iCloud to sync") distinctly from the not-Pro lock state.
- Apply the standardized locked pattern (see shared pattern above) to the not-Pro branch.
- **Entitlements (the "proper entitlements" ask):** `NSUbiquitousKeyValueStore` is a no-op without the iCloud key-value-store capability. XcodeGen (`project.yml`) does not currently generate an `.entitlements` file. Add one:
  - New `Voxglass/Resources/Voxglass.entitlements` with `com.apple.developer.ubiquity-kvstore-identifier` = `$(TeamIdentifierPrefix)$(CFBundleIdentifier)`.
  - `project.yml` → `targets.Voxglass.settings.base`: `CODE_SIGN_ENTITLEMENTS: Voxglass/Resources/Voxglass.entitlements`.
  - Keep the README "iCloud Sync setup" note; update it to state the entitlement is now committed (manual capability toggling no longer required for KVS).

**Tests:** `VoxglassTests/CloudSyncEntitlementTests.swift` (new) — assert the entitlements file exists and contains the ubiquity-kvstore key (read via `Bundle`/file check, mirroring `HomeViewTests.testInfoPlistDeclaresBackgroundAudioMode`). Add a `VoxglassCloudSync` test with an in-memory `AppDatabase` asserting `sync()` early-returns when not entitled and performs push/pull round-trip when entitled (inject entitlement via `EntitlementCache` test seam — see §Testing infra).

---

## 2. EQ UI

**Problem:** engine works but `engageEQ()`/`applyEQPreset()`/`setEQGain()` on `AVPlayerAudioEngine` are never called; no UI; no user-preset persistence.

**Plumbing:**
- `PlaybackCoordinator` — add pass-throughs so views don't touch the engine directly: `var isEQEngaged`, `func setEQEngaged(_:)`, `func applyEQPreset(_:)`, `func setEQGain(_:at:)`, exposing the existing `AVPlayerAudioEngine` methods (guard the `as? AVPlayerAudioEngine` cast). Persist engaged-state + current gains via a new `EQSettingsStore` (UserDefaults, JSON) so EQ survives relaunch and is re-applied in `load(...)` (the engine already re-attaches on item change when `isEngaged`).
- **User presets (advertised "your own"):** `EQPreset` is already `Codable`. Add `EQPresetStore` (UserDefaults JSON array) with `save/delete/all`; combine with `EQPreset.builtInPresets`.

**View:** new `Voxglass/Features/Player/EQView.swift` — a sheet with a horizontal preset picker (built-ins + saved), 10 vertical band sliders (`EQEngine.isoBands` labels: 31…16k), a master engage toggle, and "Save as preset" (name prompt). All gated: if `!ProFeature.isEnabled(.eq)` the view is a locked teaser that presents the paywall.

**Entry points:**
- `NowPlayingView.swift:202-232` `actionBar` — replace the disabled `speedometer` placeholder (or add a `slider.horizontal.3` button) that opens the EQ sheet; show a `lock.fill` overlay when not Pro and route to paywall on tap.
- `SettingsView.swift` — add an "Audio" section with an "Equalizer" `DisclosureListRow` (locked badge when not Pro).

**Tests:** extend `VoxglassTests` with `EQPresetStoreTests` (save/load/delete round-trip, built-ins always present) and `EQSettingsStoreTests` (engaged-state + gains persistence). Add gating asserts: `applyPreset`/`setGain` are no-ops when not entitled (already guarded in `EQAudioProcessor`; add a test that locks the entitlement and asserts `currentGains` unchanged).

---

## 3. Prefetch Depth

**Current:** `PlaybackCoordinator.prefetchNextChapter` (line 216) + `AVPlayerAudioEngine.prefetchIntoCache` warm exactly the **next** chapter (hard cap `prefetchItems.count < 2`), always, ungated. Per decision **D7**, depth-1 stays free (it powers near-gapless); Pro sells depth-N / whole-queue over Wi-Fi.

**Changes:**
- Add `AppPreferencesStore.Keys.prefetchDepth` (Int, default 1) and `prefetchWifiOnly` (Bool, default true).
- `AVPlayerAudioEngine` — generalize `prefetchIntoCache` to accept a list/allow a configurable cap (raise the `< 2` guard to the requested depth); add `prefetchIntoCache(urls: [URL])`.
- `PlaybackCoordinator.prefetchNextChapter` → `prefetchUpcomingChapters`: compute depth = `ProFeature.isEnabled(.prefetchDepth) ? storedDepth : 1`. If `prefetchWifiOnly` and `NetworkMonitor.shared.isCellular`, clamp to 1 (never break near-gapless). Enqueue the next `depth` cacheable chapters.
- **Settings UI:** "Playback" section → a stepper/segmented control (1 / 3 / whole book) + a "Prefetch only on Wi-Fi" toggle. Locked (badge + paywall) when not Pro; when locked, show fixed "Next chapter (1)".

**Tests:** `PrefetchDepthTests` — pure helper `PlaybackCoordinator.resolvedPrefetchDepth(isPro:stored:isCellular:wifiOnly:)` (extract as a `static` pure function, mirroring `OfflineDownloadManager.startDecision`) asserting: not-Pro → 1; Pro+Wi-Fi → stored; Pro+cellular+wifiOnly → 1; Pro+cellular+!wifiOnly → stored.

---

## 4. Folder Watch (full import + watch)

**Current:** Voxglass has **no local-file import path** at all (`SourceKind.localFiles` exists but is unused). This is the largest item.

**Model/services:**
- Reuse `SourceKind.localFiles`. A watched folder → one `Source`; each audio file → a `Chapter` with `localURL`; one `Book` per folder (title = folder name).
- New `Voxglass/Core/Services/Import/FolderWatchService.swift` (`@MainActor ObservableObject`):
  - Store security-scoped bookmarks (UserDefaults, `[Data]`) for user-picked folders; resolve with `startAccessingSecurityScopedResource` on launch.
  - `scan(folder:)` enumerates playable audio (reuse `AudioFormatSelection.allPlayableExtensions`), diffs against existing chapters, and inserts new books/chapters via a new `LibraryRepository.importLocalFolder(...)`.
  - Live watch via `NSFilePresenter` (`presentedSubitemDidChange`) + a foreground rescan on `willEnterForeground`.
  - **Gate:** all entry points check `ProFeature.isEnabled(.folderWatch)`; picking/scanning is a no-op → paywall when not Pro.
- `LibraryRepository.importLocalFolder(name:sourceID:files:)` — insert `localFiles` source + book + chapters (durations via `AVURLAsset.load(.duration)`).
- Register `FolderWatchService` in `AppServices` + inject via `.environmentObject`; kick a rescan in `bootstrap()`.

**UI:** `SettingsView.swift` new "Local Files" section — "Watch a Folder" row opening `.fileImporter` (folder). Show watched folders with a remove action. Locked badge + paywall when not Pro. New file `Voxglass/Features/Settings/FolderWatchView.swift` for managing watched folders.

**Info.plist:** no new key needed for `.fileImporter` folder access (security-scoped). Confirm no `UIFileSharingEnabled` needed.

**Tests:** `FolderWatchServiceTests` — pure diff helper `newAudioFiles(in:knownURLs:)` (filter by extension, exclude known); `LibraryRepositoryTests` extension — `importLocalFolder` inserts a `localFiles` source + book + chapters and is idempotent on rescan (no dupes). Gating test: import is skipped when entitlement is off.

---

## 5. Listening Stats (new event logging)

**Data model (new migration id 4 in `DatabaseMigrations.swift`):**
```sql
CREATE TABLE listening_events (
  id TEXT PRIMARY KEY,
  book_id TEXT REFERENCES books(id) ON DELETE SET NULL,
  seconds REAL NOT NULL,
  occurred_at REAL NOT NULL
);
CREATE INDEX listening_events_occurred_at ON listening_events(occurred_at DESC);
```
(`ON DELETE SET NULL` keeps lifetime totals correct after a book is removed; genre/author breakdowns join `book_taste` while the book exists.)

**Logging:** in `PlaybackCoordinator.tickProgress` (the 1s loop, line 339), accumulate wall-clock listened seconds while `engine.isPlaying`; flush a `listening_events` row every ~30s and on pause/background/chapter-change via a new `ListeningStatsStore.record(bookID:seconds:)`. This is **always logged** (privacy-safe, on-device only) — the *viewing* of stats is Pro-gated, matching how competitors work and keeping data continuity if a user upgrades later. (Note this in decisions doc; it's local-only, no telemetry.)

**Store:** `Voxglass/Core/Services/Stats/ListeningStatsStore.swift` — `record(...)`, plus aggregates: `totalTime()`, `dailyTotals(days:)`, `currentStreak()`, `topAuthors(limit:)` / `topSubjects(limit:)` (join `book_taste`). Pure aggregation helpers (streak calc from a `[Date: TimeInterval]`) extracted as `static` for testing.

**View:** `Voxglass/Features/Stats/ListeningStatsView.swift` — total time, current/longest streak, a simple 7/30-day bar chart (Swift Charts is available on iOS 17; if avoiding it, hand-draw bars like the cache usage bar in `SettingsView`), top authors/genres. Locked teaser + paywall when `!ProFeature.isEnabled(.listeningStats)`.

**Entry point:** `SettingsView.swift` "Listening Stats" row (locked badge when not Pro); optionally a Home ("Listen" tab) card later — Settings is sufficient for this pass.

**Tests:** `ListeningStatsStoreTests` — `record` inserts rows; `totalTime` sums; `currentStreak` pure helper over synthetic day buckets (0, 1, consecutive, gap cases); `topAuthors` joins taste terms. Migration test: `DatabaseMigrationsTests`-style assert that a fresh DB has `listening_events`.

---

## 6. Add Offline Play to advertised features

**Problem:** `.offlineDownloads` is fully implemented but absent from the paywall list.

**Changes:**
- `ProPaywallView.swift:8-25` — add an entry: `("arrow.down.circle.fill", "Offline Downloads", "Download whole books for gap-free listening with no connection — pinned so they're never evicted.")`. Order it near the top (high value).
- `README.md` Highlights already says "Stream or download"; keep. Ensure paywall "Stays free forever" copy still excludes offline (offline is Pro) — current copy is fine.

**Tests:** `ProPaywallContentTests` (new) — assert the paywall feature list contains one row per advertised Pro feature and that the set of advertised features **exactly matches** the intended Pro set (see §7 registry) so future drift is caught. This is the "audit as a test" safety net.

---

## 7. Remove CarPlay & Apple Watch from Pro; document as roadmap

**Changes:**
- `ProFeature.swift` — remove `case carplay` and `case appleWatch`. Remaining: `cachePresets, prefetchDepth, folderWatch, eq, icloudSync, listeningStats, offlineDownloads`.
- `ProPaywallView.swift` — remove the `car.fill` CarPlay and `applewatch` rows (already no implementation).
- `FreeTierRegistryTests.swift:70-90` — update `testAllProFeaturesDeclared` and `testProFeaturesAreGatedWhenNotEntitled` to the new set (drop carplay/appleWatch, add offlineDownloads/listeningStats). Add an assertion that `.carplay`/`.appleWatch` no longer exist (compile-time removal is enough, but keep the positive-set assertion authoritative).
- `README.md` Roadmap — CarPlay & Apple Watch already appear in the roadmap (items 4 & the CarPlay note). Tighten to an explicit **"Planned (not yet available)"** subsection listing **CarPlay** and **Apple Watch app** so it's unambiguous they're future, not shipped. Remove the stale "CarPlay is already planned separately and omitted" phrasing.
- `docs/opus-pro-unlock/2026-07-09/decisions.md` — add a deviation note (D5 listed carplay as a gate); record that CarPlay/Watch are deferred to roadmap and removed from `ProFeature`.

---

## 8. Test strategy — Pro unlocked vs. Free locked (with lock icons)

**Testing infra (prerequisite):** `EntitlementCache` is a singleton reading `UserDefaults.standard`. Add a **test seam**: a `#if DEBUG` `EntitlementCache.setTestEntitlement(_ Bool?)` (or an override property) so tests can flip Pro on/off deterministically without StoreKit. All gating routes through `ProFeature.isEnabled`, so this one seam controls every feature.

**Per-feature test matrix (unit + logic):** for each of the 7 Pro features, add tests asserting:
1. **Pro ON → feature functions:** cache preset switch persists; `cloudSync.sync()` runs; EQ preset applies gains; prefetch depth resolves to stored value; folder import inserts books; stats view has data; offline `startDecision(isPro:true,...) == .start`.
2. **Pro OFF → feature is inert AND surfaces a lock:** each gate returns the no-op/`.needsPro` path (`CacheManager.setPreset` ignores Pro presets; `VoxglassCloudSync.sync` early-returns; `EQAudioProcessor` no-ops; prefetch depth clamps to 1; folder scan skipped; `OfflineDownloadManager.startDecision == .needsPro`).

**Lock-icon UI tests (the key item-8 requirement — "each feature shown with a lock so tapping opens Pro tier"):**
- Extend `VoxglassUITests/VoxglassUITests.swift`. Add a launch argument `-VoxglassForceFreeTier` (read in `#if DEBUG` in `EntitlementCache.init`) to force the free tier deterministically in UI tests.
- UI test `testFreeTierShowsLocksAndOpensPaywall`: launch with free-tier + `-VoxglassInitialTab more`; for each gated control (Cache 2GB/10GB presets, iCloud "Unlock", Equalizer row, Prefetch Depth, Folder Watch, Listening Stats), assert a lock affordance exists (via `accessibilityIdentifier` we add, e.g. `pro.lock.eq`) and that tapping it presents the paywall (assert `ProPaywallView`'s "Voxglass Pro" title / "Unlock Pro" button appears).
- To make this robust, give every locked entry point a stable `accessibilityIdentifier` and route all of them through the shared `.proLocked` modifier so the paywall presentation is uniform.
- UI test `testProTierUnlocksControls`: launch with `-VoxglassForcePro`; assert the same controls are interactive and **no** lock identifiers are present.

**Registry drift test:** `ProPaywallContentTests` (from §6) ties the advertised list, the `ProFeature` enum, and the free-tier registry together so an added/removed feature must update all three.

**Run:**
```
xcodegen generate
xcodebuild -scheme Voxglass -destination 'platform=iOS Simulator,name=iPhone 16' build
xcodebuild -scheme Voxglass -destination 'platform=iOS Simulator,name=iPhone 16' test
```
Plus CI guards (StoreKit import boundary, network endpoints) must stay green.

---

## 9. Favorite a book from Now Playing

**Problem:** No favorite affordance in `NowPlayingView`. The `actionBar` (`NowPlayingView.swift:202-232`) has a `bookmark` placeholder (disabled) but nothing for favorites. `NowPlayingView` only has `@EnvironmentObject playback`; it can't favorite without `LibraryStore`, and `session.book.isFavorite` is a stale snapshot captured at play time. Favoriting elsewhere goes through `libraryStore.setFavorite(_:for:)` (`BookDetailView.swift:180`), which updates `LibraryStore.books` but **not** the live `PlaybackSession.book`.

**Changes:**
- `RootView.swift:63-67` — the `NowPlayingView` sheet re-injects only `playback`. Also inject `.environmentObject(libraryStore)` (RootView already holds `@EnvironmentObject libraryStore`) so the sheet reliably has it.
- `NowPlayingView.swift`:
  - Add `@EnvironmentObject private var libraryStore: LibraryStore`.
  - Add a computed `isFavorite` derived from the store (live source of truth), falling back to the session snapshot: `libraryStore.book(withID: session.book.id)?.book.isFavorite ?? session.book.isFavorite`. Updates reactively because `LibraryStore` is `ObservableObject` and `setFavorite` mutates `books`.
  - In `actionBar`, replace the disabled `bookmark` placeholder (or add a leading heart button) with a favorite toggle: `heart.fill`/`heart`, brass tint when favorited, calling `Task { await libraryStore.setFavorite(!isFavorite, for: session.book.id) }`. Add `.accessibilityLabel(isFavorite ? "Unfavorite" : "Favorite")` and `.accessibilityIdentifier("nowplaying.favorite")`.

**Not gated:** favorites are a free-tier feature; no lock here.

**Optional (not required):** mirror the same heart on `MiniPlayerView` — deferred unless requested.

**Tests:**
- `VoxglassTests` — favorite-state derivation test: given a `LibraryStore` seeded with a book, toggling favorite flips `book(withID:)?.book.isFavorite`; assert the Now-Playing derivation prefers the store value over a stale session snapshot.
- `VoxglassUITests` — open Now Playing, tap `nowplaying.favorite`, assert its selected state toggles.

---

## Agentic coding handoff (execution order)

Execute phases in order; each ends green before the next. Regenerate the project (`xcodegen generate`) whenever files are added. Paths verified against the repo. Read the ground rules above and `docs/opus-pro-unlock/2026-07-09/03-handoff.md` before touching the playback path.

- **Phase 0 — Infra:** `EntitlementCache` test/UI seams (`setTestEntitlement`, `-VoxglassForcePro`/`-VoxglassForceFreeTier` read in `#if DEBUG` init); extract `ProLockBadge` + `.proLocked(_:id:onTapLocked:)` in `VoxglassComponents.swift`. AC: helper unit test; existing suite green.
- **Phase 1 — Item 7 (removals):** delete `.carplay`/`.appleWatch`, prune paywall, update `FreeTierRegistryTests`, README roadmap, decisions.md. AC: builds; registry tests updated.
- **Phase 2 — Item 6 (offline advertised) + Item 1 (iCloud):** paywall offline row; entitlements file + `project.yml`; inject `cloudSync`; wire "Sync Now". AC: `ProPaywallContentTests`, `CloudSyncEntitlementTests`, sync round-trip test.
- **Phase 2b — Item 9 (Now Playing favorite):** inject `libraryStore` into the Now Playing sheet; add derived `isFavorite` + heart toggle in `actionBar`. Small, standalone; depends only on Phase 0 env wiring, independent of Pro gating. AC: derivation unit test + UI toggle test.
- **Phase 3 — Item 2 (EQ UI):** coordinator pass-throughs, `EQSettingsStore`, `EQPresetStore`, `EQView`, Now Playing + Settings entries with locks. AC: preset/settings store tests + gating tests + UI lock test for EQ.
- **Phase 4 — Item 3 (Prefetch Depth):** prefs keys, engine depth generalization, `resolvedPrefetchDepth` pure fn, Settings control. AC: `PrefetchDepthTests`.
- **Phase 5 — Item 5 (Listening Stats):** migration 4, `ListeningStatsStore`, logging in `tickProgress`, `ListeningStatsView`, Settings entry. AC: store + streak + migration tests.
- **Phase 6 — Item 4 (Folder Watch):** `FolderWatchService`, `importLocalFolder`, `FolderWatchView`, Settings entry, `AppServices` wiring. AC: diff-helper + repository idempotency tests.
- **Phase 7 — Item 8 (full test matrix):** per-feature Pro-ON/OFF unit tests + the two UI lock/unlock tests + registry drift test. AC: all green in CI incl. guards.

**Definition of done:** every AC green; `FreeTierRegistryTests` + `ProPaywallContentTests` passing; CI import/network guards green; Now Playing favorite toggles and persists; `decisions.md` updated with any deviations (incl. the always-on listening-event logging note); README roadmap reflects CarPlay/Watch as planned-not-shipped.

## Key risks

- **Listening events are logged for all users** (Pro gate is on *viewing*). On-device only, privacy-safe; document in `decisions.md`.
- **iCloud entitlement** requires a real signing team for on-device KVS; simulator/StoreKit tests use the `EntitlementCache` seam and file-presence check, not live iCloud.
- **Folder Watch** is greenfield (no existing local-import path); keep the DSP/playback path untouched — it only adds `localURL` chapters that flow through the existing `resolvedPlayableURL()`.
