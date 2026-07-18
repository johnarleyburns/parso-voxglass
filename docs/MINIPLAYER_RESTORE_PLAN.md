# Miniplayer Launch-Restore Plan

**Goal:** after any relaunch (force quit, upgrade, OS kill), the miniplayer shows
*exactly* the book + chapter + position the user was last listening to, the
moment the UI is up. Pressing play resumes from there. No manual navigation.

**Symptom (reported 2026-07-17):** position *is* saved (navigating to the book
resumes correctly), but after a force quit or app upgrade the miniplayer is
sometimes empty or shows the wrong track, so the user has to find the book by
hand and resume.

This document is self-contained: root causes are verified against the code with
file/line references, and the fix is specified per file. Line numbers are as of
commit `c20235c`.

---

## 1. How restore works today (verified)

- The miniplayer renders iff `playback.currentSession != nil`
  (`Voxglass/Features/Player/MiniPlayerView.swift:9`).
- `currentSession` is only set at launch by
  `PlaybackCoordinator.restoreLatestSession(from:)`
  (`Voxglass/Core/Playback/PlaybackCoordinator.swift:107-136`), called once from
  `AppServices.bootstrap()` (`Voxglass/App/AppServices.swift:127`).
- Position durability itself is solid: 1 Hz UserDefaults snapshots
  (`saveCurrentSnapshot`, PlaybackCoordinator.swift:929), 5 s SQLite periodic
  saves (`tickProgress`, :853), sync snapshot on `willResignActive` (:991), and
  `reconcileSnapshots()` (:143) replays snapshots into SQLite at launch. This is
  why the position survives but the *presentation* doesn't.

## 2. Root causes, ranked

### RC1 — Restore is gated behind a long network-bound bootstrap chain

`AppServices.bootstrap()` (AppServices.swift:102-130) awaits, **before**
restoring the session: `StoreManager.refreshEntitlement()` (StoreKit, network),
`libraryStore.refresh()`, three repository backfills, a taste-history rebuild,
`homeRecommendationStore.load(...)` (network fetch), offline-download state
refresh, and `cloudSync.pullPlaybackPositions()`. On a cold post-upgrade launch
(cold caches, backfills doing real work) or with a slow/absent network, the
miniplayer appears seconds late or — if any await stalls — never. This matches
"sometimes" and "when I upgrade".

### RC2 — `currentSession` is only set after a successful `engine.load(...)`

`restoreLatestSession` awaits `engine.load(url:startTime:)`
(PlaybackCoordinator.swift:121) before assigning `currentSession` (:124). For a
streamed chapter, `AVPlayerAudioEngine.load` builds a `CachingResourceLoader`
item and awaits an exact `player.seek`
(`Voxglass/App/AVPlayerAudioEngine.swift:167-182`) — which can stall or behave
badly offline. The UI restore is hostage to the audio engine and the network.
It should not be: the paused miniplayer needs only metadata.

### RC3 — Restore ignores `resolveResume`, so chapter-boundary rows restore the wrong track

`restoreLatestSession` loads `latest.chapterID` at `latest.position` verbatim
(:114-131). Unlike `play(_:)` (:196-207) it never goes through the pure resolver
`resolveResume` (:261-292). If the newest row is `isFinished` (force quit at or
shortly after a chapter end), restore presents the *previous, finished* chapter
at its end instead of the next chapter at 0 — "not on the same track as before".

### RC4 — After a gapless auto-advance, the new chapter has no durable row for several seconds

`handleItemChanged` (:746-779) persists the *previous* chapter as finished, then
updates the session to the next chapter — but writes nothing for the new
chapter: the anti-zero guard (:897) drops periodic/snapshot writes while
position ≤ 0 / engine not ready, and `saveCurrentSnapshot` has the same guard
(:933). A force quit within the first seconds of an auto-advanced chapter leaves
the finished previous chapter as the newest row → RC3 territory.

### RC5 (upgrade-specific, separable) — absolute `local_url` paths break across app updates

`local_url` is persisted as an absolute `file://` URL
(`ModelMapping.databaseValue(_: URL?)`, Voxglass/Core/Database/ModelMapping.swift:11-14;
read back verbatim at :52-54). iOS moves the app data container on update, so
every stored absolute path goes stale. `Chapter.resolvedPlayableURL()`
(Voxglass/Core/Models/BookModels.swift:88-93) falls back to `remoteURL` when the
file is missing — so streamed-then-downloaded books silently lose their offline
copy and re-stream — and for `localFiles`-source books (no `remoteURL`) it
returns a dead URL, so play after upgrade fails. Doesn't hide the miniplayer by
itself, but breaks "press play to resume" after upgrades.

