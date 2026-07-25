# Voxglass — Watch CloudKit Sync + Standalone Operation

**Date:** 2026-07-24
**Repo:** `johnarleyburns/parso-voxglass`
**Deliverable:** Real CloudKit sync between phone and watch **and** a watch that is fully usable **standalone** (with or without an iCloud account, and without the phone present).
**Execution model:** Single implementation phase. At the end of the phase the agent MUST (a) run a self-review against this plan and emit a gap report, then (b) regenerate the project, run the local gates, commit, merge to `main`, push, and verify GitHub Actions CI is green — fixing any red before finishing.

Place this file at the repo root as `2026-07-24-voxglass-watch-cloudkit-standalone-plan.md` (matches the existing root-level dated-plan convention, e.g. `2026-07-24-voxglass-playback-refactor-plan.md`).

---

## 0. Why the watch is currently unusable (context for the implementer)

The watch target is a complete UI shell wired to an **empty local SQLite database** with **no data-plane behind it**. Concretely, verified in the current tree:

- `WatchAppServices.init` builds its own DB via `AppDatabase.makeApplicationDatabase()` → `…/Application Support/Voxglass/voxglass.sqlite` **inside the watch sandbox** (watch entitlements have no App Group). Nothing ever writes books into it.
- The only cross-device channel that exists, `VoxglassCloudSync`, is **iCloud KVS** and carries only positions/bookmarks/favorite-flags — **never the library** (and KVS caps at ~1 MB / 1024 keys, so it never could).
- `WatchConnectivitySession` is referenced **only inside its own file** — never instantiated, never activated (`session.activate()` never runs), handles only audio files, and has **no library-metadata path**. The phone has **zero** `WatchConnectivity` code (`grep -r "import WatchConnectivity" Voxglass/` is empty).
- `WatchStorageManager.refresh()` scans byte totals but leaves `localChapters = [:]` and `totalBookCount = 0` every call, and is **never called** anyway; `deleteOffline` has an empty file-removal loop; `rebuildStorageInfo` hardcodes `byteCount: 0`.
- `WatchSearchView.searchScope` defaults to `.myBooks`, is **never switched** (no `.searchScopes`), and the `.myBooks` branch does nothing; the LibriVox result detail buttons ("Add to My Books", "Stream") are empty closures.

This plan replaces the dead transport with a CloudKit-mediated data plane and makes the watch a first-class standalone client.

---

## 1. Objective & success criteria

A build passes this phase when **all** of the following are true on device:

**Sync (phone ↔ watch):**
1. A book added on the phone appears on the watch (and vice-versa) with its chapters, without the companion app running and without any WCSession transfer.
2. Playback position, `is_finished`, favorites, and bookmarks converge across devices (last-writer-wins on `updated_at`), including deletions (tombstones).

**Standalone (watch alone):**
3. With **no phone present** but iCloud available: the watch pulls the full library from CloudKit on first launch and plays any book by streaming from Internet Archive.
4. With **no iCloud account at all**: the watch still searches LibriVox, adds books to its own local DB, streams/downloads from Internet Archive, and tracks local positions/bookmarks. Sync silently no-ops until an account appears, then back-fills.
5. The watch can **download** chapters for offline use and **play them offline** (airplane mode, no phone). Downloads are a per-device local cache keyed by SHA-256 (`StreamCacheUtils.key`), never synced.

