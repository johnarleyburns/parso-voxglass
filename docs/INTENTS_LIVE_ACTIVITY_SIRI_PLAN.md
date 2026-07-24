# Voxglass — App Intents, Live Activity & Siri Plan

**Mockups:** [`docs/mockups/intents-live-activity-siri.html`](mockups/intents-live-activity-siri.html) — lock screen,
Dynamic Island, Siri, Shortcuts/Spotlight/Action button, widgets and Control Center.

## Context

Voxglass already publishes to the system playback surfaces: `SystemPlaybackBridge` feeds
`MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`, and `NowPlayingArtworkTests` guards the artwork path. That gives
lock-screen controls, but it gives nothing else:

- No **Live Activity** — no persistent lock-screen card with book progress, time left, sleep-timer countdown, or a
  configurable skip interval; no Dynamic Island.
- No **App Intents** — Voxglass is invisible to Shortcuts, the Action button, Spotlight, widgets and Control Center.
- No **Siri** — "resume my audiobook" does nothing.

For an audiobook app these are not garnish. The two most common listening moments — starting the car and putting the phone
down at night — are exactly where a Siri phrase or a lock-screen sleep-timer button removes the whole unlock-find-tap dance.

**Intended outcome:** every playback action Voxglass supports is reachable without opening the app, through one shared
intent layer, with no second notion of "where you were".

---

## Design principle

> Every surface mutates playback **only** through App Intents, and every intent goes through `PlaybackCoordinator` +
> `PositionStore`.

Widgets and controls run out of process; a Live Activity button that tried to touch the database directly would create a
second, divergent position writer. This is the failure mode `docs/RELEASE_PLAN.md` is built to prevent, so:

- Playback-mutating intents conform to **`AudioPlaybackIntent`** (iOS 17+), which runs the intent in the *app* process and
  is allowed to start audio.
- Live-Activity buttons conform to **`LiveActivityIntent`**.
- Read-only/setup intents (download a book, list books) are ordinary `AppIntent`s.

---

## Part 1 — The intent layer

New group `Voxglass/Features/Intents/`:

| File | Type | Notes |
|---|---|---|
| `BookEntity.swift` | `AppEntity` + `EntityQuery` | Wraps `BookWithChapters`; `DisplayRepresentation` = title / author / "6h 12m left". Query is backed by `LibraryRepository`, giving Siri disambiguation and Spotlight indexing for free. |
| `ResumeListeningIntent.swift` | `AudioPlaybackIntent` | No parameters. Resolves the most recent book through the same path launch-restore uses, then `playback.play(book, chapter:)` at the stored offset. `openAppWhenRun = false`. |
| `PlayBookIntent.swift` | `AudioPlaybackIntent` | Parameter: `BookEntity`. Optional `chapter` parameter. |
| `TogglePlaybackIntent.swift` | `AudioPlaybackIntent` | Wraps `playback.togglePlayPause()`. |
| `SkipIntent.swift` | `AudioPlaybackIntent` | Parameter: direction. Uses the user's configured `AppPreferencesStore.Keys.skipBackInterval` / `skipForwardInterval`, so it matches the buttons. |
| `NextChapterIntent` / `PreviousChapterIntent` | `AudioPlaybackIntent` | `skipToNextChapter()` / `skipToPreviousChapter()`. |
| `SetSleepTimerIntent.swift` | `AppIntent` | Parameter: enum mirroring `SleepTimer.Mode` (5/10/15/30/45/60/end of chapter/off). Returns dialog "Sleep timer set for 20 minutes." |
| `SetPlaybackRateIntent.swift` | `AppIntent` | Parameter: `Double` clamped to `PlaybackRate.menuLadder`. |
| `AddBookmarkIntent.swift` | `AppIntent` | `playback.addBookmark()`, returns the formatted timestamp. |
| `DownloadBookIntent.swift` | `AppIntent` | Parameter: `BookEntity`. Calls `OfflineDownloadManager.makeAvailableOffline`; surfaces the cellular decision as an intent confirmation instead of a dialog. |
| `VoxglassShortcuts.swift` | `AppShortcutsProvider` | Phrases below. |

### Siri phrases

```
"Resume my audiobook with ${applicationName}"
"Play \(.$book) on ${applicationName}"
"Set a ${applicationName} sleep timer for \(.$duration)"
"Bookmark this in ${applicationName}"
"Speed up ${applicationName}" / "Slow down ${applicationName}"
"What am I listening to on ${applicationName}"
```

Each has a spoken `IntentDialog` result so it works from AirPods, HomePod and CarPlay without a screen.

### Wiring into the app process

`AppServices` (`Voxglass/App/AppServices.swift`) already owns the singleton `PlaybackCoordinator`. Intents reach it through
a small `@MainActor enum IntentBridge` that vends `AppServices.shared.playback` / `.libraryStore`, so an intent that fires
while the app is suspended wakes the app process and lands on the *same* coordinator instance the UI uses.

---

## Part 2 — Live Activity and Dynamic Island

New target `VoxglassWidgets` (widget extension) in `project.yml`, plus shared source
`Voxglass/Features/Intents/BookActivityAttributes.swift`:

```swift
struct BookActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var chapterTitle: String
        var position: TimeInterval
        var chapterDuration: TimeInterval
        var bookRemaining: TimeInterval?
        var isPlaying: Bool
        var rate: Float
        var sleepRemaining: TimeInterval?
    }
    let bookID: UUID
    let title: String
    let author: String
    let narrator: String?
    let coverURL: URL?
}
```

