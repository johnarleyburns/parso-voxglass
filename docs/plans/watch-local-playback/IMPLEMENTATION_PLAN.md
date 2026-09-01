# Watch-local audiobook playback corrective phase

**Status:** Approved for implementation  
**Decision:** Download-first, audibly Watch-owned playback. Phone playback control is not added in
this phase; it remains a separately labeled future convenience mode and must never be an implicit
fallback.

## 1. Problem statement

The shipping Watch surface currently sets its presentation state to playing before `AVPlayer`
produces audio, starts a remote URL without configuring or activating the watchOS long-form audio
session, ignores downloaded chapter files, does not observe readiness/buffering/failure, and does
not publish system Now Playing information. The custom progress view is a constant. This permits
three dishonest outcomes: a pause icon with no player, silent playback after audio-route activation
fails, and iPhone Now Playing appearing to own playback while the Watch UI says `Apple Watch`.

The earlier watch-rearchitecture audit says these capabilities exist, but the current source is the
release fact and they do not. This corrective phase replaces the optimistic façade with one
testable Watch playback owner.

## 2. Product contract

1. A Watch button never starts or controls the iPhone player.
2. The Watch resolves a complete local chapter first. If it is absent, a phone-approved,
   credential-free HTTPS URL may be streamed only while connected. There is no other URL fallback.
3. Complete downloaded books play locally even when the phone is unreachable.
4. Before creating audible playback, configure `AVAudioSession` as `.playback`, `.spokenAudio`,
   `.longFormAudio`, then asynchronously activate it. Player start follows successful activation.
5. No UI state says `Playing` until the player reports that it is playing. Preparing, waiting for
   audio output, buffering, paused, ended, and failed are distinct states.
6. Route activation failure is visible and actionable: `Connect Bluetooth headphones, then try
   again.` The app must not silently redirect to iPhone.
7. System Now Playing is published by the Watch for Watch-owned playback and cleared on stop/fatal
   failure. It contains book, author, chapter, duration, elapsed time, playback rate, chapter index,
   chapter count, and stable content identifiers. Remote play, pause, toggle, previous chapter,
   next chapter, and position commands call the same engine actions as the app UI.
8. The custom Now Playing view derives its icon, status, progress, elapsed time, and enabled controls
   from observed engine state. `Apple Watch` remains the ownership label; route status is separate.
9. Previous/next moves exactly one chapter. Automatic completion advances one chapter and stops at
   the final chapter. A failed chapter change preserves an honest failure state.
10. Playback position is chapter-relative, ticks while playing, and is persisted at least every ten
    seconds and on pause, chapter change, interruption, background, and termination opportunity.
11. Audio interruptions pause state honestly. A resumable interruption may resume only when the
    system explicitly supplies `shouldResume`. Route loss pauses and explains how to recover.
12. Simulator smoke uses an injected playback driver and never claims audible output, Bluetooth
    routing, WatchConnectivity, background survival, or system Now Playing integration.

## 3. Architecture and seams

### 3.1 Pure Watch core

Add Foundation-only types to `VoxglassWatchCore`:

- `WatchPlaybackPhase`: `idle`, `preparing`, `waitingForOutput`, `buffering`, `playing`, `paused`,
  `ended`, `failed(message)`.
- `WatchPlaybackSnapshot`: book/chapter identity, zero-based chapter index/count, position,
  duration, rate, phase, source kind, and computed progress/control availability/status copy.
- `WatchPlaybackSourceKind`: `downloaded`, `stream`.
- `WatchPlaybackSourceResolver`: sanitize the durable filename, resolve
  `DownloadedBooks/<book-id>/<filename>`, prefer an existing regular file, then accept only an
  approved HTTPS stream when streaming is allowed; otherwise return a typed unavailable error.
- `WatchPlaybackReducer`: pure transitions for prepare, player waiting/playing/paused/failed,
  periodic time, interruption, route loss, and end-of-item. It clamps nonfinite/negative time and
  progress and rejects stale events for a previous chapter token.
- `WatchPlaybackPositionStore`: actor-backed Codable persistence keyed by book and chapter IDs,
  with atomic writes and corrupt-file recovery to an empty store.

Core must remain AVFoundation-, MediaPlayer-, WatchKit-, WatchConnectivity-, and CloudKit-free.

### 3.2 Watch app engine

Add a single main-actor `WatchPlaybackEngine`, owned by `WatchAppServices`:

- production adapters wrap `AVAudioSession`, `AVPlayer`, `MPNowPlayingInfoCenter`, and
  `MPRemoteCommandCenter`;