**The three original defects, fixed:**
6. **Search** works on the watch: a scope switch (My Books ↔ LibriVox) exists; My Books filters the local library; LibriVox queries `CatalogStore.searchLibriVox`; the result detail's **Add to My Books** imports and **Stream** plays.
7. **My Books / Listening** is populated (via #1/#3 when iCloud sync is on, via #4 for standalone) and is never permanently empty when the user has books anywhere.
8. **Settings surfaces exist**:
   - **Watch** — a Settings/More surface with per-book "Download to Watch" toggles, a storage readout, **Clear Watch Cache**, and a sync-status line.
   - **Phone** — an "Apple Watch & Sync" section in `SettingsView` (sync toggle, iCloud account status, and guidance), sitting alongside the existing iCloud "Sync" card.

**Engineering gates (must stay green):**
9. `bash scripts/guard_wiring.sh` passes, **including the new guards this plan adds**.
10. `swift test` passes, including the new `VoxglassCore` tests this plan adds.
11. `xcodebuild build` succeeds for **both** the `Voxglass` and `VoxglassWatch` schemes (this is the `compile` CI job).
12. The project is regenerated (`xcodegen generate`) and committed so the target-membership and xcodeproj-drift guards pass.

---

## 2. Non-negotiable constraints / invariants

These are hard rules. Violating any is a phase failure.

- **C1 — Standalone is a first-class mode, not a fallback.** Every feature except cross-device sync must work with `CKAccountStatus != .available`. Sync code paths must **degrade to no-ops**, never crash, log, or block the UI, on `.noAccount` / `.restricted` / `.couldNotDetermine`.
- **C2 — Everything is free. No Pro tier anywhere.** Every feature — search, streaming, export, offline downloads, positions/bookmarks, **and cross-device sync** — is available to all users. Do not add, reference, or leave seams for a paid tier, an entitlement, or an `isProUnlocked` concept. If any existing comment implies a "Pro iCloud gate," the new code does not honor it.
- **C3 — Do not build StoreKit/IAP or any purchase/entitlement check.** The **only** conditions on cross-device sync are (1) the user's iCloud-sync preference toggle (`AppPreferencesStore.Keys.iCloudSyncEnabled`, a privacy control that defaults on) and (2) iCloud account availability. Route both through **one** centralized, testable predicate (`SyncGate`); do not scatter checks and do not introduce any tier logic.
- **C4 — Audio never goes through CloudKit.** Only metadata + user state sync. Audio is fetched on demand from Internet Archive (`chapter.remoteURL` / `chapter.opusURL`) by whichever device needs it. `download_records`, `local_url`, and cached bytes are **per-device and never synced**.
- **C5 — Never sync device-local fields.** On encode, **strip** `local_url` from chapters and never emit `download_records`, taste/reco tables, listening events, or snapshot state. (See the explicit exclusion list in §3.3.)
- **C6 — SHA-256 cache keys only.** All watch cache filenames go through `StreamCacheUtils.key(for:)` (SHA-256 of the absolute URL string). Never `Swift.Hasher`, never ad-hoc.
- **C7 — Content identity for dedupe is `ContentKey`.** Merge/dedupe books and chapters by `content_key` (`ContentKey.book(forSourceURL:kind:)` / `ContentKey.chapter(...)`), exactly as `LibraryBackupService` already does (`SELECT id FROM books WHERE content_key = ?`). Never dedupe on raw `UUID` across devices — UUIDs differ per import.
- **C8 — Local SQLite stays the source of truth.** CloudKit is a mirror. The UI reads the local DB only; sync mutates the local DB and pushes/pulls in the background.
- **C9 — No new non-allowlisted URLs anywhere under `Voxglass/`.** The CI network guard fails the build on any `https?://` host outside `archive.org|librivox.org|parso.guru|wikipedia.org|greaterbooks.com`. CloudKit uses the container identifier, not URLs — **do not** hardcode `apple.com`/`icloud.com` URLs in code or comments under `Voxglass/`.
- **C10 — Regenerate the project.** Any change to `project.yml` (Info.plist properties, background modes) or any new app-target/watch-target source file requires `xcodegen generate` + committing the regenerated `Voxglass.xcodeproj`. `.entitlements` files are referenced by path and edited directly (not generated).
- **C11 — No dead placeholders.** No empty-closure buttons, no `isEnabled: false` "coming soon" rows. Every control this plan adds is wired. (A new guard enforces this for the watch target.)

---

## 3. Architecture

### 3.1 Container, zone, database roles

- **CloudKit container:** `iCloud.guru.parso.voxglass` (already present in both `.entitlements`).
- **Database:** the user's **private** database (`container.privateCloudDatabase`). Per-Apple-ID, automatically shared across the user's own devices — this *is* the phone↔watch link, and it is reachable by the watch independently, which is what makes standalone-with-iCloud work.
- **Zone:** one custom record zone `CKRecordZone(zoneName: "Library")`. A custom zone is required for zone-level change tokens and atomic multi-record batches; `CKSyncEngine` creates it on first save.
- **Sync engine:** **`CKSyncEngine`** (available iOS 17 / watchOS 10 — the repo's exact deployment floor). It owns change-token/state persistence, batching, retry, and account-change handling. One implementation, shared by both targets via `VoxglassCore`.

### 3.2 Record type schema (private DB, zone `Library`)

| Record type | Fields | Notes |
|---|---|---|
| `Source` | `kind`, `title`, `url`, `createdAt` | `recordName` = `"source-" + contentIdentity` (stable). |
| `Book` | `title`, `authorsJSON`, `narratorsJSON`, `summary`, `sourceRef` (`CKReference`, `.deleteSelf`), `coverURL`, `createdAt`, `updatedAt`, `isFavorite`, `contentKey`, `chaptersData` | `recordName` derived from `content_key`. Chapters **embedded** as gzipped JSON of `[Chapter]` in `chaptersData` (chapters are immutable catalog metadata; embedding avoids N+1 fan-out for 50–100-chapter LibriVox books). **Strip `local_url` before encoding** (C5). If a book's compressed chapter list would exceed the ~1 MB field limit, store `chaptersData` as a `CKAsset` instead (fallback path; assets in a metadata record are metadata, not audio — still compliant with C4). |
| `PlaybackPosition` | `bookRef` (`.deleteSelf`), `chapterID` (value), `positionSeconds`, `durationSeconds`, `updatedAt`, `isFinished` | LWW on `updatedAt`. `recordName` = position row id. |
| `Bookmark` | `bookRef` (`.deleteSelf`), `chapterID` (value), `positionSeconds`, `note`, `createdAt`, `updatedAt`, `isDeleted` | LWW on `updatedAt`; `isDeleted` is the tombstone (already exists in schema, migration `bookmarks_updated_at_tombstone`). |

Favorites fold into `Book.isFavorite` (no separate record). Positions/bookmarks use `sourceRef`/`bookRef` parent references so CloudKit cascade-deletes them when a book record is deleted.

### 3.3 What syncs vs what NEVER syncs

**Syncs:** `sources`, `books` (+ embedded chapters), `playback_positions`, `bookmarks`, and `books.is_favorite`.

**NEVER syncs (C4/C5) — the agent must not emit these to CloudKit:**
- `download_records` (per-device offline state)
- `chapters.local_url` (device-specific filesystem paths)
- cached audio bytes / the watch audio cache
- `book_taste`, `taste_profile_terms`, `taste_signal_state`, `reco_surfaced` (local personalization)
- `listening_events` (local stats; the events stay on-device)
- last-playback snapshot / `NSUbiquitousKeyValueStore` state (retired — see §3.8)

### 3.4 Layering (Core vs targets)

Put **all testable sync logic in `VoxglassCore`** (`Voxglass/Core/**`, the SwiftPM package that builds for iOS + watchOS + macOS and is imported by both app targets). Put **platform glue** (remote-notification registration, app-delegate hooks) in the targets.

- **`Voxglass/Core/Services/Sync/CloudKit/`** (new, in VoxglassCore):
  - `CloudKitRecordMapper.swift` — pure functions: `Book`/`[Chapter]`/`PlaybackPosition`/`Bookmark`/`Source` ⇄ `CKRecord`. Deterministic `recordName` from `content_key`. Strips `local_url`. **No CloudKit I/O — fully unit-testable.**
  - `CloudKitSyncEngine.swift` — wraps `CKSyncEngine`; implements the delegate (`handleEvent`, `nextRecordZoneChangeBatch`); applies fetched changes to the local DB via the repository/stores; enqueues local dirty rows. Guards every entry on `SyncGate.shouldSync`.
  - `SyncGate.swift` — the single predicate: `shouldSync = iCloudSyncEnabled && accountStatus == .available`. `iCloudSyncEnabled` is the user's sync preference (defaults on); there is **no** Pro/entitlement term (C2/C3). Pure/testable given injected inputs.
  - `CloudSyncStateStore.swift` — persists the engine's serialized state, per-record CloudKit system fields, and the dirty queue (see §3.7 tables).
  - `SyncMutationLog.swift` — the "mark dirty" API called by the repository/stores whenever a synced row changes.
- **`Voxglass/App/`** (phone target): register for remote notifications in `AppDelegate`; construct/start the engine in `AppServices`.
- **`VoxglassWatch/`** (watch target): a `WKApplicationDelegateAdaptor` for remote-notification registration; construct/start the engine in `WatchAppServices`.

> Rationale: `swift test` runs against the VoxglassCore package with no simulator and no entitlements. Keeping mapping, gating, conflict resolution, and DB-apply logic in Core makes them testable there; only registration/push plumbing needs a device.

### 3.5 Sync-preference / account-status matrix

| iCloud account | Sync toggle | Behavior |
|---|---|---|
| available | on | Full bidirectional CloudKit sync + standalone. |
| available | off | Standalone only — the user turned sync off. Engine constructed but `shouldSync == false` → dormant. |
| none / restricted | (n/a) | Standalone only, local-only. Engine dormant; on account arrival (`CKSyncEngine` account-change event) it activates and back-fills. |

The watch must be **fully usable in every row** — no feature is withheld. Only row 1 shows another device's library. There is no purchase or tier dimension (C2).

### 3.6 Audio & standalone playback

- The watch streams via its existing `AVPlayer` adapter (`WatchPlaybackEngine.load(url:startTime:)` already does `AVPlayerItem(url:)`), fed `chapter.playableURL` (`localURL ?? remoteURL`). For standalone, that resolves to the IA remote URL — already supported; the missing piece was the empty library, not the engine.
- Downloading for offline: `WatchStorageManager` must actually fetch bytes from `chapter.remoteURL`/`opusURL` into `cacheDir` under `StreamCacheUtils.key`, maintain a real `content_key → cached chapters` map, and evict via the existing `WatchEvictionPolicy` / `WatchStoragePolicy`. (§WS5 rewrites the broken internals.)
- **Opus-when-ready policy:** prefer `opusURL` when present, else `remoteURL` (mirror the phone's caching policy; do not block playback waiting for Opus).

### 3.7 Conflict resolution, tombstones, local persistence

- **Conflict policy:** `books`/`sources` are creation-wins, idempotent by `content_key` (metadata rarely changes post-import; on `serverRecordChanged`, keep the record with newer `updatedAt`). `playback_positions`/`bookmarks` are **last-writer-wins on `updated_at`** (matches the existing KVS logic and `snapshotWins`/`preferredPosition` merge helpers).
- **Deletions:** deleting a book locally enqueues a `CKRecord` deletion; `.deleteSelf` references cascade positions/bookmarks server-side. Bookmarks additionally carry `is_deleted` tombstones (already modeled) so a delete propagates even if the book survives.
- **New migration `id: 9`** (the current max is `id: 8` in `DatabaseMigrations.swift` — confirm and append the next sequential id) adding:
  - `cloud_records(record_name TEXT PRIMARY KEY, record_type TEXT NOT NULL, local_id TEXT NOT NULL, system_fields BLOB, updated_at REAL NOT NULL)` — encoded `CKRecord` system fields per synced row, for conflict detection and change-tag tracking.
  - `sync_engine_state(id INTEGER PRIMARY KEY CHECK (id = 1), state BLOB NOT NULL, updated_at REAL NOT NULL)` — the serialized `CKSyncEngine.State`.
  - `pending_sync(local_id TEXT NOT NULL, record_type TEXT NOT NULL, change_type TEXT NOT NULL, enqueued_at REAL NOT NULL, PRIMARY KEY (local_id, record_type))` — the dirty queue feeding `nextRecordZoneChangeBatch`.

### 3.8 KVS migration & retirement

`VoxglassCloudSync` (KVS) is superseded by CloudKit for positions/bookmarks/favorites.
- **One-time migration** on first launch of the new build: read existing KVS values, ensure the corresponding rows exist in the **local DB**, then let `CKSyncEngine` push them. Gate behind a `migratedKVSToCloudKit` preference so it runs once.
- **Stop writing** to KVS from the sync paths. Keep the KVS **read** path for exactly one release (to catch positions that hadn't propagated), then delete in a follow-up.
- A **new guard** (§6) forbids new `NSUbiquitousKeyValueStore` writes outside the migration shim.

### 3.9 WCSession audio relay — implemented, enabled accelerator (WS7)

With CloudKit + direct IA fetch, WCSession is **no longer load-bearing for correctness** — but it is **included and enabled** this phase as a real optimization, not a stub. Delete the orphaned `WatchConnectivitySession` (never activated, audio-only, no library path) and replace it with a working two-sided `WatchAudioRelay`:

- **Watch side** (`WatchAudioRelay` in `VoxglassWatch/`): activates a `WCSession`; when the user starts/downloads a chapter that is **not** already in the watch cache, it asks the phone whether that chapter's bytes are available and, if so, requests them.
- **Phone side** (`PhoneAudioRelay` in `Voxglass/App/`): activates a `WCSession`; on request, if `OfflineDownloadManager`/the phone cache already holds that chapter file (matched by `content_key` + `StreamCacheUtils.key`), it `transferFile`s the bytes to the watch, which ingests them into `WatchStorageManager` under the same SHA-256 key.

It engages automatically when useful and is otherwise a silent no-op — **no user-facing toggle**. **Correctness must never depend on it:** if the phone is unreachable, the companion app isn't installed, or the chapter isn't cached on the phone, the watch fetches from Internet Archive directly (§3.6). The message-shape structs may live in `VoxglassCore` (reuse the existing `WatchTransferRequest` model) so they're unit-testable; the `WCSession` activation is target glue.

---

## 4. Workstreams (ordered; single phase)

Implement in this order; later workstreams depend on earlier ones.

### WS0 — Capabilities, entitlements, project regen
- Edit **both** `.entitlements` (`Voxglass/Resources/Voxglass.entitlements`, `VoxglassWatch/Resources/VoxglassWatch.entitlements`): add
  - `com.apple.developer.icloud-services` → `<array><string>CloudKit</string></array>`
  - `aps-environment` → `development` (Release signing flips to production via profile; keep the key present)
  - keep the existing `icloud-container-identifiers` (`iCloud.guru.parso.voxglass`).
- Edit `project.yml`: add `remote-notification` to `UIBackgroundModes` for **both** targets (phone currently `[audio]`, watch currently `[audio]`).
- Run `xcodegen generate`; commit `project.yml` + regenerated `Voxglass.xcodeproj` together (C10).
- **Acceptance:** both schemes still build; entitlements contain CloudKit + aps-environment; xcodeproj-drift guard passes.

### WS1 — Local persistence for sync (migration `id: 9`)
- Add the three tables from §3.7 to `DatabaseMigrations.swift`.
- Add a `CloudSyncStateStore` (VoxglassCore) with typed accessors for `sync_engine_state`, `cloud_records`, and `pending_sync`.
- **Acceptance:** migration applies on a fresh DB and on an upgraded DB; unit test round-trips state/system-fields/dirty-queue.

### WS2 — Record mapper (pure, testable)
- `CloudKitRecordMapper.swift`: `Book`+`[Chapter]` ⇄ `Book` record (gzip `chaptersData`, strip `local_url`), `Source` ⇄ record, `PlaybackPosition` ⇄ record, `Bookmark` ⇄ record. Deterministic `recordName` from `content_key` (reuse `ContentKey`).
- **Acceptance:** `swift test` round-trip for every type; asserts `local_url` is absent from encoded chapters; asserts the same `content_key` yields the same `recordName` (idempotent dedupe, C7).

### WS3 — Sync gate + mutation log
- `SyncGate.swift` (§3.4/§3.5) and `SyncMutationLog.swift` (enqueue dirty rows).
- Wire the mutation log into `LibraryRepository` (book import/delete/favorite/narrator updates), `SQLitePositionStore.save`, and `SQLiteBookmarkStore` writes so every synced mutation enqueues into `pending_sync`.
- **Acceptance:** unit tests for the gate truth table (§3.5); mutating a position/bookmark/book enqueues exactly one dirty row.

### WS4 — CloudKit sync engine (shared) + platform push glue
- `CloudKitSyncEngine.swift`: construct `CKSyncEngine` against `privateCloudDatabase`, zone `Library`; implement the delegate — persist state on `stateUpdate`, apply `fetchedRecordZoneChanges` to the local DB (dedupe by `content_key`, resolve conflicts per §3.7), provide batches in `nextRecordZoneChangeBatch` from `pending_sync`, handle `accountChange` (activate/deactivate per §3.5). Every public entry short-circuits when `!SyncGate.shouldSync`.
- Phone: in `AppDelegate` add `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` / registration and forward CloudKit pushes; construct+start the engine in `AppServices` (alongside the existing `cloudSync`), and trigger a push after import via the existing `libraryStore.onBookImported` hook.
- Watch: add a `WKApplicationDelegateAdaptor` for remote-notification registration; construct+start the engine in `WatchAppServices`.
- Follow current Apple `CKSyncEngine` guidance for the exact delegate/push signatures; the **project-specific** contract (schema, dedupe, gate, DB-apply) is fixed above.
- **Acceptance (device/manual, recorded in the gap report):** add-on-phone → appears-on-watch and reverse; position/bookmark/favorite convergence incl. deletions; kill the phone app and confirm the watch still syncs (standalone-with-iCloud).

### WS5 — Fix `WatchStorageManager` (real offline cache)
- Rewrite `refresh()` to map cache files back to books/chapters via `content_key`/`StreamCacheUtils.key` and compute **real** byte totals (fix the `bookChapters` no-op and `totalBookCount = 0` bug).
- Implement real file deletion in `deleteOffline`; compute real `byteCount` in `rebuildStorageInfo` (remove the hardcoded `0`).
- Add a real **download** path: fetch `chapter.opusURL ?? chapter.remoteURL` bytes into `cacheDir` under `StreamCacheUtils.key`, update the map, enforce `WatchStoragePolicy`/`WatchEvictionPolicy`.
- Call `offlineManager.refresh()` from watch bootstrap and after each ingest/delete.
- **Acceptance:** unit tests for the cache-file→book mapping, real byte totals, eviction ordering, and delete-removes-files; On-Watch tab reflects real state.

### WS6 — Fix watch Search (the original defect)
- In `WatchSearchView`: add a scope control via `.searchScopes($searchScope)` with `.myBooks` / `.librivox`.
- Implement the **My Books** branch: filter `libraryStore.books` by title/author locally and render them (currently renders nothing).
- Keep the **LibriVox** branch calling `CatalogStore.searchLibriVox`.
- Wire the result detail: **Add to My Books** calls the import path (`CatalogStore.importResult` → `LibraryRepository.importInternetArchiveItem(_:sourceKind:)`, the same entry the phone uses) and, on success, enqueues a sync push (WS3); **Stream** presents the book in `WatchPlaybackCoordinator` and plays `playableURL`.
- **Acceptance:** typing filters My Books; switching to LibriVox returns catalog results; Add imports into the local DB (and syncs when iCloud sync is on); Stream plays. No empty-closure buttons remain (placeholder guard, §6).

### WS7 — Settings surfaces (the original defect) + WCSession audio relay
- **Watch Settings/More:** add `WatchSettingsView` (reachable from the On-Watch tab or a toolbar affordance) with: per-book "Download to Watch" toggles (drives WS5), a storage readout (`totalBytes`/`maxBytes`, `totalBookCount`/`maxBooks`), **Clear Watch Cache** (wipes `cacheDir` + resets the map), and a sync-status line (iCloud account status + last sync + a standalone/synced indicator). These directly answer "bools downloaded to my watch for offline use and clear watch cache."
- **Phone Settings:** add an "Apple Watch & Sync" section to `SettingsView` next to the existing `SyncSettingsCard`: an iCloud-sync toggle bound to `AppPreferencesStore.Keys.iCloudSyncEnabled` (already the sync switch), an iCloud **account-status** row, and short guidance ("Your library and progress sync to Apple Watch when iCloud is available; the watch also works on its own"). Do **not** claim to enumerate on-watch downloads from the phone (that state is per-device); the watch manages its own cache. No Pro/upgrade copy anywhere (C2).
- **WCSession audio relay (implemented, enabled — §3.9):** delete the orphaned `WatchConnectivitySession.swift` and its references, and add the working two-sided `WatchAudioRelay` (watch) / `PhoneAudioRelay` (phone). It engages automatically (no toggle) and is a silent no-op when the phone is unreachable or lacks the chapter — the watch then fetches from Internet Archive directly. Correctness must not depend on it.
- **Acceptance:** watch Settings toggles/clear-cache/sync-status all function; phone section renders and the toggle drives the gate; `grep -r "WatchConnectivitySession" .` returns nothing (only its deletion in the diff); with both apps installed and a chapter cached on the phone, starting that chapter on the watch pulls bytes over WCSession (verify via a relay counter/log), and with the phone unreachable the same chapter still plays via IA.

### WS8 — App-wide bootstrap wiring
- Move watch startup out of `WatchListeningView.task` so it runs app-wide: call `services.bootstrap()` once from `VoxglassWatchApp` (e.g. a root `.task`), and have `bootstrap()` also call `offlineManager.refresh()` and start the engine. Fix `adoptCloudPosition()` so it operates after the library is populated (today it looks up books in an empty store and never matches).
- **Acceptance:** opening any watch tab first still yields a populated library and refreshed storage; resume-last-book works once the library exists.

---

## 5. Entitlements & project.yml — exact changes

`Voxglass/Resources/Voxglass.entitlements` and `VoxglassWatch/Resources/VoxglassWatch.entitlements` — add inside the top-level `<dict>`:

```xml
<key>com.apple.developer.icloud-services</key>
<array>
    <string>CloudKit</string>
</array>
<key>aps-environment</key>
<string>development</string>
```
(Keep the existing `com.apple.developer.icloud-container-identifiers` array with `iCloud.guru.parso.voxglass`. Keep the phone's `carplay-audio` and both targets' `ubiquity-kvstore-identifier` until KVS retirement completes.)

`project.yml` — for **both** `Voxglass` and `VoxglassWatch` under `info.properties.UIBackgroundModes`:
```yaml
UIBackgroundModes:
  - audio
  - remote-notification
```
Then `xcodegen generate` and commit the regenerated project (C10).

---

## 6. New CI guards (append to `scripts/guard_wiring.sh`)

Follow the existing pattern (numbered `check_*` functions, source-derived so they can't rot, `::error` output, wired into the `run_check` summary). The current script's `SWIFT_FILES` covers `Voxglass/{App,Core,Features,DesignSystem}` **only** — extend coverage to the watch where noted.

- **G-A — Watch data-plane wiring.** Assert `WatchAppServices` instantiates and starts the CloudKit engine, and that `offlineManager.refresh()` is called from watch bootstrap. (grep for the constructor + `refresh(` in `VoxglassWatch/`.)
- **G-B — Both targets start the engine.** Assert the engine type is referenced in **both** `Voxglass/App/` and `VoxglassWatch/`.
- **G-C — Search scope is switchable.** Assert `VoxglassWatch/WatchSearchView.swift` contains `.searchScopes(` and assigns/binds `searchScope` (guards against regression to the permanently-`.myBooks` bug).
- **G-D — No dead placeholders in the watch.** Port Rule 3's spirit to `VoxglassWatch/`: fail on empty-closure buttons — grep for `Button {` whose body is only a comment, and on `isEnabled: false` near "coming soon"/"not available".
- **G-E — No new KVS writes.** Fail on `NSUbiquitousKeyValueStore` `.set(` outside the migration shim file (allowlist the shim path).
- **G-F — Orphan removed.** Fail if `WatchConnectivitySession` still exists as an unreferenced type (or simply assert the file is gone).
- **G-G — Watch target membership** (optional but recommended): extend `check_xcodeproj_membership` to include `VoxglassWatch` sources (today it checks only `Voxglass VoxglassUITests`), so a new watch file that wasn't added to the target is caught pre-compile.

Wire each into the `run_check` block and the summary. Keep the existing network-endpoint guard green (C9).

---

## 7. Tests to add (`VoxglassTests`, run by `swift test`)

All must run without a simulator, network, or entitlements (inject inputs; use the `AppDatabase.makeTemporaryDatabase()` seam and the existing `#if DEBUG testForceAvailable`-style pattern for account status).

- **T1 — Mapper round-trip** for `Book(+chapters)`, `Source`, `PlaybackPosition`, `Bookmark`: encode→decode equals original (modulo `local_url`, which must be absent).
- **T2 — Idempotent recordName:** same `content_key` ⇒ same `recordName`; different imports (different UUIDs, same content) collapse to one record (C7).
- **T3 — Conflict resolution:** LWW picks the higher `updated_at` for positions/bookmarks; creation-wins for books; tombstone (`is_deleted`) beats a stale non-deleted copy.
- **T4 — Sync gate truth table:** every row of §3.5 (account status × sync toggle) yields the expected `shouldSync`. Assert there is no Pro/entitlement input to the predicate.
- **T5 — Standalone-no-account path:** with account unavailable, a book import + position write mutate the local DB and enqueue dirty rows but perform **no** CloudKit I/O and never throw (C1).
- **T6 — KVS migration shim:** given seeded KVS values, the shim writes them into the local DB once and sets the `migrated` flag; a second run is a no-op.
- **T7 — Watch storage mapping:** cache files map to books via `StreamCacheUtils.key`; byte totals and `totalBookCount` are real; eviction order matches `WatchEvictionPolicy`; delete removes files and updates totals.
- **T8 — Search scope filter:** the My Books filter matches by title/author case-insensitively over a seeded library (pure function extracted from the view so it's testable).
- **T9 — Relay message contract:** the `WatchAudioRelay`/`PhoneAudioRelay` request/response structs (in `VoxglassCore`) round-trip through their dictionary payloads, and the "is this chapter cached on the phone?" match resolves by `content_key` + `StreamCacheUtils.key` (pure resolver, no `WCSession`).

---

## 8. Self-review against plan (mandatory before finalization)

Before committing, the agent MUST produce a **gap report** (write it to `docs/` or append to the PR/commit body) that walks this plan and marks each item ✅ done / ⚠️ partial / ❌ not done, specifically:

1. Every success criterion in §1 (1–12).
2. Every constraint in §2 (C1–C11) — with a one-line justification each.
3. Every workstream WS0–WS8 acceptance line.
4. Every guard G-A–G-G present and passing.
5. Every test T1–T9 present and passing.
6. The device/manual acceptance items in WS4 (add-on-phone↔watch, standalone-no-phone, standalone-no-iCloud) — state how each was verified or, if only simulator was available, what remains to verify on hardware.

Any ⚠️/❌ must have a written reason and a follow-up note. Do not silently drop scope.

---

## 9. Finalization (run in order; do not stop on the first green)

1. `xcodegen generate` — regenerate the project; confirm no unexpected diff beyond intended target/Info.plist changes.
2. Local gates:
   - `bash scripts/guard_wiring.sh` (must pass, incl. new guards)
   - `swift test` (must pass, incl. new tests)
   - `xcodebuild build -project Voxglass.xcodeproj -scheme Voxglass -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO`
   - `xcodebuild build -project Voxglass.xcodeproj -scheme VoxglassWatch -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO`
3. Commit on a feature branch with a descriptive message referencing this plan; include the §8 gap report.
4. Merge to `main` (fast-forward or PR-merge per repo norms) and `git push origin main`.
5. Verify GitHub Actions: watch the `iOS` workflow (`.github/workflows/ios.yml`) — jobs `compile`, `logic-tests`, `guarded-tests` must all be green (e.g. `gh run watch` / `gh run list`). The `testflight` job only runs on `main` and self-skips if signing secrets/app-record aren't configured — a **skip is acceptable**, a **failure is not**.
6. If any job is red, fix and repeat from step 2. The phase is complete only when `compile`, `logic-tests`, and `guarded-tests` are green on `main`.

---

## 10. Appendix — file inventory

**New (VoxglassCore — SwiftPM, both platforms, not subject to the xcodeproj-membership guard):**
- `Voxglass/Core/Services/Sync/CloudKit/CloudKitRecordMapper.swift`
- `Voxglass/Core/Services/Sync/CloudKit/CloudKitSyncEngine.swift`
- `Voxglass/Core/Services/Sync/CloudKit/SyncGate.swift`
- `Voxglass/Core/Services/Sync/CloudKit/CloudSyncStateStore.swift`
- `Voxglass/Core/Services/Sync/CloudKit/SyncMutationLog.swift`
- migration `id: 9` appended to `Voxglass/Core/Database/DatabaseMigrations.swift`

**New (app/watch targets — MUST be added via `xcodegen`):**
- `VoxglassWatch/WatchSettingsView.swift`
- `VoxglassWatch/WatchAppDelegate.swift` (or an inline `WKApplicationDelegateAdaptor`)
- `VoxglassWatch/WatchAudioRelay.swift` (WCSession accelerator, watch side — WS7/§3.9)
- `Voxglass/App/PhoneAudioRelay.swift` (WCSession accelerator, phone side — WS7/§3.9)
- optional shared message structs in `Voxglass/Core/Services/Sync/` (reuse `WatchTransferRequest`), if extracted for T9
- phone: an "Apple Watch & Sync" section (extend `Voxglass/Features/Settings/SettingsView.swift`)

**Edited:**
- `Voxglass/Resources/Voxglass.entitlements`, `VoxglassWatch/Resources/VoxglassWatch.entitlements` (CloudKit + aps-environment)
- `project.yml` (background modes) + regenerated `Voxglass.xcodeproj`
- `Voxglass/App/AppServices.swift`, `Voxglass/App/VoxglassApp.swift` (engine construct/start + push registration)
- `VoxglassWatch/WatchAppServices.swift`, `VoxglassWatch/VoxglassWatchApp.swift` (engine + app-wide bootstrap + `offlineManager.refresh()`)
- `VoxglassWatch/WatchStorageManager.swift` (real cache — WS5)
- `VoxglassWatch/WatchSearchView.swift` (scope + filter + wired actions — WS6)
- `Voxglass/Core/Library/LibraryRepository.swift`, `Voxglass/Core/Playback/PositionStore.swift` impl, bookmark store (mutation-log hooks — WS3)
- `scripts/guard_wiring.sh` (new guards — §6)
- `VoxglassTests/…` (new tests — §7)

**Deleted:**
- `VoxglassWatch/WatchConnectivitySession.swift` (orphaned; replaced by CloudKit for data + `WatchAudioRelay`/`PhoneAudioRelay` for the optional audio-byte accelerator)

**Key existing symbols to reuse (do not reinvent):**
- `ContentKey.book(forSourceURL:kind:)` / `ContentKey.chapter(...)` — dedupe identity (C7)
- `StreamCacheUtils.key(for:)` — SHA-256 cache key (C6)
- `LibraryRepository.importInternetArchiveItem(_:sourceKind:)` and `CatalogStore.importResult(...)` — the import path Search must call (WS6)
- `LibraryBackupService`'s `content_key` dedupe/upsert pattern — template for CloudKit apply-remote logic
- `WatchStoragePolicy` / `WatchEvictionPolicy` — storage caps + LRU (WS5)
- `AppPreferencesStore.Keys.iCloudSyncEnabled` — the user's iCloud-sync preference; the only sync condition besides account availability (C2/C3)
