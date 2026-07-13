# Voxglass — Competitive Analysis & Gap Closure Plan

> **Deliverables:** (1) commit this document to the repo as `docs/COMPETITIVE_GAP_PLAN.md`, (2) update `README.md` to replace the informal backlog with the ranked roadmap below **and list CarPlay as a future option**, (3) execute P0→P2 with a test-first architecture where **almost everything is a unit test** and only four things need a device.
>
> **CarPlay is explicitly out of scope for this plan.** The `com.apple.developer.carplay-audio` entitlement request is pending with Apple; nothing can be built or even run in the CarPlay simulator until it is granted. It is recorded in the README as a planned future option and will be planned separately when the entitlement lands. Note that P0 below is its exact prerequisite anyway — `CPNowPlayingTemplate` is driven entirely by `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`, so shipping speed, artwork, and the remote commands now is what makes CarPlay a small job later.

---

## Context

Voxglass is a privacy-first iOS 17 SwiftUI audiobook player for the public-domain LibriVox catalog (sourced entirely via archive.org), with a one-time $9.99 StoreKit 2 "Pro" unlock and zero third-party dependencies. It ships a genuinely strong catalog story: 21 subject categories plus curated collections, an on-device recommendation engine, 15-language filtering, FLAC/Opus/Vorbis/MP3 selection with a network-aware derivative policy, a custom range-caching resource loader, a 10-band EQ, folder watch, private iCloud sync, and listening stats — no ads, no accounts, no telemetry.

But it is missing three of the most basic things an audiobook listener expects.

### Competitive landscape (App Store, July 2026)

| App | Developer | Price | Rating | Speed | Sleep timer | Bookmarks | CarPlay | Offline |
|---|---|---|---|---|---|---|---|---|
| **LibriVox Audiobooks** | BookDesign LLC | Free + ads; $1.99/mo, $9.99/yr, **$24.99 lifetime** ad-free | **4.8★ / 32K** | ✅ | ✅ | ✅ | ✅ | ✅ free |
| **LibriVox Audiobooks – Ad-Free** | BookDesign LLC | **$4.99 one-time**, no IAP | too few | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Audiobooks – Librivox Library** | Le Thanh Quang | Free + ads; $1.99 remove-ads | 4.3★ / 2.2K | ❌ | ❌ | ❌ | ❌ | ✅ |
| **Librivox – All Audiobooks** | Webron Software | Free + ads; to $49.99 lifetime | too few | ❌ | ❌ | ❌ | ❌ | ✅ |
| **Librivox – Library audio books** | N. Morozova | Free + ads; $4.99/wk–$29.99/yr | too few | ❌ | ✅ | ❌ | ❌ | ✅ |
| **Voxglass (today)** | — | **$9.99 one-time** | — | ❌ | ❌ | ❌ | ❌ | Pro-gated |
| *Audible (ref)* | Amazon | $159.99/yr | 0.5–3.5x | ✅ | ✅ + clips/notes | ✅ | ✅ + Watch | ✅ |
| *Spotify (ref)* | Spotify | 15 audiobook hrs/mo in Premium | ✅ | ✅ | ✅ | ✅ | ✅ |

**Only BookDesign matters.** It owns the category (32K ratings at 4.8★) and is the only competitor that is a competent *player*. The three long-tail LibriVox apps are ad-riddled catalog browsers with worse players than Voxglass already has. Audible and Spotify confirm the table stakes: variable speed (Audible reaches 3.5x), sleep timer, bookmarks, CarPlay.

**The wedge is real.** BookDesign's recent reviews are dominated by self-inflicted wounds: a UI redesign users can't navigate ("I now have a hard time finding the previous book"), speed control regressed to an unlabeled slider capped at 2x when it used to hit 3x, narrator names removed from chapters, a slow waveform progress bar, and ads with volume spikes that wake people mid-chapter. There is clear demand for *the same catalog in a player that respects you*. That is precisely Voxglass's thesis — it just cannot claim it while lacking speed control.

### The gap, stated plainly

Voxglass charges **$9.99** and cannot change playback speed, cannot set a sleep timer, cannot set a bookmark, and shows no lock-screen artwork. BookDesign does all of that for **$4.99** — or free, with ads. Today Voxglass asks *more money for less product*, and the paywall headlines "Offline Downloads," which a shopper reads as *"the app doesn't work offline unless you pay."*

Worse: the shipped paywall and Settings copy already advertise **bookmark syncing**, which does not exist (`Features/Settings/ProPaywallView.swift:51`, `SettingsView.swift:555`). That is false advertising in the store today, and P0-3 is what fixes it.

The blockers are half-built already — the scaffolding is there and inert:
- Sleep timer button exists and is `.disabled(true)` (`Features/Player/NowPlayingView.swift:237`).
- `bookmarks` table + `Bookmark` model exist; nothing reads or writes them (`Core/Database/DatabaseMigrations.swift:108`).
- `playlists`/`playlist_books` tables exist; the "Playlist" button is `isEnabled: false` (`Features/Library/BookDetailView.swift:185`).
- `LibraryBookFilter` + `books(filteredBy:)` exist with no UI (`Core/Library/LibraryStore.swift:45`).

**Outcome:** reach parity with BookDesign on the player table stakes we can ship today, ship it all free, then refit the paywall so $9.99 leads with what BookDesign cannot match (EQ, volume normalization, folder watch, private sync, stats, FLAC, no ads ever). CarPlay closes the last remaining gap once Apple grants the entitlement.

