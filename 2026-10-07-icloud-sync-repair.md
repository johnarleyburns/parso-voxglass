# iCloud sync field investigation and repair

Investigated the connected iPhone and installed production Mac app on October 7,
2026. Both installed apps report version 1.1.425. The Mac's signing entitlements
use CloudKit Production in `iCloud.guru.parso.voxglass`; both devices use the same
account-scoped authoring database. Account/environment mismatch does not explain
this report.

## My Books queue starvation

The copied phone library database contains 25,631 pending changes:

- 25,573 PlaybackPosition updates, of which 25,504 reference nonexistent rows.
- 69 queued updates reference real playback positions; 78 actual position rows exist.
- 37 Book deletions, 8 Book updates, and 13 Bookmark updates.
- No CloudKit record mappings have been persisted.

An older position writer generated a fresh ID for each checkpoint while SQLite's
`ON CONFLICT(book_id, chapter_id)` retained the original row ID. Its mutation queue
used the discarded fresh ID, accumulating requests that cannot be built. The
current writer had already been changed to prefer the persisted ID; this repair
also removes the fallback to the transient ID if the lookup fails.

The uploader inspected only the first 50 requests and retained every unbuildable
request. The first 50 were orphaned position IDs, so Sync Now sent nothing and
never reached the books.

Repair removes only orphaned playback *queue entries*, never playback rows. On a
copy of the phone database the queue drops to 127 and all 78 positions remain.
Books are processed before dependent records; one sync drains successive batches
and moves past unbuildable requests. Upload acknowledgments remove only the queue
revision they sent, preserving edits made during an upload. Concurrent send calls
are serialized, and playback autosaves do not cancel a running send.

Old Book deletions without a record mapping remain unresolved; they are preserved
rather than silently dropping a requested deletion. The status reports blocked
changes explicitly, while other buildable changes can proceed.

## Recording backup writes and verification disagree on zone

`CloudKitProductionSync.records(from:)` constructed CKRecord.ID with only a record
name, writing records into CloudKit's default zone. Its fetch and delete paths
used `VGProductionStudioZone`. `CloudAssetUploader` therefore uploaded successfully,
then looked for the asset in a different zone and reported that the uploaded record
could not be re-read for verification.

Every production record and parent reference now uses the same explicit zone as
verification and hydration. Individual CloudKit save/fetch failures and zone
creation failures are propagated instead of treating overall operation completion
as proof that each record succeeded. Recording uploads require the audio attachment;
a conflict retry retains the current recording fields and attachment. Existing
unverified local recordings are retained and retried through the normal backup path.

## Narration metadata receive failures can look like empty success

The phone's authoring store has 3 project, 3 chapter, and 10 paragraph entities.
All 16 have server change tags and sent outbox receipts. The Mac has zero entities.
The phone's record system fields identify the intended `VGStudioAuthoringV2` zone.

The authoring CKSyncEngine fetched all private zones by default. Its reducer tried
to decode every incoming record as an authoring-v2 entity, including unrelated
library and recording records. It logged local import failures and blocked a
checkpoint, but `synchronize()` did not check those failures before reporting
success. Thus an empty Mac store could be reported as “no projects were found.”

Fetch/send now explicitly scope the engine to `VGStudioAuthoringV2`, and callbacks
filter by that zone. Failed imports and per-zone fetch errors make the sync action
fail visibly. A one-time, account-scoped checkpoint repair replays cloud records
without deleting local entities, pending edits, or upload receipts.

Apple documents the default all-zone fetch and explicit zone scoping:
https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/fetchchangesoptions/scope-swift.enum
Apple documents individual record results separately from operation completion:
https://developer.apple.com/documentation/cloudkit/ckmodifyrecordsoperation/perrecordsaveblock-7yq9d

The existing CI launch-restore regression is also repaired: a background cloud pull
must leave an already-loaded local playback session alone, as documented. Explicit
newer remote Now Playing adoption continues through its separate handoff method.

## Scope of validation

Tests exercise stable position identities across 200 checkpoints, orphan-queue
cleanup without position loss, multi-batch draining past blocked requests, failed
upload retention, acknowledgment races, matching production record/reference
zones, required recording attachments, and checkpoint repair preserving local work.

Device databases were copied and inspected, not modified. Actual cloud round-trip
verification requires running the updated signed applications on both devices.

Validation completed: the full host suite passed 1,575 tests; the final focused
sync/position/authoring/restore run passed 91 tests. iPhone/embedded Watch and Mac
compile checks passed, as did production guards, the Swift 6 guard, and whitespace
checks. Compilation used signing-disabled builds; live production iCloud behavior
has not yet been exercised with updated installed applications.

## Mac My Books verification

Mac bootstrap, manual Sync Now, and the periodic sync path call the independent
library CloudKit engine and refresh My Books after the pull. Narration opt-in is
not a requirement for that library pull.

Additional library fixes keep Source IDs aligned with Book source references;
import books and chapters before applying dependent positions/bookmarks; retain
the previous cloud token when any library import fails; and reset historical
library checkpoints once to replay records older builds may have skipped.

When the same book was imported independently on both devices, chapter UUIDs
can differ. Cloud chapter IDs are mapped to existing local chapters by content
key/index, preserving downloaded files and local identity. Missing cloud chapters
are added, and received Book record mappings allow cloud deletions to reach the
local library.

Regression tests now cover a fresh My Books pull without narration records,
repeated imports, real Source URLs, chapters and playback positions, preservation
of a failed import's checkpoint, and matching remote positions/bookmarks to an
existing Mac library plus applying a cloud Book deletion. The focused cloud and
restore run passed 75 tests; the latest Mac compile passed.
