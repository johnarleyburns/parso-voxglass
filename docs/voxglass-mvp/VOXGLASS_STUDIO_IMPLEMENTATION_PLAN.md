# Voxglass Audiobook Studio — Non-AI MVP Implementation Plan

*Companion to `Voxglass Audiobook Studio — MVP v1 Agent Handoff` (2026-07-29). This document turns that handoff into a build-ready plan at Swift-class granularity: concrete types, test suites, and one simulator smoke test per device type, mapped to the attached mockups (`mac/`, `iphone/`, `watch/`, `carplay/`).*

Repository: `johnarleyburns/parso-voxglass` · Commit in S1–S9 order, one reviewable commit per stage.

---

## A. What "non-AI MVP" means in code

The MVP is a **solo human-narration production and proofing environment**. There is **no speech synthesis anywhere in the codebase**.

**IN scope**
- Microphone capture (macOS only) → lossless PCM takes.
- Import of existing audio: WAV, AIFF, CAF, M4A, MP3, FLAC (decode via AVFoundation).
- Paragraph-addressable takes, non-destructive assembly, review queues, device preview, packaging.

**OUT of scope (do not add, do not stub toward)**
- No TTS engine, no on-device voice models, no MLX/CoreML inference, no model downloads, no voice cloning, no forced alignment, no cloud AI calls.

**The one AI-adjacent affordance that stays:** `AudioOrigin.aiImported(providerLabel:)` remains a *provenance label only*. A user may import an AI-rendered WAV as a take, but the app never generates it. Its sole behavioral effects:
1. It is accepted as an import like any other file.
2. It sets the project's narration origin such that **LibriVox packaging is disabled** (LibriVox rejects AI recordings).

There is no generation code path behind that label. A CI gate (§H) enforces the absence of synthesis symbols in all MVP targets.

---

## B. Cross-cutting technical decisions

| Concern | Decision | Rationale |
|---|---|---|
| Language / concurrency | Swift 6, strict concurrency on. Domain types `Sendable` value types; I/O behind `actor`s or async protocols. | Handoff domain model is already `Sendable`. |
| View models | **`@Observable` (Observation), never `ObservableObject`.** State scoped so metering/transport updates invalidate only their subtree. | Avoids the app-wide 1 Hz invalidation storm previously hit in the player. CI-gated (§H). |
| Metadata store | **GRDB** over SQLite in **WAL** mode, one DB per `.voxproject`. | Matches existing stack; atomic, concurrent reads during playback. |
| Asset identity | **SHA-256** (CryptoKit) content addressing. **Never `Swift.Hasher`** (reseeds per launch). CI-gated. | Known defect class; content-addressed cache must be stable across launches. |
| Project generation | **XcodeGen** `project.yml`. | Existing convention. |
| Audio decode/playback/metering | AVFoundation (`AVAudioEngine`, `AVAudioFile`, `AVAudioPCMBuffer`). Session config lives in apps, not Core. | Handoff rule: no `AVAudioSession` in Core. |
| Audio **encode** for export | **Bundled transcoder** (ffmpeg helper) behind an `AudioTranscoding` protocol. See §I-1. | **AVFoundation cannot encode MP3 or FLAC**, both of which the export presets require. This is a material constraint the handoff did not call out. |
| Tests | **Swift Testing** for logic/VM suites; **XCUITest** for device smoke tests. | Modern, parallel; UI automation still needs XCUITest. |
| A11y identifiers | Every interactive view sets `.accessibilityIdentifier("<view>.<element>")` from the registry in §G-5. | Required by handoff accessibility section *and* is what the smoke tests key on. |
| Purchase | **StoreKit 2** behind a `LicenseProvider` protocol; gate defined in exactly one place (`LicenseGate`). | Handoff pricing: $149 one-time; gate only economic output. CI-gated placement. |

---

## C. Target & module topology

```
VoxglassCore                (SwiftPM, pure logic — no UI, no AVAudioSession, no CloudKit/StoreKit concretes)
  ├─ AudiobookProjectDomain  ├─ ProjectPackage     ├─ ProductionStore
  ├─ ReviewQueue             ├─ AudioAssembly      ├─ AudioValidation
  ├─ RightsProfiles          ├─ Packaging          ├─ ProductionSync (protocols + mappers)
  ├─ WatchLink (protocols)   └─ LicenseGate (policy + protocol)
VoxglassCoreTestSupport      (SwiftPM — fakes + fixtures; test-only)

VoxglassStudio        macOS 14+ SwiftUI app   → concretes: AVCapture, AVMetrics, FFmpegTranscoder, CloudKitSync, StoreKitLicense
Voxglass              iPhone app (existing)   → additions: production preview, review, CarPlay scene
VoxglassWatch         watchOS app (existing)  → additions: relayed review
  (CarPlay is a SCENE inside the Voxglass iPhone target — com.apple.developer.carplay-audio — not a separate app target)

Test targets:
  VoxglassCoreTests · VoxglassStudioTests · VoxglassTests · VoxglassWatchTests
  VoxglassStudioUITests · VoxglassUITests · VoxglassWatchUITests · VoxglassCarPlaySmokeTests
```

Dependency rule: apps depend on `VoxglassCore`; Core depends on nothing platform-specific. All CloudKit/StoreKit/WatchConnectivity/AVAudioEngine access is behind a Core protocol whose concrete lives in an app target and whose **fake lives in `VoxglassCoreTestSupport`**.

---

## D. VoxglassCore — classes

