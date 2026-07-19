# Voxglass — Release Plan

## Context

Voxglass is a privacy-first iOS player for the public-domain LibriVox catalog, competing against one app
that owns the category: **LibriVox Audiobooks** (BookDesign LLC, 4.8★/32K ratings). Voxglass's opening is
that BookDesign's users hate what it became — an unnavigable redesign, speed control regressed to an
unlabeled slider, narrator names deleted from chapters, ads with volume spikes. Voxglass is "the same
catalog in a player that respects you."

**All features are free.** The app previously had a one-time Pro unlock ($7.99) for offline
downloads, iCloud sync, folder watch, EQ, listening stats, and library backup. That has been
removed — every feature is now available to everyone at no cost. Future monetization will come
from audiobook sales and library partnership integrations. The free tier decisively beats
BookDesign's paid tier (speed, sleep timer, bookmarks, lock-screen artwork, per-chapter narrators,
volume normalization, skip silence, playlists, favorites, full catalog, EQ, offline downloads,
listening stats, no ads).

**What this plan is now about: the app loses your place, and that is the one thing it must never do.**

An audiobook player has exactly one core promise — resume where you stopped. Voxglass breaks it in three
independent ways, and the identity model underneath makes it unrecoverable across a reinstall or a second
device. That is a 1-star-review bug and it outranks everything else remaining.

**Intended outcome:** you can always resume any book at the exact position you left off — across restart,
force-quit, crash, app upgrade, delete-and-reinstall, and a second device — and the remaining App Store
polish items are closed.

---

## The problem, precisely

**1. `play(book)` always starts at chapter 1. This is the one users hit daily.**

`PlaybackCoordinator.play(_:chapter:)` (`Voxglass/Core/Playback/PlaybackCoordinator.swift:131-133`):

```swift
let chapter = requestedChapter ?? book.chapters.first
```

Six call sites pass no chapter — `BookDetailView.swift:158` (the main **Play** button), `PlaylistsView.swift:79`,
and the four play-what-I-just-imported paths (`DiscoverView:159`, `ListenView:179`, `SearchView:133`,
`SettingsView:475`). And the store has **no per-book resume query at all**: `PositionStore` offers only
`position(for:chapterID:)` — which needs a chapter you don't have — and a global `latestPosition()`.

So tapping Play on a book you are eight chapters into resumes **chapter 1**, at chapter 1's stale offset.
Launch restore (`restoreLatestSession`) rehydrates only the single globally-newest book, and only *paused*;
the moment you navigate to the book and press Play, you are back at the beginning.

**2. The crash / force-quit path can drop the write.**

`willTerminate` and `didEnterBackground` both do `Task { await persistCurrentPosition() }`
(`PlaybackCoordinator.swift:826-845`) — an async hop onto the `AppDatabase` **actor**. When the OS kills a
backgrounded app, that enqueued write never runs. `willResignActive` — which fires *earlier*, and is the
one that covers the swipe-up-to-kill gesture — is not observed at all. The 1 Hz UserDefaults snapshot
(`LastPlaybackSnapshotStore`) is the real safety net, but it is a **single global slot**: it protects one
book, and switching books discards the other's net.

**3. Position 0 can overwrite a good position.**

`persistCurrentPosition` reads `engine.currentTime`, and `AVPlayerAudioEngine.currentTime` returns `0`
whenever `player.currentTime().seconds` is non-finite — exactly the window after `load()` and before the
item is ready. A pause or tick in that window writes `position_seconds = 0` over a good row. There is no
floor guard anywhere.

**4. Underneath all three: identity is not stable.**

`Book.id` / `Chapter.id` are random UUIDs minted at import (`BookModels.swift:15`). They survive an
in-place upgrade (same SQLite file) but **not** a delete-and-reinstall, and **not** a second device.
Because `playback_positions` sync ships raw `book_id`/`chapter_id` and `PRAGMA foreign_keys = ON`, a
position pulled from another device references a book id that does not exist locally, **fails the foreign
key, and throws**. Cross-device position sync is structurally dead today. `LibraryBackupService`'s
`INSERT OR IGNORE INTO playback_positions` silently drops every position for the same reason.

### Decision: position sync is free

"Never lose your place" is a trust promise, not an upsell — and it is squarely the "a player that respects
you" wedge. **Playback-position sync, bookmarks sync, and favorites sync are all free.**

### Lessons ported from `../parso-radio-ios-app`

