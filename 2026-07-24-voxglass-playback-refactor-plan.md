# Voxglass — Deterministic Playback, Observation, and Chrome Refactor

**Date:** 2026-07-24  
**Repository:** `johnarleyburns/parso-voxglass`  
**Target branch:** `main`  
**Suggested path in repo:** `plans/playback-refactor/2026-07-24/plan.md`  
**Delivery shape:** One pull request with six ordered commits. Do not squash.  
**App target:** `Voxglass`  
**Shared test import:** `@testable import VoxglassCore`  
**Minimum deployment target:** iOS 17.0  
**Primary frameworks involved:** SwiftUI, Observation, AVFoundation/MediaPlayer, Combine for existing store and CarPlay pipelines

---

## 1. Purpose

This refactor fixes the miniplayer, playback-selection, and playback-progress architecture as one coordinated change.

The current implementation has four interacting failure modes:

1. **Playback presentation is published too late.** Selecting a book does not reliably make the miniplayer visible until position restoration, URL resolution, and audio-engine preparation complete.
2. **Playback requests race.** Repeated book or chapter selections can overlap, allowing an older request to finish after a newer request and overwrite the user's latest selection.
3. **Fast clocks fan out through one `ObservableObject`.** The 1 Hz playback tick and 2 Hz sleep timer invalidate all views observing `PlaybackCoordinator`, including large tab roots that do not consume those values.
4. **Miniplayer visibility is inferred from lifecycle callbacks.** A missed or delayed `onDisappear` can leave `visiblePushedBookID` stale and suppress the miniplayer across unrelated tabs.

The target architecture separates:

- selected playback identity;
- playback preparation and failure state;
- live chapter-relative playback time;
- persistent/restored position;
- sleep-countdown presentation;
- navigation-derived miniplayer visibility.

The result must provide immediate visual feedback, latest-request-wins selection semantics, property-granular Observation invalidation, deterministic CarPlay updates, and stable per-tab navigation state.

---

## 2. Success criteria

The refactor is complete only when all of the following are true:

- Tapping Play or selecting a chapter publishes a visible selected session before audio preparation finishes.
- The miniplayer can display a preparing state immediately.
- A stale or cancelled request cannot change playback identity, phase, or error state.
- The 1 Hz playback clock does not reassign `currentSession`.
- Only the scrubber or another direct `playhead` consumer invalidates on the 1 Hz tick.
- Only direct sleep-countdown consumers invalidate on the 2 Hz sleep tick.
- CarPlay does not observe the 1 Hz playhead and does not observe finer sleep resolution than its UI requires.
- Miniplayer visibility is derived from current playback plus deterministic selected-tab/navigation state, not from balanced lifecycle callbacks.
- Switching tabs preserves each tab's navigation stack, route, and ordinary scroll state.
- All coordinator environment injections use Observation `.environment(...)`.
- Existing `ObservableObject` stores and the miniplayer router remain unchanged unless explicitly covered by this plan.
- No source-text gate is deleted merely to make the build pass. Outdated implementation gates must be replaced by equal or stronger behavioral invariants.

---

## 3. Non-goals

This PR does not:

- redesign the audio engine;
- add a new caching strategy;
- migrate all app stores to Observation;
- redesign the visual appearance of the miniplayer or Now Playing screen;
- add CarPlay features beyond preserving current behavior;
- change the persistence schema unless required to represent an already-existing saved chapter-relative position;
- add background audio capabilities not already present;
- change catalog or library domain models without a demonstrated need.

Avoid opportunistic cleanup outside the files and invariants described here.

---

## 4. Architectural invariants

### INV-0 — Immediate presentation

Selecting a playable book or chapter publishes a presentation session and `.preparing` phase before waiting for engine preparation.

Miniplayer visibility must not depend on successful AVFoundation loading.

### INV-1 — Latest request wins

Only the latest non-cancelled selection request may alter:

- `currentSession`;
- `playbackPhase`;
- `playbackError`;
- active engine content;
- playhead identity or duration.

Completion order must never override user-selection order.

### INV-2 — Session identity is quiet during steady playback

The periodic progress tick does not reassign `currentSession`.

`currentSession` changes only for meaningful state transitions such as:

- selection;
- chapter transition;
- play/pause transition;
- materially changed duration;
- explicit restored/committed position;
- clear;
- failure presentation where the selected identity remains relevant.

### INV-3 — Live position has one operational source

When the engine is loaded, operational position reads use `engine.currentTime`.

`currentSession.position` stores the restored, initial, or explicitly committed chapter-relative position. It is not the periodic live clock.

### INV-4 — Chapter-relative units are explicit

The scrubber seek target, playhead, restored position, and chapter duration are chapter-relative.

Book-relative elapsed time is calculated separately:

\[
\text{bookElapsed}
=
\text{elapsedBeforeCurrentChapter}
+
\text{chapterPosition}
\]

A total book duration must never be passed to a chapter-relative seek calculation.

### INV-5 — Fast properties invalidate only direct readers

The 1 Hz `playhead` and 2 Hz `sleepRemaining` are tracked properties under Observation.

Views that do not read those properties must not invalidate because they changed.

### INV-6 — Navigation determines visibility

Miniplayer visibility is derived from:

- whether a playback session exists;
- whether Now Playing is presented;
- the selected tab;
- the selected tab's current top route, if the product rule still hides the miniplayer on the active playing-book page.

Visibility must not require `onAppear`/`onDisappear` callbacks to balance correctly.

### INV-7 — Observation bridges are state invalidation bridges

Observation-to-Combine or Observation-to-callback adapters:

- explicitly perform an initial refresh;
- re-arm after Observation invalidation;
- intentionally coalesce a batch of synchronous mutations;
- stop deterministically;
- do not observe `playhead`;
- do not emit after cancellation.

### INV-8 — Invalid media times never enter UI state

`playhead`, `playheadDuration`, seek targets, and progress ratios must be finite and nonnegative.

`NaN`, infinity, negative duration, and indefinite duration values are rejected or replaced with a valid fallback.

---

## 5. Hard constraints

### 5.1 Migration scope

Migrate only `PlaybackCoordinator` from `ObservableObject` to Observation.

The following remain `ObservableObject` and continue using `@EnvironmentObject` / `.environmentObject(...)`:

- `LibraryStore`
- `OfflineDownloadManager`
- `CatalogStore`
- `HomeRecommendationStore`
- `PlaylistStore`
- `MiniPlayerPresentationRouter`
- any other store not explicitly named in this plan

Mixed environment injection is intentional.

### 5.2 Router ownership

Keep root router ownership as:

```swift
@StateObject private var miniPlayerRouter = MiniPlayerPresentationRouter()
```

Keep router injection as:

```swift
.environmentObject(miniPlayerRouter)
```

The router is not a fast-changing object and is not part of the Observation migration.

### 5.3 Coordinator environment

Every view that reads `PlaybackCoordinator` must use:

```swift
@Environment(PlaybackCoordinator.self)
```

Every app, sheet, popover, cover, or separately rooted subtree that reinjects the coordinator must use:

```swift
.environment(playback)
```

or:

```swift
.environment(services.playbackCoordinator)
```

A missed injection is a runtime fatal when that subtree is presented.

### 5.4 Existing user behavior

Preserve existing catalog-import call sites such as:

```swift
await playback.present(imported)
showingNowPlaying = true
```

The declaration and injection mechanism changes; the presentation behavior does not.

### 5.5 Source-text tests

The repository contains grep-style source tests. Do not blindly preserve a gate that pins defective implementation detail.

Rules:

- Never delete a gate solely to pass CI.
- Preserve gates that encode still-valid wiring or product requirements.
- Replace implementation-string gates with equal or stronger behavioral tests when the implementation itself is being corrected.
- A gate requiring `visiblePushedBookID != currentBookID` must not block route-derived visibility. Replace it with behavioral visibility tests.
- Keep the router ownership/injection gate.
- Keep catalog-import and artwork-presentation call-site gates.
- Update coordinator, DI, scrubber, CarPlay, navigation, and Observation gates to encode the final invariants.

### 5.6 Build commands

Use:

```bash
xcodegen generate
xcodebuild test \
  -scheme Voxglass \
  -destination 'platform=iOS Simulator,name=iPhone 15'
```

If `iPhone 15` is unavailable, enumerate installed simulators and use an available iOS 17+ device. Record the actual destination in the PR description.

Do not bypass a failing test plan by changing schemes or excluding tests.

---

## 6. Commit plan

Land one PR with these ordered commits:

1. **S1 — Deterministic playback selection and immediate presentation**
2. **S2 — PlaybackCoordinator Observation migration**
3. **S3 — Coordinator dependency-injection migration**
4. **S4 — Progress isolation and scrubber extraction**
5. **S5 — CarPlay Observation bridges**
6. **S6 — Persistent tabs and route-derived miniplayer visibility**

Each commit must build and pass the tests applicable at that point.

---

# S1 — Deterministic playback selection and immediate presentation

## Goal

Fix the user-visible selection failure before changing the observation mechanism.

After S1:

- selection immediately creates a visible session;
- the coordinator exposes `.preparing`;
- a newer request cancels and supersedes an older request;
- cancellation does not show an error;
- stale continuations cannot publish state;
- repeated taps on the same preparing selection do not start duplicate loads.

## Files

Primary:

- `Voxglass/Core/Playback/PlaybackCoordinator.swift`
- playback phase/error model file, either existing or new
- existing audio-engine protocol and fake engine
- playback coordinator tests
- book/chapter selection call sites only if needed to establish one task owner

## 6.1 Add playback phase

Add a UI-facing phase type in `VoxglassCore`:

```swift
public enum PlaybackPhase: Equatable, Sendable {
    case idle
    case preparing
    case paused
    case playing
    case failed(PlaybackFailure)
}
```

Use a small equatable failure value instead of storing arbitrary `Error`:

```swift
public struct PlaybackFailure: Equatable, Sendable {
    public let message: String
    public let isRetryable: Bool

    public init(message: String, isRetryable: Bool) {
        self.message = message
        self.isRetryable = isRetryable
    }
}
```

Add to the coordinator:

```swift
public private(set) var playbackPhase: PlaybackPhase = .idle
```

Under S1 it may temporarily remain `@Published`; S2 removes property wrappers.

Do not overload `currentSession?.isPlaying` to mean loading.

## 6.2 Establish one selection-task owner

Add implementation state:

```swift
private var selectionTask: Task<Void, Never>?
private var activeSelectionID: UUID?
```

These become `@ObservationIgnored` in S2.

Prefer a synchronous entry point that owns cancellation:

```swift
public func selectAndPlay(
    _ book: BookWithChapters,
    chapter requestedChapter: Chapter? = nil
) {
    if isPreparingSameSelection(book: book, chapter: requestedChapter) {
        return
    }

    selectionTask?.cancel()

    let requestID = UUID()
    activeSelectionID = requestID

    selectionTask = Task { [weak self] in
        await self?.performSelection(
            book,
            chapter: requestedChapter,
            requestID: requestID
        )
    }
}
```

If preserving the current `async play(...)` API is necessary for many call sites, it may remain, but it must internally enforce cancellation and latest-request-wins. Do not create an unowned nested task in both the view and coordinator.

Choose one model and apply it consistently.

## 6.3 Resolve enough state to present immediately

The selected book and requested/default chapter should be resolved before the expensive engine load.

If saved position lookup is asynchronous, choose one of these acceptable patterns:

### Preferred pattern

1. Resolve a chapter synchronously from the passed `BookWithChapters`.
2. Publish a preparing session at position `0` or a synchronously available saved value.
3. Load saved position asynchronously.
4. If the request is still active, update the committed start position before loading or seeking the engine.

### Acceptable pattern

If position lookup is known to be fast, actor-based, and nonblocking:

1. begin request;
2. await position lookup;
3. verify request token;
4. publish session;
5. begin engine load.

Even in this pattern, session publication must occur before engine loading.

The miniplayer must not wait for `engine.load`.

## 6.4 Publish preparing state

Before calling `engine.load`:

```swift
currentSession = PlaybackSession(
    book: book.book,
    chapters: book.chapters,
    chapter: target.chapter,
    position: target.startTime,
    duration: validTime(target.chapter.duration),
    isPlaying: false
)

playhead = target.startTime
playheadDuration = validTime(target.chapter.duration)
playbackError = nil
playbackPhase = .preparing
```