- injected smoke mode uses a deterministic driver which transitions preparing → playing, advances
  elapsed time without network/audio, and records commands;
- retain all notification/time/player observations and remove them on replacement/deinit;
- activate the audio session before loading/playing the item;
- observe item status, time-control status, end/failure, audio interruptions, route changes, and app
  lifecycle notifications;
- update Now Playing on item start, phase/rate changes, seeks, and periodic time with throttling;
- resolve local files on every chapter start so a completed download becomes immediately usable;
- save and restore chapter-relative position, seeking only after the item is ready;
- expose immutable snapshot state to SwiftUI and translate technical errors into actionable copy.

`WatchAppServices` remains the library/download/session composition root but delegates every
playback operation and presentation fact to this engine. It must not maintain a second optimistic
playing model.

### 3.3 UI

Revise `WatchNowPlayingView`:

- actual determinate progress when duration is valid, indeterminate progress while preparing or
  buffering, and no fabricated 25% value;
- `Preparing…`, `Waiting for headphones`, `Buffering…`, `Playing`, `Paused`, or the failure text;
- elapsed and remaining time derived from the snapshot;
- play/pause icon and accessibility label from actual phase;
- disable play/pause when no item exists or a start is already in flight; disable previous/next at
  queue boundaries;
- preserve simultaneous 44×44 previous/play/next controls and stable accessibility identifiers;
- expose stable identifiers for phase, progress, elapsed, remaining, source, and error/retry;
- retry repeats Watch-local preparation for the selected chapter.

Book detail Play navigates immediately to Now Playing but initially shows preparing. Chapter rows
use the same path. Download completion does not itself start audio.

## 4. Unit-test specification

Add host tests under `VoxglassTests/` for all pure logic:

### Source resolution

- existing durable file wins over an HTTPS stream;
- downloaded file resolves while disconnected;
- missing local file uses approved HTTPS only when streaming is allowed;
- HTTP, credential-bearing, malformed, and file URLs from projection are rejected;
- missing local and unavailable stream returns `chapterUnavailable`;
- traversal/absolute durable filenames are rejected;
- shared-file offsets remain represented as chapter-relative seek offsets without changing the
  resolved source.

### State reducer

- prepare is not playing;
- waiting, buffering, playing, pause, resume, route loss, interruption, and failure transitions;
- stale callbacks cannot mutate the current chapter;
- time and duration clamp invalid values and progress remains in `0...1`;
- chapter boundaries enable/disable previous and next correctly;
- end advances when a next chapter exists and ends on the final chapter;
- output/status copy matches each phase.

### Position persistence

- round trip positions for multiple books/chapters;
- overwrite is monotonic by update sequence rather than numeric position, allowing a user seek
  backward;
- negative/nonfinite values store as zero;
- corrupt data recovers without crashing;
- remove-book deletes only that book's positions.

### Static/guard checks

- Watch target retains `UIBackgroundModes = audio` and links MediaPlayer;
- production source contains `.playback`, `.spokenAudio`, `.longFormAudio`, async activation,
  Now Playing publication, remote commands, interruption and route-change observation;
- the old optimistic `isPlaying = true` model and constant `ProgressView(value: 0.25)` are absent;
- playback resolution references `DownloadedBooks` and local file existence;
- no phone playback coordinator or playback command is imported/called by Watch code.

Every new guard receives a negative probe in `scripts/test_guards.sh` if implemented as a shell
gate. Prefer behavioral unit tests where possible.

## 5. Watch smoke-test changes

The deterministic `VoxglassWatchUITests` flow must:

1. launch with the existing injected library plus an explicit injected playback driver;
2. open Alice and tap Play;
3. observe `watch.player.phase` reach `Playing` without network or an audio route;
4. assert output ownership says `Apple Watch` and source says `Downloaded`;
5. assert progress is not the legacy constant and elapsed time advances;
6. pause and assert phase/icon/accessibility label become paused/play;
7. resume and assert playing/pause;
8. tap next chapter, assert chapter title changes exactly once and previous becomes enabled;
9. tap previous, assert the original chapter returns;
10. assert previous is disabled on chapter one and next is disabled on the final chapter;
11. launch an injected missing-source failure state and verify actionable error plus Retry;
12. assert previous/play/next all exist without scrolling and each frame is at least 44×44 on the
    smallest configured Watch destination.

The normal `Watch-Small` smoke is required. A separate 40 mm Apple Watch SE destination must run
the same frame/visibility assertions and save a screenshot artifact where the installed simulator
runtime provides that device. If unavailable, record the exact destination evidence as pending;
do not substitute a larger device and claim success.