### D.1 AudiobookProjectDomain
Adopt the handoff's structs verbatim, and add the types it referenced but did not define, plus the invariant-enforcing derivations:

```swift
// Referenced-but-undefined in handoff — define these:
struct SourceDocument: Codable, Sendable {
  var format: SourceFormat            // epub | txt | markdown | docx
  var originalFilename: String
  var extractedTextRef: AudioAssetReference   // content-addressed
  var sourceMapRef: AudioAssetReference?      // paragraph→source offsets
  var importedAt: Date
}
struct ProductionProfile: Codable, Sendable {
  var recording: RecordingDefaults    // 48 kHz / 24-bit / mono default
  var assembly: AssemblySettings      // gaps, head/tail silence
  var intendedDestination: ValidationTarget
}
struct PronunciationNote: Identifiable, Codable, Sendable { let id: UUID; var term: String; var guidance: String }
struct AudioAssetReference: Codable, Sendable, Hashable { var sha256: String; var relativePath: String; var byteCount: Int }
struct AudioProcessingStep: Codable, Sendable { var kind: ProcessingKind; var parameters: [String:Double] } // trim/gain/fade — instructions, non-destructive
struct AudioQualityMetrics: Codable, Sendable {
  var peakDBFS: Double; var rmsDBFS: Double; var estNoiseFloorDBFS: Double
  var clipCount: Int; var dcOffset: Double; var leadingSilence: TimeInterval
  var trailingSilence: TimeInterval; var duration: TimeInterval; var sampleRate: Double; var channels: Int
}
enum DeviceKind: String, Codable, Sendable { case mac, iPhone, watch, carPlay }

// AudioOrigin has associated values → provide explicit Codable (discriminator) so it round-trips in SQLite/CloudKit.
extension AudioOrigin { /* encode/decode with `kind` discriminator + payload */ }

// THE domain rule, made unconstructable-by-accident:
struct EligibilityProfile: Sendable, Equatable {
  let narrationOrigin: NarrationOrigin      // .humanOnly | .containsImportedAI
  let librivoxEligible: Bool
  private init(origin: NarrationOrigin) { self.narrationOrigin = origin; self.librivoxEligible = (origin == .humanOnly) }
  /// Only way to build one — from the project's *accepted* takes.
  static func evaluate(_ project: AudiobookProject) -> EligibilityProfile {
    let anyAI = project.chapters.flatMap(\.paragraphs)
      .compactMap { p in p.selectedTakeID.flatMap { id in p.takes.first { $0.id == id } } }
      .contains { if case .aiImported = $0.origin { return true } else { return false } }
    return EligibilityProfile(origin: anyAI ? .containsImportedAI : .humanOnly)
  }
}
enum NarrationOrigin: String, Sendable { case humanOnly, containsImportedAI }
```
Also: `ProjectIntegrity.check(_:) -> [IntegrityFinding]` (duplicate/missing ordinals, missing selected take, hash mismatch, orphan asset).

### D.2 ProjectPackage — the `.voxproject` on disk
```swift
protocol ContentAddressedStore: Sendable {                     // fake: InMemoryAssetStore
  func put(_ data: Data, ext: String) async throws -> AudioAssetReference   // key = sha256(data)
  func url(for ref: AudioAssetReference) -> URL
  func exists(_ ref: AudioAssetReference) -> Bool
}
struct FileAssetStore: ContentAddressedStore { let root: URL }  // Audio/Original never mutated
enum SHA256 { static func hex(_ data: Data) -> String }         // CryptoKit; NOT Swift.Hasher
struct PackageManifest: Codable, Sendable { var schemaVersion: Int; var projectID: UUID; var createdAt: Date; var appVersion: String }
struct ProjectPackage: Sendable {                               // wraps <title>.voxproject/
  let root: URL
  static func create(title: String, at: URL) throws -> ProjectPackage      // writes manifest.json, database.sqlite, dir tree
  static func open(_ url: URL) throws -> ProjectPackage                     // integrity check + autosave recovery
  func move(to: URL) throws; func copy(to: URL) throws
}
struct PackageIntegrityChecker { func check(_ pkg: ProjectPackage) -> [IntegrityFinding] }
struct PackageRecovery { func recoverFromAutosave(_ pkg: ProjectPackage) throws -> RecoveryOutcome }
```

### D.3 ProductionStore — GRDB
```swift
protocol ProductionStore: Sendable {                            // fake: InMemoryProductionStore
  func listProjects() async throws -> [ProjectSummary]
  func load(_ id: UUID) async throws -> AudiobookProject
  func upsert(_ project: AudiobookProject) async throws
  func apply(_ event: ReviewEvent) async throws                 // append-only fold
  func delete(_ id: UUID) async throws
}
struct GRDBProductionStore: ProductionStore { let dbQueue: DatabaseQueue }   // WAL
enum SchemaMigrator { static func migrator() -> DatabaseMigrator }           // versioned, reversible in tests
struct ProjectSummary: Codable, Sendable { var id: UUID; var title: String; var author: String; var narrator: String; var percentRecorded: Double; var flaggedCount: Int; var readyToExport: Bool }
```