If `playhead` is not introduced until S2, use an internal temporary field or introduce it now and migrate its wrapper in S2.

The miniplayer should render:

- book and chapter identity;
- preparing indicator;
- disabled or retry-appropriate controls.

## 6.5 Load with request-token checks

After every suspension:

```swift
guard !Task.isCancelled,
      activeSelectionID == requestID else {
    return
}
```

Required checkpoints include:

- after saved-position lookup;
- after URL or cache resolution if asynchronous;
- after `engine.load`;
- after engine play/pause commands if asynchronous;
- after artwork or metadata operations if they can suspend;
- before setting errors.

Do not let a stale request:

- overwrite `currentSession`;
- clear a newer error;
- display its own error;
- start playback;
- update playhead;
- update Now Playing identity.

## 6.6 Cancellation behavior

Cancellation is not a playback failure.

```swift
catch is CancellationError {
    return
}
```

If the engine exposes a cancellation method, stop or invalidate the stale prepare operation where safe.

When a newer request supersedes an older request, retain the newer request's preparing UI.

## 6.7 Successful completion

After a valid load completes:

```swift
guard activeSelectionID == requestID else { return }

isEngineLoaded = true
applyStoredRate(forBookID: book.book.id)
engine.play()

mutateSession {
    $0.isPlaying = true

    if let duration = validTime(engine.duration) {
        $0.duration = duration
    }
}

playhead = validTime(engine.currentTime) ?? target.startTime
playheadDuration =
    validTime(engine.duration) ??
    validTime(currentSession?.duration)

playbackPhase = .playing
startProgressLoop()
updateNowPlayingInfo()
schedulePrefetchAfterPresentation(...)
```

Do not schedule broad prefetch before the responsive state commit.

## 6.8 Failure behavior

On a non-cancellation failure for the active request:

- keep the selected session visible;
- set `isPlaying = false`;
- set `.failed(...)`;
- expose retry;
- do not clear the miniplayer automatically.

Example:

```swift
playbackError = failure.message
playbackPhase = .failed(failure)
```

A user should see which book failed and be able to retry.

## 6.9 Duplicate-tap protection

While `.preparing`, disable the same selection's Play action or make it idempotent.

A different book or chapter selection must supersede the current request.

## 6.10 Main-thread boundaries

The coordinator may remain `@MainActor`, but synchronous heavy work must not run on the main actor.

Audit the following for disk, database, image, cache, and AVAsset work:

- position lookup;
- cache lookup;
- `engine.load`;
- artwork resolution;
- prefetch URL construction and scheduling;
- persistence;
- Now Playing metadata generation.

Move heavy operations into existing actors/services. Do not use `Task.detached` merely to bypass isolation unless the transferred values are safe and the service design justifies it.

## S1 tests

Add:

```swift
testSessionAppearsBeforeEngineLoadCompletes
testPhaseIsPreparingWhileEngineLoadIsSuspended
testLatestSelectionWinsWhenEarlierLoadFinishesLast
testCancelledSelectionCannotPublishFailure
testRepeatedPlayOfSamePreparingSelectionDoesNotStartSecondLoad
testFailedLoadKeepsSelectedSessionVisible
testRetryUsesSelectedIdentity
testClearingPlaybackCancelsSelectionAndProgressTasks
```

The fake engine must support controlled suspension and completion of multiple loads.

---

# S2 — PlaybackCoordinator Observation migration

## Goal

Replace object-wide Combine invalidation with property-granular Observation while preserving S1 selection semantics.

## File

- `Voxglass/Core/Playback/PlaybackCoordinator.swift`
- new or existing Observation-specific tests

## 7.1 Class declaration

```swift
import Observation

@MainActor
@Observable
public final class PlaybackCoordinator {
```

Remove:

```swift
: ObservableObject
```

Remove `import Combine` only if no remaining symbol in this file requires it.

## 7.2 Remove `@Published`

Delete all `@Published` wrappers.

Tracked UI-facing state should include at least:

```swift
public private(set) var currentSession: PlaybackSession?
public private(set) var playbackPhase: PlaybackPhase = .idle
public private(set) var playbackError: String?
public private(set) var playbackRate: Float
public private(set) var sleepMode: SleepMode
public private(set) var sleepRemaining: TimeInterval?
public private(set) var sleepDisplayMinute: Int?
public private(set) var bookmarkCount: Int
public private(set) var playhead: TimeInterval = 0
public private(set) var playheadDuration: TimeInterval?
```

Use the project's actual types and defaults.

`sleepDisplayMinute` is optional but recommended for CarPlay or other coarse countdown consumers.

## 7.3 Explicit property classification

Do not use “when unsure, ignore it.”

Classify every stored property in a table in the implementation notes or PR description.

Mark implementation-only state `@ObservationIgnored`, including service references, tasks, caches, callbacks, and internal flags such as:

```swift
@ObservationIgnored private let engine: AudioEngine
@ObservationIgnored private let positionStore: PositionStore
@ObservationIgnored private let snapshotStore: SnapshotStore
@ObservationIgnored private let rateStore: RateStore
@ObservationIgnored private var sleepTimer: ...
@ObservationIgnored private var sleepTask: Task<Void, Never>?
@ObservationIgnored private var progressTask: Task<Void, Never>?
@ObservationIgnored private var engineLoadTask: Task<Void, Never>?
@ObservationIgnored private var selectionTask: Task<Void, Never>?
@ObservationIgnored private var activeSelectionID: UUID?
@ObservationIgnored private var listenedAccumulator: ...
@ObservationIgnored private var lastListenTick: ...
@ObservationIgnored private var lastPeriodicSave: ...
@ObservationIgnored private var isHandlingInterruption = false
@ObservationIgnored private var isEngineLoaded = false
@ObservationIgnored private var currentArtworkBookID: ...
@ObservationIgnored private var artworkProvider: ...
@ObservationIgnored private var bridge: ...
@ObservationIgnored private var onTasteSignal: ...
```

Track a property if it is directly rendered or is a dependency of a rendered computed property that must invalidate automatically.

## 7.4 Time validation helper

Add a helper:

```swift
private func validTime(_ value: TimeInterval?) -> TimeInterval? {
    guard let value,
          value.isFinite,
          value >= 0 else {
        return nil
    }

    return value
}
```

Use it before publishing:

- `playhead`;
- `playheadDuration`;
- engine duration;
- restored position;
- seek target;
- total duration inputs.

## 7.5 Material duration comparison

Avoid exact floating-point comparison.

```swift
private func materiallyDifferent(
    _ lhs: TimeInterval?,
    _ rhs: TimeInterval?,
    tolerance: TimeInterval = 0.25
) -> Bool {
    switch (lhs, rhs) {
    case let (lhs?, rhs?):
        return abs(lhs - rhs) > tolerance
    case (nil, nil):
        return false
    default:
        return true
    }
}
```

Use this before mutating session duration.

## 7.6 Rewrite `tickProgress()`

Make it internal for direct tests if necessary:

```swift
func tickProgress() async {
    guard let session = currentSession else { return }

    accumulateListening()

    let livePosition =
        validTime(engine.currentTime) ??
        validTime(session.position) ??
        0

    let engineDuration = validTime(engine.duration)
    let liveDuration =
        engineDuration ??
        validTime(session.duration)

    if playhead != livePosition {
        playhead = livePosition
    }

    if playheadDuration != liveDuration {
        playheadDuration = liveDuration
    }

    let liveIsPlaying = engine.isPlaying
    let durationChanged = materiallyDifferent(
        validTime(session.duration),
        engineDuration
    )

    if session.isPlaying != liveIsPlaying || durationChanged {
        mutateSession {
            $0.isPlaying = liveIsPlaying

            if let engineDuration {
                $0.duration = engineDuration
            }
        }

        playbackPhase = liveIsPlaying ? .playing : .paused
    }

    saveCurrentSnapshotIfNeeded()

    if engine.isPlaying,
       Date().timeIntervalSince(lastPeriodicSave) >= 5 {
        await persistCurrentPosition(reason: .periodic)
    }

    updateNowPlayingInfoIfNeeded()
}
```

Required properties:

- no periodic `currentSession.position` assignment;
- no session mutation for insignificant duration jitter;
- invalid times never enter tracked state.

## 7.7 Tick-side work audit

Observation does not make persistence and media metadata free.

Audit:

```swift
saveCurrentSnapshotIfNeeded()
persistCurrentPosition(reason:)
updateNowPlayingInfoIfNeeded()
```

Required changes:

- avoid writes when position has not materially changed;
- keep durable persistence at an explicit interval and lifecycle transitions;
- avoid rebuilding Now Playing dictionaries when identity, elapsed-time anchor, rate, and state are unchanged;
- let the media system extrapolate elapsed time from elapsed position plus playback rate where supported;
- keep synchronous main-actor tick work small.

## 7.8 Seek semantics

Publish the optimistic playhead before suspension:

```swift
public func seek(to position: TimeInterval) async {
    guard let session = currentSession else { return }

    let duration =
        validTime(playheadDuration) ??
        validTime(engine.duration) ??
        validTime(session.duration)

    let clamped = PlaybackMath.clampedPosition(
        validTime(position) ?? 0,
        duration: duration
    )

    playhead = clamped
    playheadDuration = duration

    if isEngineLoaded {
        await engine.seek(to: clamped)
    }

    mutateSession {
        $0.position = clamped
    }

    await persistCurrentPosition(reason: .seek)
    updateNowPlayingInfoIfNeeded(force: true)
}
```

An explicit seek may commit `currentSession.position`. The periodic tick may not.

## 7.9 Relative skip reads

Update every relative-position operation to use:

```swift
let base =
    isEngineLoaded
    ? (validTime(engine.currentTime) ?? session.position)
    : session.position
```

At minimum:

- `skip(by:)`;
- `skipToPreviousChapter()`;
- any bookmark, sleep, chapter, or remote-command operation based on “current position.”

Do not change a chapter-start position that is deliberately stored as a committed offset.

## 7.10 Reset behavior

On complete clear:

```swift
playhead = 0
playheadDuration = nil
playbackPhase = .idle
```

On paused presentation or restoration:

```swift
playhead = restoredPosition
playheadDuration = restoredDuration
playbackPhase = .paused
```

Do not reset a restored paused presentation to zero.

## 7.11 Sleep display bucketing

Keep `sleepRemaining` for the direct countdown view.

If CarPlay needs a countdown value, update a coarse property only when its displayed unit changes:

```swift
private func updateSleepDisplayMinute() {
    sleepDisplayMinute = sleepRemaining.map {
        Int(ceil(max($0, 0) / 60))
    }
}
```

A 2 Hz timer may mutate `sleepRemaining`; it must not cause a 2 Hz CarPlay bridge.

## S2 tests

Add:

```swift
testTickDrivesPlayheadNotSessionPosition
testTickReconcilesPlayPauseTransition
testTickDoesNotRepublishSessionForDurationJitter
testTickRejectsNaNDuration
testSkipUsesEngineTimeWhileLoaded
testSeekPublishesOptimisticPlayheadBeforeEngineCompletes
testPausedPresentationRestoresPlayheadInsteadOfZero
testPlayheadMutationDoesNotInvalidateCurrentSessionReader
testCurrentSessionMutationInvalidatesCurrentSessionReader
testSleepRemainingMutationDoesNotInvalidateUnrelatedReader
```

Observation dependency tests should use `withObservationTracking`.

Remember that Observation invalidation callbacks are one-shot and may coalesce synchronous mutation batches.

---

# S3 — Coordinator dependency-injection migration

## Goal

Replace all coordinator `EnvironmentObject` declarations and injections with Observation environment injection, while leaving every other store and the router unchanged.

## 8.1 Declarations

Convert:

```swift
@EnvironmentObject private var playback: PlaybackCoordinator
```

to:

```swift
@Environment(PlaybackCoordinator.self) private var playback
```

Search the entire repository rather than trusting stale line numbers.

Expected files include, but may not be limited to:

- `RootView.swift`
- `SettingsView.swift`
- `DiscoverView.swift`
- `SearchView.swift`
- `BookPageOverflowSheet.swift`
- `BookmarksView.swift`
- `BookPageActionRow.swift`
- `EQView.swift`
- `MiniPlayerView.swift`
- `CatalogDiscoveryView.swift`
- `BookPageView.swift`
- `BookRelatedViews.swift`
- `PlaylistsView.swift`
- `GlassDock.swift`
- `ListenView.swift`

