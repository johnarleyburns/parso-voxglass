# Voxglass Watch — iPhone-Owned Library Rearchitecture

Status: **awaiting owner approval**  
Reference implementation: `../parso-tonearm/docs/plans/watch-rearchitecture/`  
Mockups: [`mockups/index.html`](mockups/index.html)  
Acceptance: [`ACCEPTANCE_MATRIX.md`](ACCEPTANCE_MATRIX.md)

## 0. Instructions to the implementing agent

Read this document, `ACCEPTANCE_MATRIX.md`, every mockup state, and `CLAUDE.md` before
editing code. Decisions in §§1–8 are closed unless the selected Apple SDK proves an API
unavailable. Record exact compiler/runtime evidence before substituting an API.

Implement one phase at a time. At the end of each phase: run its tests and guards, update
the implementation audit, commit that phase, and stop for owner review. Preserve unrelated
changes. Never claim a physical-device WatchConnectivity gate from simulator evidence.

## 1. Product contract

### 1.1 Authority

- The iPhone is the only CloudKit client and authoritative owner of My Books, metadata,
  chapter order, artwork, source resolution, and desired watch downloads.
- The watch has no CloudKit code, entitlement, container identifier, database, catalog
  search, production/review feature, narration capture, or direct library mutation.
- WatchConnectivity carries a versioned projection, playback commands, transfer intent,
  files, and acknowledgements. It is not treated as an audio stream.
- The watch owns installed-file truth, local playback state, and actual storage usage.

### 1.2 Connected mode

When the paired iPhone is reachable, the watch can only:

1. view the iPhone's My Books projection;
2. open a book and its chapters;
3. listen on the watch;
4. request or remove a complete-book watch download;
5. view Now Playing with artwork, play/pause, and explicit previous/next chapter controls.

No Explore, internet search, Settings catalog, Productions, review, dictation, or recording
surfaces remain in the watch app.

Playback without a complete watch download is source-aware:

- public HTTPS audio: the watch may stream the phone-approved, credential-free URL;
- phone-local/private audio: the phone sends the selected chapter just in time, and playback
  starts after that chapter is installed in an ephemeral cache;
- an ephemeral chapter never makes the book visible offline or marks it Downloaded;
- failures say `Open Voxglass on iPhone to prepare this chapter`; no fake streaming state.

### 1.3 Disconnected mode

After a two-second debounced loss of iPhone reachability:

- My Books contains only books whose complete manifest is validated locally;
- every visible row is playable without network or phone;
- local playback and system Now Playing continue;
- no download/remove actions that require the phone are shown;
- an empty state says `No downloaded books` and directs the user to My Books on iPhone;
- reconnection restores the phone projection without dismissing Now Playing or replacing a
  local queue.

### 1.4 Download truth

The iPhone owns desired state; the watch owns installed state. A book can be:

`notRequested`, `queued`, `preparing`, `transferring`, `installing`, `downloaded`,
`removing`, or `failed(code)`.

Only `downloaded` means every required chapter and artwork manifest entry is present and
validated. Phone rows derive their indicator from the latest watch acknowledgement, not
sender progress. Partial books are resumable but never visible disconnected.

Removing a download removes the offline root and durable files, but leaves active ephemeral
playback until playback moves away or stops. Downloads are never automatically evicted.

## 2. Target architecture

```text
iPhone (authority)                              Apple Watch (projection/client)
──────────────────────────────────────────────────────────────────────────────
LibraryRepository + CloudKitSyncEngine          WatchLibraryRepository
          │                                     (local metadata + manifests)
PhoneWatchProjectionCoordinator                 WatchAppCoordinator
          │                                             │
PhoneWatchSessionAdapter ◄── typed protocol ──► WatchSessionAdapter
          │               context/events/files          │
PhoneWatchDownloadManager                       WatchFileInstaller
          │                                             │
OfflineDownloadManager / local source           validated durable files
                                                        │
public URL approval ───────────────────────────► WatchPlaybackCoordinator
local chapter JIT transfer ────────────────────► ephemeral chapter cache
```