### D.4 ReviewQueue — pure
```swift
enum ReviewPredicate: Sendable { case allRecorded, flagged, needsPickup, unapproved, selectedParagraphs(Set<UUID>) }
enum QueueOrder: Sendable { case documentOrder, byChapter, flaggedFirst }
struct ReviewQueueDefinition: Codable, Sendable { var projectID: UUID; var chapterIDs: Set<UUID>?; var predicate: ReviewPredicate; var order: QueueOrder; var autoAdvance: Bool }
struct ReviewQueueResolver { func resolve(_ def: ReviewQueueDefinition, in project: AudiobookProject) -> [UUID] }  // ordered paragraph IDs
struct ReviewEvent: Codable, Sendable, Identifiable {           // append-only, idempotent by id
  let id: UUID; var projectID: UUID; var paragraphID: UUID
  var type: ReviewEventType; var noteText: String?; var tag: ReviewTag?; var device: DeviceKind; var createdAt: Date
}
enum ReviewEventType: String, Codable, Sendable { case flag, unflag, approve, needsPickup, addNote, voiceNoteRequested }
struct ReviewEventFolder { func fold(_ events: [ReviewEvent], into state: ReviewState) -> ReviewState }  // idempotent, last-writer-wins by (paragraph,type,timestamp)
```

### D.5 AudioAssembly — pure plan, no rendering
```swift
struct PlaybackSegment: Sendable { let paragraphID: UUID; let chapterID: UUID; let assetRef: AudioAssetReference; let trim: Range<TimeInterval>; let leadingSilence: TimeInterval; let trailingSilence: TimeInterval }
enum PlaybackMode: Sendable { case wholeBook, currentChapter, selectedChapters(Set<UUID>), flagged, needsPickup, unapproved, reviewQueue(ReviewQueueDefinition) }
struct SegmentQueueBuilder { func build(_ mode: PlaybackMode, from project: AudiobookProject) -> [PlaybackSegment] }
struct AssemblySettings: Codable, Sendable { var paragraphGap: TimeInterval = 0.45; var chapterHeadSilence: TimeInterval; var chapterTailSilence: TimeInterval }
struct RenderPlan: Sendable { let chapterID: UUID; let segments: [PlaybackSegment]; let cacheKey: String }   // cacheKey = SHA-256(inputs+settings)
protocol RenderCache: Sendable { func cachedRender(for key: String) -> AudioAssetReference?; func store(_ ref: AudioAssetReference, for key: String) }
protocol SegmentPlayer: AnyObject { /* per-platform; play([PlaybackSegment]), currentParagraphID, next/prev, gapless */ }  // fake: FakeSegmentPlayer
```

### D.6 AudioValidation — pure rules + I/O boundary
```swift
protocol AudioMetricsCalculating: Sendable {                    // concrete: AVMetricsCalculator (app); fake returns fixtures
  func metrics(for ref: AudioAssetReference) async throws -> AudioQualityMetrics
}
enum ValidationTarget: String, Codable, Sendable { case librivox, internetArchive, retail }
struct ValidationIssue: Sendable, Identifiable { let id: UUID; var severity: Severity; var code: IssueCode; var paragraphRef: (UUID,UUID)?; var message: String; var fix: FixAction? }
enum Severity: Sendable { case blocking, warning, passed }
struct ValidationRuleEngine {                                   // PURE: metrics + project + target → issues
  func evaluate(project: AudiobookProject, metrics: [UUID: AudioQualityMetrics], target: ValidationTarget) -> [ValidationIssue]
}
struct ValidationReport: Sendable { var target: ValidationTarget; var issues: [ValidationIssue]; var eligibility: EligibilityProfile }
```
Rule coverage (from handoff §14): missing title/author/narrator/language; unattested rights; missing source URL for LibriVox; **AI take in LibriVox project (blocking)**; missing accepted take; text changed after accepted recording; unresolved needsPickup; duplicate/missing ordinals; asset/hash mismatch; clipping; excessive peak/silence; low level; stereo-where-mono; sample-rate mismatch; suspected truncated boundary; loudness discontinuity; duration outlier.

### D.7 RightsProfiles + destination specs — pure
```swift
struct DestinationProfile: Sendable {
  let target: ValidationTarget
  let sampleRate: Double; let channels: Int; let container: Container; let codec: Codec; let bitrateKbps: Int?; let cbr: Bool
  let filenameRule: FilenameRule; let requiredMetadata: Set<MetadataField>
}
enum FilenameRule: Sendable { case librivoxLowercaseNoSpace, freeform }
struct FilenameSanitizer { func sanitize(_ raw: String, rule: FilenameRule) -> String }   // pure, exhaustively unit-tested
extension DestinationProfile {
  static let librivox  = DestinationProfile(target:.librivox, sampleRate:44_100, channels:1, container:.mp3, codec:.mp3, bitrateKbps:128, cbr:true, filenameRule:.librivoxLowercaseNoSpace, requiredMetadata:[.title,.author,.narrator,.sourceURL])
  static let retailACX = DestinationProfile(target:.retail,   sampleRate:44_100, channels:1, container:.mp3, codec:.mp3, bitrateKbps:192, cbr:true, filenameRule:.freeform, requiredMetadata:[.title,.author,.narrator,.language,.cover])
  // Internet Archive: lossless master (WAV/FLAC) + optional MP3 derivative + manifest
}
struct EligibilityEvaluator { func canPackage(_ target: ValidationTarget, _ project: AudiobookProject) -> Bool }  // LibriVox ⇒ requires .humanOnly
```

