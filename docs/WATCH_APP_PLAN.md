# Voxglass for Apple Watch - Implementation Handoff

**Mockup:** [docs/mockups/watch-app.html](mockups/watch-app.html). Treat the mockup as normative for navigation states, layout budgets, and smoke-test accessibility identifiers.

## Goal

Build a standalone watchOS 10+ Voxglass app that can search My Books and LibriVox, read book detail, stream over Wi-Fi/LTE, download a small on-watch library, play with the phone absent, and sync positions back to the iPhone without losing the user's place.

This is not a "mostly straightforward Core reuse" project. Core reuse is the advantage, but prior watch projects failed on exact WatchKit packaging, signing, sync feedback, and tiny-screen layouts. This plan is a gated handoff for avoiding those failures.

## Read First / Inspect First

Before coding a phase, re-read the files that define the real app shape:

- `project.yml` - XcodeGen is the source of truth; iOS deployment target is `17.0`; current app bundle is `guru.parso.voxglass`; Release profile is `Parso Voxglass App Store`.
- `Package.swift` - package currently supports iOS 17 and macOS 14; watchOS must be added deliberately.
- `.github/workflows/ios.yml` - CI writes `ExportOptions.plist` dynamically; there is no checked-in export options file.
- `Voxglass/App/AppServices.swift` - the wiring point for database, library, catalog, playback, cloud sync, offline downloads, and stats.
- `Voxglass/Core/Playback/PlaybackCoordinator.swift` - resume, position persistence, snapshots, and `preferredPosition(row:snapshot:)`.
- `Voxglass/Core/Services/Sync/VoxglassCloudSync.swift` - iCloud KVS position/bookmark payload shape and content-key fallback.
- `Voxglass/Core/Services/Playback/OfflineDownloadManager.swift` - current phone offline cache semantics; do not confuse these with on-watch storage.
- `Voxglass/Core/Catalog/CatalogStore.swift` - import/search mapping and LibriVox catalog behavior.
- `docs/mockups/watch-app.html` - normative UI states, point budgets, and accessibility identifiers.

## Prior-Watch Lessons

These constraints come from the sibling projects `../parso-workout-ios-app` and `../parso-tonearm`; treat them as non-negotiable:

- **Archive metadata must be exact.** Prior TestFlight builds failed around `WKApplication` vs stale `WKWatchKitApp` metadata, missing `WKCompanionAppBundleIdentifier`, missing `CFBundleIconName`, missing watch app icon metadata, watch-specific provisioning profiles, bad `SKIP_INSTALL`, version mismatches, and a global `ARCHS=arm64` override that stripped the watch `arm64_32` slice.
- **Every tap must show motion or feedback.** Tonearm had visible albums/songs where tapping did nothing because fetch UI only existed inside Now Playing, there was no navigation after transfer completion, and unreachable iPhone states returned silently. Voxglass watch actions must push or reveal Now Playing/fetch status immediately.
- **Small watch screens punish fragile SwiftUI.** Workout watch fixes showed long status text and nested scroll/geometry compositions collapse on small watches. Split long status copy into stacked rows, avoid simple-screen `GeometryReader` and nested `ScrollView` patterns, and make every async-initialized screen show loading state instead of blank content.
- **Logic belongs in Core and host tests.** Sync state, queueing, storage accounting, position merge, elapsed/progress display, search result mapping, transfer display state, and download policy must be pure/testable in `VoxglassCoreTests`; SwiftUI and platform adapters stay thin.

## Definition Of Done

- TestFlight build installs both the iPhone app and embedded watch app.
- Watch app launches and plays a book with the phone powered off.
- Standalone streaming works over watch Wi-Fi/LTE.
- On-watch download of one book completes, offline playback works with network disabled, and storage accounting is correct.
- A known watch pause offset appears on the iPhone after reconnect via the existing position sync path.
- Play, Resume, Stream, Add, Fetch, Retry, Cancel, Delete, and route actions all produce visible navigation or state changes.
- Smallest supported and largest available watch simulator screenshots pass the mockup fit gates; no blank async screens, clipped controls, or collapsed long text.

