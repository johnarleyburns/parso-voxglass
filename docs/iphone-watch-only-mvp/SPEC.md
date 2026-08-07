# Voxglass iPhone + Watch Audiobook Studio - MVP Specification

Status: revised product specification derived from `/Users/arley/github/parso-voxglass/docs/voxglass-mvp/VOXGLASS_STUDIO_SPEC.md`.

Date: 2026-08-07.

Scope thesis: Voxglass becomes an iPhone-first audiobook production environment for solo narrators. The Mac app is removed from the model. iPhone is the single writer for projects, recording, validation, and export. Apple Watch is a companion for review, dictation, and offline queue work. Free users can complete LibriVox and Internet Archive packages. Pro unlocks commercial retail delivery.

Mockups live in [`mockups/`](mockups/index.html). Each view below references the relevant HTML file.

## 1. Product Definition

Voxglass iPhone Studio is not a DAW. It is a manuscript-addressed audiobook workflow optimized for the best practical iPhone setup: USB-C audio interface or USB microphone, wired headphones or direct monitoring, external storage-aware file handling, and a UI that treats a book as chapters and paragraphs rather than a timeline.

The target user is a solo narrator, LibriVox volunteer, indie author, or semi-pro narrator who wants to produce an audiobook without maintaining a desktop studio. The product must be honest: it can organize, record, validate, master, and package; it cannot make a noisy room or low-quality Bluetooth input sound like a treated studio.

### Platform Surfaces

| Surface | Job | Creates audio? | Owns project state? |
|---|---|---:|---:|
| iPhone app | Project creation, source import, recording, takes, review, validation, storage, export, Pro purchase | Yes | Yes |
| Apple Watch app | Offline review queues, playback, approve/flag/pickup, dictated notes, recording remote | No | No |
| iCloud private database | Backup/offload of project metadata and narration assets | No | Remote mirror only |

Removed from the MVP:

- macOS Studio app.
- Mac project windows, Finder-first `.voxproject` workflow, AppKit entitlements, security-scoped bookmarks.
- Mac-to-phone projection model.
- CarPlay production review. The consumer CarPlay player may remain outside this spec, but production CarPlay is deferred so the MVP remains iPhone/watch-only.

### Distribution Lanes

| Lane | Tier | Output | Notes |
|---|---|---|---|
| LibriVox | Free | 128 kbps CBR mono MP3 per section, ID3 tags, durations, checklist | Human narration only. No paywall. |
| Internet Archive | Free | WAV/FLAC masters, optional MP3 derivatives, metadata, checksums, checklist | No auto-upload; user submits. |
| Personal master | Free | Lossless WAV chapters | User always has access to their own recording. |
| Commercial retail | Pro | ACX/aggregator MP3, mastered files, M4B, FLAC masters, retail sample, metadata, exported validation reports | One-time purchase. |

### Product Principles

1. Never lose a take. In-flight audio is written incrementally, recoverable after force-quit, interruption, route change, and disk pressure.
2. The text is the index. Recording, retakes, notes, validation, and review are addressed by paragraph.
3. Local storage is a working cache, not the only copy. Once an asset is verified in iCloud, non-working chapters may be evicted under user-controlled limits.
4. Free must be complete. LibriVox and Internet Archive contribution cannot hit Pro gates.
5. The app prepares files; the human submits.
6. Hardware truth beats marketing. Retail readiness checks must tell users when their mic/room cannot meet a destination requirement.

## 2. Free / Pro Boundary

### Free Forever

- Unlimited projects, chapters, paragraphs, takes, and recording time.
- Source import: EPUB, TXT, Markdown, DOCX.
- Script editing, split/merge, drift detection, generated LibriVox disclaimers.
- Recording, retakes, take comparison, imported audio assignment.
- Audio setup test and quality metrics.
- Review queues on iPhone and Watch.
- iCloud backup/offload for all project data subject to the user's iCloud quota.
- Full validation for every destination, including retail.
- LibriVox export.
- Internet Archive export.
- Personal WAV export.

### Pro

Single non-consumable IAP, product ID `guru.parso.voxglass.studio.pro` unless renamed before launch.

Pro unlocks:

- Retail destination profiles: ACX/Audible, Apple Books/aggregator, generic retail.
- Mastering chain.
- Chapterized M4B.
- FLAC commercial masters.
- Batch/resumable whole-book commercial export.
- Commercial metadata fields: ISBN/ASIN, publisher, rights holder, production copyright, retail sample.
- Validation report export as HTML/JSON for commercial/client delivery.