Additional paper cut: when the book/chapter lookup fails, restore sets
`playbackError = "Couldn't restore your last listening session."` (:117) and
gives up entirely instead of degrading (e.g. book start).

## 3. Design

Mirror the approach proven in `../parso-radio-ios-app`
(`SessionRestoreController`): restore is a *presentation* concern first —
rebuild the session from persisted metadata immediately and cheaply; touch the
audio engine lazily, on the first play press.

1. **Engine-free presented session.** New
   `restorePresentedSession(from books:)` sets `currentSession` (paused) from
   the reconciled snapshot/SQLite position **without calling `engine.load`**,
   resolving the target through `resolveResume`. The coordinator tracks
   `isEngineLoaded`; play/seek/skip lazily load the engine at
   `session.position` first.
2. **Bootstrap reorder.** Run snapshot reconcile + presented restore right
   after `libraryStore.refresh()`, before any network-bound step. After the
   cloud position pull completes later, re-resolve and update the presented
   session only if the user hasn't started playback (preserves the "cloud
   position applies this launch" property from AppServices.swift:121-124).
3. **Boundary write.** `handleItemChanged` durably records the new chapter at
   position 0 immediately, bypassing the anti-zero guard (a genuine 0 for a
   fresh chapter start).
4. **Upgrade-proof local paths** (separable phase): rebase stale absolute
   `file://` URLs onto the current container at read time + one-time migration.

## 4. Implementation

### Phase A — engine-free restore + lazy engine load (PlaybackCoordinator.swift)

1. Add state: `private var isEngineLoaded = false`.
   - Set `true` after every successful `engine.load` (in `play(_:chapter:)`,
     `loadChapter`, and the new `ensureEngineLoaded`).
   - Set `false` in `stopPlayback(forDeletedBook:)` and on load failure.

2. Replace `restoreLatestSession(from:)` with:

   ```swift
   public func restorePresentedSession(from books: [BookWithChapters]) async {
       let row = try? await positionStore.latestPosition()
       let latest = Self.preferredPosition(row: row ?? nil, snapshot: snapshotStore.latest())
       guard let latest,
             let book = books.first(where: { $0.book.id == latest.bookID }),
             let target = Self.resolveResume(chapters: book.chapters, saved: latest)
       else { return }   // nothing restorable — no error banner
       applyStoredRate(forBookID: book.book.id)
       updateArtwork(for: book.book)
       currentSession = PlaybackSession(
           book: book.book, chapters: book.chapters, chapter: target.chapter,
           position: target.startTime,
           duration: (latest.chapterID == target.chapter.id ? latest.duration : nil)
               ?? target.chapter.duration,
           isPlaying: false)
       isEngineLoaded = false
       updateNowPlayingInfo()
   }
   ```

   Notes: `resolveResume` already handles finished rows (→ next chapter at 0),
   missing chapter (→ book start), and near-end epsilon — this closes RC3 and
   drops the dead-end error path. Keep the old method name as a thin deprecated
   wrapper only if other callers exist (currently none besides AppServices).

3. Add lazy engine load:

   ```swift
   @discardableResult
   private func ensureEngineLoaded() async -> Bool {
       if isEngineLoaded { return true }
       guard let session = currentSession,
             let url = session.chapter.resolvedPlayableURL() else {
           playbackError = AudioEngineError.missingPlayableURL.localizedDescription
           return false
       }
       do {
           try await engine.load(url: url, startTime: session.position)
           applyStoredRate(forBookID: session.book.id)
           isEngineLoaded = true
           let bwc = BookWithChapters(book: session.book, chapters: session.chapters)
           prefetchNextChapter(from: bwc, currentChapter: session.chapter)
           preloadImmediateNextChapter(in: session)
           return true
       } catch {
           playbackError = error.localizedDescription
           return false
       }
   }
   ```

4. Route all "start playing" entry points through it. `togglePlayPause` (:295)
   and `resume()` (:980) are sync; make the unloaded branch async:

   ```swift
   public func togglePlayPause() {
       guard currentSession != nil else { return }
       if engine.isPlaying { pause(); return }
       Task { @MainActor in
           guard await ensureEngineLoaded() else { return }
           engine.play()
           mutateSession { $0.isPlaying = true }
           startProgressLoop()
           updateNowPlayingInfo()
       }
   }
   ```

   `resume()` gets the same treatment (it serves the remote/lock-screen and
   CarPlay play commands — CarPlay cold-launch must work headless).
   `handleAudioInterruptionEnded` (:1025) can only fire after a load, but guard
   it with `isEngineLoaded` anyway.

