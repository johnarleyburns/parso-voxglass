# Phone-owned watch listening (AAC96)

## Contract

- Choose books on the iPhone. Only explicitly selected books appear in the compressed watch catalog. It contains titles, IDs, chapter timing, local filenames/checksums, resume positions and transfer state; never remote audio or artwork URLs.
- The iPhone resolves complete cached or local-bookmark audio, extracts shared-file chapters, and prepares complete 96,000 bit/s AAC/M4A files. Originals and narration masters are untouched. Artwork is a phone-generated thumbnail.
- Blocking AVFoundation decoding runs on a dedicated dispatch queue, not Swift's bounded cooperative worker pool. Each buffer drains an autorelease pool; cancellation is communicated through a locked flag. Concurrent conversion is regression-tested with the cooperative pool restricted, as well as in the regular host suite.
- `WCSession.transferFile` carries only whole prepared AAC chapter files and artwork. No audio chunking, reachability gate, watch-initiated download, streaming, or automatic resubmission.
- Metadata follows Cladiron's retained-context/latest-state pattern: compressed binary property-list catalog via `updateApplicationContext`, with live messaging as a fast path. The watch consumes `receivedApplicationContext`, not its own outgoing `applicationContext`. Delivery never depends on a metadata confirmation exchange.
- Watch Sync Now sends one live sync request only while the native iPhone app is reachable. Disconnected Sync Now is disabled. Periodic inventory reports are status, not requests; they include an explicitly empty inventory after reset. They have durable increasing sequence numbers so delayed old reports cannot overwrite newer truth.
- The receiver synchronously takes ownership of Apple's temporary file before the callback returns, verifies size/SHA-256 and readable AAC, and atomically installs it. Unique verified files on disk determine installation, not callback counts or transfer reaching 100%. Files may arrive before catalog metadata; subsequent reconciliation discovers them.
- Failed native delivery/installation or an uninstalled transfer after 24 hours offers an explicit phone retry. Submission dates persist across phone relaunch. No watchdog sends another file. A later valid installed report can still complete an expired transfer.
- Removal originates on the phone, cancels outstanding files for that book, and uses versioned deletion. A partial zero-byte status is not a removal result. Older removals/files cannot defeat a newer explicit submission.
- Watch playback is local-only. Native system volume controls replace the custom player-gain crown. Diagnostics are in Sync Status. A confirmed About reset clears listening data on next launch, not phone originals or unsubmitted narration review events.

## Regression coverage

`VoxglassTests/Production/WatchPhonePushTests.swift` uses a real CC0 audio fixture to exercise MP3-to-AAC96 preparation, extensionless cached input, chapter clipping, native-readable installed AAC, duplicates, files-before-metadata, relaunch, corruption, path confinement, persisted selection, stale installation/removal reports, explicit empty inventory, and the 24-hour manual-retry deadline. Existing watch foundation/offline suites remain enabled. UI smoke expectations now reject Download/Stream controls on the watch.

Host tests do not prove paired-device delivery, Bluetooth output, or audible watch playback. Compile-only builds do not prove those either. No local simulator was used for this change; Xcode reported both physical devices offline.

## Paired-device test plan

1. Install the matching phone and watch build. Open both apps. Watch Sync Status must distinguish native iPhone reachability from installed books. Sync Now, when connected, should show **Sync updated** after receiving the phone catalog. With the phone unreachable, it must instead explain that Sync Now is available when connected; no request is queued by the watch.
2. On the phone, send a short fully cached book. My Books → On My Watch must show preparation/submission without an installed checkmark. Watch Sync Status should move from zero chapters to actual installed chapters. **Audio installed and ready to play** and the installed book count—not phone transfer progress—confirm success.
3. Play the book from the watch, then put the phone out of range. Check audible Bluetooth output, Crown volume direction, chapter transitions, playback speed, sleep timer, and remembered position after watch relaunch. Repeat with a shared-file M4B and a long audiobook; chapter 2 must not replay chapter 1.
4. Remove the book from the phone's watch shelf, then explicitly send it again. A delayed old removal must not remove the new copy. Confirmed watch reset followed by phone sync must show zero installed books, not historical completed transfers. Older selections may need an explicit **Try Again** on the phone to adopt AAC96; no migration automatically submits audio.

If a transfer does not complete, capture the book name, phone On My Watch state, phone last-catalog/last-report times, watch installed chapter counts, Audio receipt, Artwork receipt, and any native error from Sync Status. **No receipt** means audio delivery is unconfirmed; **received/validated but incomplete chapters** means some files or their matching catalog have not arrived; **installed and ready** with no sound narrows the issue to playback/output rather than transfer.