That app solved this problem; these are its load-bearing ideas.

- **Resume at the point of play, not at launch.** Radio's autosave lookup lives *inside* `playTrack`, so
  every entry surface resumes for free and there is no separate "restore" path that can diverge from the
  normal play path. This single idea fixes all six Voxglass call sites at once.
- **Redundant stores with different failure modes, plus an explicit tie-break.** SQLite (rich, async,
  killable) vs UserDefaults (flat, synchronous, survives the kill). On restore, prefer the durable one when
  they disagree beyond an epsilon. Radio encodes this as a literal unit test
  (`PlaybackReliabilityTests.swift:85` — *"durable session offset must beat the stale DB position"*).
- **Save on `willResignActive`; assume `willTerminate` never arrives.**
- **Save at every context transition, not just on a timer.** The timer is the backstop, not the mechanism.
- **Position hygiene, unit-tested:** don't save below a floor, don't strand the user 3 s from the end, clear
  on natural finish. Otherwise "resume" means "resume at 0:02" or "resume at the credits, forever."
- **Deterministic ids** so every write is an idempotent upsert with no delete-then-insert window.

---

## Step 0 — Get the existing work committed

The changes below are implemented and ready for commit.

Run `scripts/test.sh` and `scripts/guard_wiring.sh` against the working tree as it stands, fix any fallout,
and **commit**.

---

## Phase 1 — Resume where you actually were  *(release blocker)*

Fixes the loss users hit daily. Independent of every other phase — shippable alone.

**`Voxglass/Core/Playback/PositionStore.swift`** — add to the `PositionStore` protocol and
`SQLitePositionStore`:

```swift
func latestPosition(forBookID: UUID) async throws -> PlaybackPosition?
// SELECT ... FROM playback_positions WHERE book_id = ? ORDER BY updated_at DESC LIMIT 1
```

**`Voxglass/Core/Playback/PlaybackCoordinator.swift`** — extract a **pure, static** resume resolver so the
rules are testable with zero I/O. This is the repo's established pattern (cf. `startDecision`,
`pinCount(states:)`):

```swift
struct ResumeTarget: Equatable { let chapter: Chapter; let startTime: TimeInterval }

static func resolveResume(
    chapters: [Chapter],
    saved: PlaybackPosition?,
    startFloor: TimeInterval = 5,     // below this, start the chapter at 0
    endEpsilon: TimeInterval = 5      // within this of the end, treat as finished
) -> ResumeTarget?
```

Rules, in order:

| Condition | Result |
|---|---|
| no saved position, or the saved chapter no longer exists | chapter 1 @ 0 |
| saved chapter finished (`isFinished`, or within `endEpsilon` of its duration) **and** a next chapter exists | **next chapter @ 0** |
| saved chapter finished **and** it was the last chapter | chapter 1 @ 0 (book done → restart) |
| saved position `< startFloor` | that chapter @ 0 |
| otherwise | that chapter @ saved position |

Then rewrite `play(_:chapter:)`: **when no chapter is passed**, call `latestPosition(forBookID:)` and run it
through `resolveResume`. An explicitly requested chapter still wins and still uses
`position(for:chapterID:)` for its own offset. **No view changes are needed** — one change fixes all six
call sites.

**Add the anti-zero guard** (problem 3) to `persistCurrentPosition` / `saveCurrentSnapshot`: never persist
when the engine has no loaded item or reports a non-finite/zero time, *unless* the user explicitly seeked
there. Give `AudioEngine` an `isReady` / `hasLoadedItem` signal (or make `currentTime` return
`TimeInterval?`) and bail out of the save rather than writing `0`. This is a silent, real data-loss path.

**AC:** `testPlayBookWithoutChapterResumesLastPlayedChapter` fails on today's tree and passes after.
Device: play book A to ch5 @ 12:30, force-quit, relaunch, Library → Book A → **Play** → lands on ch5 @
12:30, not chapter 1.

---

## Phase 2 — Survive the crash and the force-quit

**`Voxglass/Core/Playback/LastPlaybackSnapshotStore.swift`** — promote from one global slot to a bounded
**per-book** map, still in UserDefaults. UserDefaults is the store with the *good* crash profile: `cfprefsd`
is a separate process and survives the app being SIGKILLed, whereas the SQLite write is an enqueued actor
hop that does not.

- Keep the existing `guru.parso.voxglass.lastPlaybackSnapshot` key and keep **reading** it on first load, so
  an upgrading user's in-flight position is not thrown away.