## Target And Signing Contract

Use XcodeGen. Do not hand-edit the generated `.xcodeproj` except for diagnosis; regenerate it from `project.yml`.

### Watch Target

- Target name: `VoxglassWatch`
- Target type: `application`
- Platform: `watchOS`
- Deployment target: `10.0` unless a real Voxglass Core symbol requires a newer SDK. Do not copy Tonearm's watchOS 11 default without a build reason.
- Source root: `VoxglassWatch`
- Bundle ID: `guru.parso.voxglass.watchkitapp`
- Companion bundle ID: `guru.parso.voxglass`
- Product name: `VoxglassWatch`
- `TARGETED_DEVICE_FAMILY: "4"`
- `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`
- Watch app icon asset set must be present in the watch target. Watch icons must have no transparency and must fill the circular mask.
- `CFBundleDisplayName: Voxglass`
- `CFBundleIconName: AppIcon`
- `CFBundleShortVersionString: "$(MARKETING_VERSION)"`
- `CFBundleVersion: "$(CURRENT_PROJECT_VERSION)"`
- `WKApplication: true`
- `WKRunsIndependentlyOfCompanionApp: true`
- `WKCompanionAppBundleIdentifier: guru.parso.voxglass`
- `UIBackgroundModes: [audio]`
- Debug signing: Automatic.
- Release signing: Manual, `CODE_SIGN_IDENTITY: "Apple Distribution"`, `PROVISIONING_PROFILE_SPECIFIER: "Parso Voxglass Watch App Store"` until the real App Store Connect profile name is verified.

### Embedding And `SKIP_INSTALL`

- Add `VoxglassWatch` as a dependency of the iOS `Voxglass` target so XcodeGen creates the Embed Watch Content phase.
- The iOS `Voxglass` app must remain the installable archive product.
- The embedded watch target should not become a second top-level archive product; verify `SKIP_INSTALL` behavior in the generated project and final archive.
- Archive gate: `Products/Applications/Voxglass.app/Watch/VoxglassWatch.app` exists, includes the watch icon metadata, and has the same marketing/build version as the iOS app.

### Package

- Add `.watchOS(.v10)` to `Package.swift`.
- Build the watch scheme against the watchOS SDK before assuming Core is portable.
- Prefer narrow `#if !os(watchOS)` guards around truly unavailable symbols. Do not fork playback, catalog, position, recommendation, or search semantics merely to silence compile errors.
- `VoxglassCoreTests` must keep running under `swift test`.

## CI And TestFlight Contract

The current workflow dynamically writes export options in `.github/workflows/ios.yml`. Extend that workflow; do not add a checked-in `ExportOptions.plist`.

- Add secret `WATCH_PROVISIONING_PROFILE_BASE64`.
- The TestFlight preflight step must require both `BUILD_PROVISION_PROFILE_BASE64` and `WATCH_PROVISIONING_PROFILE_BASE64`.
- Install both provisioning profiles into `~/Library/MobileDevice/Provisioning Profiles`.
- Decode and validate both profile names:
  - iOS: `Parso Voxglass App Store`
  - watch: `Parso Voxglass Watch App Store` until verified.
- Generated export options must include both bundle IDs:

```xml
<key>provisioningProfiles</key>
<dict>
  <key>guru.parso.voxglass</key>
  <string>Parso Voxglass App Store</string>
  <key>guru.parso.voxglass.watchkitapp</key>
  <string>Parso Voxglass Watch App Store</string>
</dict>
```

- Keep archive signing settings on the targets in `project.yml`; do not pass global `PROVISIONING_PROFILE_SPECIFIER` command-line overrides that leak onto the SwiftPM package.
- Do not set global `ARCHS=arm64`; that can strip watch `arm64_32` and break archive validation.
- Add a PR compile gate for the watch scheme:

```sh
xcodebuild build \
  -project Voxglass.xcodeproj \
  -scheme VoxglassWatch \
  -destination 'generic/platform=watchOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

- Keep the iOS compile gate. The archive gate remains the `Voxglass` scheme so the embedded watch app is validated in the iPhone archive.

## Sync Invariants

Positions are the hard constraint. The watch may be offline, the phone may be off, and both devices may write positions; the merge path must stay unified.

- iCloud KVS remains the source of truth for cross-device positions.
- WatchConnectivity is only latency plumbing and file-transfer plumbing.
- Every watch position write must use the same `PositionStore` row shape used by the phone:
  `id`, `book_id`, `chapter_id`, `position_seconds`, `duration_seconds`, `updated_at`, `is_finished`.
- Cloud payloads must keep the same content-key fields used by `VoxglassCloudSync`: `book_content_key` and `chapter_content_key`, with UUID fallback.
- Watch resume must call the same conflict policy as the phone: `PlaybackCoordinator.preferredPosition(row:snapshot:)` and `snapshotWins(row:snapshot:)`.
- The watch needs a `LastPlaybackSnapshotStore` equivalent so a crash or OS kill cannot lose the latest local offset before SQLite/cloud flush.
- Position saves happen on pause, seek, chapter change, route interruption, app resign active, and a bounded heartbeat during playback. The heartbeat interval must be a Core policy with tests.
- No watch-only "newer wins except..." policy is allowed. If the merge behavior changes, change it once in Core and update phone/watch tests together.

## Playback Contract

- `WatchPlaybackEngine` is a thin watchOS adapter around `AVPlayer`.
- Configure `AVAudioSession` for long-form audio with category `.playback`, route sharing policy `.longFormAudio`, and background audio enabled in the watch Info.plist.
- If no valid route is available, present the system route picker or an explicit route-needed state. Never fail silently.
- Direct streaming is allowed in v1. A book can be streamed before it exists on the watch offline cache.
- Playback coordinator state, elapsed/progress display, skip intervals, speed display, sleep display, and chapter progression are Core models; SwiftUI only renders and dispatches.

## Transfer, Download, And Storage Contract

On-watch storage is separate from the phone's offline cache. The phone may have a pinned stream-cache file that the watch does not have, and the watch may have a book downloaded while the phone cache does not.

- Preferred path when the phone already has complete chapter audio: `WCSession.transferFile` from phone to watch.
- Fallback path: watch downloads directly over `URLSession` when network policy allows.
- Default cap: 5 books or 2 GB, whichever comes first. Future setting may raise the byte cap, but v1 UI and tests must assume the default.
- Eviction: least recently played first, never the currently playing book, never a book with a user-pinned transfer if pinning is added.
- Every transfer/delete/fetch mutation emits a visible watch state and a manifest/status update to the phone.
- Delivery order is not guaranteed. The transfer state machine must tolerate audio-before-manifest and manifest-before-audio.
- File-transfer metadata must include stable content keys, local UUIDs when known, byte size, chapter index, duration, source URL, transfer request id, and generation/version.
- Manifest report from watch to phone includes all on-watch book/chapter keys, bytes, pinned/current-playing flags, free space, failures, and generation/version.
- Fetch timeout: if no acknowledgement or progress arrives within the Core-defined timeout, show a failed state with Retry and Cancel.
- Delete/cancel must be idempotent. It is valid to receive late progress for a canceled transfer; Core state must ignore stale updates by generation/request id.

Minimum Core state machine:

| State | Visible watch behavior |
|---|---|
| `notAvailable` | Row says Streams; action is Fetch or Stream |
| `queued` | Fetch status pushed with Cancel |
| `waitingForPhone` | Explains phone is needed; Retry and Cancel visible |
| `transferring` | Progress visible; Cancel visible |
| `available` | Green on-watch indicator; Play/Resume goes directly to playback |
| `failed` | Error text split into short rows; Retry and Cancel/Remove visible |

## Navigation And Tap Contract

Every user action must lead to an immediate, visible result:

- `Play`, `Resume`, `Stream`, row tap on an available chapter, and row tap on an available book push Now Playing immediately.
- Tapping a not-local chapter/book pushes Now Playing or a fetch status screen immediately, before network/phone work completes.
- `Add to My Books` shows an importing state, then either the Book Detail/Now Playing action state or a visible error.
- If the iPhone is unreachable, the watch shows `waitingForPhone` with Retry and Cancel. Do not return silently from a `WCSession` call.
- When a fetch completes, navigation lands on Now Playing and playback starts or is ready with a visible Play button.
- When a fetch fails, navigation stays in the status context and shows the error.
- Every async-initialized root shows `Loading`, `Empty`, or `Error` content. A blank or zero-height screen fails the phase.

Smoke-test anchors must be wired as accessibility identifiers in the watch app:

- `root.listening`
- `root.search`
- `root.onWatch`
- `book.detail`
- `book.stream`
- `book.fetch`
- `book.add`
- `np.playpause`
- `np.back15`
- `np.forward30`
- `np.route`
- `fetch.status`
- `fetch.cancel`
- `fetch.retry`

## Layout Doctrine

Do not make iPhone SwiftUI smaller. Build watch-first layouts.

- Browsable roots use `List` or watch-native list styles. Avoid hand-rolled nested scroll areas for lists.
- No nested `ScrollView` plus `GeometryReader` compositions for simple screens.
- Avoid `GeometryReader` for fixed tool surfaces unless the screen truly needs a measured drawing area.
- Long sync/status copy is split into stacked rows; do not put a paragraph into a single row beside controls.
- Buttons that perform transport/actions keep fixed dimensions. Minimum tap target is 44 pt.
- Use icons for compact tool buttons where watchOS has familiar symbols. Avoid text-only toolbar rows when icon buttons fit.
- Use Dynamic Type styles. Apply `lineLimit` and `minimumScaleFactor` only where the point budget explicitly allows it.
- All loading/fetch/error states reserve stable vertical space so the screen does not collapse while async data arrives.
- Verify every touched screen on the smallest supported watch simulator and the largest available watch simulator.

### Point Budgets

Baseline mockups are 45 mm (`198 x 242 pt`). The implementation must also fit the smallest supported simulator, assumed as `162 x 197 pt` until the local Xcode install proves otherwise.

| Surface | 45 mm budget | Small-watch doctrine |
|---|---:|---|
| Now Playing nav/status | 16 pt | Keep short; no multi-line status in top bar |
| Cover | 44 pt | May reduce to 36 pt |
| Title/chapter/narrator | 34 pt | Max 2 title lines total; narrator can move below |
| Progress/times | 20 pt | Fixed height; monospace times |
| Transport controls | 44 pt | Fixed 44 pt main button; side controls remain tappable |
| Tool row | 34 pt | Prefer 4 icon buttons; labels may hide at small size |
| Book detail header | 44 pt | Cover 36-40 pt; title gets 2 lines |
| Primary book actions | 44-88 pt | Stack actions on small watches instead of squeezing |
| Fetch/error state | 88 pt minimum | Cancel/Retry remain visible without scrolling |

## Screens

| Screen | Required behavior | Primary anchors |
|---|---|---|
| Now Playing | Current book, chapter, narrator, progress, back 15, play/pause, forward 30, speed, sleep, chapters, route. Crown scrubs only when progress has focus; otherwise volume/system behavior. | `np.playpause`, `np.back15`, `np.forward30`, `np.route` |
| My Books root | Segments Listening, All, On Watch. Rows show progress/time-left and on-watch/download state. | `root.listening`, `root.onWatch`, `root.search` |
| Search | watchOS text entry, recents, My Books/LibriVox scope. Local results immediate; remote results visible with loading/error. | `root.search` |
| Search results | Remote rows open Book Detail with Stream and Add controls. Results remain scoped to LibriVox. | `book.detail` |
| Book Detail | Cover, title, author, narrator, full crown-scrollable description, Resume/Play/Stream, Add, Fetch/Download, Favorite, Chapters. | `book.stream`, `book.add`, `book.fetch` |
| Chapters | Current chapter scrolled into view and highlighted; row tap plays or fetches with visible state. | `chapters.list` |
| Fetch status | Queued/transferring/waiting/failed states with progress, Retry, and Cancel. | `fetch.status`, `fetch.retry`, `fetch.cancel` |
| On Watch | Storage meter, per-book bytes, download status, delete/remove. | `root.onWatch` |
| Speed & Sleep | Crown-driven rate, sleep timer, skip silence if supported. | `playback.options` |
| Complications/Smart Stack | Deferred until app reliability is proven. | `widget.resume` |

## Gated Phases

Every phase uses this gate procedure unless a step is explicitly not applicable:

```sh
swift test
xcodegen generate
xcodebuild build -project Voxglass.xcodeproj -scheme Voxglass \
  -destination 'platform=iOS Simulator,name=iPhone 16'