**Lock screen (mockup 1):** cover, brand line, title, "chapter · narrator", sleep countdown in the corner, progress bar,
`17:43 / 6h 12m left in book / -22:17`, and four buttons — ↺15, ⏯, ↻30, ☾. Skip labels come from the user's configured
intervals via `SkipSymbol`.

**Dynamic Island (mockup 2):**
- *compact leading* — cover thumbnail; *compact trailing* — waveform, static when paused
- *minimal* — brass waveform glyph
- *expanded* — cover, title, chapter, narrator + rate, route button, progress, and the full five-button transport

**Update policy** — this is where Live Activities usually go wrong:
- Push a `ContentState` update on: play/pause, chapter change, seek, rate change, sleep-timer set/fire.
- **Do not** update on the 1 Hz progress tick. Use `ProgressView(timerInterval:)` so the bar animates itself between
  updates, and refresh at most every 30 s while playing.
- End the activity when playback stops or after 8 hours idle; `staleDate` = expected chapter end.

Start/stop lives in one place, `PlaybackCoordinator`'s existing session lifecycle, behind a `LiveActivityController`
injected the same way `listeningStatsStore` and `bookmarkStore` already are — so Core stays free of ActivityKit.

---

## Part 3 — Widgets, controls, Spotlight, Action button

- **Home Screen widgets** — small "current book" (cover, chapter, time left, progress, ↺15 + ⏯ via `LiveActivityIntent`
  buttons) and medium "Continue" (last three books, tap a cover to resume).
- **Lock Screen widgets** — circular progress ring, rectangular title + time left, inline "6h 12m left in The Hobbit".
- **Control Center controls** (iOS 18+, `ControlWidget`) — Resume Listening, Sleep Timer, Speed, Bookmark.
- **Action button** — works automatically once `ResumeListeningIntent` is an App Shortcut.
- **Spotlight** — falls out of `BookEntity` + `EntityQuery`; searching a book title offers "Resume chapter 5".
- **Interaction with CarPlay** — none of this changes `CarPlayActionDispatcher`; both layers call the same coordinator.

---

## Implementation order

1. **P0** — `BookEntity`, `ResumeListeningIntent`, `TogglePlaybackIntent`, `SkipIntent`, `AppShortcutsProvider`.
   Ship-able on its own: Siri, Shortcuts, Spotlight and the Action button all light up.
2. **P1** — `VoxglassWidgets` target + `BookActivityAttributes` + lock-screen Live Activity + Dynamic Island.
3. **P2** — `SetSleepTimerIntent`, `SetPlaybackRateIntent`, `AddBookmarkIntent`, `NextChapter`/`PreviousChapter`,
   and their buttons on the Live Activity.
4. **P3** — Home/Lock Screen widgets, then Control Center controls.
5. **P4** — `DownloadBookIntent`, "What am I listening to", Handoff/`NSUserActivity` continuity with the watch app.

### `project.yml` additions

- `VoxglassWidgets` target: `type: app-extension`, `platform: iOS`, deployment 17.0, bundle id
  `guru.parso.voxglass.widgets`, dependencies `VoxglassCore` + `WidgetKit` + `ActivityKit` + `AppIntents`, embedded in
  `Voxglass`.
- `Voxglass` Info.plist: `NSSupportsLiveActivities: true`, `NSSupportsLiveActivitiesFrequentUpdates: false`.
- App group `group.guru.parso.voxglass` so the widget can read cached artwork written by `ArtworkService`.

---

## Tests

CI is Linux/source-level (no simulator), so assert what can be asserted there, in
`VoxglassTests/IntentLayerTests.swift`:

1. **Single-writer guard** — no file under `Voxglass/Features/Intents` or the widget target contains `SQLitePositionStore`,
   `AppDatabase(`, or `PositionStore(`; every playback mutation string in those files is one of the known
   `PlaybackCoordinator` method names. This is the test that stops the divergent-position regression.
2. `AudioPlaybackIntent` conformance — every intent that calls `play`/`togglePlayPause`/`skip` declares
   `AudioPlaybackIntent` and `openAppWhenRun = false`.
3. Skip intents read `AppPreferencesStore.Keys.skipBackInterval` / `skipForwardInterval` rather than hardcoding 15/30.
4. Sleep-timer intent options are exactly `SleepTimer.Mode`'s ladder; rate options are exactly `PlaybackRate.menuLadder`.
5. Live Activity update sites are limited — the source contains no `Activity.update` inside the 1 Hz progress path.

## Verification

1. `swift test`, then build the `Voxglass` scheme with the widget extension embedded.
2. Device walk:
   - "Hey Siri, resume my audiobook" with the phone locked → audio starts at the exact saved offset, spoken confirmation,
     app never opens.
   - Lock screen shows the Live Activity; ↺15 and ⏯ respond in under 300 ms without unlocking; the sleep-timer button
     sets 15 min and the countdown ticks down in the corner.
   - Long-press the Dynamic Island → expanded view; the progress bar advances smoothly between updates.
   - Add "Resume Listening" to the Action button → press-and-hold from locked resumes.
   - Spotlight "hobbit" → Voxglass row resumes chapter 5.
   - Control Center → Sleep Timer control sets the timer while another app is foreground.
   - Plug into CarPlay while a Live Activity is running → no duplicate sessions, no position jump.
3. Battery/thermal sanity: one hour of playback with a Live Activity should not measurably change the baseline.
