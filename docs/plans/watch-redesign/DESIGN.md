# Voxglass Watch — redesign spec

Status: design, not implemented. Mockups: [`mockups/index.html`](mockups/index.html), which are normative for
hierarchy, sizes, copy and states (not pixel-exact). This replaces the watch UI described in
[`docs/WATCH_APP_PLAN.md`](../../WATCH_APP_PLAN.md) and `docs/mockups/watch-app.html`. The sync, download and protocol
design stays as it is.

It shares the **Watch Listening Kit** (§3) with Platterhead (`parso-tonearm/docs/plans/watch-redesign/DESIGN.md`).
Only the accent colour and the audiobook-specific controls differ, so fixes and polish port between the two apps.

**Device rule from CLAUDE.md:** verify on the physical watch, never a simulator, unless the owner asks.

## 1. What's wrong today (code review + owner device report, 2026-09-30)

| # | Problem | Where |
|---|---|---|
| 1 | Chapters never play: "Playback stalled", 0:00, with AirPods connected. `a1af8a6` shows the full reason; root cause still open | `WatchPlaybackEngine.swift` |
| 2 | The player is a scrolling `List`: transport sits between metadata and chapters and scrolls away; 44 pt glyph buttons with no shape | `WatchBookDetailView.swift` |
| 3 | Prev/next are *chapter* jumps; there's no 15/30 s skip, no speed, no sleep timer, which are the core audiobook controls | `WatchBookDetailView.transportRow`, `installRemoteCommands` |
| 4 | Failures are one red caption line plus a text "Retry"; every AVFoundation/OSStatus error becomes "Connect Bluetooth headphones" | `statusText`, `audioErrorMessage` |
| 5 | The current book is reachable only through a small waveform toolbar icon; the library is plain text rows with no cover or progress | `WatchRootView`, `WatchLibraryView` |
| 6 | Connection state is a toast that pops in and disappears after 2.5 s; streaming vs downloaded is invisible while playing | `WatchLibraryView.connectionToast` |
| 7 | Downloads have a spinner but no progress, no reason when waiting, and no stop | `WatchBookRow` |

## 2. Principles

1. **Raise wrist, keep listening.** Home leads with the current book; one tap resumes.
2. **One fixed player face** made for spoken audio. Crown = volume. Nothing on it scrolls.
3. **Time over tracks.** Skip 15/30 s, chapter times, "left in book" at the current speed, and a sleep timer.
4. **Honest states.** "Playing" only after audio is confirmed; every failure is a Problem Card with its code;
   streaming is labelled.
5. **Everything automatic is visible and stoppable** (downloads, streaming, sleep timer).

## 3. Watch Listening Kit (shared with Platterhead)

Same components and contracts as Platterhead's spec §3. Put them in `VoxglassWatch/Kit/`:
`NowPlayingScaffold`, `TransportButton`, `TargetChip` (here: the output name, plus "streaming" when
`sourceKind == .stream`), `ProgressHairline`, `ProblemCard`, `ActionPill`, `StatusChip`, `ArtTile` (book covers use
a 3:4 `cover` variant), `TransferRing`, `HomeHero`.

**Tokens.** Accent gold `#D8AD67` (matches `--gold` in `docs/mockups/_shared.css`), text `#F7F0E6`, muted
`#B9AFA4`, on black. Success, warn and bad as in Platterhead. Use semantic fonts only.

**Voxglass-specific transport.** Side buttons are `gobackward.15` and `goforward.30`, 44 pt. The toolbar has four
`ToolButton`s: Chapters (`list.bullet`), Speed (text label = current rate, e.g. "1.2×"), Sleep (`moon`, accent
when armed), Output (`airplay.audio`, opens the system route picker).

## 4. Information architecture

```
Home (NavigationStack root, inset-grouped List)
├─ HomeHero (current book) ─▶ Player
├─ Library rows (cover · title · progress/location) ─▶ Player if current, else Book page
└─ Footer: StatusChip · Downloads · About
Player ── toolbar: Chapters · Speed · Sleep · Output
Book page ── Resume/Start (primary) · Chapters · Download state
```

- Remove the `waveform` toolbar shortcut in `WatchRootView`; the hero replaces it, and the a11y id
  `watch.nowPlaying` moves to the hero.
- Split `WatchBookDetailView` into `WatchPlayerView` (current book) and `WatchBookPageView` (any other book).
  The original reason for merging them was "pressing Play opened a second screen that needed a second tap". The
  split keeps that fix: the Book page's primary button starts playback *and* pushes the Player in one tap.

## 5. Screens