**Decisions taken:** keep $9.99, refit the paywall (do not reprice). Scope P0 → P2, **excluding CarPlay (pending Apple), widgets/Siri/App Intents, and localization**.

---

## Step 0 — the testability precondition (do this first; everything depends on it)

**The problem.** `PlaybackCoordinator` accepts an injectable `AudioEngine` protocol (`Core/Playback/AudioEngine.swift:4`) — but then **downcasts to the concrete `AVPlayerAudioEngine` in 13 places**: `Core/Playback/PlaybackCoordinator.swift:45, 120, 183, 193, 238, 247, 253, 259, 271, 306, 352, 392`. Every downcast silently no-ops against a fake engine. That is why there is no `PlaybackCoordinatorTests` in the suite today, and it is exactly the surface P0/P1 lives on (preload, cancel-preload, EQ, prefetch, item-changed). **Without fixing this, none of the new work can be unit tested.**

**The fix — absorb all 13 downcasts into the protocol:**

```swift
@MainActor
protocol AudioEngine: AnyObject {
    var currentTime: TimeInterval { get }
    var duration: TimeInterval? { get }
    var isPlaying: Bool { get }
    var rate: Float { get }                    // P0-1
    var volume: Float { get set }              // P0-2 fade-out
    var isEQEngaged: Bool { get }
    var onPlaybackEnded: (@MainActor () -> Void)? { get set }
    var onItemChanged: (@MainActor () -> Void)? { get set }   // was concrete-only (:45)

    func configureAudioSession()
    func load(url: URL, startTime: TimeInterval) async throws
    func play()
    func pause()
    func seek(to position: TimeInterval) async
    func setRate(_ rate: Float)                // P0-1
    func preloadNext(url: URL)                 // was concrete-only (:121, :194, :353, :397)
    func cancelPreload()                       // was concrete-only (:184) — sleep timer depends on this
    func prefetchIntoCache(urls: [URL])        // was concrete-only (:328)
    func setEQEngaged(_ engaged: Bool)
    func applyEQPreset(_ preset: EQPreset)
    func setEQGain(_ gain: Float, at band: Int)
    func setEQGains(_ gains: [Float])
}
```

Then delete every `as? AVPlayerAudioEngine` from the coordinator. This is a mechanical, behavior-preserving refactor — its own commit, existing suite green, before any feature work.

**New test double** — `VoxglassTests/Fixtures/FakeAudioEngine.swift`: conforms to `AudioEngine`, records an ordered `[Call]` log (`.load(url, startTime)`, `.play`, `.pause`, `.seek(t)`, `.setRate(r)`, `.preloadNext(url)`, `.cancelPreload`, …), exposes settable `currentTime`/`duration`/`isPlaying`, and lets tests fire `onPlaybackEnded()` / `onItemChanged()` synchronously. This single file is what makes the coordinator — where speed, sleep timer, bookmarks, artwork, and skip intervals all live — fully unit-testable with no AVFoundation and no simulator.

**Also extract a pure now-playing builder.** `updateNowPlayingInfo()` (`PlaybackCoordinator.swift:665-683`) is untestable and hardcodes `MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0` (`:676`) — which will make the lock-screen scrubber drift the moment speed ships. Extract:

```swift
static func nowPlayingInfo(session: PlaybackSession, currentTime: TimeInterval,
                           duration: TimeInterval?, rate: Float, isPlaying: Bool,
                           artwork: MPMediaItemArtwork?) -> [String: Any]
```

Rate fields, artwork, and chapter metadata all land here and become assertable as a plain dictionary.

**Testability rule for the rest of this plan:** every feature splits into a *pure decision* (a function or small type with injected clock/stores — no AVFoundation, no UIKit, no network) and a *thin effectful shell*. Tests target the decision. This is what keeps the device-test list down to four items.

---

## Two real bugs found while reading (fix in Step 0 — same code paths)

1. **EQ silently dies on every gapless auto-advance.** `AVPlayerAudioEngine.preloadNext` calls `eqProcessor.attach(to: item)` (`Core/Playback/AVPlayerAudioEngine.swift:162`), but `EQAudioProcessor.attach` early-returns on `guard !isActive else { return }` (`Core/Services/Playback/EQ/EQAudioProcessor.swift:28`). The current item already set `isActive = true`, so the preloaded item never receives an `audioMix` — when AVQueuePlayer advances, EQ is off until the next manual `load()`. One processor owns one tap, so it structurally cannot serve two items. Fix: tap-per-item, keyed by `ObjectIdentifier(AVPlayerItem)`.
   *Unit test:* extract the "which items have taps" bookkeeping into a plain `EQTapRegistry` (a dictionary wrapper) and assert attach-current + attach-preloaded yields two live entries, and that item-changed evicts the old one. No AVFoundation needed.
2. **`EQAudioProcessor.attach` reads `playerItem.asset.tracks` synchronously** (`EQAudioProcessor.swift:80`). For a remote `AVURLAsset` this is often empty before load, so `audioTrack` is `nil` and the tap attaches to nothing. Use async track loading.
   *This one is genuinely hard to unit test* — it is an AVFoundation timing bug. Cover it in the device smoke test (D-1 below) rather than faking it.

---

## P0 — credibility blockers (all FREE; **zero** new `ProFeature` cases)

### P0-1 Variable playback speed (0.5x–3.5x, per-book memory)