Use symbol search and grep after modification.

## 8.2 Injections

Convert coordinator injection:

```swift
.environmentObject(playback)
```

to:

```swift
.environment(playback)
```

Convert:

```swift
.environmentObject(services.playbackCoordinator)
```

to:

```swift
.environment(services.playbackCoordinator)
```

Search all:

- app roots;
- sheets;
- full-screen covers;
- popovers;
- preview roots;
- test host views;
- separately constructed destination roots.

Known likely files include:

- `VoxglassApp.swift`
- `RootView.swift`
- `SettingsView.swift`
- `BookPageOverflowSheet.swift`
- `BookPageView.swift`

Do not change router injection.

## 8.3 Previews

Every preview that renders a coordinator-dependent view must inject a coordinator with `.environment(...)`.

Do not suppress preview crashes by making the environment optional.

## 8.4 Runtime smoke coverage

Add host/UI smoke coverage that presents all separately scoped coordinator consumers:

- Now Playing;
- book page;
- book overflow sheet;
- EQ;
- settings playback controls;
- bookmarks;
- playlist detail;
- catalog import followed by paused presentation.

The test should fail if any view lacks the coordinator environment.

## 8.5 DI grep gates

Add repository-wide gates:

- no line containing both `@EnvironmentObject` and `PlaybackCoordinator`;
- no `.environmentObject(playback)`;
- no `.environmentObject(services.playbackCoordinator)`;
- coordinator views contain `@Environment(PlaybackCoordinator.self)`;
- router ownership and `.environmentObject(miniPlayerRouter)` remain.

Do not use grep gates as a substitute for runtime presentation tests.

---

# S4 — Progress isolation and scrubber extraction

## Goal

Ensure the large book page does not read the 1 Hz playhead. Move all live chapter-progress rendering and scrubbing state into a small leaf.

## Files

- new `Voxglass/Features/Player/ScrubberView.swift`
- `BookPageView.swift`
- related progress math helpers/tests

## 9.1 Explicit scrubber units

Use names that encode units:

```swift
struct ScrubberView: View {
    @Environment(PlaybackCoordinator.self) private var playback

    let isActiveBook: Bool
    let chapterFallbackPosition: TimeInterval
    let chapterFallbackDuration: TimeInterval
    let elapsedBeforeChapter: TimeInterval
    let totalBookDuration: TimeInterval?
    let onSeekChapterPosition: (TimeInterval) -> Void

    @State private var isScrubbing = false
    @State private var scrubPosition: TimeInterval = 0
}
```

Never pass `resolved.totalDuration` as `chapterFallbackDuration`.

## 9.2 Derived live values

```swift
private var liveChapterPosition: TimeInterval {
    if isActiveBook {
        return playback.playhead
    }

    return chapterFallbackPosition
}

private var liveChapterDuration: TimeInterval {
    if isActiveBook,
       let duration = playback.playheadDuration,
       duration.isFinite,
       duration > 0 {
        return duration
    }

    if chapterFallbackDuration.isFinite,
       chapterFallbackDuration > 0 {
        return chapterFallbackDuration
    }

    return 1
}
```

## 9.3 Body calculations

Inside the leaf:

```swift
let chapterPosition =
    isScrubbing
    ? scrubPosition
    : liveChapterPosition

let chapterDuration = liveChapterDuration

let chapterProgress = min(
    max(chapterPosition / chapterDuration, 0),
    1
)

let bookElapsed =
    elapsedBeforeChapter + chapterPosition

let bookRemaining = totalBookDuration.map {
    max($0 - bookElapsed, 0)
}
```

Validate all values before using them in width, offset, gesture, or text calculations.

## 9.4 Drag behavior

Lift the existing visual markup and gesture behavior, but enforce optimistic seek ordering.

On drag change:

```swift
isScrubbing = true
scrubPosition = target
```

On drag end:

```swift
let target = scrubPosition
playback.setOptimisticPlayhead(target)
onSeekChapterPosition(target)
isScrubbing = false
```

Alternatively, call an async coordinator seek method that sets `playhead` synchronously before its first suspension.

The bar must not snap back to a stale tick after drag end.

## 9.5 Parent inputs

In `BookPageView`, calculate static/identity-changing inputs only.

For the active session:

- chapter fallback position: committed `session.position`;
- chapter fallback duration: `session.chapter.duration ?? session.duration ?? 1`;
- elapsed before chapter: precomputed or calculated from chapter identity;
- total book duration: session or resolved book total.

For an inactive book page:

- resolve the persisted chapter identity;
- use that chapter's saved chapter-relative position;
- use that chapter's duration;
- calculate elapsed before that persisted chapter.

Do not assume `progressByBook.lastPosition` is chapter-relative unless the persistence model guarantees it.

If it is book-relative, convert it to chapter plus chapter-relative offset before passing it to the scrubber.

## 9.6 Precompute chapter offsets

Prefer adding a helper or session field that avoids repeated linear scans:

```swift
public var elapsedBeforeCurrentChapter: TimeInterval
```

or:

```swift
public let chapterOffsets: [TimeInterval]
```

If changing the model is too invasive, calculate the value only when the chapter identity changes, not on every body evaluation.

## 9.7 Remove parent clock coupling

Delete from `BookPageView`:

- parent `@State` used only for live scrub position;
- `.onChange(of: playback.currentSession?.position)` used as a tick mirror;
- `onAppear` assignment that initializes live scrub position from a periodically mutated session;
- any read of `playback.playhead`;
- any read of `playback.playheadDuration`.

Only `ScrubberView` may read the fast clock.

## 9.8 Mini player progress

If the miniplayer has a progress bar:

- either move it into its own leaf reading `playhead`;
- or keep the miniplayer identity-only in this PR.

Do not make the full `GlassDock` or root read `playhead`.

## S4 tests

Add:

```swift
testChapterScrubberUsesChapterDurationNotBookDuration
testFiftyPercentDragSeeksToHalfOfChapter
testBookRemainingIncludesElapsedPriorChapters
testInactiveBookUsesPersistedChapterRelativePosition
testInvalidDurationFallsBackWithoutNaNProgress
testDragEndDoesNotSnapBackBeforeSeekCompletes
```