- Add `guru.parso.voxglass.positionSnapshots` — `[String: PlaybackPosition]` keyed by book UUID, capped at
  ~50 most-recent by `updatedAt`.
- API: `save(_:)`, `position(forBookID:)`, `latest()`, `all()`, `clear(bookID:)`, `clear()`.

**`PlaybackCoordinator.configureNotifications()`** — three changes:

1. **Observe `UIApplication.willResignActiveNotification`** and write the snapshot **synchronously, inline
   on the main thread** (no `Task`). This is the one save that must not be async.
2. Wrap the SQLite flush on background/terminate in `UIApplication.shared.beginBackgroundTask` /
   `endBackgroundTask` so the actor write actually gets to run.
3. Keep `didEnterBackground` and `willTerminate` as backstops.

**Capture before mutating.** Each transition save (pause, seek, skip, chapter change, interruption, route
change) must capture the position *before* touching the player — radio calls `saveCurrentSpot()` before
`audioPlayer.pause()`.

**`Voxglass/App/AppServices.swift:67`** — fix the bootstrap ordering and add a reconcile:

```
libraryStore.refresh()
cloudSync.pullPlaybackPositions()          // KVS read is local + cheap. Today sync() runs AFTER restore,
                                           // so a cloud position is always one launch stale.
playbackCoordinator.reconcileSnapshots()   // NEW — replay UserDefaults snapshots into SQLite
playbackCoordinator.restoreLatestSession(from:)
cloudSync.sync()                           // the rest, in the background
```

`reconcileSnapshots()` upserts every UserDefaults snapshot into SQLite, last-writer-wins on `updatedAt`,
**with the radio tie-break**: for the same (book, chapter), if `snapshot.position > row.position + 2`, the
snapshot wins even if the row's `updated_at` is newer — because a lost SQLite write is precisely the failure
this defends against.

**Stop failing silently.** `restoreLatestSession` (`PlaybackCoordinator.swift:107-112`) `return`s with no
error when the book, the chapter, or `resolvedPlayableURL()` doesn't resolve. Set `playbackError`. Note that
`resolvedPlayableURL()` returns `localURL ?? remoteURL` — a **stale local URL for an evicted cached file**,
which will fail to play. Fall back to `remoteURL` when the local file is gone.