**Files:** `Core/Playback/AudioEngine.swift` (protocol, per Step 0) · `Core/Playback/AVPlayerAudioEngine.swift` (`makePlayerItem` :21, `prefetchIntoCache` :41, `preloadNext` :152) · `Core/Playback/PlaybackCoordinator.swift` (`play()` :88, `restoreLatestSession()` :58, `configureRemoteCommands()` :595, `updateNowPlayingInfo()` :665) · **new** `Core/Services/Playback/PlaybackRateStore.swift` (mirror `EQSettingsStore.swift:5`) · `Features/Player/NowPlayingView.swift:223-250` (speed `Menu` in `actionBar`).

**Use `player.defaultRate`, not manual `player.rate` assignment:**

```swift
func setRate(_ rate: Float) {
    self.rate = rate
    player.defaultRate = rate                    // iOS 16+; we target 17
    if player.timeControlStatus == .playing { player.rate = rate }
}
```

`AVPlayer.play()` resumes at `defaultRate`, so **every existing resume path inherits the rate for free** — remote play (`:598`), interruption-ended resume (`:586`), `loadChapter` (`:335`), `togglePlayPause` (`:137`). The `timeControlStatus` guard matters: assigning `player.rate` to a *paused* player would start playback.

**Pitfalls:**
- **Set `audioTimePitchAlgorithm = .spectral` unconditionally on every `AVPlayerItem`** at construction (`:21`, `:52`, `:155`). `.timeDomain` covers only 0.5–2.0x; `.spectral` covers 1/32–32x. The algorithm cannot be meaningfully changed on a playing item, so do not switch by rate — otherwise 1.5x → 2.5x mid-chapter glitches, and the gapless preloaded item (built earlier at a different rate) carries the wrong algorithm across the auto-advance.
- **Gapless carry-over works** because `defaultRate` is player-level, not item-level — but only if the next item's algorithm matches, hence the above.
- **EQ interaction is benign but costs CPU.** The tap uses `kMTAudioProcessingTapCreationFlag_PreEffects` (`EQAudioProcessor.swift:72`), so it sees source-rate samples *before* the time-pitch unit; biquad coefficients stay valid at any rate. But at 3.5x the tap is pulled ~3.5x more samples/sec and `EQEngine.process` is scalar per-sample (`:59-63`). Spectral pitch + 10-band scalar EQ at 3.5x is the worst case — this is why D-1 (device perf) exists.
- **Do not scale listening stats by rate.** `accumulateListening()` (`PlaybackCoordinator.swift:458`) records wall-clock seconds, which is the correct semantic. Leave it; add a comment so nobody "fixes" it.

**Remote command** (after `:652`) — register `changePlaybackRateCommand` with `supportedPlaybackRates = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]`. Only these appear in the system UI; the full 0.5–3.5 range stays in-app. This is also exactly what CarPlay's rate button will consume for free when that lands.

**Per-book memory** — apply the stored rate in `play(_:chapter:)` after `engine.load(...)` and before `engine.play()` (`:99`), in `restoreLatestSession` after load (`:73`), and re-assert after each `loadChapter` (`:334`; idempotent, cheap).

**Unit tests** (`PlaybackRateTests`, `PlaybackCoordinatorRateTests`):
- `PlaybackRate.clamp` bounds and the allowed-rate ladder — pure.
- `PlaybackRateStore` per-book isolation + default fallback — pure, `UserDefaults(suiteName:)`.
- Against `FakeAudioEngine`: playing book A at 1.5x then opening book B yields `setRate(1.0)`; reopening A yields `setRate(1.5)`. Asserted on the call log.
- `loadChapter` re-asserts the rate: fire `onItemChanged()` on the fake, assert a `setRate` follows.
- `nowPlayingInfo(...)` sets **both** rate keys, and `MPNowPlayingInfoPropertyPlaybackRate == 0.0` when paused.
- `FreeTierRegistryTests.testSpeedControlIsFree` under `EntitlementCache.shared.setTestEntitlement(false)`.

### P0-2 Sleep timer

**Files:** **new** `Core/Playback/SleepTimer.swift` · `PlaybackCoordinator.swift` (`advanceAfterChapterEnd()` :400, `handleItemChanged()` :360) · `Features/Player/NowPlayingView.swift:237-241` (**replace the dead disabled button** with a Menu: 5/10/15/30/45/60 min · End of chapter · Off; show remaining when armed) · `Features/Settings/SettingsView.swift:28` (default duration in the existing `settingsGroup("Playback")`).

`SleepTimer` is a `@MainActor ObservableObject` with `enum Mode { case off, duration(TimeInterval), endOfChapter }`, an **injected `now: () -> Date` clock**, and an `onFire` closure. The injected clock is the whole reason this is unit-testable — no `Task.sleep` in tests, ever.

**The one hard interaction — end-of-chapter vs gapless preload.** By the time `advanceAfterChapterEnd()` runs, AVQueuePlayer has *already* advanced to the preloaded item and is playing the next chapter. So end-of-chapter must be armed **at selection time**:
- On selecting `.endOfChapter` → immediately `engine.cancelPreload()` (now protocol-visible per Step 0) so the queue physically cannot advance.
- In `advanceAfterChapterEnd()`, if mode is `.endOfChapter`: pause, persist as finished, clear the timer, and **return without loading the next chapter** (skip the fallback `loadChapter` at `:428`).
- If the user cancels `.endOfChapter`, re-arm via `preloadChapterAfter` (`:391`).