### D.8 Packaging — build export packages
```swift
protocol AudioTranscoding: Sendable {                           // concrete: FFmpegTranscoder (app); fake: FakeTranscoder
  func transcode(_ input: AudioAssetReference, to profile: DestinationProfile, output: URL) async throws -> ExportedFile
}
protocol PackageBuilder: Sendable {
  func build(project: AudiobookProject, into exportsDir: URL) async throws -> ExportBundle
}
struct LibriVoxPackageBuilder: PackageBuilder        // human-only; 128 CBR mono MP3; per-file naming; intro/outro fields; duration report; checklist; NO auto-upload
struct InternetArchivePackageBuilder: PackageBuilder // lossless master + optional MP3; metadata manifest (JSON/XML); artwork; checksums; opensource_audio default; test-collection mode
struct RetailMasterPackageBuilder: PackageBuilder    // Pro: batch chapter files, M4B chapterized, MP3/WAV/FLAC masters, dither on bit-reduction, validation report (JSON/HTML)
struct MetadataManifestBuilder { func iaManifest(_ p: AudiobookProject) -> Data }
struct ChecksumWriter { func sha256Manifest(_ files: [ExportedFile]) -> Data }
```

### D.9 ProductionSync — CloudKit abstraction (protocols + mappers in Core)
```swift
protocol ProductionSyncEngine: Sendable {                       // concrete: CloudKitProductionSync (apps); fake: FakeSyncEngine
  func publishProjection(_ projection: SyncProjection) async throws        // Mac → CloudKit (accepted takes only)
  func fetchProjection(projectID: UUID) async throws -> SyncProjection
  func push(_ events: [ReviewEvent]) async throws
  func fetchEvents(since token: SyncToken?) async throws -> ([ReviewEvent], SyncToken)
  func setHidden(_ projectID: UUID, _ hidden: Bool) async throws
}
struct ProjectionBuilder { func projection(from project: AudiobookProject) -> SyncProjection }  // only selected/accepted takes; compact proxy asset refs
struct SyncProjection: Sendable { var project: ProjectSummary; var chapters: [ChapterProjection]; var paragraphs: [ParagraphProjection]; var revision: Int }
// Record-type mappers: VGProductionProject / VGProductionChapter / VGProductionParagraph / VGReviewEvent (handoff §12)
```

### D.10 WatchLink — WatchConnectivity abstraction
```swift
protocol WatchTransport: Sendable {                             // concrete per app; fake: FakeWatchTransport
  func sendSummaries(_ s: [ProjectSummary]) async throws
  func sendActiveQueue(_ q: ResolvedQueuePayload) async throws          // queue + enough segment audio for current+next
  func sendArtwork(_ a: [UUID: Data]) async throws
  func receiveEvents() -> AsyncStream<ReviewEvent>
}
struct ResolvedQueuePayload: Codable, Sendable { var projectID: UUID; var paragraphIDs: [UUID]; var segmentAudio: [UUID: AudioAssetReference]; var texts: [UUID:String] }
```
Watch **never** touches CloudKit; it only speaks `WatchTransport` to the phone.

### D.11 LicenseGate — the single economic boundary
```swift
protocol LicenseProvider: Sendable {                            // concrete: StoreKitLicenseProvider; fake: FakeLicenseProvider
  var isPro: Bool { get async }
  func purchasePro() async throws -> EntitlementState
  func restore() async throws -> EntitlementState
}
enum ProFeature: Sendable { case cleanExport, retailPresets, mastering, batchExport, m4bExport, flacExport, commercialMetadata }
struct LicenseGate {                                            // the ONLY place gating logic exists
  let provider: LicenseProvider
  func require(_ feature: ProFeature) async throws              // throws .proRequired
}
```
Free features (recording, review, preview, PD community export) **must not reference `LicenseGate`/`isPro` at all** — CI-gated (§H).

---

## E. Platform layers — view models & views mapped to mockups

All view models are `@Observable`. All views set a11y identifiers (§G-5).

### E.1 VoxglassStudio (macOS) — root + concretes
```swift
@main struct StudioApp: App { /* NavigationSplitView shell */ }
enum StudioSection { case library, needsReview, readyToExport, archive, settings }        // sidebar (mockup 01)
struct StudioRootView: View { /* sidebar + project editor tabs: Script/Record/Review/Assemble/Metadata/Validate&Export */ }
// Concrete platform services (implement Core protocols):
final class AVAudioEngineCapture: AudioCapturing
struct AVMetricsCalculator: AudioMetricsCalculating
final class AVSegmentPlayer: SegmentPlayer
struct FFmpegTranscoder: AudioTranscoding
final class CloudKitProductionSync: ProductionSyncEngine
final class StoreKitLicenseProvider: LicenseProvider
```

| Mockup (mac/) | SwiftUI View | `@Observable` View Model | Key surface |
|---|---|---|---|
| 01-project-library | `ProjectLibraryView` | `ProjectLibraryModel` | project cards, progress chips, New Audiobook, activity |
| 02-new-project | `NewProjectWizard` (4 steps) | `NewProjectModel` | title/author/narrator, purpose, rights basis, source URL, "does not determine copyright" attest |
| 03-source-import | `SourceImportView` | `SourceImportModel` | chapter/¶ tree, re-segment, split/merge, scene break, accept structure |
| 04-project-dashboard | `ProjectDashboardView` | `ProjectDashboardModel` | progress, review count, chapters, device preview, feedback |
| 05-script-editor | `ScriptEditorView` | `ScriptEditorModel` | chapters list, ¶ inspector, direction/pronunciation, split/merge, drift chips |
| 06-recording-workspace | `RecordingWorkspaceView` | `RecordingModel` + `RecordingMeter` (isolated) | teleprompter, waveform, transport, takes inspector, quality, keyboard flow |
| 07-import-audio | `ImportAudioView` | `ImportAudioModel` | origin, split markers, assign N segments |
| 08-take-comparison | `TakeComparisonView` | `TakeComparisonModel` | A/B, select take |
| 09-review-queue | `ReviewQueueView` | `ReviewQueueModel` | flagged list, note, auto-advance, approve/pickup/keep |
| 10-chapter-assembly | `ChapterAssemblyView` | `AssemblyModel` | gaps, head/tail silence, render preview, rebuild changed |
| 11-metadata-rights | `MetadataRightsView` | `MetadataRightsModel` | book details, rights evidence, **narration-origin audit**, attest |
| 12-device-preview | `DevicePreviewView` | `DevicePreviewModel` | sync now, hide from devices, offline queue, feedback |
| 13-validation-report | `ValidationReportView` | `ValidationModel` | issues by severity, go-to-paragraph, run again |
| 14-export-wizard | `ExportWizardView` | `ExportModel` | LibriVox (Free) / IA (Free) / Retail (Pro $149) → `LicenseGate` only here |
| 15-settings-audio | `SettingsView` | `SettingsModel` | input device, format, monitoring, pre-roll, clip warn, 10-s test, License |