## 6. Implementation order

1. Add this plan and mark `current_status.md` active.
2. Add core types/resolver/reducer/position store and host unit tests; run focused tests.
3. Add MediaPlayer to `project.yml`, regenerate the Xcode project, and confirm membership.
4. Implement the injected driver and production engine.
5. Replace optimistic service state and hard-coded UI state.
6. Expand smoke and guard coverage.
7. Run focused tests, all logic tests, guards, Watch build, combined iPhone build, normal Watch
   smoke, 40 mm geometry smoke, and `git diff --check`.
8. Perform the mandatory post-implementation acceptance review below before staging or committing.
9. Fix every review finding, rerun affected checks plus the complete required gate, update the plan
   audit and status, explicitly stage only phase files, and commit without pushing.

## 7. Acceptance criteria

| ID | Criterion | Required evidence |
|---|---|---|
| WP-01 | Watch never controls or silently falls back to iPhone audio. | Source guard + code review |
| WP-02 | Local installed chapter wins and plays without connectivity. | Resolver unit tests + injected smoke |
| WP-03 | Remote fallback is HTTPS-only, credential-free, and connected-only. | Resolver unit tests |
| WP-04 | Long-form audio session is configured and activated before play. | Adapter unit/static test + Watch build; paired hardware pending |
| WP-05 | UI never reports playing before player confirmation. | Reducer tests + smoke phase transition |
| WP-06 | Route/activation/player failures are actionable and never show a pause icon. | Reducer tests + failure smoke |
| WP-07 | Downloaded files written by the app are the files resolved for playback. | Resolver tests using real temporary files |
| WP-08 | Progress, elapsed, remaining, and play/pause reflect observed state. | Reducer tests + advancing smoke |
| WP-09 | Watch publishes complete Now Playing metadata and handles remote commands. | Static/unit seam checks; paired hardware pending |
| WP-10 | Interruption and route loss produce honest paused/recovery state. | Reducer tests; paired hardware pending |
| WP-11 | Positions persist and restore chapter-relatively. | Position-store tests |
| WP-12 | Previous/next changes exactly one chapter and respects boundaries. | Unit tests + smoke |
| WP-13 | Audio continues wrist-down/background with controls available. | Background mode/build; paired hardware pending |
| WP-14 | Transport fits 40 mm with 44×44 targets and no scrolling. | 40 mm frame assertions + screenshot |
| WP-15 | Existing Watch library/download and iPhone/CarPlay behavior do not regress. | Full logic/guards, combined builds, iPhone + Watch smoke |
| WP-16 | Swift 6 strict concurrency build is warning-free for changed production files. | Build logs + review |

## 8. Mandatory post-implementation acceptance review

This is a separate verification activity after implementation and before commit. Do not treat tests
passing as the review itself.

1. Re-read every product contract item and every WP row against the final source and runtime
   evidence.
2. Build a review table in this document's Implementation Audit with `pass`, `pending hardware`,
   or `fail`; include an exact test/command/file reference for each row.
3. Trace these scenarios manually through the code: downloaded/disconnected start; connected stream
   start; no headphones; stream failure; pause/resume; interruption; route loss; seek backward;
   chapter end; final-book end; app background; relaunch/resume; rapid chapter changes producing
   stale callbacks.
4. Inspect the final diff for duplicate playback ownership, retained observers, concurrency hazards,
   filesystem traversal, inaccurate copy, constant/fake production state, and unrelated edits.
5. Any `fail` is a release blocker: fix it, add or strengthen a regression test, rerun the affected
   tests and all required gates, then repeat the review. Do not commit with a failed row.
6. `pending hardware` is permitted only for facts simulators cannot prove: audible routing, physical
   remote controls/system Now Playing, wrist-down/background longevity, WatchConnectivity delivery,
   and physical 40 mm layout if that simulator is unavailable. Record an executable device test
   script for each pending row.
7. Only after there are no failed rows: update `current_status.md`, stage explicit paths, inspect the
   staged diff, commit on `main` with hooks enabled, and do not push.

## 9. Required verification commands

Use actual installed destinations if the documented names are unavailable.

```sh
swift test --filter WatchPlayback
bash scripts/test_logic.sh
bash scripts/test_guards.sh
bash scripts/guard_wiring.sh
bash scripts/guard_production.sh
xcodebuild -scheme VoxglassWatch -destination 'platform=watchOS Simulator,name=Voxglass-Agent-Watch,OS=latest' -derivedDataPath /tmp/voxglass-watch-playback build CODE_SIGNING_ALLOWED=NO
xcodebuild -scheme Voxglass -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -derivedDataPath /tmp/voxglass-watch-playback-phone build CODE_SIGNING_ALLOWED=NO
bash scripts/test.sh --all
git diff --check
```