**Other notes:** the countdown is **wall-clock deadline-based** (`Date`), never tick-counted, or pause/background/rate changes skew it. Drive it from its own 0.5s `Task`, not the playback `progressTask` (different lifetime — that one survives pause and is only cancelled in `stopPlayback`, `:228`). Background firing already works (`UIBackgroundModes: [audio]` in `Resources/Info.plist`). Fade out by ramping `engine.volume` to 0 over ~5s, then pause, then **restore volume to 1.0** or the next play is silent.

**Shake-to-extend: optional, last, cut it if the sprint tightens.** SwiftUI has no shake hook; it needs a `UIViewControllerRepresentable` overriding `motionEnded(_:with:)` mounted invisibly in `RootView` (`App/RootView.swift:35`), behind a default-off toggle. Nothing depends on it.

**Unit tests** (`SleepTimerTests`, `PlaybackCoordinatorSleepTests`) — all pure, zero sleeps:
- Arm 30 min → `remaining` computed from the injected clock; advance the fake clock → `remaining` decrements; cross the deadline → `onFire` called **exactly once** (assert idempotence on repeated ticks).
- Pause/resume does not skew the deadline; changing rate does not skew it.
- **The critical one:** selecting `.endOfChapter` emits `cancelPreload` on the `FakeAudioEngine` call log; then firing `onPlaybackEnded()` yields `pause` and **no** subsequent `load(...)` — i.e. it did not roll into the next chapter. Cancelling `.endOfChapter` re-emits `preloadNext`.
- Fade-out ramps `volume` down and **restores it to 1.0** after pause (a call-log assertion — this is the bug that would otherwise ship silent playback).
- `FreeTierRegistryTests.testSleepTimerIsFree`.

### P0-3 Bookmarks — makes the shipped paywall copy true

**Migration** — add id 5 to `DatabaseMigration.all` (`Core/Database/DatabaseMigrations.swift:184`). The existing `bookmarks` table (`:107`) lacks what LWW sync needs:

```sql
ALTER TABLE bookmarks ADD COLUMN updated_at REAL NOT NULL DEFAULT 0;
ALTER TABLE bookmarks ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0;
UPDATE bookmarks SET updated_at = created_at;
CREATE INDEX bookmarks_book_created ON bookmarks(book_id, created_at DESC);
```

**The `is_deleted` tombstone is mandatory, not optional.** `VoxglassCloudSync` is last-writer-wins on `updated_at` (`Core/Services/Sync/VoxglassCloudSync.swift:69, 108, 144`). Positions never delete, so the existing code never had to solve this — but a hard `DELETE` on device A would be resurrected by device B's next push. Soft-delete + tombstone push is the fix.

**Model** — `Core/Models/PlaybackModels.swift:31`: add `updatedAt: Date` and `isDeleted: Bool` with a memberwise init providing defaults (it currently relies on the synthesized init).

**Store** — **new** `Core/Playback/BookmarkStore.swift`, mirroring `SQLitePositionStore` (`Core/Playback/PositionStore.swift:9-81`) exactly — **protocol + SQLite impl**, so tests can inject an in-memory fake into the coordinator: `add`, `bookmarks(forBookID:)` (`WHERE is_deleted = 0`), `allBookmarks()`, `delete(id:)` → soft-delete + bump `updated_at`, `updateNote(_:id:)`.

**Wiring** — construct in `App/AppServices.swift:17` (already holds `database`), inject into `PlaybackCoordinator`. Coordinator gets `addBookmark(note:)` (captures current book/chapter/`engine.currentTime`) and `jump(to:)` (same chapter → `seek(to:)` at `:160`; different chapter → reuse `loadChapter(_:in:startTime:shouldPlay:)` at `:331`).

**UI** — bookmark button in the Now Playing `actionBar` (`NowPlayingView.swift:223`; tap = add + haptic, long-press = list) · **new** `Features/Player/BookmarksView.swift` (list, tap-to-jump, swipe-to-delete, edit note) · a "Bookmarks (n)" row in `BookDetailView.swift:288` alongside `chapterPreview`.

**iCloud sync — rides the *existing* `.icloudSync` Pro gate.** `Key.bookmarksPrefix` is already declared and unused (`VoxglassCloudSync.swift:16`). Add `pushBookmarks()`/`pullBookmarks()` following `pushPlaybackPositions` (`:57`)/`pullPlaybackPositions` (`:124`), called from `sync()` (`:196`) and `handleExternalChange` (`:206`).
- **Pack per book, not per bookmark:** key `voxglass.cloudsync.bm.<bookID>` → a JSON array of that book's bookmarks *including tombstones*, versioned on `MAX(updated_at)`. NSUbiquitousKeyValueStore caps at 1 MB / 1024 keys and positions already burn up to 200; per-bookmark keys would blow the budget on a heavy user.
- Payload must carry `is_deleted`, and pull must apply tombstones (UPSERT with `is_deleted = excluded.is_deleted`).

**Gating: bookmark CRUD is FREE; bookmark *sync* uses the existing `.icloudSync` gate.** This makes the already-shipped copy true **with zero changes to `ProFeature`, `ProPaywallView.advertised`, or `ProPaywallContentTests`.**