### 2.1 Dependency boundaries

Create narrowly scoped groups/targets if the existing Xcode project cannot enforce these
boundaries cleanly:

- `WatchProtocol`: Foundation-only Codable envelopes, IDs, DTOs, states, reducers.
- `WatchCore`: local repository, manifest reconciliation, connection reducer, storage and
  playback state machines. No CloudKit, GRDB, network catalog clients, or UI.
- iPhone app: adapters from existing library/playback/download services to WatchProtocol.
- watch app: WatchConnectivity and AVFoundation adapters plus SwiftUI.

The watch-linked closure must contain no `CloudKit`, `CK*`, CloudKit container identifier,
`CloudKitSyncEngine`, Internet Archive catalog client, LibriVox search client, production
sync, or phone credentials. Keep and strengthen `WatchNoCloudKitTests`.

### 2.2 Replace, consolidate, delete

- Replace `WatchAudioRelay` and the second production transport with one
  `WatchSessionAdapter` and one delegate owner.
- Replace `WatchAppServices` with a coordinator composed from protocol/repository/playback.
- Replace the current five-tab/root experience with one My Books navigation stack and a
  Now Playing entry point.
- Replace direct watch catalog/search/download behavior in `WatchStorageManager` with
  manifest installation and local queries.
- Fold useful playback code from `WatchPlaybackEngine`/`WatchPlaybackCoordinator` behind one
  local playback actor.
- Delete watch Productions, review, recording remote, Search, Settings, fetch-status, and
  direct URL-download UI after replacement tests pass.
- Preserve iPhone production/watch-review support only if another shipped surface still uses
  it; it must not remain linked into the consumer watch target.

## 3. Persistence model

Use a small watch-local store with explicit CloudKit opt-out. GRDB is acceptable if already
isolated; SwiftData is preferred to mirror Tonearm, configured with
`cloudKitDatabase: .none`. The choice is locked in Phase 1 after dependency-closure proof;
do not migrate the iPhone database.

Persist value-equivalent records:

- `WatchBook`: stable content key, phone book ID, title, author, narrator, duration, artwork
  key, metadata revision, ordered chapter IDs.
- `WatchChapter`: stable chapter key, book key, index, title, duration, approved stream URL
  if public, expected durable filename/bytes/hash.
- `WatchAsset`: chapter key, relative path, bytes, hash, purpose (`durable`/`ephemeral`),
  validation state, last access.
- `WatchBookManifest`: book key, desired revision, required chapter keys, install state,
  error code, timestamps.
- `WatchPlaybackState`: book/chapter keys, position, rate, queue, playing intent, timestamp.
- `WatchSyncState`: protocol version, paired library ID, projection revision, last manifest
  acknowledgement, last successful phone contact.
- `AppliedMessage`: bounded idempotency ledger.

Model objects never cross actor boundaries; repositories expose Sendable snapshots. Store
open failure quarantines the database, scans durable files, opens a fresh store, and asks
the phone to reconcile. It never terminates the app.

## 4. Protocol

Every logical message uses a binary-property-list Codable envelope:

```text
version, messageID, correlationID?, pairedLibraryID,
projectionRevision, sentAt, kind, payload
```

Channels:

- `updateApplicationContext`: newest complete My Books summary, connection capabilities,
  and download-status summary.
- `sendMessageData`: reachable-only library detail, play/JIT request, retry/remove request,
  and immediate acknowledgement with an eight-second deadline.
- `transferUserInfo`: durable desired-manifest changes, reconciliation, installed manifest,
  and deletion acknowledgement.
- `transferFile`: metadata bundle, artwork, and audio with property-list-safe metadata.

Required message kinds:

- `hello/helloReply`, `librarySnapshot`, `bookDetailRequest/Response`;
- `playRequest`, `jitChapterRequest`, `playbackSnapshot`;
- `setBookDownload`, `removeBookDownload`, `downloadStatusSnapshot`;
- `bookManifest`, `assetFile`, `watchManifest`, `reconcileRequest`;
- `error` with stable codes.

All application is revisioned and idempotent. Delivery order is never assumed. Duplicate or
stale messages acknowledge without rollback. Unknown protocol versions preserve local books
and show `Update Voxglass on iPhone and Apple Watch`.

## 5. Download and playback pipelines

### 5.1 Complete-book download

1. iPhone UI writes desired book root and revision.
2. Planner resolves every chapter from phone cache, local import, or approved remote source.
3. Phone sends metadata/artwork, then at most two outstanding chapter transfers.
4. Watch copies callback URLs to staging before returning.
5. Installer verifies identity, bytes, hash, codec, and free-space reserve.
6. Installer atomically moves files and commits asset + manifest state.
7. Watch acknowledges its actual manifest and byte count.
8. iPhone row changes to Downloaded only after complete acknowledgement.

Resume from `outstandingFileTransfers`; retry transient failures with bounded backoff.
Cancellation and deletion are idempotent. Reserve max(250 MB, 10% free capacity) before a
book and recheck per file.

### 5.2 Connected play

If durable local chapter exists, play it. Else if a credential-free HTTPS URL was approved
by the phone, stream it on the watch and optionally maintain a bounded ephemeral cache. Else
request a JIT chapter file, show `Preparing chapter…`, install ephemerally, then play. JIT
gets priority over background complete-book transfers.

The watch owns the audible playback target in this design; controls do not secretly control
the iPhone player. Configure `.playback`, `.longFormAudio`, route/interruption handling,
remote commands, and Now Playing metadata/artwork. Persist position every ten seconds and on
pause/chapter/background transitions. Position reports may flow to the phone, which remains
the sync authority.

## 6. User interface contract

### Watch

- Connected My Books: connection label, Now Playing if active, full projected books, honest
  download glyph/status.
- Disconnected My Books: `On This Watch` label and complete downloaded books only.
- Book detail: artwork, title/author, Play, chapters, and download state/action only while
  connected.
- Now Playing: artwork, chapter/book, elapsed/remaining, previous chapter/play-pause/next chapter,
  Crown volume, and an explicit `Apple Watch` output label. Previous/next always move by chapter,
  never by an unlabeled time interval or queue item. Disable the unavailable direction at the
  first/last chapter and expose `Previous chapter` / `Next chapter` VoiceOver labels.
- The primary transport row must fit without horizontal clipping on the smallest supported Watch.
  Use one row with three controls and no competing seek row. Secondary actions belong below the
  fold or in a menu; artwork may scale down before transport targets do.

### Small-Watch layout contract

The 40 mm Apple Watch SE simulator is the minimum geometry gate, even when the routine smoke uses
the existing 42 mm `Watch-Small` destination. Now Playing must render at the minimum supported
Dynamic Type size and accessibility sizes without hiding chapter navigation:

- previous chapter, play/pause, and next chapter are simultaneously visible on initial display;
- each control retains a minimum 44×44-point hit target and does not overlap its neighbor;
- artwork, chapter title, elapsed/remaining, and the transport row fit without horizontal scroll;
- vertical scrolling may reveal secondary actions, but must not be required to reach transport;
- long chapter/book titles truncate or wrap within their assigned region without pushing controls;
- safe-area and rounded-screen clipping are checked from screenshots and element frames;
- VoiceOver order is artwork/status, title/chapter, progress, previous chapter, play/pause, next
  chapter, then secondary actions.
- Transfer state: compact status with queued/preparing/transferring/installing/failure copy.
- Empty/recovery/incompatible states are actionable and never indefinite spinners.

### iPhone

- Every My Books row has a trailing watch status control independent of the existing context
  menu: Download, queued/progress, downloaded, failed/retry.