**AC:** `testRestorePrefersDurableSnapshotOverStaleDatabaseRow` (radio's I4, ported). Device: kill the
process from Xcode mid-chapter → relaunch within ~1 s of where you were.

---

## Phase 3 — Stable identity: survive reinstall, backup restore, and a second device

**Migration 7** in `Voxglass/Core/Database/DatabaseMigrations.swift` (the ladder is at id 6; migrations are
additive and tracked in `schema_migrations`):

```sql
ALTER TABLE books ADD COLUMN content_key TEXT;
ALTER TABLE chapters ADD COLUMN content_key TEXT;
CREATE INDEX books_content_key ON books(content_key);
CREATE INDEX chapters_content_key ON chapters(book_id, content_key);
```

New **pure** `Voxglass/Core/Library/ContentKey.swift` (no I/O, fully unit-testable):

- `book(forSourceURL:kind:)` → `ia:<identifier>`, parsed from the `sources.url` details URL — the same
  identifier `ensureInternetArchiveSource` already dedupes on (`LibraryRepository.swift:446`) — or
  `local:<normalized folder name>` for `localFiles`.
- `chapter(remoteURL:localURL:index:title:)` → normalized filename stem (stable for both IA and local files,
  and stable across a folder move), falling back to `idx:<index>`.

**Backfill** on first launch after migration 7, deriving `content_key` for every existing book and chapter
from data already in the DB. Then set it at import time in `LibraryRepository.importInternetArchiveItem`
and `importLocalFolder`.

**`Voxglass/Core/Services/Sync/VoxglassCloudSync.swift`:**

- **All sync is free.** `pushPlaybackPositions()` / `pullPlaybackPositions()`/
  `pushBookmarks()`/`pullBookmarks()` all run without any entitlement gate.
- Add `book_content_key` and `chapter_content_key` to the KVS position payload.
- **Pull resolves by content key**, not raw UUID: match the local book/chapter by `content_key` and upsert
  with *local* ids. Guard every `UUID(uuidString:)`.
- **Adopt-on-import:** after a new book lands, re-scan `voxglass.cloudsync.pos.*` for rows whose
  `book_content_key` matches and apply them. **This is what makes delete-and-reinstall work** — reinstall,
  re-import the book from LibriVox, and your position comes back. No new local table is needed; KVS is
  already the durable store.
- Prune stale `pos.*` keys — KVS has a 1024-key / 1 MB ceiling and nothing prunes today.

**`Voxglass/Core/Services/Backup/LibraryBackupService.swift`** — its
`INSERT OR IGNORE INTO playback_positions` silently drops every position when books were re-imported under
new UUIDs. Change to a content-key-resolved upsert with LWW on `updated_at`. **Library Backup already
shipped with this defect baked in** — Phase 3 is what fixes it.

**AC:** `testCloudPullResolvesForeignBookIDsViaContentKey` fails on today's tree (FK throw) and passes
after. Device: delete the app, reinstall, re-import the same LibriVox book → position restored.

---

## Phase 4 — Derived progress is wrong

`LibraryRepository.fetchBookProgress()` (`Voxglass/Core/Library/LibraryRepository.swift:527`) uses
`MAX(position_seconds)` — the largest *within-chapter* offset, not cumulative elapsed time — and
`MIN(is_finished)` over only the chapters that *have* rows, so **a book with one finished chapter row reads
as finished**. This drives the Library `.finished` / `.inProgress` filters.

Recompute: finished ⇔ every chapter has a finished row; progress ⇔ Σ(finished chapter durations) + current
chapter offset.

---

## Phase 5 — Remaining App Store polish

**A4. Settings polish.**

**E2. Accessibility.** The repo has **exactly one** `accessibilityValue` (`NowPlayingView:159`, the
scrubber). The labels sweep across the bare `Features/` views never happened. For an app whose pitch is *"a
player that respects you"*, with an audience that skews older, this is both an App Review risk and squarely
on-brand to fix.

**E3. README is stale.** `README.md:62` still points at `docs/COMPETITIVE_GAP_PLAN.md` as the live plan.
Rewrite Highlights / Competitive position / Roadmap to describe the app that now exists.

**E4. Skip Silence never got its device sign-off.** The toggle is shipped (`SettingsView:807`) with no
evidence the device pass happened. Verify on a real LibriVox recording, **or pull the toggle** — better no
toggle than a dead one.

---

## CarPlay — approved, free, and standalone

**Apple approved `com.apple.developer.carplay-audio` on 2026-07-16. Design is complete** — the full
engineering handoff, model, test matrix, plist/entitlement diffs, and view-by-view mockups live in
**`docs/CARPLAY_DESIGN.md`**. It is a self-contained workstream (does not block Phases 1–5).

**Two binding product decisions (2026-07-16):**

- **CarPlay is free for everyone.** No gate on browsing, searching, resuming, or playing in the car.
  Stripping transport controls from a driver mid-trip is unsafe and 1-star-review material, and "never
  lose your place" is a free trust promise.
- **CarPlay is standalone.** Search, browse, resume, and download entirely from the head unit — no
  phone handoff — including the cold-launch-straight-into-CarPlay path (phone locked, app never
  foregrounded).

The build is small where it can be: `CPNowPlayingTemplate` is driven entirely by `MPNowPlayingInfoCenter` +
`MPRemoteCommandCenter`, both of which already ship (speed, artwork, remote commands). The new surface is the
browse tree — a pure, host-testable `CarPlayMenuBuilder` in `VoxglassCore` rendered by a thin app-layer
`CarPlayInterfaceController`, mirroring the existing `PlaybackPlatformBridge` seam. In-car play routes
through `PlaybackCoordinator.play(...)` so resume + position persistence stay intact.

---

## Sequencing

| Order | Work | Notes |
|---|---|---|
| **0** | Commit the existing uncommitted work | 19 modified + 5 untracked; everything below builds on it |
| **1** | **Phase 1** — resume at the right chapter | The release blocker. Independent; shippable alone. |
| **2** | **Phase 2** — crash / force-quit durability | Independent of Phase 3. |
| **3** | **Phase 3** — content keys, free position sync | Must precede any further Library Backup work. |
| **4** | **Phase 4** — derived progress | Small, independent. |
| **5** | **Phase 5** — A4, E2, E3, E4 | Parallelizable. |
| **Parallel** | CarPlay | Approved 2026-07-16; free + standalone. Self-contained — see `docs/CARPLAY_DESIGN.md`. |

---

# Agentic coding handoff

## Ground rules (binding)

- `import StoreKit` **has no restrictions** — Pro feature gating has been removed.
- No new network endpoints beyond `archive.org`, `librivox.org`, `parso.guru` — CI-guarded.
- XcodeGen-managed: new files just need to live under `Voxglass/`; **run `xcodegen generate` before
  building**. Never hand-edit the `.xcodeproj`. Never use `xcodegen --project` — it silently nests the
  project and breaks the build (see `docs/AUDIO_FIXES_HANDOFF.md`).
- No code comments unless non-obvious.
- Prefer **pure, static, injectable** decision functions over logic buried in the coordinator — this is how
  `startDecision`, `pinCount(states:)` and `resolveResume` stay testable with zero I/O.

## Falsification first

This repo's discipline: write each new test against the **current tree** and confirm it **fails** before
fixing anything. A bug that ships green shipped because the test went *around* the call site, not through it
— that is exactly how the download-cap bypass survived.

Tests that **must fail today**:

- `PlaybackResumeTests.testPlayBookWithoutChapterResumesLastPlayedChapter` (Phase 1 — returns chapter 1)
- `PlaybackResumeTests.testPlayBookResumesAtSavedOffsetNotChapterZero` (Phase 1)
- `PlaybackResumeTests.testEngineZeroTimeDoesNotOverwriteSavedPosition` (Phase 1 — problem 3)
- `PositionDurabilityTests.testSnapshotStoreKeepsAPositionPerBook` (Phase 2 — single global slot)
- `CloudSyncTests.testCloudPullResolvesForeignBookIDsViaContentKey` (Phase 3 — FK throw)
- `LibraryRepositoryTests.testBookIsFinishedOnlyWhenAllChaptersFinished` (Phase 4)

## New test files

**`VoxglassTests/PlaybackResumeTests.swift`** — pure `resolveResume` + `FakeAudioEngine`:
resume-last-chapter; resume-at-offset; finished chapter advances to next @ 0; finished *last* chapter
restarts at book start; below-floor starts at 0; engine-zero does not overwrite.

**`VoxglassTests/PositionDurabilityTests.swift`**:
- `testRestorePrefersDurableSnapshotOverStaleDatabaseRow` — hand-seed the two stores into disagreement (DB @
  40 s, snapshot @ 137 s), assert 137 wins. Radio's I4 test, ported.
- `testReconcileReplaysSnapshotsIntoDatabaseOnLaunch`
- `testSnapshotStoreKeepsAPositionPerBook`

**`VoxglassTests/ContentKeyTests.swift`** (pure) + additions to `CloudSyncEntitlementTests`:
`testBookContentKeyIsStableAcrossReimport`; `testCloudPullResolvesForeignBookIDsViaContentKey`;
`testImportAdoptsCloudPositionForMatchingContentKey` (the reinstall scenario).

## Verification

**Guards (ubuntu CI, seconds):** `scripts/guard_wiring.sh`, plus
`xcodegen generate && git diff --exit-code Voxglass.xcodeproj`.

**Compile (macOS CI):** `xcodebuild build -scheme Voxglass -destination generic/platform=iOS` — no simulator
boot. This job exists and is green; CI now genuinely compiles the app.

**Local suite:** `scripts/test.sh` (simulator; local-only gate by design).

**Device — the irreducible acceptance tests. This is what "never lose my position" means:**

1. Play book A to chapter 5 @ 12:30. **Force-quit from the app switcher.** Relaunch → mini player shows ch5
   @ 12:30. Library → Book A → **Play** → lands on ch5 @ 12:30, *not* chapter 1.
2. Play mid-chapter, **kill the process from Xcode** (simulated crash). Relaunch → within ~1 s of where you
   were.
3. Start book B, switch to book A, switch back to B → B resumes at B's spot.
4. Play to the end of a chapter → resume lands at the **start of the next chapter**, not 3 s from the end of
   the old one.
5. **Upgrade:** install a pre-change build, get a position, install the new build over it → migration 7
   backfills, position preserved.
6. **Reinstall:** delete the app, reinstall, re-import the same LibriVox book → position restored from
   iCloud, on a **free** build.
7. Airplane mode → restore still works from local stores.
8. Skip silence firing on a real LibriVox recording (E4).
9. A VoiceOver pass over Now Playing (E2).

**Definition of done:** every AC green; `guard_wiring.sh` + `scripts/test.sh` green; the seven falsification
tests confirmed failing before their fixes; the nine device checks pass.
