# Offline Download Playback & Watch Transfer Plan

**Intended repo path:** `docs/OFFLINE_DOWNLOAD_PLAYBACK_AND_WATCH_TRANSFER_PLAN.md`

**Goal:** downloaded books play offline on the iPhone with the same reliability as
local-folder books, and getting a book onto the Apple Watch for offline listening
is possible and reliable — either the watch downloads it itself, or the iPhone
sends it, but the path actually works end to end.

**Symptom (reported 2026-08-05):**
1. Offline listening works for **local-folder tracked** books but **not for
   downloaded** books. The download appears to complete, but later — offline —
   the downloaded book won't play.
2. There is **no iPhone UI to download a book to the watch** for offline listening.

This document is self-contained: root causes are verified against the code with
file/line references, and the fix is specified per file. Line numbers are as of
commit `8358ede`.

---

## 1. How offline availability works today (verified)

### 1.1 Two kinds of "offline" book — only one goes through the cache

- **Local-folder books** carry a real `local_url` in the `chapters` table
  (`DatabaseMigrations.swift:90`). `Chapter.resolvedPlayableURL()` rebases that
  path onto the current container and returns it when the file exists
  (`Voxglass/Core/Models/BookModels.swift:102`). Because a `file://` URL is **not
  remote-cacheable** (`StreamCacheUtils.isRemoteCacheable`,
  `StreamCacheUtils.swift:18`), `AVPlayerAudioEngine.makePlayerItem` plays it with
  a plain `AVPlayerItem(url:)` — no cache, no resource loader, no network
  (`Voxglass/App/AVPlayerAudioEngine.swift:36-48`). This path has no offline
  dependency, which is why it always works.

- **Downloaded books** (a *streaming* book the user made available offline) have
  no `local_url`. `resolvedPlayableURL()` returns the persisted `remote_url`
  (http). Playback therefore routes through the streaming cache: `makePlayerItem`
  swaps the scheme to `voxglass-cache://`, attaches a `CachingResourceLoader`, and
  the loader serves bytes out of `StreamCacheStore` (`AVPlayerAudioEngine.swift:38-42`;
  `CachingResourceLoader.swift`). **Offline playback of a downloaded book is
  entirely dependent on the cached blob + its metadata still being on disk.**

### 1.2 The download → cache contract is internally consistent

- `OfflineDownloadManager` downloads each cacheable chapter with a background
  `URLSession` and ingests the finished file into the shared cache
  (`OfflineDownloadManager.swift:228` → `StreamCacheStore.ingestCompleteFile`).
- Both the downloader and the player key on `StreamCacheUtils.key(for:)` =
  `SHA256(url.absoluteString) + "-" + ext` (`StreamCacheUtils.swift:9`), and both
  derive that URL from `resolvedPlayableURL()`
  (`OfflineDownloadManager.swift:315`; coordinator load at
  `PlaybackCoordinator.swift:376`). Keys match.
- `ingestCompleteFile` writes the blob, inserts the full range `0..<total` into a
  `ByteRangeMap`, marks the entry `complete`, sets `totalBytes`, and pins it
  (`StreamCacheStore.swift:130-157`). `ByteRangeMap` is `Codable` and round-trips
  (`ByteRangeMap.swift`). On relaunch, `loadMetas` + `loadPinnedKeys` restore all
  of this from disk (`StreamCacheStore.swift:52-53`).

There is a **single** `StreamCacheStore.shared` instance and a single on-disk
location, so downloader and player read/write the same place. The key, the range
map, the completeness flag, and the pin all persist. **The cache-layer contract
is correct** — which is the important clue: the failure is not a key/lookup bug,
it is that the blob is *gone* by the time offline playback needs it (see RC1).

### 1.3 Where the cache physically lives

`StreamCacheStore.cacheBaseDirectory()` returns the **system Caches directory**
(`StreamCacheStore.swift:33`), and both the streaming cache and the pinned
"offline downloads" live under it: `Caches/Voxglass/StreamCache`
(`StreamCacheStore.swift:45`), with metadata in `Caches/Voxglass/StreamCacheMeta`
and pins in `Caches/Voxglass/StreamCachePins.json`.