Add source gates:

- `BookPageView.swift` references `ScrubberView`;
- `BookPageView.swift` contains no `playback.playhead`;
- old `currentSession?.position` tick-mirroring block is absent;
- `ScrubberView.swift` contains the playhead reads.

---

# S5 — CarPlay Observation bridges

## Goal

Restore CarPlay update triggers after removing Combine publishing from the coordinator, without observing fast playback clocks.

## Files

- new Observation adapter file under CarPlay
- `CarPlayNowPlayingConfigurator.swift`
- `CarPlayInterfaceController.swift`
- adapter tests

## 10.1 Adapter semantics

Create a small main-actor adapter. Prefer a callback adapter for direct consumers and a publisher adapter only where an existing Merge pipeline requires Combine.

Example callback adapter:

```swift
import Observation

@MainActor
final class ObservationSubscription {
    private var cancelled = false
    private let track: () -> Void
    private let onChange: () -> Void

    init(
        track: @escaping () -> Void,
        onChange: @escaping () -> Void
    ) {
        self.track = track
        self.onChange = onChange
        arm()
    }

    private func arm() {
        guard !cancelled else { return }

        withObservationTracking {
            track()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.cancelled else { return }

                self.onChange()
                self.arm()
            }
        }
    }

    func cancel() {
        cancelled = true
    }

    deinit {
        cancelled = true
    }
}
```

Document:

- callback timing is Observation invalidation timing;
- the next main-actor turn reads fresh values;
- a synchronous mutation batch may coalesce into one callback;
- this is a state-invalidated signal, not an event-count stream.

## 10.2 Publisher adapter

If `CarPlayInterfaceController` must merge this with existing Combine publishers, provide a small publisher bridge with explicit ownership.

Do not introduce unsafe captures or detached tasks. The implementation must compile cleanly under the project's concurrency settings.

A single adapter type is also acceptable if ownership is simple and tested.

## 10.3 Now Playing configurator

Replace `objectWillChange.sink`.

Perform an explicit initial:

```swift
apply()
```

Track only properties actually needed for control configuration, such as:

```swift
_ = coordinator.currentSession?.book.id
_ = coordinator.currentSession?.chapter.id
_ = coordinator.currentSession?.isPlaying
_ = coordinator.playbackRate
_ = coordinator.sleepMode
_ = coordinator.sleepDisplayMinute
_ = coordinator.bookmarkCount
```

Do not track:

- `playhead`;
- `playheadDuration`;
- raw 2 Hz `sleepRemaining`, unless a reviewed CarPlay UI truly displays seconds.

If `bookmarkCount` is not needed, omit it.

Keep or improve the existing config equality/deduplication guard.

Cancel the adapter in deterministic teardown.

## 10.4 Interface controller

Replace `$currentSession` with an Observation-derived trigger tracking session identity:

```swift
_ = coordinator.currentSession?.book.id
_ = coordinator.currentSession?.chapter.id
```

Include play/pause only if template structure changes because of it.

Merge that trigger with the existing six store publishers.

Preserve:

- existing `removeDuplicates`;
- existing debounce;
- existing store triggers;
- current threading guarantees.

After installing the subscriptions, explicitly refresh the templates so a preexisting session is represented immediately on CarPlay connect.

In `stop()`:

```swift
coordinatorSignal?.cancel()
coordinatorSignal = nil
```

Verify no re-arm task survives disconnect.

## 10.5 Strict concurrency

Do not add:

- `@unchecked Sendable`;
- unsafe global state;
- detached tasks;

merely to silence warnings.

The final build must introduce no new Swift concurrency warnings.

## S5 tests

Add:

```swift
testObservationSubscriptionEmitsAfterTrackedMutation
testObservationSubscriptionRearmsAfterFirstInvalidation
testObservationSubscriptionCoalescesSynchronousMutationBatch
testObservationSubscriptionStopsAfterCancel
testUntrackedPropertyDoesNotEmit
testCarPlaySignalDoesNotTrackPlayhead
testCarPlaySignalUsesCoarseSleepState
testInterfaceControllerPerformsInitialRefresh
testStopPreventsFurtherRefresh
```

Where immediate mutation counts matter, await an actor turn between mutations.

---

# S6 — Persistent tabs and route-derived miniplayer visibility

## Goal

Replace lifecycle-derived visibility with deterministic navigation state and preserve each tab's stack across ordinary tab switching.

## Files

Likely:

- `RootView.swift`
- tab/root navigation model files
- `MiniPlayerPresentationRouter.swift`
- tab destination builders
- navigation and miniplayer tests

## 11.1 Product rule

Choose and encode one rule.

### Recommended rule

Show the miniplayer whenever:

- a playback session exists;
- Now Playing is not presented.

This is the most reliable global playback model and does not need current book-page suppression.

### Alternative rule

If product design requires hiding the miniplayer while the selected tab is displaying the currently playing book page, visibility must be route-derived.

Do not preserve lifecycle registration as the authority.

This plan assumes the alternative rule because it retains current behavior, but the coding agent should prefer the recommended simpler rule if the product owner approves it before implementation.

## 11.2 Explicit routes

Define route identity:

```swift
enum AppRoute: Hashable {
    case book(Book.ID)
    // existing additional routes
}
```

Each tab must own a stable path:

```swift
@State private var listenPath = NavigationPath()
@State private var libraryPath = NavigationPath()
@State private var discoverPath = NavigationPath()
@State private var searchPath = NavigationPath()
@State private var playlistsPath = NavigationPath()
```

Use the actual tab list.

A shared observable navigation model is acceptable if it simplifies route inspection.

## 11.3 TabView

Replace root `switch`-based tab subtree replacement with:

```swift
TabView(selection: $selectedTab) {
    listenRoot
        .tag(VoxglassTab.listen)

    libraryRoot
        .tag(VoxglassTab.library)

    discoverRoot
        .tag(VoxglassTab.discover)

    searchRoot
        .tag(VoxglassTab.search)

    playlistsRoot
        .tag(VoxglassTab.playlists)
}
```

Each root owns or receives its tab-specific navigation-path binding.