5. Seek/skip/pause before the first play (user opens full player and scrubs):
   - `seek(to:)` (:327): when `!isEngineLoaded`, skip `engine.seek`; just mutate
     `session.position` (clamped) and persist. The next `ensureEngineLoaded`
     picks the new offset up automatically since it loads at `session.position`.
   - `persistCurrentPosition` (:889): compute
     `let position = isEngineLoaded ? engine.currentTime : currentSession?.position ?? 0`
     and relax the anti-zero guard for the unloaded case only for `.seek`
     (other reasons can't produce meaningful writes while unloaded, keep
     returning early).
   - `pause()` (:307) and `tickProgress` already no-op safely via the
     `engine.isReady` guards; verify no path calls `startProgressLoop()` while
     unloaded.
   - `skipToNextChapter`/`skipToPreviousChapter`/`jump(to:)` while unloaded:
     acceptable to leave as-is (they call `loadChapter`, which loads the
     engine); just confirm `loadChapter` sets `isEngineLoaded = true`.

6. Now Playing while unloaded: `updateNowPlayingInfo` (:1041) currently passes
   `engine.currentTime` (0 when unloaded). Pass
   `isEngineLoaded ? engine.currentTime : session.position` (and
   `isPlaying: false`) so the lock screen matches the miniplayer.

### Phase B — bootstrap reorder + post-cloud-pull refresh (AppServices.swift)

Reorder `bootstrap()` so restore happens before any network-bound await:

```swift
func bootstrap() async {
    await CacheManager.shared.evictIfNeeded()
    await CacheManager.shared.garbageCollectStalePartials()
    await libraryStore.refresh()
    await playbackCoordinator.reconcileSnapshots()
    await playbackCoordinator.restorePresentedSession(from: libraryStore.books)
    await StoreManager.shared.refreshEntitlement()
    // ... backfills, taste rebuild, reco load, offline refresh (unchanged) ...
    await cloudSync.pullPlaybackPositions()
    await playbackCoordinator.refreshPresentedSessionAfterCloudPull(from: libraryStore.books)
    await cloudSync.sync()
    await folderWatchService.rescanAll()
}
```

New coordinator method:

```swift
/// After the iCloud position pull lands, adopt a newer cloud position into the
/// presented (still-unplayed) session. Local activity always wins: once the
/// engine is loaded or playing, the pull is presentation-irrelevant this launch.
public func refreshPresentedSessionAfterCloudPull(from books: [BookWithChapters]) async {
    guard !isEngineLoaded, currentSession?.isPlaying != true else { return }
    await restorePresentedSession(from: books)
}
```

(If `currentSession` was nil — first launch on a new device with cloud data —
this also makes the miniplayer appear once the pull lands.)

Entitlement note: `restorePresentedSession` touches no Pro-gated feature
(`applyStoredRate` and artwork are free), so running it before
`refreshEntitlement()` is safe. `restoreEQ` already ran in `init`.

### Phase C — durable row at chapter auto-advance (PlaybackCoordinator.swift)

In `handleItemChanged` (:746), after assigning the new-chapter session, write
the new chapter's start durably, bypassing the anti-zero guard:

```swift
private func persistChapterStart(_ session: PlaybackSession) async {
    let start = PlaybackPosition(
        bookID: session.book.id, chapterID: session.chapter.id,
        position: 0, duration: session.duration,
        updatedAt: Date(), isFinished: false)
    snapshotStore.save(start)
    try? await positionStore.save(start)
}
```

Call it from `handleItemChanged` right after `currentSession = ...` (:767) and
from the tail of `loadChapter` if `persistCurrentPosition(reason: .chapterChange)`
(:733) is being dropped by the anti-zero guard there too (verify: at that point
the engine just loaded and `currentTime` may be 0 → the guard drops it → same
gap on manual chapter skips; if so, replace that call with
`persistChapterStart`). Writing 0 over that chapter's older row is correct: the
user just started this chapter fresh, and `resolveResume`'s `startFloor` treats
sub-5 s as 0 anyway. It also refreshes `updatedAt`, which is what makes this
chapter the `latestPosition()` winner. Do **not** emit a taste signal for this
write.

### Phase D (separable PR) — upgrade-proof local file URLs