## 10. Implementation Audit

Performed 2026-09-01 after implementation and before commit. Every product-contract item
(§2) and WP row (§7) was re-read against the final source and runtime evidence. No row is
`fail`; simulator-improvable rows are `pending hardware` with the required device scripts
below. The mandatory acceptance review's manual scenario traces are recorded after the table.

| ID | Criterion | Verdict | Evidence |
|---|---|---|---|
| WP-01 | Watch never controls or silently falls back to iPhone audio. | pass | `WatchAppServices` no longer imports AVFoundation or holds an `AVPlayer`; the sole playback owner is `WatchPlaybackEngine`. `VoxglassTests/WatchPlaybackTests.swift` `productionWiring` asserts `WatchPlaybackEngine.swift` contains no `PlaybackCoordinator` and the service contains no `isPlaying: true`. Watch target links only Watch-local modules. |
| WP-02 | Local installed chapter wins and plays without connectivity. | pass | `WatchPlaybackSourceResolver` prefers the existing file under `DownloadedBooks/<book-id>/<filename>` regardless of `allowsStreaming`. Unit tests `downloadedWins`, `downloadedDisconnected`, `realDownloadedFileResolves`; injected smoke asserts source `Downloaded` while phase reaches `Playing` with no network/route. |
| WP-03 | Remote fallback is HTTPS-only, credential-free, and connected-only. | pass | Resolver tests `streamPolicy` (rejects http, credential-bearing, file URLs) and `streamDisconnected`; engine `streamingAllowed` provider makes chapter advance/retry connected-only. |
| WP-04 | Long-form audio session configured and activated before play. | pass (simulator); pending hardware | `productionWiring` asserts `.playback`, `.spokenAudio`, `.longFormAudio`, and `await session.activate`; Watch build clean. Audible route activation needs paired hardware. |
| WP-05 | UI never reports playing before player confirmation. | pass | Reducer `honestStateAndStaleEvents`; smoke `waitForPhase("Playing")` waits for the engine-published `Playing` phase. |
| WP-06 | Route/activation/player failures actionable, never a pause icon. | pass | Reducer `stateTransitions` (route loss → `failed("Connect Bluetooth headphones, then try again.")`); `audioErrorMessage` maps AVFoundation/OSStatus domains to that copy; failure smoke asserts the error text and a `Play` label. |
| WP-07 | Downloaded files written by the app are the files resolved. | pass | `realDownloadedFileResolves` writes a real temporary file and resolves it with streaming disallowed; resolver uses the default `FileManager` existence check. |
| WP-08 | Progress, elapsed, remaining, play/pause reflect observed state. | pass | Reducer `timeAndBoundaries` clamps time/duration/progress; smoke asserts elapsed advances and play/pause icon flips with phase. |
| WP-09 | Watch publishes complete Now Playing metadata and handles remote commands. | pass (seam); pending hardware | `updateNowPlaying` publishes title/album/artist/duration/elapsed/rate/chapter index/count/external identifier and clears on fatal failure; play/pause/toggle/next/previous/seek remote commands registered. System Now Playing integration needs paired hardware. |
| WP-10 | Interruption and route loss produce honest paused/recovery state. | pass (reducer); pending hardware | Reducer `stateTransitions`; interruption handler resumes only on `.shouldResume`; `oldDeviceUnavailable` pauses with recovery copy. Paired events pending hardware. |
| WP-11 | Positions persist and restore chapter-relatively. | pass | `positionPersistence` covers round trip, backward seek, nonfinite→zero, corrupt-file recovery, and per-book removal. |
| WP-12 | Previous/next changes exactly one chapter and respects boundaries. | pass | Reducer `timeAndBoundaries` plus smoke chapter 1→2→3 with boundary disables. |
| WP-13 | Audio continues wrist-down/background with controls available. | pending hardware | `UIBackgroundModes = audio` asserted by `productionWiring`; scenePhase background persistence wired in `VoxglassWatchApp`. Wrist-down longevity requires paired hardware. |
| WP-14 | Transport fits 40 mm with 44×44 targets and no scrolling. | pass | `Watch-SE-40` (Apple Watch SE 3, 40 mm) smoke ran the frame/visibility assertions: each of previous/play/next ≥ 44×44 and fully inside the 162×197-point app frame; screenshot saved to `docs/plans/watch-local-playback/evidence/watch-now-playing-transport-40mm-se.png`. |
| WP-15 | Existing Watch library/download and iPhone/CarPlay behavior do not regress. | pass | Full logic suites (1,384 + 6 performance), guard self-tests, watch foundation/production/wiring guards, Watch and combined iPhone builds, iPhone smoke, and Watch smoke on the 46 mm and 40 mm destinations all green. |
| WP-16 | Swift 6 strict concurrency is warning-free for changed files. | pass | Watch and combined iPhone builds emit no compiler warnings in the changed Watch files (only the pre-existing AppIntents metadata note). |