**Recording isolation rule:** `RecordingMeter` is a separate `@Observable` sampled at ~display rate that feeds only the meter/waveform subview; `RecordingModel` holds durable take state. Live metering must not invalidate the teleprompter/inspector.

### E.2 Voxglass (iPhone) — additions
Add a top-level **My Productions** shelf/source filter alongside existing Audiobooks.

| Mockup (iphone/) | View | View Model |
|---|---|---|
| 01-library-my-productions | `MyProductionsShelf` | `MyProductionsModel` |
| 02-production-book-detail | `ProductionBookDetailView` | `ProductionDetailModel` |
| 03-production-player | `ProductionReviewPlayerView` | `ProductionPlayerModel` |
| 04-paragraph-list | `ProductionParagraphListView` | `ParagraphListModel` |
| 05-review-queue-builder | `ReviewQueueBuilderView` | `ReviewQueueBuilderModel` |
| 06-review-note-sheet | `AddReviewNoteSheet` | `ReviewNoteModel` |
| 07-production-sync-storage | `ProductionSyncStorageView` | `ProductionSyncModel` |

Concretes: `CloudKitProductionSync` (consumer), `WatchConnectivityTransport` (phone side), `AVSegmentPlayer` (iOS), `ProductionPreviewStore` (local projection cache; prefetch next 3 ¶).

### E.3 CarPlay scene (inside Voxglass iPhone target)
`com.apple.developer.carplay-audio`. `CPTemplateApplicationScene` + delegate. No free-text entry.

| Mockup (carplay/) | Template / Controller |
|---|---|
| 01-productions-tab | `CPTabBarTemplate` (Continue / Productions / Review) via `ProductionsTabTemplate` |
| 02-production-detail | `ProductionDetailTemplate` (Play Whole Book / Review Flagged) |
| 03-review-queue-list | `ReviewQueueListTemplate` (Flagged / Needs Pickup / Unapproved; auto-advance) |
| 04-review-player | `CPNowPlayingTemplate` + custom buttons (Keep Flagged / Approve / Needs Pickup) via `ReviewPlayerNowPlaying` |
| 05-review-note-summary | `ReviewNoteSummaryTemplate` |
| 06-voice-action-confirmation | `VoiceActionConfirmation` (Play Next / Undo) |
| 07-review-queue-browser | `ReviewQueueBrowserTemplate` |
| 08-carplay-review-settings | `ReviewSettingsTemplate` |

`CarPlayReviewController` maps `CPNowPlaying` prev/next remote commands to **paragraph boundaries** (production mode) and custom buttons to `ReviewEvent`s. Voice notes → timestamped `voiceNoteRequested` marker for completion on phone.

### E.4 VoxglassWatch — additions
Watch speaks only `WatchTransport`.

| Mockup (watch/) | View | View Model |
|---|---|---|
| 01-productions-list | `ProductionsListView` | `WatchProductionsModel` |
| 02-production-home | `ProductionHomeView` | `WatchProductionHomeModel` |
| 03-review-queue-list | `ReviewQueueListView` | `WatchReviewModel` |
| 04-review-player | `ReviewPlayerView` | `WatchReviewModel` |
| 05-paragraph-text | `ParagraphTextView` | `WatchReviewModel` |
| 06-review-action-confirmation | `ReviewActionConfirmationView` | — |
| 07-dictation-category | `DictationCategoryView` | `WatchDictationModel` |
| 08-dictation-result | `DictationResultView` | `WatchDictationModel` |
| 09-watch-sync-status | `WatchSyncStatusView` | `WatchSyncModel` |
| 10-offline-queue | `OfflineQueueView` | `WatchSyncModel` |

Crown = volume (not ¶ selection); tap/swipe = prev/next ¶; prominent Flag; long-press = tags; haptic at ¶ boundary; explicit offline state when phone/audio unavailable.

---

## F. Stage-by-stage plan (S1–S9)

Each stage lists **classes to add**, **tests to write** (Swift Testing unless noted), and the handoff's **acceptance** criteria restated as assertions.

