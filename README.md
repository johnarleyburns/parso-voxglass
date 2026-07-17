# Voxglass

A privacy-first iOS audiobook player for the public-domain **LibriVox** catalog, sourced through the
**Internet Archive** (`archive.org`). No accounts, no tracking, no analytics — nothing you listen to
leaves your device (content is fetched from archive.org, and cross-device sync, when enabled, uses your
own iCloud).

## Highlights

- Stream or download the full LibriVox catalog (70,000+ public-domain audiobooks) sourced through the
  Internet Archive. Multi-format audio: FLAC, Opus, Vorbis, MP3.
- **Never lose your place**: resume at the exact chapter and offset across restart, force-quit, crash,
  upgrade, delete-and-reinstall, and a second device. Positions persist redundantly (SQLite +
  UserDefaults snapshots) and sync free via your private iCloud — identity is content-keyed, so a
  re-imported book keeps its position.
- **Variable playback speed** (0.5×–3.5× with per-book memory), **sleep timer** (fixed durations,
  end-of-chapter, fade-out), **bookmarks** with notes, **lock-screen & Control Center artwork**,
  per-chapter narrator display, customizable skip intervals, volume normalization, and skip silence.
- On-device library with playback positions, favorites, playlists, recently-played history, and
  filter/sort (SQLite, no account).
- **Personalized recommendations, cached locally**: the "Recommended for You" shelf is built on-device
  from your listening history and persisted, so it appears instantly on cold launch — even offline —
  and never flashes back to generic popular titles. An animated launch splash hands off cleanly to
  the app.
- **Dark-mode-first design** with Dynamic Type support. No ads, no telemetry, no tracking — nothing
  you listen to leaves your device.
- One-time **Voxglass Pro** unlock ($7.99, StoreKit 2, Family Sharing supported) for unlimited offline
  downloads, bookmarks & favorites sync, Folder Watch, 10-band EQ, listening stats, library
  backup & restore, bigger streaming cache presets (2 GB / 10 GB), and whole-book prefetch.

## Competitive position

The LibriVox catalog on iOS is effectively owned by one competitor: **LibriVox Audiobooks** (BookDesign
LLC, 4.8★ / 32K ratings), free with ads or a **subscription** — $1.99/mo, $9.99/yr, or $24.99 lifetime —
that buys ad removal only. Recent reviews are dominated by complaints about an unnavigable redesign,
broken speed control, missing narrator names, and ads with volume spikes. A newer entrant, **Lex Reader**
(MWM, $9.99/mo premium), offers free synchronized text+audio over LibriVox but lacks CarPlay and player
depth — synchronized read-along is Voxglass's named v1.1 differentiator
(see `docs/RELEASE_READINESS.md`).

**Voxglass's free tier already beats BookDesign's paid tier** — speed, sleep timer, bookmarks,
lock-screen artwork, per-chapter narrators, volume normalization, skip silence, playlists, favorites,
position sync across devices, CarPlay, the full catalog, and no ads at all. Pro adds unlimited offline
downloads, bookmarks & favorites sync, Folder Watch, 10-band EQ, listening stats, library backup &
restore, bigger streaming cache presets, and whole-book prefetch — all for a one-time purchase.

The opening is: *the same catalog in a player that respects you*.

## Roadmap

### Shipped
- [x] Variable playback speed, sleep timer, bookmarks, lock-screen/Control Center artwork (P0 table stakes).
- [x] Customizable skip intervals, library sort/filter, playlists (P1 parity).
- [x] Volume normalization, Dynamic Type support (P2 differentiation).
- [x] Offline downloads with free-tier taste limit, 10-band EQ, Folder Watch, listening stats,
      library backup & restore, bookmarks & favorites sync (Pro features).
- [x] One-time Pro unlock with paywall, Family Sharing, App Store compliance.
- [x] **Resume reliability** (`docs/RELEASE_PLAN.md`): resume at the right chapter and offset from every
      entry point, crash/force-quit durability, content-keyed identity, free position sync — the app
      never loses your place.
- [x] **CarPlay** — free and standalone: search, browse, resume, and play entirely from the car, no
      phone needed. Not a Pro feature; the Pro price did not change. Design in
      [`docs/CARPLAY_DESIGN.md`](docs/CARPLAY_DESIGN.md).

### Future (not yet planned)

- **Skip silence** device-sign-off (the toggle is built but not released).
- **Apple Watch app** — browse your library and control playback from your wrist.
- **Widgets, Siri & App Shortcuts** — needs an app-group entitlement and relocated SQLite database.
- **Localization** — the UI is English-only today (catalog already supports 15 languages).
- **Narrator-centric discovery, Project Gutenberg read-along** — longer-term differentiators unique to
  public-domain content.