**Unit tests** (`BookmarkStoreTests`, `BookmarkSyncTests`, `PlaybackCoordinatorBookmarkTests`):
- Store CRUD against `AppDatabase.makeTemporaryDatabase` (the seam `PositionStoreTests` already uses) — on-disk temp SQLite, still a fast unit test.
- Migration 5 is idempotent and back-fills `updated_at = created_at` on a pre-existing row.
- `delete` soft-deletes: the row survives with `is_deleted = 1` and a bumped `updated_at`; `bookmarks(forBookID:)` excludes it.
- **The tombstone test — the one most likely to be wrong.** Do it as a *pure merge-function test*: extract `BookmarkSync.merge(local:remote:) -> [Bookmark]` and assert a remote payload containing a live bookmark does **not** resurrect a locally-tombstoned one with a newer `updated_at`, and vice versa. This tests the actual LWW logic with no iCloud at all. (D-3 then only smoke-tests the transport.)
- KVS payload for a book with 50 bookmarks stays under the 1 MB per-key cap — pure encoding assertion.
- Coordinator: `addBookmark` captures `engine.currentTime` from the fake; `jump(to:)` on the same chapter emits `seek`, on a different chapter emits `load(startTime:)` — call-log assertions.
- Extend `CloudSyncEntitlementTests` for push/pull gating (the `testForceAvailable` seam is at `VoxglassCloudSync.swift:52`); add `FreeTierRegistryTests.testBookmarksAreFree`.

### P0-4 Lock-screen artwork

**File:** `PlaybackCoordinator.swift:665` plus the Step-0 builder. `MediaPlayer` and `UIKit` are already imported; no `project.yml` change.

`updateNowPlayingInfo()` runs on **every 1s tick** (`:455`) — do **not** build an `MPMediaItemArtwork` per tick. Cache one `MPMediaItemArtwork?` on the coordinator keyed by book id, populated once per session load by awaiting `ArtworkService.shared.image(for:)` (`ArtworkService.swift:60`), then re-emit the info dict. Ship a static bundled fallback for books with no cover, or where `validatedImage` rejected an IA placeholder (`ArtworkService.swift:116-166`) — do not render the procedural `BookArtworkView` per tick.

**Unit tests:** `nowPlayingInfo(... artwork:)` sets `MPMediaItemPropertyArtwork` when non-nil and omits the key when nil (pure dictionary assertion). Artwork is fetched **once per book**, not per tick — assert against a counting fake artwork provider after 10 simulated ticks. Fallback is used when the cover URL is nil.

---

## P1 — parity with BookDesign (all FREE)

### P1-1 Customizable skip intervals

Add `skipForwardInterval`/`skipBackInterval` to `App/AppPreferencesStore.swift:4`. `configureRemoteCommands` (`:622-638`) hardcodes `preferredIntervals = [30]`/`[15]` and `skip(by: 30)`/`skip(by: -15)` — read the stored values *inside* the closures (so no re-registration is needed) and add `reconfigureSkipIntervals()` that only updates `preferredIntervals` on change. `NowPlayingView.swift:175-206` hardcodes the `gobackward.15`/`goforward.30` SF Symbols, so **constrain the picker to symbol-backed values** (back `[10,15,30,45,60]`, forward `[15,30,45,60,90]`) with a pure `skipSymbol(direction:seconds:)` mapper.