Recommended pricing remains: `$99` intro, `$149` standard. Purchase entry points are Export and Settings only. Validation remains ungated so the value is visible before purchase.

## 3. External Requirements

The destination constants are inherited from the source Studio spec and must be re-verified before release.

LibriVox profile:

- MP3, 128 kbps CBR.
- 44.1 kHz.
- Mono.
- Approximate perceived volume around 89 dB, warning-only.
- Spoken intro/outro disclaimers generated as paragraphs and recorded by the human narrator.
- AI/synthetic narration is ineligible.

Internet Archive profile:

- WAV or FLAC masters.
- Optional MP3 derivatives.
- Metadata sidecars and checksums.
- Generated upload checklist and suggested `ia upload` command.
- No auto-upload.

Commercial profile:

- ACX baseline: MP3 192 kbps or higher CBR, 44.1 kHz, one file per chapter/section, under 120 minutes per file.
- RMS between -23 dBFS and -18 dBFS.
- Peak at or below -3 dBFS.
- Noise floor at or below -60 dBFS RMS.
- Room tone at head/tail.
- Opening credits, closing credits, retail sample.
- Cover art at least 2400 x 2400 px for retail profiles.

Legal strings:

- "Voxglass does not determine copyright status."
- "Voxglass prepares files; it does not guarantee acceptance or determine copyright."
- "You submit these files yourself. Voxglass never uploads on your behalf."
- "LibriVox accepts only recordings made by human volunteers using their own voices."

## 4. Architecture

### Module Topology

`Voxglass/Core/Production` remains the shared pure core:

- `Domain`: project, chapter, paragraph, take, rights, destination profiles.
- `Store`: SQLite project store and migrations.
- `Text`: importers, segmenter, re-identification, drift, generated scripts.
- `Audio`: protocols, metrics, silence detection, ReplayGain.
- `Assembly`: segment queues, render plans, cache keys.
- `Review`: events, fold, queues.
- `Validation`: rules and reports.
- `Packaging`: builders and checklists.
- `CloudAssets`: iCloud asset manifest, offload state, hydration plans.
- `WatchLink`: phone/watch payloads and outbox.
- `License`: StoreKit protocol and Pro gate.

`Voxglass/Features/ProductionStudio` becomes the iPhone implementation:

- Project library, new project, source import.
- Script editor, recording workspace, audio setup.
- Take comparison, review queues, assembly.
- Metadata/rights/artwork.
- Storage and iCloud offload.
- Validation, export, settings, Pro purchase.

`VoxglassWatch/ProductionStudio` becomes the watch companion:

- Production list.
- Queue player.
- Offline queue storage.
- Dictated notes.
- Recording remote controls.

### Single-Writer Model

The iPhone is the only writer of project metadata and take selection. iCloud is a remote mirror and asset store, not a second editing surface. Watch actions are append-only `ReviewEvent`s relayed to the phone. If the phone is unavailable, watch events remain in a file-backed outbox.

This avoids the Mac spec's projection conflict model. There is no "publish preview"; the phone edits the real project and optionally uploads backed-up assets.

### Project Layout on iPhone

Projects live under:

`Application Support/ProductionProjects/<projectID>/`

```
project.sqlite
manifest.json
Audio/Original/<sha fanout>.<wav|caf|m4a>
Audio/Render/<cacheKey>.caf
Audio/ExportStaging/<runID>/
Text/source/<sha>.<ext>
Text/extracted/<sha>.json
Artwork/
Autosave/session.json
Autosave/takes/<uuid>.wav
Trash/
```

Users export portable packages through Files:

- `.voxmobileproject` backup bundle for moving projects.
- `.zip` or directory export for LibriVox, Internet Archive, and retail packages.
- Direct "Save to Files" via `UIDocumentPickerViewController`.

The app must not rely on users browsing internal project directories.

## 5. iCloud Backup and Offload

This is a first-class requirement, not a later sync feature.

### Storage Tiers

Every asset has one of these states:

| State | Meaning |
|---|---|
| `localOnly` | Exists only on iPhone. Never evict. |
| `uploading` | Upload in progress. Never evict. |
| `localAndRemote` | Local file exists and iCloud copy verified by SHA-256. Evictable if not pinned. |
| `remoteOnly` | Metadata local, blob in iCloud, file hydrated on demand. |
| `stagedForExport` | Hydrated for a running export. Never evict until export completes or is canceled. |
| `missing` | Metadata references an unavailable blob; blocks export and deep verify. |