- Context menu mirrors Download/Remove/Retry to Apple Watch.
- Book detail uses the same state source.
- UI tests use deterministic injected watch state; they do not require simulator pairing.

Stable accessibility IDs are listed in the acceptance matrix and are API contracts.

## 7. Deterministic smoke-test design

### iPhone smoke

Extend the existing single iPhone smoke method and seed:

1. open My Books with Alice `notRequested` and Catch-22 `downloaded`;
2. assert `library.watchDownload.<id>` says Download to Apple Watch;
3. tap Alice, inject queued → transferring → downloaded acknowledgements;
4. assert progress and final Downloaded to Apple Watch state;
5. open Catch-22 action and assert Remove from Apple Watch;
6. keep `-uiTestDisableCloudKit`; use `PhoneWatchSessionFake`, never WCSession pairing.

### Watch smoke

Delete production-review and direct-internet-download smoke flows. One deterministic watch
smoke launches against an injected protocol/repository fixture and performs:

1. connected My Books shows Alice (not downloaded) and Catch-22 (downloaded);
2. Alice detail Play drives JIT preparing → local Now Playing with artwork;
3. download request drives queued → installing → downloaded;
4. relaunch disconnected; only Alice/Catch-22 complete fixtures appear;
5. play a downloaded chapter, verify elapsed advances and artwork exists;
6. move to the next chapter and back with the dedicated controls, asserting chapter identity and
   chapter-relative elapsed time update;
7. relaunch disconnected-empty and verify guidance.

The simulator proves UI/state wiring, not real WCSession transfer. Physical-device gates
cover background delivery, lock/force-quit behavior, Bluetooth/Wi-Fi paths, and long-form
audio.

## 8. Implementation phases

### Phase 0 — Approve contract and mockups

Deliverables: this plan, acceptance matrix, all mockup states, owner decisions recorded.
No production code. Exit: owner explicitly approves or requests revisions.

### Phase 1 — Foundation: boundaries, store, protocol, and connectivity

Create WatchProtocol/WatchCore boundaries, one WCSession delegate owner per device, and the fake
duplex transport. Implement the CloudKit-disabled Watch store, schema, repositories,
bootstrap/recovery, legacy-file adoption, typed envelope/channels, revisions, message ledger,
paired-library identity, timeouts, debounced connection reducer, application-context ingestion,
and reconciliation. Keep the old UI behind a temporary legacy assembly.

Tests cover architecture/entitlement closure, protocol round trips, fake transport faults,
relaunch/recovery/corruption, duplicate/out-of-order/stale/late delivery, and concrete iOS/Watch
simulator builds. Commit `Build watch foundation and connectivity` and stop.

### Phase 2 — Phone projection and end-to-end download pipeline

Project My Books/details/artwork/source capabilities from `LibraryRepository`; persist phone
projection revisions and desired book-download roots. Implement preparation, scheduling,
outstanding-transfer recovery, cancellation/removal, checksums, estimates, Watch staging,
validation, atomic installation, durable/ephemeral assets, storage reserve, acknowledgements,
manifest reconciliation, and safe adoption of provably complete legacy files. Integrate existing
phone cache and local imports without duplicating bytes; the Watch performs no catalog networking.

Tests cover Archive.org, folder/ZIP/shared-file imports, missing/deleted sources, interrupted and
out-of-order transfers, partial-book filtering, truthful acknowledged status, relaunch, removal,
and storage pressure. Commit `Build watch library and download pipeline` and stop.

### Phase 3 — Playback and complete iPhone/Watch UI replacement

Implement Watch-local playback resolution for durable files, approved public streams, and JIT
chapter transfers; add queue/chapter navigation, persisted chapter-relative positions, audio
session/route/interruption recovery, and system Now Playing artwork. Replace Watch UI with the
approved connected/disconnected My Books, detail, transfer, Now Playing, and empty/recovery states.
Now Playing uses one always-visible previous-chapter/play-pause/next-chapter row; it does not carry
forward separate time-seek and chapter rows. Add the iPhone My Books Watch indicator/action,
progress/failure/retry/removal, deterministic fake session, and updated phone smoke.