Keep:

- custom `GlassDock`;
- custom tab controls;
- Now Playing sheet at the same logical root level;
- router `@StateObject` and `.environmentObject(miniPlayerRouter)` if the router remains for sheet state.

Hide the system tab bar using the least invasive supported method and verify safe-area behavior.

Do not use a global `UITabBar.appearance()` change if `.toolbar(.hidden, for: .tabBar)` works correctly across supported versions.

## 11.4 Route-derived visible book

For the selected tab, derive its top book route:

```swift
var selectedTabTopBookID: Book.ID? {
    switch selectedTab {
    case .listen:
        return topBookID(in: listenPath)
    case .library:
        return topBookID(in: libraryPath)
    case .discover:
        return topBookID(in: discoverPath)
    case .search:
        return topBookID(in: searchPath)
    case .playlists:
        return topBookID(in: playlistsPath)
    }
}
```

If `NavigationPath` type erasure makes inspection awkward, store typed route arrays:

```swift
@State private var libraryPath: [AppRoute] = []
```

Prefer typed paths for testability.

## 11.5 Final visibility function

Recommended simple rule:

```swift
func shouldShowMiniPlayer(currentBookID: Book.ID?) -> Bool {
    currentBookID != nil && !isNowPlayingPresented
}
```

Route-preserving rule:

```swift
func shouldShowMiniPlayer(
    currentBookID: Book.ID?,
    visibleBookID: Book.ID?
) -> Bool {
    guard let currentBookID,
          !isNowPlayingPresented else {
        return false
    }

    return visibleBookID != currentBookID
}
```

The caller supplies route-derived `visibleBookID`.

Do not mutate `visiblePushedBookID` from view lifecycle callbacks.

## 11.6 Router cleanup

The router may continue to own:

- `isNowPlayingPresented`;
- presentation binding helpers.

Remove or deprecate lifecycle registration APIs if no longer used:

- `register`;
- `unregister`;
- `forceClearPushedBookPage`;
- `visiblePushedBookID`.

If source-gate compatibility requires a staged removal, leave deprecated forwarding methods temporarily but ensure they do not determine final visibility. Remove them in the same PR if practical.

Do not add a blind tab-change clear as the final structural fix.

## 11.7 Book page lifecycle

Remove miniplayer visibility registration from:

- `.task(id:)`;
- `.onAppear`;
- `.onDisappear`.

Book page lifecycle must not control global chrome truth.

## 11.8 Tab preservation tests

Test:

- navigation path for each tab remains unchanged after switching away and back;
- top route is correctly derived for the selected tab;
- a playing book detail hides or shows the miniplayer according to the chosen product rule;
- switching to another tab updates visibility immediately;
- returning to a retained book page gives correct visibility without relying on `onAppear`;
- presenting and dismissing Now Playing hides then restores miniplayer correctly;
- no stale state from another tab suppresses miniplayer.

## 11.9 Geometry and accessibility verification

Manually and, where possible, automatically verify:

- bottom safe area;
- home-indicator spacing;
- custom dock height;
- keyboard presentation;
- landscape;
- iPad;
- VoiceOver order and tab semantics;
- sheets and detents;
- iOS 17;
- newer OS appearance behavior.

---

## 12. Source-text gate plan

### Preserve

Keep gates that confirm:

- root owns router with `@StateObject`;
- root injects router via `.environmentObject(miniPlayerRouter)`;
- remote catalog imports still call `await playback.present(imported)`;
- presentation call sites still set `showingNowPlaying = true`;
- required artwork/layout behavior remains.

### Replace

Replace gates pinning:

```swift
visiblePushedBookID != currentBookID
```

with behavioral tests for route-derived visibility.

This is a strengthening, not a weakening, because the old gate preserves the mechanism responsible for the latch.

### Add

Coordinator gates:

- contains `@Observable`;
- contains `import Observation`;
- does not contain `: ObservableObject`;
- does not contain `@Published`;
- implementation state contains `@ObservationIgnored`;
- `tickProgress` writes `playhead`;
- `tickProgress` does not periodically assign `currentSession.position`.

DI gates:

- no coordinator `@EnvironmentObject`;
- no coordinator `.environmentObject(...)`;
- expected views use `@Environment(PlaybackCoordinator.self)`.

Scrubber gates:

- `BookPageView` references `ScrubberView`;
- `BookPageView` does not read `playhead`;
- `ScrubberView` reads `playhead`;
- no total-book duration is passed as chapter duration.

CarPlay gates:

- configurator contains no `objectWillChange`;
- interface controller contains no `$currentSession`;
- both reference the Observation adapter;
- stop path cancels and releases the adapter;
- no CarPlay tracking closure reads `playhead`.

Navigation gates:

- `RootView` uses `TabView(selection:)`;
- typed tab paths or equivalent stable path ownership exist;
- book page lifecycle does not register miniplayer visibility;
- visibility is supplied selected-tab route state.

---

## 13. Instrumentation

Add `OSSignposter` instrumentation around:

```text
Playback.Select
Playback.ResolvePosition
Playback.PublishPreparingSession
Playback.EngineLoad
Playback.FirstAudio
Playback.Seek
Playback.Tick
Playback.PersistPosition
Playback.SaveSnapshot
Playback.UpdateNowPlaying
Playback.SchedulePrefetch
Chrome.ResolveMiniPlayerVisibility
CarPlay.ApplyConfiguration
CarPlay.RefreshTemplates
```

Do not leave personally identifying book metadata in signpost names.

## Performance targets

Treat these as engineering targets measured on a representative physical device:

\[
P95(T_{\text{tap→preparing presentation}}) < 100\text{ ms}
\]

Preferred:

\[
P95(T_{\text{tap→preparing presentation}}) < 50\text{ ms}
\]

Main-thread synchronous selection work:

\[
P95 < 16\text{ ms}
\]

Periodic main-thread tick work:

\[
P95 < 4\text{ ms}
\]

For an already-known remote URL on a normal connection:

\[
P95(T_{\text{tap→audio}}) < 1.5\text{ s}
\]

Audio startup is a separate metric from visual presentation.

---

## 14. Verification matrix

### Automated

