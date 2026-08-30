# Voxglass Watch Rearchitecture — Acceptance Matrix

Evidence: `Host` = logic/unit test, `Sim` = deterministic injected UI smoke, `Device` =
paired physical iPhone/Watch, `Guard` = source/build/archive boundary. Device evidence cannot
be replaced by simulator evidence. All rows below are release-blocking unless marked `No`.

| ID | Requirement | Evidence |
|---|---|---|
| A-01 | Watch target and transitive closure contain no CloudKit import/symbol/container | Guard |
| A-02 | Watch entitlements contain no iCloud, CloudKit, push, or app group | Guard + archive |
| A-03 | Local watch store explicitly disables CloudKit | Host + Guard |
| A-04 | Watch links no catalog search, production sync/review, or credential provider | Guard |
| A-05 | iPhone remains sole My Books and desired-download authority | Host |
| A-06 | Protocol diagnostics exclude titles, URLs, paths, and credentials | Host |
| B-01 | Clean watch launch creates a persistent local store | Host + Sim |
| B-02 | Relaunch preserves complete books, files, manifest, and playback position | Host + Sim |
| B-03 | Store corruption recovers without deleting validated durable audio | Host |
| B-04 | Missing/corrupt asset makes book unavailable offline and requests reconcile | Host |
| B-05 | Existing provably complete cache is adopted during upgrade | Host + Device |
| C-01 | Versioned envelope round-trips every payload | Host |
| C-02 | Duplicate, stale, late, and out-of-order delivery converges | Host |
| C-03 | Immediate requests time out within eight seconds with actionable state | Host + Sim |
| C-04 | Reachability blip under two seconds does not replace the UI | Host |
| C-05 | Confirmed disconnect filters to complete local books once | Host + Sim + Device |
| C-06 | Reconnect restores projection without replacing navigation/playback | Sim + Device |
| C-07 | Unknown version preserves offline books and shows update guidance | Host + Sim |
| C-08 | Paired-library identity change cannot overwrite unrelated downloads | Host + Sim |
| D-01 | Connected watch lists complete iPhone My Books projection | Host + Sim + Device |
| D-02 | Disconnected watch lists only complete validated downloads | Host + Sim + Device |
| D-03 | Deleted phone book disappears connected but durable download removal is explicit | Host |
| D-04 | Imported folder/ZIP/single-file chapters retain title, order, and offsets | Host + Device |
| E-01 | Phone Download action persists desired root and shows queued | Host + Sim |
| E-02 | Sender progress never renders Downloaded before watch acknowledgement | Host + Sim |
| E-03 | Relaunch resumes outstanding file transfers and state | Host + Device |
| E-04 | File callback is copied before return and verified by size/hash/codec | Host |
| E-05 | Complete acknowledgement marks phone and watch Downloaded | Host + Sim + Device |
| E-06 | Partial book is resumable but invisible disconnected | Host + Sim |
| E-07 | Remove is idempotent and leaves My Books on iPhone untouched | Host + Device |
| E-08 | Storage reserve rejects safely with actionable error | Host + Device |
| F-01 | Durable local chapter always wins playback resolution | Host |
| F-02 | Approved public URL streams on watch while connected | Host + Device |
| F-03 | Phone-local chapter JIT transfers and plays without full-book completion | Host + Device |
| F-04 | Ephemeral JIT cache never marks book Downloaded or exposes it offline | Host + Sim |
| F-05 | Disconnected playback needs neither phone nor network | Sim + Device |
| F-06 | Now Playing publishes artwork, title, chapter, duration, elapsed, and rate | Host + Sim + Device |
| F-07 | Route loss/interruption/media reset recover honestly | Host + Device |
| F-08 | Position persists and uses chapter-relative offsets for shared audio files | Host + Device |
| F-09 | Previous/next controls move exactly one chapter, clamp at book ends, and reset/restore chapter-relative position correctly | Host + Sim + Device |
| U-01 | Connected UI contains only My Books, book detail/download, and Now Playing | Sim + Guard |
| U-02 | Disconnected empty state directs download from iPhone | Sim |
| U-03 | Every asynchronous action immediately exposes accepted or typed failure | Sim |
| U-04 | Status uses text/icon, not color alone; VoiceOver labels are meaningful | Host + Sim |
| U-05 | Dynamic Type, Reduce Motion, and 44pt targets are respected | Guard + Device |
| U-06 | On a 40 mm Apple Watch SE, artwork/title/progress and all three primary transport controls fit without horizontal clipping, overlap, or scrolling | Sim screenshot/frame test + Device |
| U-07 | Previous chapter, play/pause, and next chapter each retain a 44×44pt hit target and logical VoiceOver order at supported Dynamic Type sizes | Sim frame test + Device |
| S-01 | iPhone smoke proves not-requested → progress → downloaded → remove UI | Sim |
| S-02 | Watch smoke proves connected JIT, download, disconnected filtering/playback | Sim |
| S-03 | Simulator smoke uses injected transport and makes no pairing/network claim | Review |
| S-04 | Locked/background/force-quit phone paths reconcile | Device |
| S-05 | Bluetooth-only, shared Wi-Fi, and no-network paths are exercised | Device |
| S-06 | iOS compile, concrete Watch simulator compile, logic, guards, and smokes pass CI | CI |

## Stable accessibility identifiers

- iPhone: `library.watchDownload.<bookKey>`, `library.watchStatus.<bookKey>`,
  `library.watchRemove.<bookKey>`, `library.watchRetry.<bookKey>`.
- Watch root: `watch.library`, `watch.connection`, `watch.nowPlaying`,
  `watch.book.<bookKey>`, `watch.empty.downloads`.
- Watch detail: `watch.book.play`, `watch.book.download`, `watch.book.remove`,
  `watch.book.status`, `watch.chapter.<chapterKey>`.
- Watch player: `watch.player.artwork`, `watch.player.title`, `watch.player.chapter`,
  `watch.player.elapsed`, `watch.player.remaining`, `watch.player.previousChapter`,
  `watch.player.playPause`, `watch.player.nextChapter`, `watch.player.output`.