Tests include previous/next chapter semantics, shared-file offsets, the 40 mm Apple Watch SE
screenshot/frame geometry gate, Dynamic Type/VoiceOver ordering, the normal `Watch-Small` smoke,
and deterministic iPhone download-state smoke. Commit `Replace watch playback and library UI` and
stop.

### Phase 4 — Cutover, reliability, and release verification

Replace the Watch smoke completely; delete legacy Watch UI, services, transports, direct downloader,
production/review/recording/search/settings code, and dead target membership. Strengthen source,
link, entitlement, and project-drift guards. Run all logic, guard, hosted CarPlay, iPhone, 40 mm
geometry, and Watch simulator gates. Then run the paired-device matrix: locked/background phone,
force quits, interrupted files, Bluetooth-only/shared-Wi-Fi/no-network, route loss, wrist-down,
hours-long playback, storage pressure, reinstall, and upgrade. Fix blockers and archive-inspect
entitlements/linkage; record genuinely unavailable hardware rows as pending, never simulated.

Commit `Complete watch cutover and release verification` and stop for release approval without
pushing.

## 9. Global definition of done

- Every release-blocking acceptance row passes with its required evidence.
- Watch target and transitive closure are structurally CloudKit/catalog/production-free.
- Connected mode exposes only My Books, download management, and watch playback.
- Disconnected mode exposes only complete, validated books and local playback.
- Phone download indicators reconcile from watch acknowledgements.
- Imported single-file and ZIP books transfer and preserve chapter offsets.
- Now Playing has artwork and correct chapter-relative timing.
- Now Playing exposes previous/next chapter controls and fits the smallest supported Watch without
  clipping or requiring scroll to reach transport.
- No legacy watch UI/service remains linked.
- CI and repository hooks pass; physical-device-only evidence is recorded honestly.

## 10. Implementation audit

### Phase 1 — Foundation (2026-08-29)

- Added the `VoxglassWatchProtocol` Foundation-only package product at
  `VoxglassWatchProtocol/`. It owns stable IDs, library/chapter/manifest DTO placeholders,
  download states, channel mapping, binary property-list envelopes, protocol faults, and the
  transport contract.
- Added the `VoxglassWatchCore` package product at `VoxglassWatchCore/`. It owns the local
  Codable watch store, paired-library/revision-gated projection ingestion, durable download
  records, complete-book filtering, and corruption recovery that preserves the audio directory.
  The store configuration records the explicit CloudKit-disabled policy (`none`).
- The generated Xcode layout links both named products into `VoxglassWatch`; the existing
  `VoxglassCore` dependency remains temporarily for the shipped legacy Watch assembly and will
  be removed during cutover. The new products contain no CloudKit, WatchConnectivity,
  AVFoundation, catalog, credential, or UI imports.
- Added `WatchFakeDuplexLink`, duplicate/delay/reorder/reachability/failure controls,
  `WatchMessageLedger`, `WatchConnectionReducer`, and `WatchProtocolRouter` to the protocol
  boundary. Added host tests covering envelope round trips, pair/revision behavior, debounce,
  transport faults, and corrupt-store recovery.
- The legacy Watch relay/transport remains compiling as a temporary compatibility path; no new
  playback, download pipeline, or UI behavior was introduced in this phase.
- Verification: `swift test --filter WatchFoundationTests`, `bash scripts/test_logic.sh`,
  `bash scripts/test_guards.sh`, `xcodebuild -scheme VoxglassWatch -destination
  'platform=watchOS Simulator,name=Voxglass-Agent-Watch,OS=latest' ... build`, and
  `xcodebuild -scheme Voxglass -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'
  ... build` passed. No physical-device evidence was claimed.