IDs match the mockup. Keep existing identifiers where the role survives: `watch.library`, `watch.book.<id>`,
`watch.book.title`, `watch.book.play`, `watch.book.elapsed`, `watch.book.remaining`,
`watch.book.remainingInBook`, `watch.book.retry` (now on the Problem Card's primary pill), `watch.book.download`,
`watch.book.remove`, `watch.chapter.<id>`, `watch.connection` (now on the StatusChip),
`watch.empty.downloads`. The ids `watch.book.previousChapter` and `watch.book.nextChapter` move to chapter-list
actions; update `VoxglassWatchUITests` in the same commit and keep equivalent assertions.

- **H1 Home hero.** Cover 34×46, title, "Ch N · Xh Ym left" (at the current speed), hairline, 34 pt play. Hidden
  when no book has ever been opened.
- **H2 Library.** Sorted by last listened. Status line: "N% · on watch" / "Not started · iPhone" /
  "Downloading N%" with `TransferRing`.
- **H3 Empty.** Primary pill opens the iPhone app on its book list (universal link via `WKApplication`), keeping
  the instruction text.
- **P1–P3 Player.** Title = chapter title; subtitle = book title. Times are chapter times; tapping them toggles to
  "Xh Ym left in book". P3 labels streaming in the chip.
- **C1 Chapters.** Scrolled to the current chapter (`ScrollViewReader`). ✓ finished, ring for current, dot for
  upcoming; dimmed with a reason if not playable. Tapping starts playback and pops back to the Player.
- **C2 Speed.** A large numeral, Crown 0.5–3.0× in 0.05 steps, detent haptic at each 0.25, presets 1× and 1.5×.
  Engine: `player.rate` (or `defaultRate` on watchOS 26) plus `audioTimePitchAlgorithm = .spectral`. Persist per
  book alongside `WatchPlaybackPositionStore`. Publish `snapshot.rate`, already read by `updateNowPlaying`.
- **C3 Sleep.** End of Chapter / 15 / 30 / Off. A 10 s volume fade, pause, save position. A chip on the Player and
  in Always On while armed. Cancel from the same list.
- **B1/B2 Book page.** Cover 40×54, title, author, narrator. Primary pill names the action precisely: "Resume ·
  Ch 3 · 0:51", "Start", or "Download · 412 MB" when not downloaded. Secondary: Chapters, the download state
  (opens Remove + size), and "Stream Chapter 1" only while connected.
- **S1–S3 Problem Cards.** S1 stalled/failed shows the code (`stalled-<status>-<reason>`, the same format as
  Platterhead). S2 no output appears only when `session.activate` throws or returns false; split
  `audioErrorMessage` so other errors go to S1 with their code. S3 is the next chapter missing with no phone: stop
  at the boundary with this card, never "Buffering…".
- **D1 Downloads.** Active first with a specific waiting reason (needs the phone's transfer status; add
  `waitingReason` to the protocol if absent), Pause/Stop, then the storage bar.
- **A1 Always On.** `isLuminanceReduced`: hide transport and toolbar; show "N min left in chapter" updated per
  minute; keep the sleep chip.
- **A2 Smart Stack.** "Continue listening" `.accessoryRectangular` widget with a resume App Intent.
- **A3 Accessibility.** At AX sizes: drop the book title and times, keep transport and toolbar sizes. VoiceOver
  value on the hairline: "11 minutes 2 seconds of 23 minutes 32". Adjustable action skips 15/30 (it currently uses
  15/15).

**Remote commands (`installRemoteCommands`).** Add `skipBackwardCommand` (15) and `skipForwardCommand` (30) with
`preferredIntervals`, and disable `nextTrackCommand`/`previousTrackCommand`, so AirPods double/triple-press skip
time instead of chapters. Add `changePlaybackRateCommand` with the supported rates.

**Resume rewind.** If more than 5 minutes have passed since the last pause, resume 5 s earlier.

## 6. Build order (one commit each, on `main`)

0. **Audio root cause first.** With `a1af8a6` on the watch, read the full "Playback stalled (…)" reason and fix the
   stall. The redesign is pointless while chapters are silent.
1. Kit components (`VoxglassWatch/Kit/`), with previews.
2. Player face on the scaffold (P1, P3), 15/30 skip, remote commands, S1/S2 Problem Cards, the
   `audioErrorMessage` split.
3. Split Player / Book page (B1, B2); Home hero and library rows (H1–H3); drop the toolbar shortcut and the toast
   (StatusChip).
4. Chapters list (C1).
5. Speed (C2), with per-book persistence and engine tests.
6. Sleep timer (C3), with engine tests for the fade and the end-of-chapter trigger.
7. Downloads screen (D1) and the boundary state S3.
8. Always On (A1), accessibility pass (A3).
9. Smart Stack widget (A2).

Each commit: the pre-commit hook (`swift test`); build `VoxglassWatch` for `generic/platform=watchOS` with
`CODE_SIGNING_ALLOWED=NO`. Engine logic (speed, sleep, skip, resume rewind) goes in `VoxglassWatchCore`,
reducer-style like `WatchPlaybackReducer`, so it's host-tested.

## 7. Acceptance (owner checks on the physical watch)

- From a wrist raise, the current book resumes through AirPods in one tap, and you hear it.
- AirPods double-press skips 30 s forward; triple-press skips 15 s back.
- At 1.5×, "left in book" shrinks accordingly; speed survives relaunch for that book.
- "End of Chapter" sleep fades and stops at the boundary, with the position saved.
- Walking away from the phone mid-book with the next chapter not downloaded ends on S3, not a spinner.
- Every failure shows a card with a code; none show a pause icon while silent.