xcodebuild build -project Voxglass.xcodeproj -scheme VoxglassWatch \
  -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO
```

For phases touching watch UI, also run the local watch smoke test and capture fit screenshots on small and large watch simulators.

### P0 - Preflight And Signing

- Confirm Apple Developer app ID exists for `guru.parso.voxglass.watchkitapp`.
- Create/verify App Store provisioning profile named `Parso Voxglass Watch App Store`.
- Add `WATCH_PROVISIONING_PROFILE_BASE64` to GitHub secrets.
- Confirm CI imports both iOS and watch profiles and validates both names.
- Confirm no global `ARCHS` override exists locally or in CI.
- Confirm `project.yml` remains the source of target/signing truth.
- Gate: no Swift code required; document profile name if it differs from the placeholder.

### P1 - Target Scaffold And Core Watch Compile

- Add `.watchOS(.v10)` to `Package.swift`.
- Add `VoxglassWatch` source root with placeholder app, Info.plist, entitlements only if needed, and watch icon assets.
- Add `VoxglassWatch` target and scheme in `project.yml`; embed it in `Voxglass`.
- Make `VoxglassCore` compile for watchOS with narrow guards.
- Add CI watch compile gate with `CODE_SIGNING_ALLOWED=NO`.
- Gate: generated project contains Embed Watch Content; iOS build, watch build, and `swift test` pass.

### P2 - Core Watch Models And Tests

- Add pure Core models for watch library rows, book detail display, search scope/query mapping, Now Playing display, fetch/unreachable display, transfer state, storage accounting, and download policy.
- Add position merge tests covering watch row plus snapshot fallback.
- Add long-title/long-description model fixtures for small-screen display decisions.
- Gate: `VoxglassCoreTests` covers all model rules; no watch UI required yet.

### P3 - Watch Library, Search, And Book Detail

- Implement root `List` with Listening, All, On Watch segments.
- Implement local search from library rows and remote LibriVox search via existing catalog/query code.
- Implement Book Detail with full crown-scrollable description and stable loading/error states.
- `Add to My Books`, `Stream`, `Fetch`, and row taps produce immediate visible state.
- Gate: watch smoke reaches root, search, result, and book detail anchors; small/large screenshots pass.

### P4 - Playback And Position Persistence

- Implement `WatchPlaybackEngine` and wire it through Core playback models.
- Implement Now Playing, Chapters, route handling, speed, skip, and position heartbeat.
- Persist via `PositionStore` plus watch snapshot fallback; push/pull through existing `VoxglassCloudSync` rules.
- Gate: standalone playback works in simulator/device; pause offset survives relaunch; phone adopts watch offset after reconnect.

### P5 - Transfer, Download, And Storage

- Implement phone-to-watch `transferFile` when phone has complete chapter audio.
- Implement watch direct download fallback and policy.
- Implement on-watch manifest, storage meter, delete/cancel/retry, failure states, and LRU eviction.
- Keep watch storage separate from phone offline cache.
- Gate: host tests cover state machine, stale generations, eviction, cap math, and display models; device test downloads one book and plays offline.

### P6 - Widgets And Complications

- Start only after P3-P5 acceptance passes.
- Implement circular/corner/rectangular complications and Smart Stack resume card.
- Share display data with the phone Live Activity model where practical, but do not let widget work block playback/sync reliability.
- Gate: widgets resume the correct book/position without regressing the app.

### P7 - Hardening, Docs, And TestFlight

- Update release docs with watch screenshots, TestFlight notes, route limitations, and on-device acceptance steps.
- Run full build/test gates and TestFlight upload.
- Verify the TestFlight build installs the watch app, not just the phone app.
- Gate: Definition of Done is complete.

## Test Plan

### Host Tests In `VoxglassCoreTests`

- Position merge round trip: watch write, phone pull, newer/tie behavior through `PlaybackCoordinator.preferredPosition`.
- Watch snapshot fallback and anti-zero/anti-stale position handling.
- Download cap and LRU eviction, including "never evict current book".
- Transfer state machine: queued, transferring, failed, canceled, stale progress, audio-before-manifest, manifest-before-audio.
- Search scope query: LibriVox remote results stay inside the LibriVox collection.
- Storage accounting: bytes, partial downloads, failed records, free-space display.
- Unreachable/fetch display model: Retry/Cancel visibility and short-row text.
- Book/chapter view models with long titles, long author/narrator names, and long descriptions.

### Build Gates

```sh
swift test
xcodegen generate
xcodebuild build -project Voxglass.xcodeproj -scheme Voxglass \
  -destination 'platform=iOS Simulator,name=iPhone 16'