### 1.4 Watch: on-device store, native playback, and the phone transport

- The watch has its **own** on-device store, `WatchStorageManager`, writing to
  `Caches/voxglass-watch-audio/<key>` (`WatchStorageManager.swift:26`), keyed by
  `WatchChapterCache.key(for:)` = `SHA256(opusURL ?? remoteURL)` — **opus-preferring**
  (`Voxglass/Core/Models/WatchModels.swift:252`).
- `WatchPlaybackCoordinator.resolvedURL(for:)` prefers a local file, then opus,
  then remote (`WatchPlaybackCoordinator.swift:21`), and `localURLProvider` is
  wired to `WatchStorageManager.localURL(for:)` (`WatchAppServices.swift:58`). So
  a downloaded chapter *does* play locally on the watch — **if** its bytes are on
  the watch.
- Getting bytes onto the watch (`WatchAppServices.downloadBook`,
  `WatchAppServices.swift:171`): first ask the phone for each chapter via
  `relay.requestChapter(...)` (`:175`), wait 2 s, then fall back to the watch
  downloading directly over its own radio (`WatchStorageManager.downloadChapter`).
- The phone answers a chapter request in `PhoneAudioRelay.findAndSendChapter`
  (`PhoneAudioRelay.swift:249`) and ships the file with `transferChapterFile`
  (`:63`).

---

## 2. Root causes, ranked

### RC1 — Offline downloads live in the purgeable Caches directory (iPhone; **primary**, high confidence)

`StreamCacheStore` stores the pinned "offline" blobs **and** their metadata in the
system Caches directory (`StreamCacheStore.swift:33,45`). Apple documents Caches
as reclaimable: the system deletes its contents to free space, it is not backed
up, and it is emptied when the app is offloaded. "Pinning" only protects a blob
from the app's **own** LRU eviction — `evictToFit` skips pinned keys
(`StreamCacheStore.swift:~305`) — it does **nothing** to stop iOS from purging the
directory out from under the app.

Because the blob and the meta live together in Caches, the system reclaims both.
After that, `totalBytes(for:key)` returns nil, `CachingResourceLoader.ensureResolvedLength`
falls through to a network probe (`CachingResourceLoader.swift:110-118`), and
`serve` finds an empty range map and tries to fetch bytes — both of which fail
offline. The book was "downloaded," but the download is gone.

Local-folder books are unaffected: their audio is the user's own file, reached
via a security-scoped bookmark **outside** Caches, so it survives. This is exactly
the reported asymmetry.

> Confidence: this is the leading explanation and it is architecturally wrong
> regardless of whether a second factor is also present — offline downloads must
> not live in a purgeable location. §4 gives a decisive repro to confirm before
> shipping the migration.

### RC2 — Phone→watch transfer reads a directory nothing writes to (certain)

`PhoneAudioRelay.findAndSendChapter` looks for the chapter blob in
`Caches/voxglass-cache/<chapterKey>` (`PhoneAudioRelay.swift:249-252`). Nothing is
ever written there: `"voxglass-cache"` is the **URL scheme** string
(`StreamCacheUtils.scheme`, `StreamCacheUtils.swift:6`), not a folder. The real
blobs are in `Caches/Voxglass/StreamCache` (`StreamCacheStore.swift:45`). So
`FileManager.fileExists` is always false, `findAndSendChapter` returns false, and
the phone transfers nothing. The watch's `requestChapter` step is dead; every
watch download falls through to the watch downloading directly over its own radio.

### RC3 — Phone and watch disagree on a chapter's cache key (certain)