## Current focus

The pre-release plan is tracked in [`docs/RELEASE_PLAN.md`](docs/RELEASE_PLAN.md). The competitive gap
plan in [`docs/COMPETITIVE_GAP_PLAN.md`](docs/COMPETITIVE_GAP_PLAN.md) is substantially complete.

## Manual regression testing (recommended before every release)

Most logic is covered headlessly by `swift test` (see `scripts/test.sh`), and a single
XCUITest smoke confirms the app boots. But the **playback platform surface** — lock-screen
Now Playing, Control-Center / headphone remote controls, audio interruptions, and
background/terminate position saves — can only be verified on a **real device**, because it
runs against MediaPlayer / AVAudioSession / UIKit, which the simulator and host tests do not
exercise faithfully. Run this script on a physical device (e.g. a TestFlight build) after any
change to playback, the audio engine, or the Now Playing / remote-command bridge.

**Setup:** install the build on a real iPhone. Import at least one book with more than one
chapter and a cover image. Use wired or Bluetooth headphones for the remote-control steps.

### 1. Core playback
1. Open a book → tap Play. **Expect:** audio starts; the mini-player and Now Playing screen show the correct title, author, and chapter.
2. Tap Pause, then Play. **Expect:** audio stops and resumes from the same spot.
3. Drag the scrubber to a new position. **Expect:** audio jumps there; the elapsed/remaining times update.
4. Tap skip-forward and skip-back. **Expect:** position moves by the configured intervals (default +30s / −15s).
5. Tap next-chapter, then previous-chapter. **Expect:** playback moves between chapters; tapping previous within the first ~8s of a chapter goes to the prior chapter, otherwise it restarts the current one.

### 2. Speed, sleep timer, bookmarks, EQ
6. Change playback speed (e.g. 1.5×). **Expect:** audio speeds up; the speed persists when you reopen the book.
7. Set a sleep timer for "1 minute" and for "End of chapter". **Expect:** at 1 minute, audio fades out and pauses; "End of chapter" pauses at the chapter boundary without rolling into the next chapter.
8. Add a bookmark, move elsewhere, then jump to the bookmark. **Expect:** playback returns to the bookmarked position (loading a different chapter if needed).
9. (Pro) Open the EQ, engage it, and change a band / apply a preset. **Expect:** the sound changes; the setting persists across relaunch.

### 3. Lock screen & remote controls (bridge — the critical part)
10. Start playback, lock the phone. **Expect:** the lock screen shows the chapter title, book title, author, **cover artwork**, and a scrubber that advances at the correct rate.
11. From the lock screen / Control Center, tap play/pause, skip-forward, skip-back, next/previous track, and drag the scrubber. **Expect:** each control drives the app correctly and the Now Playing info stays in sync.
12. With headphones, use the inline play/pause and skip buttons. **Expect:** they control playback.
13. Change the skip interval in Settings, then use the lock-screen skip. **Expect:** the new interval is used.

### 4. Interruptions & background durability (bridge)
14. While playing, receive a phone call (or trigger Siri). **Expect:** audio pauses; when the call/Siri ends, audio resumes.
15. While playing, unplug/disconnect headphones. **Expect:** audio pauses (does not blast from the speaker).
16. Play for ~30s, note the position, send the app to the background, then force-quit it. Relaunch. **Expect:** the app restores the same book/chapter at (approximately) the same position — no lost progress.
17. Delete the currently-playing book. **Expect:** playback stops cleanly and the book does not resurface on the next launch.

If every step passes, the playback bridge is behaving. Any failure in sections 3–4 points at the
`SystemPlaybackBridge` / Now Playing / remote-command wiring, not the core playback logic.

## License

GPLv3 — see `LICENSE`. App Store distribution is permitted under the Additional Permission
in `LICENSE-APPSTORE-EXCEPTION.md`.

## iCloud Sync setup (for developers)

Cross-device sync uses `NSUbiquitousKeyValueStore`. Playback-position sync is free for everyone;
bookmarks & favorites sync requires Voxglass Pro. The required **iCloud key-value-store** capability is
committed as `Voxglass/Resources/Voxglass.entitlements` and wired
through `project.yml` under `settings.base` — so it is attached in **all** configurations, Release and
TestFlight included. The App Store provisioning profile now carries the iCloud capability; no manual
capability toggling is needed for development, simulator, unit-test, or archive builds.

Without the entitlement, `NSUbiquitousKeyValueStore.synchronize()` is a no-op and sync will not function
even if Pro is unlocked — so if you fork this project under a different App ID, enable **iCloud →
Key-value storage** for your App ID in the Apple Developer portal and regenerate your provisioning profile.