Offload rule: **no original recording can be evicted until its iCloud asset upload is verified by SHA-256 and the local project database has recorded the remote asset ID.**

### What Goes to iCloud

Private CloudKit database, custom zone `VGProductionStudioZone`.

Record types:

- `VGProject`: project metadata, counts, modified date, offload policy.
- `VGChapter`: chapter metadata.
- `VGParagraph`: paragraph text hash, state, selected take ID, current review state.
- `VGTake`: take metadata, metrics, origin, asset refs.
- `VGAsset`: content-addressed asset record with CKAsset, SHA-256, byte count, ext, content type.
- `VGReviewEvent`: watch-generated queued events when phone relays.

Only the user's private iCloud is used. There is no Voxglass server.

### Working Set Policy

The app pins these assets locally:

- Current recording chapter.
- Previous and next chapter when available.
- Current review queue and next 20 queue items.
- Any paragraph with unsynced review or take state.
- Export staging inputs for the active export run.
- User-pinned chapters/books.

Everything else can be evicted when the production narration cache is over limit.

### Separate Cache Limits

The consumer audiobook download/cache limit remains separate from production narration storage.

Settings expose:

- Audiobook downloads cache: existing listener cache.
- Production local working cache: default 10 GB, adjustable 2 GB to 100 GB.
- Watch production queue cache: default 200 MB.
- Export staging reserve: default "ask each time"; preflight warns if required space is unavailable.

Eviction order:

1. Render cache.
2. Export staging from completed/canceled runs.
3. Proxy/review cache.
4. Remote-verified non-working original takes, oldest chapter first.
5. Never evict `localOnly`, `uploading`, current chapter, or user-pinned assets.

### Hydration

When a user opens a remote-only paragraph/chapter:

1. Show metadata immediately.
2. Queue asset hydration with byte estimate.
3. Allow text editing and review state changes while audio hydrates.
4. Disable playback/export of that paragraph until the selected take is local.

Hydration must be resumable and content-address verified before playback/export.

Mockup: [`12-storage-icloud.html`](mockups/12-storage-icloud.html).

## 6. Audio Capture on iPhone

### Supported Inputs

Recommended for retail:

- USB-C class-compliant audio interface.
- USB microphone with hardware gain.
- Wired headphones or interface direct monitoring.

Allowed with warnings:

- Built-in microphone.
- Bluetooth microphones.
- AirPods high-quality Bluetooth recording where available on iOS 26+ and supported hardware.

The audio setup flow classifies routes:

- `retailReady`: USB/wired route, stable sample rate, sufficient input level, noise floor below threshold in a 10-second test.
- `communityReady`: acceptable for LibriVox/IA but not retail.
- `draftOnly`: Bluetooth/basic route, high latency, or failed noise-floor target.

Bluetooth must not be blocked, but retail export should show a warning if the project was recorded primarily with routes marked `draftOnly`.

### Capture Graph

`AVAudioSession` category: `.playAndRecord`.

`AVAudioEngine` graph:

```
inputNode -> tap -> lock-free ring buffer -> writer task -> Autosave/takes/<uuid>.wav
          -> meter accumulator
```

Monitoring:

- Prefer hardware/direct monitoring.
- Software monitoring is optional and warns about latency.
- Watch "record remote" controls do not stream audio.

### Recording Defaults

- Default capture: 48 kHz, 24-bit mono WAV when hardware supports it.
- Retail export resamples to 44.1 kHz.
- LibriVox export resamples to 44.1 kHz and encodes 128 kbps CBR MP3.
- If the hardware refuses the requested format, record the actual hardware format and preserve it in take metadata.

### Interruption Rules

Interruptions that must preserve a playable take:

- Phone call / Siri / system interruption.
- Route change.
- USB unplug.
- Headphones removed.
- Disk pressure.
- App backgrounded or locked.
- Force-quit during take.

On interruption:

1. Stop recording.
2. Finalize the file as far as possible.
3. Write/update `Autosave/session.json`.
4. Insert a recoverable take after restart if the file is valid.
5. Mark take with `CaptureWarning.interrupted`.

Mockups:

- [`06-recording-workspace.html`](mockups/06-recording-workspace.html)
- [`06b-audio-setup.html`](mockups/06b-audio-setup.html)
- [`06c-capture-interruption.html`](mockups/06c-capture-interruption.html)

## 7. Text, Scripts, and Project Creation

The text pipeline is unchanged in principle from the source spec:

- Import EPUB/TXT/Markdown/DOCX.
- Segment into chapters and paragraphs.
- Preserve paragraph IDs across re-import.
- Detect text drift against selected takes.
- Split and merge paragraphs.
- Generated paragraphs for LibriVox disclaimers and retail credits.

iPhone-specific simplifications:

- Large documents use progressive parse and preview.
- The Source Import screen first shows chapter counts and warnings, then lets users drill into individual chapters.
- Split/merge is contextual per paragraph, not a dense multi-pane editor.
- Re-import summaries must be bite-sized: reused/new/drifted/orphaned counts with drill-down.

Mockups:

- [`02-new-project.html`](mockups/02-new-project.html)
- [`03-source-import.html`](mockups/03-source-import.html)
- [`05-script-editor.html`](mockups/05-script-editor.html)

## 8. Recording Workflow

The iPhone recording workflow is the product's center.

States:

`idle -> preparing -> armed -> preRoll -> recording -> finalizing -> idle`

Primary actions:

- Record / Stop.
- Accept & Next.
- Retake.
- Flag.
- Play take.
- Play in context.
- Previous / next paragraph.
- Select take.

External controls:

- Hardware keyboard shortcuts where connected.
- Bluetooth media button / headset stem control maps to Record/Stop when armed.
- Watch remote can start/stop, accept, retake, and flag. It never records audio itself.

Every recorded paragraph writes a take before metadata mutation:

1. Write in autosave directory.
2. Stop/finalize.
3. Stream-hash file.
4. Move into `Audio/Original`.
5. Insert take metadata in SQLite.
6. Schedule iCloud upload if backup enabled.
7. Compute metrics in background.

No take is auto-deleted. Retakes archive by state, not by file removal.

Mockups:

- [`06-recording-workspace.html`](mockups/06-recording-workspace.html)
- [`08-take-comparison.html`](mockups/08-take-comparison.html)
- [`watch-04-recording-remote.html`](mockups/watch-04-recording-remote.html)

## 9. Importing Existing Audio

Supported: WAV, AIFF, CAF, M4A/AAC, MP3, FLAC.

Assignment options:

- Assign whole file to one paragraph.
- Split file across chapter by silence markers.
- Assign detected segments sequentially.

On iPhone, large-file import must be explicit about storage:

- Show original size.
- Show estimated slice size.
- Show local cache impact.
- Offer "trash original after verified slices" after import.

Origin declaration remains mandatory:

- Recorded by me / external human recording.
- AI-generated or AI-processed.
- Unknown.

Non-human/unknown selected takes block LibriVox.

Mockup: [`07-import-audio.html`](mockups/07-import-audio.html).

## 10. Assembly, Rendering, and Playback

Assembly remains paragraph-based:

- Trim take head/tail silence.
- Insert configured gaps.
- Render lossless chapter masters into cache.
- Preserve paragraph offsets.
- Build review queues without rendering whole chapters.

iPhone-specific rendering rules:

- Render and export are chunked by chapter.
- Long operations are cancellable between chapters and between major file units.
- The app preflights free local disk before rendering/export.
- If an asset is remote-only, export creates a hydration plan before work begins.
- If the app backgrounds, current file finalizes if possible; remaining steps resume later.

Mockup: [`10-assembly.html`](mockups/10-assembly.html).

## 11. Validation

Validation remains ungated and runs locally.

Validation levels:

- Live paragraph checks after each take.
- Chapter checks when a chapter is completed.
- Whole-project checks before export.
- Retail readiness preflight before Pro purchase.

Key rules inherited:

- Missing metadata/rights.
- Missing selected takes.
- Needs pickup unresolved.
- Text drift after recording.
- AI/unknown origin selected for LibriVox.
- Missing disclaimers/credits.
- Clipping, peak, RMS, noise floor, leading/trailing silence.
- Missing metrics.
- Chapter over max duration.
- Artwork too small/not square.

iPhone-specific validation:

- `assetRemoteOnlyForExport`: not a quality failure, but export cannot start until hydrated.
- `localStorageInsufficient`: export blocked until user frees space or reduces scope.
- `backupNotVerified`: warning when a long project has local-only originals.
- `routeNotRetailReady`: warning when selected takes were recorded on draft-quality routes.

Mockup: [`13-validation.html`](mockups/13-validation.html).

## 12. Packaging and Export

Export pipeline:

```
Choose scope -> Choose destination -> Hydration/storage preflight -> Validate
-> Pro gate if needed -> Render -> Master -> Transcode -> Tag -> Package
-> Checksums -> Checklist -> Save to Files / Share
```