xcodebuild build -project Voxglass.xcodeproj -scheme VoxglassWatch \
  -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO
xcodebuild archive -project Voxglass.xcodeproj -scheme Voxglass \
  -configuration Release -destination 'generic/platform=iOS'
```

### Watch Smoke Test - Local Only

Seed fixtures inside the watch target under `#if DEBUG`; do not depend on a live iPhone for the smoke.

Flow:

1. Launch with seeded fixtures.
2. Assert `root.listening`, `root.search`, and `root.onWatch` exist.
3. Navigate My Books -> Book Detail -> Now Playing.
4. Assert `book.detail`, `book.stream`, `book.add`, `book.fetch`, `np.playpause`, `np.back15`, `np.forward30`, and `np.route` exist.
5. Tap play/pause/skip controls.
6. Trigger fetch overlay/status, assert `fetch.status`, `fetch.retry`, and `fetch.cancel` exist, then tap `fetch.cancel`.
7. Open Search and On Watch.

### Layout Verification

- Capture screenshots on the smallest supported watch simulator and largest available watch simulator for every screen touched in a phase.
- Fail the phase if a button is offscreen, a row collapses below tap size, text overlaps, text scales to unreadable size, or a loading path is blank.
- Include fetch, unreachable-phone, and download-error states in screenshots, not only happy paths.

### On-Device And TestFlight Acceptance

- Install from TestFlight and confirm the watch app appears on the watch.
- Power off the phone. On the watch, search LibriVox, open a book, stream over Wi-Fi/LTE, and pause at a known offset.
- Download one book to the watch, disable Wi-Fi/LTE, and play offline across a chapter boundary.
- Reconnect the phone and confirm the exact watch position appears in the phone library/player.
- Confirm route picker behavior with no Bluetooth route connected.
- Fill storage to the cap and confirm the eviction/error UI names the expected book.

## Deferred Until After Reliability

- Complications and Smart Stack beyond minimal resume.
- EQ/crossfade/advanced audio effects.
- Complex queue editing on the watch.
- Large configurable download policies.
- Any watch-only sync policy that diverges from iPhone/Core behavior.
