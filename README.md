# Voxglass

A privacy-first iOS audiobook player for the public-domain **LibriVox** catalog, sourced through the
**Internet Archive** (`archive.org`). No accounts, no tracking, no analytics — nothing you listen to
leaves your device (content is fetched from archive.org, and cross-device sync, when enabled, uses your
own iCloud).

## Highlights

- Stream or download the full LibriVox catalog (70,000+ public-domain audiobooks) sourced through the
  Internet Archive. Multi-format audio: FLAC, Opus, Vorbis, MP3.
- **Variable playback speed** (0.5×–3.5× with per-book memory), **sleep timer** (fixed durations,
  end-of-chapter, fade-out), **bookmarks** with notes, **lock-screen & Control Center artwork**,
  per-chapter narrator display, customizable skip intervals, volume normalization, and skip silence.
- On-device library with playback positions, favorites, playlists, recently-played history, and
  filter/sort (SQLite, no account).
- **Dark-mode-first design** with Dynamic Type support. No ads, no telemetry, no tracking — nothing
  you listen to leaves your device.
- One-time **Voxglass Pro** unlock ($7.99, StoreKit 2, Family Sharing supported) for unlimited offline
  downloads, iCloud sync, Folder Watch, 10-band EQ, listening stats, and library backup & restore.

## Competitive position

The LibriVox catalog on iOS is effectively owned by one competitor: **LibriVox Audiobooks** (BookDesign
LLC, 4.8★ / 32K ratings), free with ads or $4.99 one-time ad-free. Recent reviews are dominated by
complaints about an unnavigable redesign, broken speed control, missing narrator names, and ads with
volume spikes.

**Voxglass's free tier already beats their paid tier** — speed, sleep timer, bookmarks, lock-screen
artwork, per-chapter narrators, volume normalization, skip silence, playlists, favorites, the full
catalog, and no ads at all. Pro adds unlimited offline downloads, iCloud sync, Folder Watch, 10-band EQ,
listening stats, and library backup & restore — all for a one-time purchase.

The opening is: *the same catalog in a player that respects you*.

## Roadmap

### Shipped
- [x] Variable playback speed, sleep timer, bookmarks, lock-screen/Control Center artwork (P0 table stakes).
- [x] Customizable skip intervals, library sort/filter, playlists (P1 parity).
- [x] Volume normalization, Dynamic Type support (P2 differentiation).
- [x] Offline downloads with free-tier taste limit, iCloud sync, 10-band EQ, Folder Watch, listening stats,
      library backup & restore (Pro features).
- [x] One-time Pro unlock with paywall, Family Sharing, App Store compliance.

### Near-term
- [ ] **CarPlay** — the single biggest remaining gap versus BookDesign. Blocked on Apple granting the
      `com.apple.developer.carplay-audio` entitlement. $9.99 Pro price point when it ships.

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

## License

GPLv3 — see `LICENSE`. App Store distribution is permitted under the Additional Permission
in `LICENSE-APPSTORE-EXCEPTION.md`.

## iCloud Sync setup (for developers)

Cross-device sync via iCloud (requires Voxglass Pro) uses `NSUbiquitousKeyValueStore`. The required
**iCloud key-value-store** capability is committed as `Voxglass/Resources/Voxglass.entitlements` and wired
through `project.yml` under `settings.base` — so it is attached in **all** configurations, Release and
TestFlight included. The App Store provisioning profile now carries the iCloud capability; no manual
capability toggling is needed for development, simulator, unit-test, or archive builds.

Without the entitlement, `NSUbiquitousKeyValueStore.synchronize()` is a no-op and sync will not function
even if Pro is unlocked — so if you fork this project under a different App ID, enable **iCloud →
Key-value storage** for your App ID in the Apple Developer portal and regenerate your provisioning profile.