1. Add a pure helper in Core, e.g. `ContainerPathRebase.swift`:
   `rebase(_ url: URL) -> URL` — for a `file://` URL whose file does not exist,
   split the path on the last well-known sandbox root component
   (`/Documents/`, `/Library/Application Support/`, `/Library/Caches/`) and
   re-anchor the suffix on the current container's matching root
   (`FileManager.default.urls(for:in:)`). Return the original URL if no root
   matches or the rebased file doesn't exist either.
2. Apply it inside `Chapter.resolvedPlayableURL()` (BookModels.swift:88) before
   the `fileExists` check, and in `OfflineDownloadManager.refreshState` /
   wherever `downloads.local_url` is read back (agent: locate the read sites in
   `Voxglass/Core/Library/LibraryRepository.swift:823-840` and the download
   manager; verify where completed downloads are stored on disk first).
3. One-time launch migration (idempotent, in `bootstrap()` after
   `libraryStore.refresh()`): for each `chapters.local_url` / `downloads.local_url`
   whose file is missing but rebases to an existing file, rewrite the stored
   URL. Guard with a UserDefaults version marker like the existing backfills.
4. Going forward, keep writing absolute URLs (rebase-on-read makes them safe),
   or optionally switch writes to container-relative — rebase-on-read is the
   smaller change and covers old rows anyway.

## 5. Tests

Extend the existing suites (`PlaybackResumeTests`, `PositionDurabilityTests`
use an injectable fake engine + in-memory stores — follow their pattern):

1. `restorePresentedSession` sets `currentSession` and **never** calls
   `engine.load` (fake engine records load calls). Miniplayer-visible state:
   correct book, chapter, position, `isPlaying == false`.
2. Finished latest row → presented session is the *next* chapter at 0 (RC3).
3. Missing chapter id (stale row) → presented session falls back per
   `resolveResume`, no `playbackError`.
4. First `togglePlayPause` after restore: engine loads at `session.position`,
   then plays; `isEngineLoaded` flips; second toggle pauses without reload.
5. `engine.load` failure on first play: `playbackError` set, session retained
   (miniplayer must not vanish), retry possible.
6. Seek before first play: `session.position` updates; subsequent load uses the
   new offset; a `.seek` persist lands with that offset while unloaded.
7. `refreshPresentedSessionAfterCloudPull`: updates the session when unloaded;
   no-ops after `ensureEngineLoaded` or while playing.
8. `handleItemChanged` writes a durable row for the new chapter (fake position
   store sees (newChapter, 0, unfinished) as newest) — then
   `restorePresentedSession` lands on the new chapter (RC4 regression test).
9. `nowPlayingInfo` payload uses `session.position` while unloaded.
10. Phase D: rebase helper unit tests with temp directories (missing file under
    old root + existing under new root → rebased; no match → unchanged), and a
    migration idempotency test.

Manual verification (simulator, local-only gate per CI policy): start playback
mid-chapter → force quit → relaunch in airplane mode → miniplayer shows same
chapter/position instantly; disable airplane mode → press play → resumes.
Repeat with a force quit ~2 s after an auto-advance chapter boundary.

## 6. Acceptance criteria

- After force quit during playback, a cold launch shows the miniplayer with the
  same book, chapter, and position (within the 1 Hz snapshot cadence, ≤ ~1 s)
  as soon as the tab UI renders — with **no network** available.
- One tap on the miniplayer's play button resumes audio at that position.
- Force quit at/just after a chapter boundary restores the *new* chapter, never
  the finished previous one.
- A newer iCloud position from another device still updates the not-yet-played
  presented session in the same launch.
- (Phase D) After an app update, previously downloaded chapters play offline
  and `localFiles` imports still play.

## 7. Non-goals / risks

- **Non-goal:** auto-*playing* on launch. Restore is paused; audio starts only
  on user intent (also keeps CarPlay/lock-screen behavior polite).
- **Risk:** entry points that assume a loaded engine. The `isEngineLoaded`
  guards in §Phase A.5 are the checklist; audit any other `engine.` call sites
  in the coordinator (`grep -n "engine\." PlaybackCoordinator.swift`).
- **Risk:** double-restore races (restore vs. user tapping a book during
  bootstrap). `play(_:)` fully replaces the session and loads the engine, so a
  user-initiated play always wins; the cloud refresh explicitly defers to it.
- **Risk (Phase C):** writing 0 over a chapter row — intentional and correct at
  a genuine chapter start; confined to `persistChapterStart` call sites so the
  anti-zero guard stays meaningful everywhere else.
- Hard constraint honored: playback position is never lost or Pro-gated
  (docs/RELEASE_PLAN.md; position durability layers untouched).