**Unit tests:** `skipSymbol` maps every allowed value to a symbol that exists (assert `UIImage(systemName:) != nil` for each — catches a typo'd symbol at test time, not on the device). Against the fake: setting forward=45 then invoking skip-forward emits `seek(currentTime + 45)`, and clamps at `duration`.

### P1-2 Library sort / filter / finished states

`LibraryBookFilter` and `fetchBooks(filteredBy:)` already exist (`Core/Library/LibraryRepository.swift:3, 46`) and are surfaced by `LibraryStore.books(filteredBy:)` (`:45`) — but that is an async DB round-trip per filter change, wrong for a SwiftUI picker. **Keep the repository method** (already covered by `LibraryRepositoryTests`) but **drive the UI in-memory**: add `@Published var filter`/`@Published var sort` to `LibraryStore` plus a computed `visibleBooks` over the already-loaded `books` (`:5`). `.downloaded` needs no DB — `LibraryView` already reads `offlineManager.state(for:)` (`Features/Library/LibraryView.swift:68`).

**Finished/in-progress needs new data.** Add `LibraryRepository.fetchBookProgress() -> [UUID: BookProgress]` aggregating `playback_positions` (finished = every chapter row has `is_finished = 1`), plus `@Published private(set) var progressByBook` refreshed in `LibraryStore.refresh()` (`:27`). Extend `LibraryBookFilter` with `.finished`/`.inProgress` — the `switch` at `LibraryRepository.swift:49` is exhaustive and must gain the cases. Add `enum LibrarySort { case recent, title, author, duration, progress }` as a **pure comparator**.

**Unit tests:** `LibrarySort` comparator over a fixture array — stable, and `recent` matches today's `ORDER BY updated_at DESC`. `visibleBooks` for every `(filter, sort)` pair over an in-memory fixture — pure, no DB. `fetchBookProgress` finished/in-progress/unstarted classification against `makeTemporaryDatabase`. Extend `LibraryRepositoryTests` for the new filter cases.

### P1-3 Playlists — ship as shelves only

Tables exist (`DatabaseMigrations.swift:117`), model exists (`PlaybackModels.swift:40`). Add **new** `Core/Library/PlaylistRepository.swift` (do *not* grow `LibraryRepository` — already 590 lines) and **new** `Core/Library/PlaylistStore.swift` (mirrors `LibraryStore`), registered in `AppServices` and the `environmentObject` chain (`VoxglassApp.swift:12`). Enable the dead button at `BookDetailView.swift:185` → playlist-picker sheet. New `Features/Library/PlaylistsView.swift` + `PlaylistDetailView`, entered from the "Library" group in Settings (`SettingsView.swift:40`).

**Architectural landmine — do not attempt cross-book continuous playback in v1.** `PlaybackSession` is book-scoped (`Core/Playback/PlaybackSession.swift:3`: `book: Book`, `chapters: [Chapter]`) and `advanceAfterChapterEnd`/`handleItemChanged`/`preloadNext` all index within `session.chapters`. Auto-advancing across books requires a queue abstraction *above* `PlaybackSession` — a much larger change. Ship playlists as shelves (tap a book → normal per-book playback); file cross-book queueing separately. Keep playlists **local-only** in v1: the `playlists` table has no tombstone column, so syncing needs the same soft-delete treatment as bookmarks.

**Unit tests:** `PlaylistRepositoryTests` against `makeTemporaryDatabase` — create/rename/delete, add/remove book, and **reorder `sort_index` stays dense and gap-free** after an arbitrary move (the classic off-by-one here); deleting a book cascades out of `playlist_books`.

---

## P2 — differentiation (scoped: **no CarPlay, no widgets/Siri, no localization**)

### P2-1 Volume normalization
A running gain + limiter inside `EQEngine` (`Core/Services/Playback/EQ/`). Genuinely valuable for LibriVox specifically, where volunteer recordings vary wildly in level — and BookDesign does not have it.
**Unit tests:** `EQEngine.process` is already a pure buffer transform. Feed a synthetic quiet buffer and a synthetic loud buffer; assert output RMS converges toward the target within N buffers, the limiter never emits a sample outside [-1, 1], and a pure-silence buffer does not wind the gain up to infinity (the classic AGC bug).

### P2-2 Skip silence — via rate boost, not an engine rewrite
An `MTAudioProcessingTap` **cannot drop frames** (it must return the requested count), so true silence-skipping is not implementable in the current tap. Two options:
- **(a) Recommended:** detect low-RMS windows in the tap and have the coordinator temporarily raise `player.rate`. Cheap, rides directly on P0-1's rate plumbing.
- (b) Rewrite to `AVAudioEngine` + `AVAudioPlayerNode` — throws away AVQueuePlayer gapless *and* the `CachingResourceLoader` integration (`AVPlayerAudioEngine.swift:21`). Not worth it.

**Unit tests:** extract a pure `SilenceDetector` (RMS window → `.silent`/`.speech` with hysteresis). Feed synthetic buffers; assert it does not flap on a single quiet sample, requires N consecutive windows to enter silence, and exits immediately on speech. Then against the fake engine: entering `.silent` emits `setRate(boosted)` and returning to `.speech` emits `setRate(userRate)` — never leaving the user stranded at boosted rate.

### P2-3 Dynamic Type
Every `Font.system(size:)` (e.g. `NowPlayingView.swift:99`, `ProPaywallView.swift:96`) → `.system(size: X, relativeTo: .body)` or semantic styles. Mechanical, wide, low risk — and an accessibility table stake the whole category ignores.
**Unit test:** a guard test that greps the SwiftUI sources and fails on any bare `Font.system(size:)` without `relativeTo:` — the same style of source-level guard CI already uses for `import StoreKit`. That makes the sweep self-enforcing instead of a one-time cleanup that rots.

*Deferred by decision:* **CarPlay** (entitlement pending with Apple — README only), widgets/App Intents/Siri (needs an app-group entitlement plus relocating the SQLite DB out of Application Support, `Core/Database/AppDatabase.swift:19`, since a widget cannot read it today), and localization.

---

## Paywall refit — keep $9.99, change what it says

Current Pro set (`Core/Services/Pro/ProFeature.swift:3-10`, advertised at `ProPaywallView.swift:21-57`): offline downloads, cache presets, prefetch depth, folder watch, EQ, iCloud sync, listening stats.

**The framing is the problem, not the price.** Offline listening *is* already free — `FreeTierRegistryTests.swift:96-106` asserts a local chapter plays without entitlement, and the streaming cache is free. What is actually gated is *bulk pre-download + pinning*. Nobody reading the paywall can tell, so "Offline Downloads" reads as "the app doesn't work offline unless you pay."

1. **Ship every P0/P1/P2 item free — add zero new `ProFeature` cases.** `ProPaywallContentTests` and `FreeTierRegistryTests.testAllProFeaturesDeclared` (`:70-78`) then need no edits, which is itself the signal that the gating is right.
2. **Soften the offline hard-wall to a taste limit:** free tier may pin 1–2 books offline; Pro = unlimited + whole-book prefetch + cache presets. One line: `OfflineDownloadManager.swift:72` (`guard isPro else { return .needsPro }`). *Unit test:* free tier pinning book 3 returns `.needsPro`; books 1–2 return `.allowed`; un-pinning one frees a slot.
3. **Stop leading the paywall with Offline Downloads.** `ProPaywallContentTests.testOfflineDownloadsIsAdvertisedNearTheTop` (`:22-27`) *pins* it to index ≤ 1 — that test encodes the uncompetitive decision and must be revisited as part of this change.
4. **Lead with what BookDesign cannot match:** 10-band EQ, volume normalization, folder watch, private iCloud sync (now truthfully including bookmarks), listening stats, FLAC, no ads ever.
5. Bookmarks-CRUD-free / bookmarks-sync-Pro is the single place a P0 feature touches the paywall — and it *fixes* false advertising rather than adding a gate.

---

## Testing strategy — almost everything is a unit test

**The four irreducible device tests.** Everything else in this plan is a unit test, and that is a direct consequence of Step 0 (protocol widening + `FakeAudioEngine`) and of splitting each feature into a pure decision plus a thin shell.

| # | Test | Why it cannot be a unit test |
|---|---|---|
| **D-1** | **Device audio smoke:** 2.5x mid-chapter with EQ on, across a gapless auto-advance | Audio *quality* (spectral pitch artifacts) and CPU headroom under 10-band scalar EQ at 3.5x are physical properties. Also the only real cover for the async-track-loading bug (`EQAudioProcessor.swift:80`). |
| **D-2** | **Lock screen / Control Center** shows artwork, and the scrubber tracks correctly at 2.5x | `MPNowPlayingInfoCenter` is a write-only system side effect. Mitigated: the dictionary itself is fully unit-tested via `nowPlayingInfo(...)`, so this verifies only that iOS renders it. |
| **D-3** | **Two-device iCloud bookmark sync**, including a delete | `NSUbiquitousKeyValueStore` needs real iCloud and two devices. Mitigated: the LWW/tombstone *logic* is unit-tested as a pure `BookmarkSync.merge`, so this smoke-tests the transport only. |
| **D-4** | **Sleep timer fires with the app backgrounded and the phone locked** | Background execution + audio-session behavior. Mitigated: all timer arithmetic and the end-of-chapter preload-cancel are unit-tested with an injected clock. |

Note the pattern: for three of the four, the *logic* is unit-tested and the device test is reduced to a thin smoke check. That is the design goal — a device test should never be the only thing standing between a bug and production. Only D-1 is irreducibly physical.

**New unit-test files:** `Fixtures/FakeAudioEngine.swift`, `PlaybackRateTests`, `PlaybackCoordinatorRateTests`, `SleepTimerTests`, `PlaybackCoordinatorSleepTests`, `BookmarkStoreTests`, `BookmarkSyncTests`, `PlaybackCoordinatorBookmarkTests`, `NowPlayingInfoTests`, `EQTapRegistryTests`, `SkipIntervalTests`, `LibrarySortTests`, `PlaylistRepositoryTests`, `SilenceDetectorTests`, `VolumeNormalizationTests`, `DynamicTypeGuardTests`.

**Extended:** `CloudSyncEntitlementTests` (bookmark gating + tombstones), `LibraryRepositoryTests` (new filters), `FreeTierRegistryTests` (+3 free-tier assertions), `OfflineDownloadManagerTests` (taste limit).

**`ProPaywallContentTests` should need no changes until the paywall refit.** If it breaks earlier, a Pro gate was added that should not have been — treat that as a build failure, not a test to update.

**Run:** `xcodebuild test -scheme Voxglass -destination 'platform=iOS Simulator,name=iPhone 16'`. CI (`.github/workflows/ios.yml`) additionally guards that `import StoreKit` appears only under `Core/Services/Pro/` + the paywall, and that network hosts stay limited to archive.org / librivox.org / parso.guru. Nothing here should trip either — if it does, something is in the wrong layer.

---

## Sequencing

| Phase | Work | Blocks on |
|---|---|---|
| **0a** | **Widen `AudioEngine`, delete all 13 downcasts, add `FakeAudioEngine`** (behavior-preserving; suite green) | — |
| **0b** | Pure `nowPlayingInfo` builder + fix the two EQ bugs | 0a |
| **1a** | **Speed** (`defaultRate` + `.spectral` on all items + remote command + `PlaybackRateStore` + UI) | 0b |
| **1b** | **Lock-screen artwork** | 0b |
| **1c** | **Sleep timer** (incl. `cancelPreload` on end-of-chapter) | 1a |
| **1d** | **Bookmarks** (migration 5 → `BookmarkStore` → coordinator → UI → cloud sync w/ tombstones) | 0a (parallelizable with 1a–1c) |
| **2a** | Skip intervals | 1a |
| **2b** | Library sort/filter/finished | — |
| **2c** | Playlists (shelves only) | 2b |
| **3a** | Volume normalization; skip-silence via rate boost | 1a |
| **3b** | Dynamic Type sweep + guard test | — |
| **4** | Paywall refit + `ProPaywallContentTests` update | Phases 1–3 |
| **5** | Docs: `docs/COMPETITIVE_GAP_PLAN.md` + README roadmap | — (do up front) |

*(CarPlay is not in this table. When Apple grants the entitlement it becomes a separate, small phase — P0 is its prerequisite and will already be done.)*

---

## Documentation deliverables

**1. `docs/COMPETITIVE_GAP_PLAN.md`** — commit this document to the repo, verbatim, as the durable rationale. It is the "why" behind every ticket below it, and the competitive table is the thing that will go stale first (re-check BookDesign's pricing and feature set each release).

**2. `README.md` update.** The README currently carries an informal, unranked self-authored backlog at lines 53–89 (comparing against Audible, Libby, Prologue, BookPlayer, Pocket Casts) plus a trailing "table stakes to confirm" list. **Replace that whole section** with:
- A short **Competitive position** paragraph: the BookDesign comparison, the wedge (their reviews), and an honest statement of what Voxglass does not yet have.
- A **Roadmap** section with the P0/P1/P2 tiers as checkboxes, linking to `docs/COMPETITIVE_GAP_PLAN.md`.
- A **Future / not yet planned** section containing **CarPlay** — stated plainly: *planned, blocked on Apple's `com.apple.developer.carplay-audio` entitlement grant; the P0 work (speed, lock-screen artwork, remote commands) is its prerequisite and lands first, so CarPlay becomes a small job once the entitlement arrives.* Apple Watch, widgets/Siri, and localization also live here.
- Correct the stale **"iCloud Sync setup"** section, which still documents the Debug-only entitlement state — the entitlement now ships in all configs (commits `87563b7`, `e8e37e1`).
- Correct the claim of a light/dark/system theme setting: the app is hard-coded `.preferredColorScheme(.dark)` (`App/VoxglassApp.swift:20`). Either drop the claim or file it.

---

## Agentic coding handoff

Each phase is a self-contained unit of work: one branch, one PR, green suite. Written so an agent (or a person) can pick up any single row without holding the rest in their head.

**Ground rules for every task**
- **`project.yml` is the source of truth**, not the `.xcodeproj` — that file is a generated artifact. Any new file, target, SDK, entitlement, or Info.plist key goes in `project.yml`; regenerate with XcodeGen.
- **Do not add a `ProFeature` case.** Everything in P0–P2 ships free. If you believe a gate is needed, stop and raise it — `ProPaywallContentTests` failing is a signal you got it wrong, not a test to update.
- **Do not build CarPlay.** The entitlement is pending with Apple. It cannot even run in the CarPlay simulator until granted. README mention only.
- **No third-party dependencies.** The app has zero and that is deliberate.
- **CI guards two invariants:** `import StoreKit` only under `Core/Services/Pro/` + the paywall, and network hosts limited to archive.org / librivox.org / parso.guru. Do not work around them.
- **Test-first.** Every task below names its unit tests. If a thing cannot be unit-tested, that is a design smell — extract the pure decision (see Step 0) rather than reaching for a UI test.
- Prefix commits with the task id (e.g. `P0-1:`).

| Task | Branch | Touches | Definition of done |
|---|---|---|---|
| **0a** Widen `AudioEngine`; delete 13 downcasts; add `FakeAudioEngine` | `refactor/audio-engine-protocol` | `Core/Playback/AudioEngine.swift`, `AVPlayerAudioEngine.swift`, `PlaybackCoordinator.swift`, **new** `VoxglassTests/Fixtures/FakeAudioEngine.swift` | Zero `as? AVPlayerAudioEngine` remain in the coordinator. Existing suite green, **no behavior change**. `FakeAudioEngine` records an ordered call log. |
| **0b** Pure `nowPlayingInfo`; fix EQ preload + async-tracks bugs | `fix/eq-gapless-and-nowplaying` | `PlaybackCoordinator.swift:665`, `EQAudioProcessor.swift:28,80`, **new** `EQTapRegistry` | `NowPlayingInfoTests` + `EQTapRegistryTests` green. Two live taps across a preload. |
| **P0-1** Playback speed | `feat/playback-speed` | see P0-1 | 0.5–3.5x; rate survives gapless advance; per-book memory; both MP rate keys set; `changePlaybackRateCommand` registered. Free-tier test green. |
| **P0-2** Sleep timer | `feat/sleep-timer` | see P0-2 | Dead button at `NowPlayingView.swift:237` replaced. End-of-chapter cancels preload and does **not** roll into the next chapter. Volume restored to 1.0 after fade. |
| **P0-3** Bookmarks | `feat/bookmarks` | see P0-3 | Migration 5 applied; CRUD + jump; iCloud sync with tombstones behind the **existing** `.icloudSync` gate. **The paywall's bookmark-sync claim is now true.** |
| **P0-4** Lock-screen artwork | `feat/nowplaying-artwork` | `PlaybackCoordinator.swift` | Artwork set once per book, not per tick; bundled fallback for missing/placeholder covers. |
| **P1-1** Skip intervals | `feat/skip-intervals` | see P1-1 | Picker constrained to symbol-backed values; `skipSymbol` test asserts every symbol resolves. |
| **P1-2** Library sort/filter/finished | `feat/library-filters` | see P1-2 | In-memory filtering (no DB round-trip per picker change); `.finished`/`.inProgress` added to the exhaustive switch at `LibraryRepository.swift:49`. |
| **P1-3** Playlists (shelves) | `feat/playlists` | see P1-3 | Dead button at `BookDetailView.swift:185` enabled. **No cross-book queueing** — that needs a queue above `PlaybackSession` and is a separate epic. `sort_index` stays dense after reorder. |
| **P2-1** Volume normalization | `feat/volume-normalization` | `EQEngine` | Limiter never clips; silence does not wind the gain to infinity. |
| **P2-2** Skip silence | `feat/skip-silence` | `SilenceDetector` + coordinator | Rate-boost approach only. Never strands the user at boosted rate. |
| **P2-3** Dynamic Type | `chore/dynamic-type` | all SwiftUI views | Guard test fails on any bare `Font.system(size:)` without `relativeTo:`. |
| **P4** Paywall refit | `feat/paywall-refit` | `ProPaywallView.swift`, `OfflineDownloadManager.swift:72`, `ProPaywallContentTests.swift` | Offline becomes a taste limit (2 free pins); paywall leads with EQ/normalization/folder-watch/sync/stats/FLAC; `testOfflineDownloadsIsAdvertisedNearTheTop` revisited. |
| **P5** Docs | `docs/competitive-roadmap` | **new** `docs/COMPETITIVE_GAP_PLAN.md`, `README.md` | README backlog (lines 53–89) replaced with the ranked roadmap; **CarPlay listed under future options with the entitlement blocker stated**; stale iCloud-entitlement and light-theme claims corrected. |

**Suggested execution order:** P5 (docs, cheap, sets context) → 0a → 0b → P0-1 → P0-4 → P0-2 → P0-3 → P1-1 → P1-2 → P2-* → P1-3 → P4.
