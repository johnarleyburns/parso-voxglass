# Simplify the player and sync controls; retire AI watch downloads

Watch transfer controls and diagnostics were scattered across book pages, player menus, library context menus, Settings, root banners and multiple watch screens. Voxglass now has one Sync surface, with concise status and one primary Sync action. Book selection and management are collapsed under Apple Watch; technical information lives under About → Sync Details.

Read by AI books can no longer be downloaded to Apple Watch. Their Watch info action explains that they play on iPhone and that watch downloads require recorded audio. Recorded audiobooks remain transferable.

## Resulting behavior

- Now Playing uses Book as its title, a native glass info action for metadata/chapters and an ellipsis action for audio controls. Continue Listening adds the narrator below the author. My Books removes Created by me and the search scope picker, always searching title/author/narrator together. Settings uses its presenting navigation stack.

- Listen has a Sync entry with the shared summary; Settings links to the same screen. The former iCloud and watch manual actions are consolidated there. iCloud preferences and diagnostic counts move into About → Sync Details rather than crowding Settings.
- Sync explicitly applies book selections. It prepares recorded audio serially, preserves cellular consent and storage estimates, exposes pause/resume/retry through the same screen, and confirms removals. Turning a book off affects only its watch copy. No automatic whole-library audio download is introduced.
- Sending a catalog or handing files to Apple does not count as installed audio. The summary distinguishes preparation, an active request, transfer, waiting, paused work, failures and confirmed installed books. Waiting/failed/paused states do not animate an indefinite progress indicator. The current request's start time and per-book progress/reason remain inspectable in Sync.
- Fresh inventory merges with staged choices so a delayed report cannot silently deselect books or discard edits. Books whose phone originals were deleted remain removable.
- Duplicate root connection toasts/watch transfer banners and player/library transfer controls are removed. My Books → On My Watch remains a quiet inventory; management belongs in Sync.
- Watch Home exposes Sync, a short status and About. The separate Downloads and Sync Status entry points are removed. About → Sync Details groups phone connection, installed chapters and receipts into native watch drill-down pages; reset stays in About. A timeout or error remains visible as a need for attention, and old request callbacks cannot overwrite a newer request's state.
- Read by AI eligibility is enforced before watch readiness checks, downloading, selection changes or conversion. Known AI sources, text chapters and mixed recorded/text books are rejected. The app's speech-rendering transfer branch is removed and its retired renderer symbol is unavailable. Existing queued AI transfers are cancelled on configuration and marked unsupported; already confirmed watch copies remain until the person removes them. The Sync list and AI book audio sheet offer an explanation instead of a new download.

## Workout app lessons applied

Reviewed the adjacent `parso-workout-ios-app` phone Settings, watch Settings, watch About, and `WatchSyncHandshake` sources. The relevant lessons are one explicit request action, short accessible status, no success claim based solely on sending, live watch requests only when reachable, and About as the home for version/connection/error details. Voxglass keeps its existing transport and per-book acknowledgement protocol; this PR does not transplant the workout protocol or add automatic audio retries.

## Validation

- 31 focused Swift Testing checks pass in an isolated host package with warnings treated as errors. This includes the production pure status, selection-merge and eligibility models, plus source contracts for transfer ownership, consent/results, diagnostics placement, retired AI rendering and stale watch callbacks. The models are copied unchanged; test source paths alone are redirected to the repository. These checks do not compile SwiftUI/WatchConnectivity or prove live transfers.
- The new eligibility checks were added before implementation and failed because the policy was absent, then passed with the policy and service gate.
- All changed Swift files pass `swiftc -frontend -parse`.
- `scripts/guard_watch_foundation.sh` and `git diff --check` pass.
- New app/watch strings cover all 16 supported locales with translated state; existing catalog entries are preserved.
- Added phone and watch UI scenarios for collapsed management, one sync entry and diagnostics behind About. They have not run here.
- Full `swift test` was attempted and fails before project tests execute in the existing `parso-audio-engine` Cvorbis dependency (`sharedbook.c`: undeclared `alloca` on Linux). This host has no Xcode or connected iPhone/Watch, so Apple-platform type checking, layout, gestures, live file transfers and physical audio remain unverified. No simulator was started.

## Physical-device checks before publishing

- Build the iPhone and Watch targets sequentially on physical devices. Check standard and accessibility text sizes on Listen, Sync and About disclosures.
- Verify Listen and Settings reach the same Sync screen; no root watch banners/toasts or per-book send/retry/remove controls remain. My Books watch inventory still reflects confirmed availability.
- Expand Apple Watch, select one recorded book and Sync. Check storage consent, Wi-Fi/cellular consent, phone-download progress, preparation, file transfer, installation confirmation, paused/stalled/error states, retry, removal, and reopening the screen. Pause while waiting on a phone download and while preparing/transferring; no later book should start after pausing.
- Confirm a late inventory report preserves staged additions/removals. Confirm an orphaned watch book can still be removed and an unselected book is never downloaded.
- On a Read by AI book, open the audio sheet and tap Watch info. In Sync, tap that book's info button. Confirm the same short explanation, no new transfer selection, and continued iPhone speech playback. Check source-identified AI, `.voxtext`, mixed chapters and a legacy queued AI request. Confirm existing installed copies can be removed without deleting phone originals.
- On Watch, check one Sync action, readable disconnected/waiting/error status, and About → Sync Details receipts/inventory. Start two sequential sync requests around the timeout window and verify an old callback cannot change the newer result.
- Inspect About → Sync Details → Connection / Apple Watch / iCloud Sync. Check timestamps, errors, counts and the existing iCloud preference without exposing transport jargon on the main Sync surface.

## Release scope

Prepared on `release/unified-sync-about` from current main (`a2de864`). Earlier listening/Find changes already merged in #324 are retained rather than republished, and unrelated staged changes in the original checkout are excluded. The remaining player follow-up, sync consolidation and subsequent removal of AI watch downloads are one PR. TestFlight is produced by the main-branch iOS workflow after the required PR checks and merge.