### S1 — Domain & project package
- **Add:** all of D.1, D.2; `GRDBProductionStore` skeleton + `SchemaMigrator` v1 (D.3); `ProjectFixtures` in TestSupport (incl. 10 000-¶ stress fixture, AI-tainted fixture, drift fixture).
- **Tests (`VoxglassCoreTests`):** `DomainCodingTests` (round-trip incl. `AudioOrigin` associated values), `EligibilityProfileTests` (human→eligible; one aiImported selected take→ineligible; aiImported present but not selected→eligible), `ProjectPackageTests` (create/open/move/copy; missing-asset → repair finding; autosave recovery), `SchemaMigrationTests` (v1 up+down reversible).
- **Acceptance:** create/open/move/copy/recover projects; 10 000-¶ fixture opens & saves reliably.

### S2 — Source import & script editor
- **Add:** `SourceImporter` protocol + `EPUBImporter`/`TXTImporter`/`MarkdownImporter`/`DOCXImporter`; `Segmenter` (chapters+paragraphs, **stable IDs**); `TextDriftDetector` (punctuation/whitespace → keep+mark; semantic → `needsPickup`); `ScriptEditorModel`, `ScriptEditorView`, `SourceImportModel`, `SourceImportView`, `NewProjectModel`, `NewProjectWizard`.
- **Tests:** `SegmenterTests` (re-import preserves unchanged ¶ IDs), `TextDriftTests` (minor vs semantic classification), `SplitMergeTests` (notes + provenance retained across split/merge).
- **Acceptance:** re-import/update does not arbitrarily change unchanged ¶ IDs; split/merge maintains notes & provenance.

### S3 — Recording & take management
- **Add:** `AudioCapturing` protocol (Core) + `AVAudioEngineCapture` (Studio); `RecordingModel`, `RecordingMeter`, `RecordingWorkspaceView`; `AVMetricsCalculator` + pure metric helpers; `ImportAudioModel`/`ImportAudioView` (WAV/AIFF/CAF/M4A/MP3/FLAC decode; manual split markers; **AI import labeled**); `TakeComparisonModel`/`View`; non-destructive `AudioProcessingStep` trims.
- **Tests:** `MetricsCalculatorTests` (peak/RMS/noise/clip/DC/silence vs fixture WAVs), `TakeManagementTests` (multiple takes, select newest optional), `ImportAssignmentTests` (single/sequential-by-silence/whole-chapter; manual marker override), `AIOriginLabelTests` (imported AI take flips eligibility).
- **Acceptance:** record 100 sequential ¶ without losing a take; recover last take after forced termination (autosave).

### S4 — Assembly & Mac review
- **Add:** D.5 (`SegmentQueueBuilder`, `RenderPlan`, `RenderCache`); `AVSegmentPlayer` (macOS); `AssemblyModel`/`View`; `ReviewQueueResolver`, `ReviewEventFolder` (D.4); `ReviewQueueModel`/`View`; `ProjectDashboardModel`/`View`.
- **Tests:** `SegmentQueueTests` (each mode → correct segments; gapless spacing), `ReviewQueueResolverTests` (predicates × order), `ReviewEventFoldTests` (idempotent by id; last-writer-wins), `RenderCacheTests` (only changed ¶ invalidate; cacheKey stable across launches — SHA-256).
- **Acceptance:** flagged queue jumps across chapters hands-free; prev/next always means **paragraph** in production mode.

### S5 — CloudKit preview & iPhone
- **Add:** D.9 (`ProjectionBuilder`, mappers) + `CloudKitProductionSync`; `ProductionPreviewStore`; iPhone views/VMs E.2 (01–07); `WatchConnectivityTransport` (phone side, stub send).
- **Tests (`VoxglassStudioTests` + `VoxglassTests`, with `FakeSyncEngine`):** `ProjectionBuilderTests` (only accepted takes published; unselected/AI-unselected excluded correctly), `ProjectionRoundTripTests` (project → projection → phone model), `OfflineEventQueueTests` (events queue offline, sync idempotently later), `ProjectionPolicyTests` (debounce; hidden project not projected; tombstones until acked).
- **Acceptance:** newly accepted Mac take appears on phone **without an export**; offline review notes sync idempotently later.

### S6 — Watch relay
- **Add:** D.10 payloads; `WatchConnectivityTransport` (watch side); `WatchSegmentPlayer`; watch views/VMs E.4; dictation flow (category → dictated text → confirm → event).
- **Tests (`VoxglassWatchTests`, `FakeWatchTransport`):** `WatchPayloadTests` (summaries/queue/audio-for-current+next), `WatchEventRelayTests` (offline watch action reaches Mac via phone fold), `WatchNoCloudKitTests` (assert watch target has **no CloudKit import/symbol** — compile-guard + grep).
- **Acceptance:** watch never initializes CloudKit; offline review action reaches Mac via phone.

### S7 — CarPlay
- **Add:** E.3 templates + `CarPlayReviewController`; entitlement docs; `VoxglassCarPlaySmokeTests` target.
- **Tests:** `CarPlayTemplateTests` (tab tree; list items from store; command→`ReviewEvent` mapping; templates stay within supported types) + the CarPlay smoke test (§G-4).
- **Acceptance:** a review-only queue can be completed without touching the phone; UI stays within supported templates.

### S8 — Validation, packaging & Pro gate
- **Add:** D.6 rule engine + `ValidationModel`/`ValidationReportView`; D.7 profiles + `FilenameSanitizer`; D.8 builders + `FFmpegTranscoder` (see §I-1) + `AudioTranscoding` fake; D.11 `LicenseGate` + `StoreKitLicenseProvider`; `ExportModel`/`ExportWizardView`; `MetadataRightsModel`/`View`.
- **Tests:** `ValidationRuleEngineTests` (each rule, incl. **AI-in-LibriVox blocking**), `FilenameSanitizerTests` (LibriVox lowercase/no-space, exhaustive), `PackageBuilderTests` with `FakeTranscoder` (LibriVox 128 CBR mono naming + intro/outro + duration report; IA manifest + checksums + test-collection mode; retail M4B/MP3/WAV batch), `LicenseGateTests` (free export never calls gate; retail export requires Pro; restore).
- **Acceptance:** AI-origin ¶ blocks LibriVox export; free project fully usable for record/review; **Pro gate appears only at professional/commercial output**.

