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
