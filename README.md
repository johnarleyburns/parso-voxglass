# Voxglass

A privacy-first iOS audiobook player for the public-domain **LibriVox** catalog, sourced through the
**Internet Archive** (`archive.org`). No accounts, no tracking, no analytics — nothing you listen to
leaves your device (content is fetched from archive.org, and cross-device sync, when enabled, uses your
own iCloud).

The shipped app targets iPhone and iPad, with Apple Watch and CarPlay companion surfaces. The main
application also builds as Mac Catalyst, and the repository now includes a separate native
`VoxglassMac` macOS app for the wide, keyboard-first narration workflow. Both Mac surfaces use the
same library, playback, narration packages, and iCloud identity; the old source remains available
only in Git history.

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
- Future monetization will come from audiobook sales and library partnership integrations —
  the app itself remains free, private, and ad-free.

## Competitive position

The LibriVox catalog on iOS is effectively owned by one competitor: **LibriVox Audiobooks** (BookDesign
LLC, 4.8★ / 32K ratings), free with ads or a **subscription** — $1.99/mo, $9.99/yr, or $24.99 lifetime —
that buys ad removal only. Recent reviews are dominated by complaints about an unnavigable redesign,
broken speed control, missing narrator names, and ads with volume spikes. A newer entrant, **Lex Reader**
(MWM, $9.99/mo premium), offers free synchronized text+audio over LibriVox but lacks CarPlay and player
depth — synchronized read-along is Voxglass's named v1.1 differentiator
(see `docs/RELEASE_READINESS.md`).

**Voxglass already beats BookDesign's paid tier** — speed, sleep timer, bookmarks,
lock-screen artwork, per-chapter narrators, volume normalization, skip silence, playlists, favorites,
position sync across devices, CarPlay, offline downloads, Folder Watch, 10-band EQ, listening stats,
library backup & restore, and the full catalog — all free, no ads at all. Future monetization will
come from audiobook sales and library partnerships, not feature gates.

The opening is: *the same catalog in a player that respects you*.

## Roadmap

### Shipped
- [x] Variable playback speed, sleep timer, bookmarks, lock-screen/Control Center artwork (P0 table stakes).
- [x] Customizable skip intervals, library sort/filter, playlists (P1 parity).
- [x] Volume normalization, Dynamic Type support (P2 differentiation).
- [x] Offline downloads, 10-band EQ, Folder Watch, listening stats, library backup & restore,
      bookmarks & favorites sync.
- [x] **Resume reliability** (`docs/RELEASE_PLAN.md`): resume at the right chapter and offset from every
      entry point, crash/force-quit durability, content-keyed identity, free position sync — the app
      never loses your place.
- [x] **CarPlay** — free and standalone: search, browse, resume, and play entirely from the car, no
      phone needed. Design in [`docs/CARPLAY_DESIGN.md`](docs/CARPLAY_DESIGN.md).

### Future (not yet planned)

- **Skip silence** device-sign-off (the toggle is built but not released).
- **Apple Watch polish** — the companion is shipped; additional complications and richer controls
  remain future work.
- **Widgets, Siri & App Shortcuts** — needs an app-group entitlement and relocated SQLite database.
- **Localization** — the UI is English-only today (catalog already supports 15 languages).
- **Narrator-centric discovery, Project Gutenberg read-along** — longer-term differentiators unique to
  public-domain content.

## Current focus

The pre-release plan is tracked in [`docs/RELEASE_PLAN.md`](docs/RELEASE_PLAN.md). The competitive gap
plan in [`docs/COMPETITIVE_GAP_PLAN.md`](docs/COMPETITIVE_GAP_PLAN.md) is substantially complete. The
current App Store Connect copy and submission checklist are in
[`docs/native-mac/APP_STORE_METADATA.md`](docs/native-mac/APP_STORE_METADATA.md).

## Build and verification

Run the host package tests during development and before committing:

```sh
swift test
```

To build the iPhone app, use the `Voxglass` scheme with a concrete iOS Simulator destination:

```sh
xcodebuild \
  -project Voxglass.xcodeproj \
  -scheme Voxglass \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -derivedDataPath /tmp/voxglass-derived \
  build CODE_SIGNING_ALLOWED=NO
```

The iPhone scheme embeds the Apple Watch app. Do not add `-sdk iphonesimulator` to this command:
that global SDK override is also applied to the Watch dependency and makes valid WatchKit source
fail as though it were iOS code. Do not use `generic/platform=iOS Simulator` for this combined
scheme because its asset-thinning step can evaluate the Watch icon catalog as an iPhone catalog.

