# Decisions

**D1 — Opus via Ogg→CAF remux, fetch-complete-then-play.**
AVFoundation won't demux Ogg; Opus-in-CAF plays natively (verified in
parso-pdaudio). The resource loader serves original bytes by range and CAF's
mandatory `pakt` table is unknowable until the full Ogg scan, so progressive
remux through `parsocache` is infeasible. Rejected: libopus/FFmpeg decode
(new C dependency, standalone constraint), synthesized-CAF resource loader
(length/pakt unknowable).

**D2 — "Opus when ready" selection policy.**
Cold taps stream FLAC (Wi-Fi) or MP3 (cellular) instantly via the existing
path; the prefetcher completes+remuxes Opus so transitions and repeat plays
upgrade. Rejected: blocking cold start on Opus fetch (adds seconds of
latency); background re-fetch upgrade after an MP3 play (doubles data).

**D3 — FLAC ships through the existing parsocache path, first.**
Native AVPlayer FLAC + existing `org.xiph.flac` mapping means selector work
only. Highest value per line of code; ships before any Opus code.

**D4 — Near-gapless now; sample-accurate gapless deferred.**
Preloaded `AVQueuePlayer` item swap gets transitions to inaudible-for-most-
material without touching the proven AVPlayer + resource-loader stack.
Sample-accurate requires an AVAudioEngine playback path — a separate,
larger plan, and the natural moment to revisit shared-engine extraction.

**D5 — One-time $9.99 Pro; no subscription.**
No recurring costs exist (no server, no accounts); the audience is
subscription-averse (Doppler's $9 one-time model and its reviews are the
market evidence). Gates are conveniences (cache presets, prefetch depth,
folder watch, EQ, CarPlay); identity features stay free and CI-pinned.

**D6 — Standalone: no parso-audio-engine.**
All new components live under `ParsoRadio/Core/Services/` (Playback/Opus,
Playback/EQ, Pro). The `AudioEffectChain`-style protocol abstraction is
dropped from scope; if extraction happens later it happens then.

**D7 — Free prefetch stays at depth 1.**
It powers both near-gapless and Opus-when-ready, i.e. free-tier identity
quality. Pro sells depth, not the mechanism.

**D8 — Entitlement gating uses the private-init pattern.**
`ProEntitlement` constructible only from a verified StoreKit transaction;
single `ProFeature.isEnabled` surface; CI-linted StoreKit import boundary.
Same discipline as the workout app's evidence-gated `Prescription` type.

## Deviations (2026-07-10)

**DEV1 — Voxglass architecture (not ParsoRadio).**
Implementation is in `parso-voxglass` repo using Voxglass's simpler
`AVPlayerAudioEngine` architecture (no custom resource loader, no
`ContiguousFileCache`, no `parsocache://` scheme). All playback goes through
direct `AVPlayerItem(url:)` URLs. The plan's references to
`CachingResourceLoaderDelegate`, `ContiguousFileCache`, and
`MP3AudioFormatSelector` are guidance only — the implementation uses
Voxglass's existing `InternetArchiveAudioSelector` and
`AVPlayerAudioEngine`.

**DEV2 — FLAC streams directly, no UTI mapping needed.**
T1.2 "FLAC through parsocache" is implemented as extension addition to
`InternetArchiveAudioSelector.playableAudioExtensions`. Since Voxglass uses
plain AVPlayer (not AVAssetResourceLoader), AVFoundation handles FLAC UTI
automatically. No `CachingResourceLoaderDelegate` UTI mapping is needed.

**DEV3 — Opus cache uses standalone URLSession download.**
Instead of `ContiguousFileCache` (which doesn't exist in Voxglass),
`OpusCacheService` downloads the full Ogg file via `URLSession.download`,
then remuxes to CAF. The CAF is served as a local `file://` URL via the
existing `Chapter.localURL` path. This is semantically equivalent to the
plan's "fetch-complete → remux → local file" pipeline.

**DEV4 — File paths use Voxglass module conventions.**
All new components live under `Voxglass/Core/Services/` instead of
`ParsoRadio/Core/Services/`. Subdirectories: `Playback/`, `Playback/Opus/`,
`Playback/EQ/`, `Pro/`, `Download/`.

**DEV5 — EQ sample rate set to 44100 Hz.**
EQEngine uses a fixed 44100 Hz sample rate for biquad coefficient
calculation. This matches typical audio content but may need per-format
adjustment if 48000 Hz FLAC or Opus content is common.

## Deviations (2026-07-12 — Pro features completion)

**DEV6 — CarPlay and Apple Watch removed from the Pro set.**
D5 listed `carplay` (and the paywall listed Apple Watch) as gates, but neither
has any implementation. `ProFeature.carplay` and `ProFeature.appleWatch` are
removed from the enum and the paywall; both are now documented in the README
as **Planned (not yet available)** roadmap items rather than shipped Pro
features. The Pro set is now: `cachePresets, prefetchDepth, folderWatch, eq,
icloudSync, listeningStats, offlineDownloads`.

**DEV7 — Offline Downloads is advertised.**
`OfflineDownloadManager` was fully implemented but absent from the paywall.
It is now the top advertised Pro feature. A registry-drift test
(`ProPaywallContentTests`) ties the paywall catalog, the `ProFeature` enum, and
the free-tier registry together so any future feature add/remove must update
all three.

**DEV8 — Listening events are logged for all users; only viewing is gated.**
`PlaybackCoordinator` records wall-clock listened seconds into a local
`listening_events` table regardless of entitlement (migration id 4). This is
strictly on-device, no telemetry, and keeps lifetime totals/continuity intact
if a user upgrades later. The *viewing* of Listening Stats is gated behind
`ProFeature.listeningStats`. `ON DELETE SET NULL` on `book_id` preserves totals
after a book is removed.

**DEV9 — iCloud entitlement is committed, not toggled by hand.**
`Voxglass/Resources/Voxglass.entitlements` (ubiquity-kvstore identifier) is
committed and wired via `project.yml`. On-device KVS still requires a real
signing team; simulator/CI tests use the `EntitlementCache` test seam plus a
file-presence check rather than live iCloud.

**DEV10 — Standardized Pro lock affordance.**
`ProLockBadge` + the `.proLocked(_:id:onTapLocked:)` view modifier in
`VoxglassComponents.swift` render a uniform `lock.fill` badge, attach a stable
`accessibilityIdentifier` (`pro.lock.*`), and present the paywall on tap for
every gated touchpoint. `EntitlementCache` gains `#if DEBUG` seams
(`setTestEntitlement`, and `-VoxglassForcePro` / `-VoxglassForceFreeTier`
launch arguments) for deterministic unit and UI tests.