Free destinations must not touch `LicenseGate`.

Export scopes:

- Current chapter.
- Selected chapters.
- Whole book.
- Review queue range.

Hydration is explicit:

- "12 chapters are in iCloud. Download 3.4 GB to export."
- User can export only local chapters, hydrate all, or cancel.

Export output:

- Prefer a `.zip` for iPhone sharing.
- Also support "Save folder to Files" when the system destination can accept directories.
- Completed exports may be immediately evicted from local staging after saved to Files if the user chooses.

Mockups:

- [`14-export-wizard-free.html`](mockups/14-export-wizard-free.html)
- [`14b-export-run-resume.html`](mockups/14b-export-run-resume.html)
- [`14c-pro-purchase.html`](mockups/14c-pro-purchase.html)

## 13. Watch Companion

The watch is a companion, not an editor.

Watch can:

- Browse production summaries.
- Download review queues.
- Play paragraph audio.
- Approve, flag, mark needs pickup.
- Dictate notes.
- Act as a recording remote for the active iPhone recording session.

Watch cannot:

- Create projects.
- Edit scripts.
- Record primary narration.
- Export.
- Touch CloudKit directly.

Transport:

- iPhone sends summaries and active queue metadata with `updateApplicationContext`.
- iPhone transfers audio and artwork with `transferFile`.
- Watch sends review events and remote-control commands with `transferUserInfo` or `sendMessage` when reachable.
- Watch stores offline events in a file-backed outbox.

Storage:

- Watch production queue cache default 200 MB.
- User can prepare a queue offline.
- Evict least-recently-reviewed audio first.

Mockups:

- [`watch-01-productions.html`](mockups/watch-01-productions.html)
- [`watch-02-review-player.html`](mockups/watch-02-review-player.html)
- [`watch-03-offline-queue.html`](mockups/watch-03-offline-queue.html)
- [`watch-04-recording-remote.html`](mockups/watch-04-recording-remote.html)
- [`watch-05-dictation.html`](mockups/watch-05-dictation.html)

## 14. iPhone UI Inventory

| View | Mockup | Purpose |
|---|---|---|
| Projects | [`01-projects.html`](mockups/01-projects.html) | Production library, local/iCloud state, cache pressure |
| New Project | [`02-new-project.html`](mockups/02-new-project.html) | Metadata, lane, rights, source import |
| Source Import | [`03-source-import.html`](mockups/03-source-import.html) | Parse, segment, warnings, accept structure |
| Dashboard | [`04-project-dashboard.html`](mockups/04-project-dashboard.html) | Progress, next action, storage status |
| Script Editor | [`05-script-editor.html`](mockups/05-script-editor.html) | Paragraph editing, drift, generated copy |
| Recording Workspace | [`06-recording-workspace.html`](mockups/06-recording-workspace.html) | Paragraph capture |
| Audio Setup | [`06b-audio-setup.html`](mockups/06b-audio-setup.html) | Input route and retail readiness |
| Capture Interruption | [`06c-capture-interruption.html`](mockups/06c-capture-interruption.html) | Recovery and route change |
| Import Audio | [`07-import-audio.html`](mockups/07-import-audio.html) | Segment external recordings |
| Take Comparison | [`08-take-comparison.html`](mockups/08-take-comparison.html) | A/B and select take |
| Review Queue | [`09-review-queue.html`](mockups/09-review-queue.html) | iPhone proofing |
| Assembly | [`10-assembly.html`](mockups/10-assembly.html) | Gaps, render cache |
| Metadata & Rights | [`11-metadata-rights.html`](mockups/11-metadata-rights.html) | Rights, artwork, IDs |
| Storage & iCloud | [`12-storage-icloud.html`](mockups/12-storage-icloud.html) | Offload, hydration, cache caps |
| Validation | [`13-validation.html`](mockups/13-validation.html) | Destination checks |
| Export | [`14-export-wizard-free.html`](mockups/14-export-wizard-free.html) | Free export flow |
| Export Run | [`14b-export-run-resume.html`](mockups/14b-export-run-resume.html) | Long/resumable export |
| Pro Purchase | [`14c-pro-purchase.html`](mockups/14c-pro-purchase.html) | Commercial unlock |
| Settings | [`15-settings.html`](mockups/15-settings.html) | Audio, storage, license, notices |

## 15. Testing and Acceptance

Core tests:

- Domain coding.
- Eligibility.
- Storage/offload state transitions.
- iCloud manifest round-trips.
- Text import and drift.
- Recording flow with fake capture.
- Autosave recovery.
- Metrics and ReplayGain.
- Assembly cache keys.
- Validation rule catalogue.
- Transcoder CBR/FLAC/M4B tests on iOS simulator where possible.
- Export end-to-end with fake assets.
- License gate placement.
- Watch payload and outbox tests.

UI smoke tests:

- iPhone project creation to dashboard.
- iPhone recording workspace fake-capture path.
- iPhone storage offload/hydration fake path.
- iPhone export flow for LibriVox.
- Watch review queue and offline event path.

Manual hardware matrix:

| # | Scenario | Pass condition |
|---|---|---|
| M-1 | Record 100 paragraphs with USB mic/interface | No take lost; memory stable; metrics complete |
| M-2 | Unplug USB interface mid-take | Take preserved, route error shown, recovery works |
| M-3 | Lock phone during take | Either recording continues or stops with preserved take; no silent loss |
| M-4 | Force-quit during take | Recovery offers valid audio |
| M-5 | Fill production cache | Remote-verified old chapters evict; local-only takes remain |
| M-6 | Hydrate remote-only chapter | Playback/export works after SHA verification |
| M-7 | Watch offline review | Events sync exactly once to iPhone |
| M-8 | LibriVox export | MP3s verify as 128 kbps CBR / 44.1 kHz / mono |
| M-9 | Internet Archive export | Metadata/checksums/checklist complete |
| M-10 | Retail export | External ACX-style checker agrees with RMS/peak/noise results |
| M-11 | Pro purchase and restore | Entitlement returns after reinstall |
| M-12 | VoiceOver pass | Every production flow is reachable |

## 16. Stage Plan

### S1 - Extract iPhone Production Core

Move/keep production domain, text, validation, assembly, packaging, and license code in `Voxglass/Core/Production`. Remove Mac-only assumptions from API names.

Acceptance: stress fixture round-trips and validates with no app target.

### S2 - iPhone Project Store and iCloud Offload

Add internal project directory layout, SQLite production store, content-addressed asset store, CloudKit backup/offload records, cache manager, hydration planner.

Acceptance: a 20-chapter fake project evicts non-working chapters under a 1 GB cap and hydrates one chapter on demand.

### S3 - Source Import and Project Creation

Add iPhone project library, new project flow, source import, segmentation, re-import summary.

Acceptance: create a LibriVox project from TXT and reach dashboard with generated paragraph counts.

### S4 - Audio Setup and Recording

Add iOS `AVAudioSession` capture implementation, audio route readiness test, recording workspace, autosave recovery.

Acceptance: fake capture records 100 paragraphs; hardware manual M-1 and M-2 pass.

### S5 - Review, Watch, and Recording Remote

Add iPhone review queues, watch queue transfer, watch actions, watch recording remote.

Acceptance: offline watch action and recording remote command reach iPhone exactly once.

### S6 - Assembly and Validation

Add iPhone assembly controls, render cache, validation report, fix actions.

Acceptance: validation of a 3,000-paragraph fixture completes under budget and includes storage/hydration issues.

### S7 - Encoders and Free Export

Wire LAME/libFLAC/AAC paths on iOS, LibriVox and Internet Archive builders, Save to Files packaging.

Acceptance: LibriVox fixture exports verified CBR MP3 from iPhone simulator/device.

### S8 - Pro Retail Export

Add StoreKit, retail profiles, mastering, M4B, report export, Pro purchase flow.

Acceptance: retail export hydrates remote chapters, resumes after interruption, and produces ACX-compliant files from fixture audio.

### S9 - Hardening and Release

Storage stress, iCloud quota behavior, route changes, low power, VoiceOver, App Store review notes, third-party notices.

Acceptance: manual matrix passes and mockups/spec are synchronized.

## 17. App Store Notes

Review note:

"Voxglass records the user's own narration and creates local export packages for audiobook distribution. The app does not upload content to retailers or determine copyright status. The Pro in-app purchase unlocks commercial export formats and mastering; LibriVox and Internet Archive exports are free."

Privacy:

- No analytics required.
- iCloud backup/offload uses the user's private iCloud database.
- Manuscript text and audio stay on device/iCloud unless the user exports them.

IAP:

- Digital functionality must use StoreKit.
- Non-consumable one-time purchase.
- Restore Purchases always visible.
- Refund/revocation returns app to free while preserving user projects.