Build the Watch app independently with its Watch scheme and a concrete Watch Simulator destination:

```sh
xcodebuild \
  -project Voxglass.xcodeproj \
  -scheme VoxglassWatch \
  -destination 'platform=watchOS Simulator,name=Voxglass-Agent-Watch,OS=latest' \
  -derivedDataPath /tmp/voxglass-watch-derived \
  build CODE_SIGNING_ALLOWED=NO
```

Simulator names vary by machine. Discover valid destinations with:

```sh
xcodebuild -project Voxglass.xcodeproj -showdestinations -scheme Voxglass
xcodebuild -project Voxglass.xcodeproj -showdestinations -scheme VoxglassWatch
```

The iOS target keeps `TARGETED_DEVICE_FAMILY: "1,2"`, so iPad remains a supported destination and
uses the regular-width sidebar/detail interface when space permits. Mac Catalyst is built from the
same scheme with a Mac Catalyst destination:

```sh
xcodebuild \
  -project Voxglass.xcodeproj \
  -scheme Voxglass \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath /tmp/voxglass-catalyst-derived \
  build CODE_SIGNING_ALLOWED=NO
```

On iPad and Catalyst, `⌘1`–`⌘4` switch between Listen, My Books, Discover, and Narration. During
narration, `⌘R` records/stops, `⌘Space` plays the current take, `⌘←`/`⌘→` move between paragraphs,
`⌘Return` accepts and advances, and Escape closes the flow. The Mac microphone selector lists
available input devices so a USB/custom microphone can be chosen before recording.

Build the native macOS app with a concrete macOS destination:

```sh
xcodebuild \
  -project Voxglass.xcodeproj \
  -scheme VoxglassMac \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/voxglass-mac-derived \
  build CODE_SIGNING_ALLOWED=NO
```

Audit the source-side App Store requirements before an archive:

```sh
scripts/audit_app_store_release.sh
```

If `project.yml` changes, regenerate the Xcode project first with `xcodegen generate`. The native
Mac target requires macOS 14 or newer and does not link WatchConnectivity or CarPlay.

### Native macOS TestFlight distribution

The release workflow uploads both the iOS/Watch build and the native `VoxglassMac` build when the
macOS App Store Connect platform and its signing material are configured. The existing
`BUILD_CERTIFICATE_BASE64` must contain the **Apple Distribution** identity that signs the app. Mac
App Store Connect export also requires a separate **Mac Installer Distribution** identity to sign
the installer package. The Mac profile must be a **Mac App Store Connect** profile for
`guru.parso.voxglass`, named `Parso Voxglass Mac App Store`.

To enable the upload once per repository:

1. In App Store Connect, open Voxglass, choose **Add Platform → macOS**, enter the macOS version
   metadata, and save it. The macOS platform uses the same app record and bundle ID as iOS.
2. Create a **Mac Installer Distribution** certificate in Apple Developer → Certificates,
   Identifiers & Profiles → **Certificates**. Use Keychain Access → **Certificate Assistant →
   Request a Certificate From a Certificate Authority** to generate a CSR and private key. Upload
   that CSR when creating the certificate, download the issued certificate, and open it in Keychain
   Access. In **My Certificates**, export the resulting **3rd Party Mac Developer Installer** identity
   as a `.p12`. The export password may be blank; if you set one, also add it as the
   `MAC_INSTALLER_P12_PASSWORD` repository secret. This identity is separate from the Apple
   Distribution identity used to sign the app itself.
3. In Apple Developer → Certificates, Identifiers & Profiles → **Profiles**, create a profile with
   **Distribution → Mac App Store Connect**, select the `guru.parso.voxglass` App ID and the
   **Apple Distribution** certificate, name it `Parso Voxglass Mac App Store`, and download it.
4. Add the downloaded profile as the GitHub Actions repository secret
   `MAC_PROVISIONING_PROFILE_BASE64`:

   ```sh
   base64 < "$HOME/Downloads/Parso_Voxglass_Mac_App_Store.provisionprofile" | tr -d '\n' | gh secret set MAC_PROVISIONING_PROFILE_BASE64 -R johnarleyburns/parso-voxglass
   ```