### S9 — Hardening
- **Add:** migration tests across schema versions; large-project performance harness (budgets §G-6); sync-conflict simulations; accessibility audit (VoiceOver labels, Dynamic Type, Watch target sizes, reduced motion); real-device audio-interruption handling; App Sandbox + file-corruption recovery.
- **Tests:** `MigrationMatrixTests`, `PerformanceBudgetTests` (XCTest `measure`), `SyncConflictTests`, `AccessibilityAuditTests`.

---

## G. Test plan

### G.1 Unit suites (VoxglassCoreTests — Swift Testing, pure, no simulator)
Coding/migration · paragraph identity/drift · queue predicates & order · review-event fold (idempotency) · export eligibility (AI→LibriVox) · audio-metric math · filename sanitation · project integrity · segment-queue building · render-cache key stability.

### G.2 VM/service integration (VoxglassStudioTests / VoxglassTests / VoxglassWatchTests)
Record→select→proxy→projection (fakes) · phone note→event→Mac fold · phone→watch transfer · paragraph replacement during playback · offline/online conflict · Pro-gate placement.

### G.3 UI smoke tests — the only five UI tests

Every other test in the repository is a Swift Testing suite run by `swift test`. These five UI smoke tests are the only XCUITest targets; they run locally (`scripts/test.sh --all`), never in CI. Convention for all five: launch with `-uiTestSeed <name>` and `-useTemporaryStore`; **never** touch the user's real projects, the microphone, CloudKit, or StoreKit (all seeded via fakes chosen by launch arg).

**macOS — `VoxglassStudioUITests` (XCUITest), three smoke tests, one per destination:**
```swift
import XCTest
final class StudioSmokeUITests: XCTestCase {
  private func createAndImport(_ app: XCUIApplication, destination: String) throws {
    app.launchArguments = ["-uiTestSeed","empty","-useTemporaryStore"]
    app.launch()
    app.buttons["library.newAudiobook"].click()                          // 01
    app.textFields["wizard.title"].click(); app.typeText("Smoke Book")   // 02
    app.textFields["wizard.author"].click(); app.typeText("Tester")
    app.textFields["wizard.narrator"].click(); app.typeText("Tester")
    app.popUpButtons["wizard.destination"].click()
    app.staticTexts[destination].click()
    app.buttons["wizard.continueToImport"].click()
    XCTAssertTrue(app.staticTexts["import.chapterCount"].waitForExistence(timeout: 5)) // 03 (bundled fixture .txt in test mode)
    app.buttons["import.acceptStructure"].click()
    XCTAssertTrue(app.buttons["dashboard.recordNext"].waitForExistence(timeout: 5))    // 04
  }

  func test_createLibrivoxAudiobook() throws { try createAndImport(XCUIApplication(), destination: "librivox") }
  func test_createInternetArchiveAudiobook() throws { try createAndImport(XCUIApplication(), destination: "internetArchive") }
  func test_createCommercialAudiobook() throws { try createAndImport(XCUIApplication(), destination: "acx") }
}
```

**iPhone — `VoxglassUITests` (XCUITest), one smoke test:**
```swift
final class ProductionSmokeUITests: XCTestCase {
  func test_myProductions_openReviewPlayer_showsControls() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-uiTestSeed","onePreviewProject"]   // injects fake projection into preview store
    app.launch()
    app.buttons["shelf.myProductions"].tap()                    // 01
    app.buttons["production.rogerAckroyd"].tap()                // 02
    XCTAssertTrue(app.buttons["detail.playWholeBook"].waitForExistence(timeout: 5))
    app.buttons["detail.reviewFlagged"].tap()                   // 03
    XCTAssertTrue(app.buttons["player.flag"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["player.approve"].exists)
    XCTAssertTrue(app.buttons["player.pickup"].exists)
  }
}
```

**watchOS — `VoxglassWatchUITests` (XCUITest):**
```swift
final class WatchReviewSmokeUITests: XCTestCase {
  func test_openQueue_flagAndApprove() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-uiTestSeed","watchQueue"]          // fake WatchTransport payload
    app.launch()
    app.buttons["watch.production.rogerAckroyd"].tap()          // 02
    app.buttons["watch.reviewFlagged"].tap()                   // 03 → 04
    XCTAssertTrue(app.buttons["watch.player.flag"].waitForExistence(timeout: 5))
    app.buttons["watch.player.approve"].tap()
    XCTAssertTrue(app.staticTexts["watch.confirmation.approved"].waitForExistence(timeout: 5)) // 06
  }
}
```
*Note:* watchOS XCUITest is constrained in CI. If the runner cannot host it, ship instead as a **hosted logic smoke** that boots the watch scene and drives `WatchReviewModel` end-to-end (list → player → approve → confirmation state), asserting VM state rather than XCUIElements. Keep exactly one, either way.