### Mandatory review — manual scenario traces

Traced through the final source (`VoxglassWatch/WatchPlaybackEngine.swift`, core types,
`WatchAppServices`, `WatchNowPlayingView`):

- **Downloaded/disconnected start** — `play` → resolver returns the local file (file wins
  regardless of `allowsStreaming`) → activate session → `installPlayer(localURL)`.
- **Connected stream start** — local absent → resolver accepts only credential-free HTTPS
  when `streamingAllowed()` → activates session → player streams.
- **No headphones / activation failure** — `activateAudioSession` throws an AVFoundation/OSStatus
  error → `audioErrorMessage` → `failed("Connect Bluetooth headphones, then try again.")`.
- **Stream failure** — item `.failed` status or `AVPlayerItemFailedToPlayToEndTime` → honest
  `failed` phase with a `Play` label and a Retry action.
- **Pause/resume** — toggle pauses/publishes `paused` and persists; resume reactivates the
  session before `play()`.
- **Interruption** — `.began` pauses + persists; `.ended` resumes only with `.shouldResume`.
- **Route loss** — `oldDeviceUnavailable` pauses, publishes the actionable failure copy, persists.
- **Seek backward** — `seek(to:)` clamps to `0...duration`, seeks `assetOffset + value` on the
  player, persists (position store test proves backward overwrite is honored).
- **Chapter end** — `itemEnded` persists then advances exactly one chapter.
- **Final-book end** — no next chapter → `ended` with position = duration.
- **App background** — scenePhase leaves `.active` → `persistPlaybackPosition()`.
- **Relaunch/resume** — store restores the chapter-relative position; seek happens only after
  the item is `.readyToPlay`.
- **Rapid chapter changes / stale callbacks** — every publish and observer checks
  `currentToken == token`; reducer rejects stale tokens (`honestStateAndStaleEvents`).

### Pending-hardware device scripts

Rows WP-04, WP-09, WP-10, WP-13 remain `pending hardware`. On a paired iPhone + Apple Watch:

1. Pair and connect Bluetooth headphones; open a downloaded book and confirm audible playback,
   system Now Playing metadata, and play/pause/next/previous from the physical controls.
2. Unplug the headphones mid-playback and confirm the actionable route-loss copy appears.
3. Start a call/other audio while playing and confirm honest pause, then resume when the system
   allows it.
4. Lower the wrist for several minutes with a long book and confirm audio continues and controls
   remain available.
5. Disconnect the phone (airplane mode) and confirm a complete downloaded book starts and plays
   locally with `On This Watch` surface behavior.

### Review findings and fixes

The following findings from the mandatory review were fixed and retested before this audit:

1. Transport row clipped on the 40 mm SE (bottom beyond the 197-pt viewport). Compacted the
   Now Playing top section (artwork 40 pt, one-line titles, spacing 4) and re-ran the
   `Watch-SE-40` geometry gate; the screenshot evidence was saved.
2. Chapter rows on Book detail started playback without navigating to Now Playing. They now use
   the same path as Play.
3. Progress bar showed a determinate (zero) bar during preparing/buffering. It now renders
   indeterminate for `idle/preparing/waitingForOutput/buffering` and determinate otherwise.
4. Item-scoped end/failure notification observers were retained across player replacement. They
   are now removed in `removePlayerObservers` and in `deinit`.
5. Now Playing metadata was not cleared on fatal failure. `updateNowPlaying` now clears it.
6. Position persistence had no background/termination hook (watchOS has no `UIApplication`
   notification). `VoxglassWatchApp` now persists via `scenePhase`; the engine exposes
   `persistPlaybackPosition()`.
7. `moveChapter`/`retry` hardcoded `allowsStreaming: true`, bypassing the connected-only stream
   contract. A `streamingAllowed` connection-state provider now gates those paths.
8. The smoke test's initial `Playing` assertion could race the engine's async first publish; it
   now waits for the phase predicate, and a 40 mm screenshot attachment was added.