Even with RC2 fixed, the request would miss. The watch requests with
`WatchChapterCache.key` = `SHA256(opusURL ?? remoteURL)` (opus-preferring,
`WatchModels.swift:252`), but the phone stores under
`StreamCacheUtils.key(resolvedPlayableURL())` = `SHA256(remoteURL)` (opus is
ignored by `resolvedPlayableURL`, `BookModels.swift:102`). For any chapter that
has an `opusURL`, the two keys diverge and the lookup fails. There is no single
source of truth for "the cache identity of a chapter's audio."

### RC4 — No consumer iPhone UI to send a book to the watch; the only path is Production-only and reactive (certain; this is the reported gap)

- The single phone-side **"Download queue to Apple Watch"** control lives in the
  **Production/Studio** flow (`ProductionViews.swift:495`, calling
  `downloadToWatch(using:)` at `:487`). That ships narration *review segments* to
  the watch — a different subsystem from the consumer audiobook library.
- No consumer view calls `PhoneAudioRelay.transferChapterFile`. The only caller is
  the reactive `findAndSendChapter` (broken by RC2). So from the iPhone library or
  player there is no affordance and no working plumbing behind one.
- The current design is watch-initiated by intent: `SettingsView`'s WatchSyncCard
  states the watch "can still search, stream, and download independently"
  (`SettingsView.swift:632`). That is a legitimate model, but combined with RC2/RC3
  it means the watch's only *working* route is downloading over its own radio,
  which many users perceive as "there's no way to put a book on my watch."

### RC5 — Watch downloads the opus rendition but plays via plain AVPlayer (conditional, medium confidence)

`WatchChapterCache.canonicalURL` prefers `opusURL` (`WatchModels.swift:252`), and
`WatchStorageManager.downloadChapter` downloads that URL, but `WatchPlaybackEngine`
is a vanilla `AVPlayer` (`WatchPlaybackEngine.swift:load`). AVFoundation cannot
decode Opus-in-Ogg. Today `opusURL` is populated only from CloudKit/backup rows
(import sets it nil, `LibraryRepository.swift:698`), so this bites only chapters
hydrated from another device. It becomes a live bug the moment opus URLs are
populated at import. Worth fixing alongside RC3 since both stem from the
opus-preferring identity.

### RC6 — `CachingResourceLoader.contentType` declares UTIs AVFoundation may reject (watch-list, low confidence)

For custom-scheme assets, AVFoundation trusts the loader's declared `contentType`
rather than sniffing the file. `contentType()` returns `"org.xiph.flac"` for FLAC
(`CachingResourceLoader.swift:~95`), which is not a system-registered UTI on all
OS versions; a cached-only FLAC asset can fail to become playable. This affects
both online and offline (so it is *not* the reported asymmetry) but is a latent
correctness issue on the same path. Track, verify with a FLAC download, fix only
if reproduced.

---

## 3. Fix plan

Two invariants drive the fixes:

- **INV-A — Offline downloads are durable.** Any blob the user explicitly
  downloaded for offline use lives outside the system-purgeable Caches directory
  and is excluded from iCloud backup. The passive streaming cache may stay in
  Caches.
- **INV-B — One canonical audio identity per chapter.** A single function decides
  the URL used for the cache key, and it is used identically by the phone
  downloader, the phone player, the watch store, and the phone→watch transfer.

### Fix 1 — Move pinned/offline blobs out of Caches (satisfies INV-A, addresses RC1)

`Voxglass/Core/Services/Playback/StreamCacheStore.swift`

- Split storage into two roots:
  - **Streaming cache** (unpinned, evictable): stays under
    `Caches/Voxglass/StreamCache` as today.
  - **Offline store** (pinned): a new base under Application Support, e.g.
    `applicationSupportDirectory/Voxglass/OfflineAudio`, created with
    `withIntermediateDirectories: true`, and marked
    `URLResourceValues.isExcludedFromBackup = true` on the directory.
- `fileURL(for:)` returns the offline root when `pinnedKeys.contains(key)`, else
  the streaming root. `pin(_:)` **moves** the existing blob + meta from the
  streaming root to the offline root (and `unpin` moves it back or removes it).
  `ingestCompleteFile` writes directly into the offline root (it already pins).