- `xcodegen generate`
- full `xcodebuild test`
- new coordinator behavior tests
- Observation dependency tests
- scrubber math tests
- DI smoke tests
- CarPlay adapter tests
- route/miniplayer behavior tests
- existing regression tests
- grep/source invariant tests

### Manual playback

Test each from a cold launch and warm state:

1. Tap Play on a local book.
2. Tap Play on a remote book.
3. Select a chapter while another chapter is loading.
4. Rapidly select Book A, Book B, then Book C.
5. Cancel or supersede a slow load.
6. Simulate load failure, then retry.
7. Seek while paused.
8. Seek while playing.
9. Skip forward/back while loaded.
10. Previous chapter behavior at more than and less than the restart threshold.
11. Restore a paused session after relaunch.
12. Clear playback.

Expected:

- immediate preparing miniplayer;
- no stale selection takeover;
- no error from cancellation;
- no scrubber snapback;
- correct chapter-relative seeks.

### Manual SwiftUI invalidation

Using Instruments SwiftUI View Body:

During steady playback:

- `ScrubberView` increments approximately at the playback tick rate;
- root tab views remain flat unless their own state changes;
- `GlassDock` identity container remains flat unless session identity or play/pause state changes;
- inactive tabs remain flat.

During sleep timer:

- countdown view increments at countdown rate;
- unrelated views remain flat;
- CarPlay configuration does not run at 2 Hz unless an explicitly approved seconds-level display requires it.

### Manual navigation

- navigate deeply in each tab;
- switch among tabs;
- confirm paths and ordinary scroll positions remain;
- play a book;
- open its detail;
- switch tabs;
- return;
- present/dismiss Now Playing;
- verify miniplayer according to chosen product rule at every step.

### CarPlay

Required release gate:

- connect;
- verify initial templates with a preexisting session;
- select a session;
- play/pause;
- change playback rate;
- start/cancel sleep timer;
- change chapter;
- disconnect;
- mutate coordinator after disconnect;
- verify no further CarPlay refresh or runaway re-arm task.

If CI cannot exercise CarPlay, record a manual CarPlay simulator/external-display or head-unit run in the PR.

---

## 15. Definition of Done

- [ ] S1–S6 exist as separate ordered commits and are not squashed.
- [ ] Each commit builds and its applicable tests pass.
- [ ] Playback session appears before engine load completes.
- [ ] Latest request wins under controlled out-of-order fake-engine completion.
- [ ] Cancellation never presents a playback error.
- [ ] `PlaybackCoordinator` uses `@Observable`.
- [ ] No `@Published` remains in `PlaybackCoordinator`.
- [ ] All implementation-only coordinator state is explicitly classified.
- [ ] Steady tick does not assign `currentSession.position`.
- [ ] Invalid media times are filtered.
- [ ] Duration jitter does not repeatedly republish session state.
- [ ] Every coordinator consumer uses Observation environment injection.
- [ ] Runtime presentation smoke tests cover separately scoped sheets.
- [ ] `BookPageView` does not read `playhead`.
- [ ] Scrubber uses chapter-relative duration and position.
- [ ] Drag end does not snap backward while seek completes.
- [ ] CarPlay does not observe the 1 Hz playhead.
- [ ] CarPlay does not observe raw 2 Hz sleep countdown without an approved requirement.
- [ ] Observation bridges perform initial refresh and deterministic teardown.
- [ ] Root uses persistent `TabView` children with explicit per-tab paths.
- [ ] Miniplayer visibility is route-derived or simplified to global visibility.
- [ ] No miniplayer truth depends on balanced book-page lifecycle callbacks.
- [ ] Instruments verifies expected body invalidation isolation.
- [ ] Performance signposts meet or materially approach the targets.
- [ ] Manual playback, navigation, and CarPlay matrices pass.
- [ ] No source gate is deleted or weakened without a stronger replacement.
- [ ] INV-0 through INV-8 hold.

---

## 16. Agent execution rules

1. Read the current implementation before editing; line numbers in prior audits are anchors only.
2. Re-locate every target by symbol.
3. Run repository-wide searches before and after DI and CarPlay changes.
4. Do not assume the listed file count is exact if the branch has moved.
5. Keep each commit focused on its named concern.
6. Add tests in the same commit as the behavior they protect.
7. Do not defer failing tests to a later commit unless the intermediate commit cannot reasonably be made buildable; prefer buildable commits.
8. Do not silence concurrency warnings with unsafe annotations.
9. Do not move synchronous heavy work to the main actor.
10. Do not use source grep tests to preserve known-bad behavior.
11. Record any product decision about miniplayer visibility in the PR description.
12. Stop and document any unexpected persistence-unit ambiguity before changing progress math. Determine whether saved positions are chapter-relative or book-relative from code and tests, then encode the answer in tests.
13. Preserve public API compatibility where practical, but correctness takes precedence for internal APIs.
14. After every commit:
    - generate the project;
    - build;
    - run targeted tests;
    - inspect the diff for accidental store migrations or environment changes.
15. Before final handoff, run the full verification matrix and include measured signpost results.

---

## 17. PR description template

### Summary

Makes playback selection immediately visible and deterministic, migrates `PlaybackCoordinator` to property-granular Observation, isolates fast progress rendering, rebuilds CarPlay observation bridges, and derives miniplayer visibility from persistent tab navigation state.

### User-visible fixes

- Miniplayer appears while audio is preparing.
- Rapid selections no longer race or revert to an older book.
- Playback and sleep clocks no longer re-render unrelated tab roots.
- Miniplayer no longer remains hidden because of a missed lifecycle callback.
- Tab navigation and scroll state survive ordinary tab switches.

### Risk areas

- playback request cancellation;
- restored-position units;
- Observation environment completeness;
- CarPlay adapter re-arming and teardown;
- custom dock geometry after `TabView`;
- route-derived visibility behavior.

### Validation evidence

Include:

- full test command and result;
- targeted test names;
- Instruments View Body screenshots or counts;
- tap-to-presentation and tick signpost measurements;
- CarPlay run environment and result;
- manual navigation matrix result.

### Commit sequence

1. S1 Deterministic playback selection
2. S2 Observation migration
3. S3 DI migration
4. S4 Scrubber isolation
5. S5 CarPlay bridges
6. S6 Persistent tabs and route-derived visibility