**CarPlay — folded into the iPhone smoke test (scene/template check; runs in iOS simulator):**
CarPlay templates are **not automatable via XCUITest**, so the CarPlay check runs as a hosted scene test (`VoxglassCarPlaySmokeTests`) in the same iOS-simulator test action as `VoxglassUITests`. It is not a separate UI smoke test.
```swift
import XCTest; import CarPlay; @testable import Voxglass
final class CarPlaySceneSmokeTests: XCTestCase {
  func test_buildsTabTemplate_andApproveEmitsOneEvent() throws {
    let env = CarPlayTestEnvironment(seed: .oneFlaggedQueue)          // fake store + sync + interface controller
    let controller = CarPlayReviewController(store: env.store, sync: env.sync)
    let root = controller.makeRootTemplate() as? CPTabBarTemplate
    XCTAssertEqual(root?.templates.count, 3)                          // Continue / Productions / Review
    let review = try XCTUnwrap((root?.templates.compactMap { $0 as? CPListTemplate })?
                                 .first { $0.title == "Review" })
    XCTAssertFalse(review.sections.first?.items.isEmpty ?? true)
    let nowPlaying = controller.startQueue(.flagged)                  // → CPNowPlayingTemplate + custom buttons
    XCTAssertTrue(nowPlaying.reviewButtonIDs.contains("carplay.approve"))
    controller.perform(.approveAndNext)                              // maps to ReviewEvent
    XCTAssertEqual(env.sync.emittedEvents.map(\.type), [.approve])   // exactly one, idempotent
  }
}
```

### G.4 Accessibility-identifier registry (source of truth for smoke tests)
`library.newAudiobook · wizard.{title,author,narrator,destination,continueToImport} · import.{chapterCount,acceptStructure} · dashboard.recordNext · record.{teleprompter,transport.record,acceptAndNext} · shelf.myProductions · production.<slug> · detail.{playWholeBook,reviewFlagged} · player.{flag,approve,pickup} · watch.production.<slug> · watch.reviewFlagged · watch.player.{flag,approve} · watch.confirmation.approved · carplay.{approve,pickup,keepFlagged}`. Adding an interactive control requires adding its ID here.

### G.5 Performance budgets (XCTest `measure`, from handoff §18)
Library first render < 500 ms after DB open · ¶ selection < 100 ms · record start < 250 ms after engine prepared · next-¶ gap within configured gap ± 50 ms · review-action feedback < 100 ms · **no global 1 Hz SwiftUI invalidation** (assert via a render-count probe on the root).

---

## H. CI grep gates (enforcement, J's pattern)

Fail the build if any of these match:

1. **No synthesis in MVP.** In all app/Core targets: forbid `import MLX`, `import CoreML` (unless later whitelisted), and any symbol matching `TTS|Synthesi[sz]e|VoiceModel|Kokoro|Chatterbox|Qwen|CosyVoice|clone`. (Keeps the MVP non-AI.)
2. **Pro gate placement.** `LicenseGate|\.isPro|ProFeature|require\(\.` must **not** appear in files matching `Recording*|Review*|Preview*|Capture*|Assembly*|Segment*|Sync*`. Economic gating lives only in `Export*`, `Packaging*`, `RetailMaster*`.
3. **No app-wide observation.** New production view models must not declare `: ObservableObject`; require `@Observable`. Grep new VM files for `ObservableObject` → fail.
4. **Stable hashing.** In `ProjectPackage/`, `Packaging/`, `AudioAssembly/`: forbid `Hasher()` / `.hashValue` for asset or cache keys; require `SHA256`.
5. **Watch isolation.** In `VoxglassWatch` target: forbid `import CloudKit`.
6. **LibriVox eligibility wired.** Require `EligibilityEvaluator`/`EligibilityProfile.evaluate` reference inside `LibriVoxPackageBuilder`; require the presence of `test_..._AIblocksLibriVox` in the test target.

---

## I. Constraints surfaced (decide before S3/S8)

1. **MP3/FLAC encoding needs a bundled encoder.** AVFoundation can *decode* MP3/FLAC but *encodes* neither, and both are mandatory for exports (LibriVox 128 kbps CBR MP3; ACX 192 kbps CBR MP3; IA/retail FLAC masters). Plan: bundle **ffmpeg** (or LAME + libFLAC) invoked via `Process` behind `AudioTranscoding`. Voxglass is GPL-3.0, so ffmpeg/LAME/libFLAC are license-compatible. **Sandbox/notarization:** the helper must be signed, sandbox-permitted (or run as an XPC helper), and CBR/true-peak settings verified against the destination profile. This is the single biggest new engineering item beyond the domain work.
2. **watchOS UI automation is limited in CI** — smoke test may need the hosted-logic fallback in §G-3.
3. **CarPlay is not XCUITest-automatable** — the CarPlay smoke test is a scene/template test (§G-3), which is also why the existing target is named `…SmokeTests`, not `…UITests`.
4. **Recording vs export formats differ:** capture masters at 48 kHz/24-bit (handoff default); LibriVox/ACX deliver 44.1 kHz mono MP3. The transcoder, not the recorder, resamples/encodes per destination — keep recording lossless and defer all lossy conversion to export.
5. **`ffmpeg`/mic/CloudKit/StoreKit never run in unit or smoke tests** — all four are behind protocols with fakes selected by `-uiTestSeed`.

---

## J. Definition of done (unchanged from handoff §21, now test-backed)
Each of the 13 DoD capabilities has at least one Swift Testing suite (logic, run by `swift test`) and is covered by the relevant device smoke test (surface). The gate is: **all five UI smoke tests green locally, all Swift Testing suites green via `swift test`, all CI grep gates passing. GitHub Actions runs no UI and no simulator tests.**