5. Add the exported installer identity as a repository secret:

   ```sh
   base64 < "$HOME/Downloads/Parso_Voxglass_Mac_Installer.p12" | tr -d '\n' | gh secret set MAC_INSTALLER_CERTIFICATE_BASE64 -R johnarleyburns/parso-voxglass
   ```

   The workflow supplies an empty password when `MAC_INSTALLER_P12_PASSWORD` is not configured.
   Never commit or print the `.p12` file or its password.
6. Push to `main`, or use **Actions → iOS → Run workflow**. The workflow validates both Mac signing
   identities and the profile, archives `VoxglassMac`, exports it for App Store Connect, and uploads
   it to TestFlight. If Mac signing secrets or the platform are absent, iOS/Watch uploads remain
   enabled and the Mac upload is reported as skipped.

7. In App Store Connect, open **Apps → Voxglass → TestFlight → macOS**. Wait for the build to finish
   processing, answer any export-compliance questions, add the build to an internal tester group,
   and invite the Apple Account used on the Mac.

On the Mac, install Apple’s **TestFlight** app from the Mac App Store, accept the invitation, open
TestFlight, select Voxglass under the macOS tab, and click **Install**. Native Mac TestFlight builds
must be uploaded with application identifiers in their provisioning profile and expire after Apple’s
normal beta-testing period.

Before a release, run the local iPhone and Watch smoke suite:

```sh
scripts/test.sh --all
```

The commit hook runs `swift test` only. Simulator smoke tests are release verification and CI
coverage, not part of every commit.

## Manual regression testing before release

The navigation simplification research and implementation plan is documented in [`docs/plans/navigation-redesign/SIMPLIFICATION_PLAN.md`](docs/plans/navigation-redesign/SIMPLIFICATION_PLAN.md).

Most logic is covered headlessly by `swift test`. The commit hook runs `swift test` only; it does
not boot simulators. Before every release, run `scripts/test.sh --all` to execute the local iPhone
and Apple Watch simulator smoke suite, then perform the physical-device checks below. A single
XCUITest smoke confirms the app boots. The **playback platform surface** — lock-screen
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
9. Open the EQ, engage it, and change a band / apply a preset. **Expect:** the sound changes; the setting persists across relaunch.

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

Voxglass consumes the published `parso-audio-engine` (PAE) **1.2.2** release;
the app and CI resolve that immutable version rather than a local or migration-branch checkout.

GNU General Public License v3.0 or later, with an additional permission under
GPLv3 §7 allowing distribution through Apple's App Store. See `LICENSE`.

### MP3 export — LAME, reintegrated in a PAE-compliant way

MP3 export (`VoxTranscoder`, `Voxglass/Core/Encoders/LAMEEncoder.swift`) uses
LAME 3.100 (`libmp3lame`, LGPL-2.1-or-later), vendored as real source in this
app's own package (`Sources/CLAMEBridge`) — `parso-audio-engine` (PAE, MIT,
shared with other apps) never links or depends on LAME itself. Voxglass
implements PAE's own `MP3Encoding` protocol (PAE's `docs/BYO-CODEC.md`) with
`LAMEEncoder`, and PAE's `AudioFileWriter` is told to use it rather than
having its audio handling overridden.

This app previously used LAME via a binary `Lame.xcframework`, moved to
PAE's own from-scratch Glint encoder in the audio-engine-unification's Phase
4 for a dependency-free MP3 path, and has now moved back to LAME as its own
licensing choice — Glint remains PAE's own default for any consumer that
hasn't made that choice for itself. A perceptual A-B of LAME vs Glint on
real spoken-word takes is still owed before either could be called the
better choice on quality alone; this reintegration is a licensing/quality
decision made independently of that open question.

## iCloud Sync setup (for developers)

Cross-device sync uses `NSUbiquitousKeyValueStore`. Playback-position sync, bookmarks sync, and
favorites sync are all free for everyone. The required **iCloud key-value-store** capability is
committed as `Voxglass/Resources/Voxglass.entitlements` and wired
through `project.yml` under `settings.base` — so it is attached in **all** configurations, Release and
TestFlight included. The App Store provisioning profile now carries the iCloud capability; no manual
capability toggling is needed for development, simulator, unit-test, or archive builds.

Without the entitlement, `NSUbiquitousKeyValueStore.synchronize()` is a no-op and sync will not function —
so if you fork this project under a different App ID, enable **iCloud →
Key-value storage** for your App ID in the Apple Developer portal and regenerate your provisioning profile.