- Persist offline metas under an `OfflineMeta` dir alongside the offline blobs so
  blob and meta share a lifetime and a location; keep streaming metas where they
  are.
- **One-time migration** on first launch after the change: for every key in
  `StreamCachePins.json`, move `Caches/Voxglass/StreamCache/<key>` (+ meta) into
  the offline root. Any pinned key whose blob is already missing (a previously
  purged download) is dropped and its `download_records` deleted so the UI shows
  it as not-downloaded rather than falsely "cached."

Note: this makes `OfflineDownloadManager.removeOffline` and the §6 purge paths
operate on the offline root automatically via `fileURL(for:)`; verify both.

### Fix 2 — Repair the phone→watch transfer (addresses RC2)

`Voxglass/App/PhoneAudioRelay.swift`

- Rewrite `findAndSendChapter` to resolve the blob through the store instead of a
  hand-built path:
  - `guard await StreamCacheStore.shared.isComplete(chapterKey) else { return false }`
  - `let fileURL = await StreamCacheStore.shared.fileURL(for: chapterKey)`
  - transfer that URL. Make the method `async` (it already runs inside a `Task`).
- Delete the `"voxglass-cache"` directory literal (`:251`); never treat the scheme
  string as a folder again.

### Fix 3 — One canonical audio identity (satisfies INV-B, addresses RC3, enables RC5 fix)

New: `Voxglass/Core/Models/ChapterAudioIdentity.swift`

```swift
public enum ChapterAudioIdentity {
    /// The single URL that defines a chapter's cache identity everywhere.
    public static func canonicalURL(for chapter: Chapter) -> URL? { /* decide once */ }
    public static func cacheKey(for chapter: Chapter) -> String? {
        canonicalURL(for: chapter).map(StreamCacheUtils.key(for:))
    }
}
```

- Decide the policy in one place. Recommended: **do not prefer opus** for the
  canonical *download/transfer* identity until the engines decode it (see Fix 5),
  i.e. canonical = `resolvedPlayableURL()`-equivalent. This makes phone and watch
  agree by construction.
- Replace call sites:
  - `OfflineDownloadManager.cacheableChapters` (`:315`) → `ChapterAudioIdentity`.
  - `WatchChapterCache.key` / `canonicalURL` (`WatchModels.swift:252`) → delegate
    to `ChapterAudioIdentity` (keep the type as a thin shim to avoid churn in the
    watch target).
  - `WatchAppServices.downloadBook` request key (`:175`) and
    `WatchAppServices.onFileReceived` match (`WatchAppServices.swift:~140`) → same.
- Add a host-testable assertion test: for a fixture chapter, the phone download
  key, the phone transfer key, and the watch store key are byte-identical.

### Fix 4 — Product decision: how a book gets to the watch (addresses RC4)

Pick one; both are compatible with the fixes above.

- **Option A (recommended) — phone-push affordance.** Add a "Download to Apple
  Watch" row to the consumer book page (`BookPageView` / `BookPageActionRow`) and
  a per-book control in `LibraryView`. On tap: for each chapter, if the phone has
  the blob (`isComplete`), `transferChapterFile` it; if not, either download it on
  the phone first (reuse `OfflineDownloadManager`) then transfer, or send a
  lightweight "please self-download" hint to the watch. `WCSession.transferFile`
  is background-capable, so this is more robust than the watch downloading over
  its own radio, and it matches user expectation ("send it from my phone").
  Surface transfer progress from the existing `WatchStorageSnapshot` the watch
  already publishes back (`PhoneAudioRelay.applyWatchStorageSnapshot`).

- **Option B — keep watch-initiated, make it reliable.** Leave download on the
  watch, but with Fix 2 + Fix 3 the `requestChapter` → phone-transfer path now
  actually delivers, so the watch no longer depends on its own radio when the
  phone is nearby. Update the WatchSyncCard copy to say the watch pulls from the
  phone when reachable and falls back to direct download otherwise.

Recommendation: ship **Option A** (it is the reported gap) and let it ride on the
now-working transport from Option B.

### Fix 5 — Keep watch downloads to a watch-playable codec (addresses RC5)

- With Fix 3's canonical identity not preferring opus, `downloadChapter` fetches
  the mp3/remote rendition that `WatchPlaybackEngine`'s `AVPlayer` can decode. If
  opus is ever desired on the watch, gate `canonicalURL`'s opus branch behind a
  capability flag that is only true once the watch engine can decode the container
  used (CAF-wrapped Opus is decodable; raw Ogg/Opus is not).

---

## 4. Diagnostics — confirm RC1 before shipping the migration

RC1 is the one probabilistic claim; make it falsifiable with a device repro:

1. On device, download a streaming book to offline. Confirm it plays offline
   immediately (rules out a same-session bug).
2. Locate the blob: `Caches/Voxglass/StreamCache/<key>` should exist and match the
   downloaded size; its meta should be `complete: true` with `totalBytes` set.
3. Force the system to reclaim Caches (simplest reliable proxy: offload the app
   via Settings › General › iPhone Storage, or fill storage to trigger eviction),
   then relaunch **offline** and attempt playback.
4. Expected under RC1: the blob and meta are gone, `totalBytes(for:key)` is nil,
   and playback falls to the network probe and fails.

If step 4 reproduces, RC1 is confirmed and Fix 1 is the remedy. If the blob
survives Caches reclamation yet playback still fails, escalate RC6 (declared UTI)
and capture the `AVPlayerItem.error` code for the failing item.

---

## 5. Tests

Host-testable (no device):

- `ChapterAudioIdentity` parity: phone-download key == phone-transfer key ==
  watch-store key for chapters with and without an `opusURL` (Fix 3).
- `StreamCacheStore` routing: a pinned key resolves `fileURL` to the offline root
  and an unpinned key to the streaming root; `pin` moves blob+meta; `unpin`
  reverses; migration relocates existing pins and drops pins whose blob is missing
  (Fix 1).
- `findAndSendChapter` resolves via the store and returns false (without touching
  the network) when the blob is absent or incomplete (Fix 2).

Integration / device:

- Download offline → offload app → relaunch offline → plays from the offline root
  (Fix 1, closes the reported bug).
- Phone-push: tap "Download to Apple Watch," airplane-mode the watch, confirm the
  chapters play on-watch from `voxglass-watch-audio` (Fix 2 + Fix 4).

---

## 6. Commit plan

1. **S1 — `ChapterAudioIdentity` + key parity tests** (Fix 3). No behavior change
   yet; establishes INV-B and the shim for `WatchChapterCache`.
2. **S2 — Offline store out of Caches + migration** (Fix 1). Closes the reported
   iPhone bug. Ship behind a launch migration; verify §6 purge/remove paths.
3. **S3 — Repair phone→watch transfer** (Fix 2). Transport now delivers.
4. **S4 — Consumer "Download to Apple Watch" UI** (Fix 4, Option A) riding on S3.
5. **S5 — Codec guard** (Fix 5) and, if reproduced, RC6 UTI fix.

Each step is independently shippable; S2 is the one that resolves the reported
offline-playback failure and should land first if a single fix is wanted.

---

## Requirements traceability

| Reported problem | Root cause | Fix | Verified by |
| --- | --- | --- | --- |
| Downloaded books don't play offline (local-folder do) | RC1 | Fix 1 (+ INV-A) | §4 repro, S2 device test |
| — latent: cached-only FLAC fails | RC6 | Fix 5 / UTI fix | FLAC download test |
| No iPhone UI to download to watch | RC4 | Fix 4 (Option A) | S4 device test |
| Watch can't get bytes from phone | RC2, RC3 | Fix 2, Fix 3 (INV-B) | key-parity + transfer tests |
| Watch would fail on opus rendition | RC5 | Fix 3 + Fix 5 | codec guard test |
