import AVFoundation
import UIKit
import XCTest
import VoxglassCore
@testable import Voxglass

/// Regressions for the 2026-08-19 field report's state-ownership defects
/// (items 4, 8, 9, 11, 12, 13). These live in the hosted narration harness
/// because `NarrationFlowModel` and `DiscoveryEnvironment` are app-target
/// types; the harness runs on its own scheme, off `scripts/test.sh` and CI.
@MainActor
final class NarrationStateFreshnessTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxglass-narration-freshness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func makeRepository() -> NarrationProjectRepository {
        NarrationProjectRepository(
            applicationSupport: root,
            clock: NarrationE2EClock(),
            ids: NarrationE2EIDGenerator()
        )
    }

    // MARK: - Phase 6: artwork is a durable project asset, not model bytes

    func testArtworkNormalizesReplacesAndReloadsFromProjectAssets() async throws {
        let repository = makeRepository()
        let seeded = try await NarrationE2EFixture.seed(into: repository)
        let model = NarrationFlowModel(repository: repository, capture: TTSAudioCapture())
        await model.load(seeded)

        await model.setArtwork(pngArtwork(color: .systemBlue))
        let firstRef = try XCTUnwrap(model.project?.metadata.coverRef)
        XCTAssertTrue(firstRef.relativePath.hasPrefix("Artwork/"))
        XCTAssertTrue(firstRef.relativePath.hasSuffix(".jpg"))
        XCTAssertEqual(firstRef.contentType, "image/jpeg")

        let firstBytes = try await repository.fileStore(for: seeded.id).data(for: firstRef)
        XCTAssertEqual(Array(firstBytes.prefix(2)), [0xFF, 0xD8], "selected images must be normalized to JPEG")
        XCTAssertEqual(SHA256Hex.hex(firstBytes), firstRef.sha256)

        await model.setArtwork(pngArtwork(color: .systemOrange))
        let replacementRef = try XCTUnwrap(model.project?.metadata.coverRef)
        XCTAssertNotEqual(replacementRef, firstRef, "a new selection must replace metadata.coverRef")

        let persisted = try await repository.load(seeded.id)
        XCTAssertEqual(persisted.metadata.coverRef, replacementRef)

        let reopened = NarrationFlowModel(repository: repository, capture: TTSAudioCapture())
        await reopened.load(persisted)
        await reopened.loadArtwork()
        let reloadedBytes = try XCTUnwrap(reopened.artworkData)
        let persistedBytes = try await repository.fileStore(for: seeded.id).data(for: replacementRef)
        XCTAssertEqual(reloadedBytes, persistedBytes)
        XCTAssertNotNil(UIImage(data: reloadedBytes))
    }

    private func pngArtwork(color: UIColor) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 32))
        return renderer.pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 32))
        }
    }

    // MARK: - Item 9: approvals must stick across a re-entry of the flow

    func testApprovalsSurviveAnotherScreenResumingTheProject() async throws {
        let repository = makeRepository()
        let seeded = try await NarrationE2EFixture.seed(into: repository)

        // The dashboard's copy of the project, captured when it was pushed.
        let dashboardSnapshot = seeded

        let flow = NarrationFlowModel(repository: repository, capture: TTSAudioCapture())
        let openedProject = await flow.storedProject(seeded.id)
        let opened = try XCTUnwrap(openedProject)
        await flow.load(opened)

        let target = try XCTUnwrap(seeded.allParagraphs.last)
        flow.acceptParagraph(target.id)
        await flow.persist()

        // A second screen re-enters the flow. It must open the *stored*
        // revision, not the snapshot it has been holding since it was pushed.
        let second = NarrationFlowModel(repository: repository, capture: TTSAudioCapture())
        let reopenedProject = await second.storedProject(dashboardSnapshot.id)
        let reopened = try XCTUnwrap(reopenedProject)
        await second.load(reopened)
        XCTAssertEqual(
            second.project?.allParagraphs.first { $0.id == target.id }?.reviewState,
            .approved,
            "the approval must still be there when the flow is re-entered"
        )

        // And an unrelated edit made through that second screen must not
        // resurrect the pre-approval state.
        second.saveMetadataField(.language, value: "en-GB")
        await second.persist()
        let stored = try await repository.load(seeded.id)
        XCTAssertEqual(stored.allParagraphs.first { $0.id == target.id }?.reviewState, .approved)
        XCTAssertEqual(stored.metadata.language, "en-GB")
    }

    // MARK: - Item 8: the source-URL prompt must not return once answered

    func testResumingAProjectWithASourceURLDoesNotPromptForOne() async throws {
        let repository = makeRepository()
        let seeded = try await NarrationE2EFixture.seed(into: repository)

        let model = NarrationFlowModel(repository: repository, capture: TTSAudioCapture())
        let openedProject = await model.storedProject(seeded.id)
        let opened = try XCTUnwrap(openedProject)
        await model.load(opened)
        model.saveSourceURL("https://example.org/the-source-edition")
        await model.persist()

        let reopened = NarrationFlowModel(repository: repository, capture: TTSAudioCapture())
        let freshProject = await reopened.storedProject(seeded.id)
        let fresh = try XCTUnwrap(freshProject)
        await reopened.load(fresh)

        XCTAssertFalse(reopened.needsSourceURLPrompt, "the narrator already answered this")
        XCTAssertEqual(reopened.project?.rights.sourceURL?.absoluteString, "https://example.org/the-source-edition")
    }

    // MARK: - Item 4: a check must judge stored state, on the first press

    func testRunValidationReadsTheStoreRatherThanItsOwnStaleCopy() async throws {
        let repository = makeRepository()
        var seeded = try await NarrationE2EFixture.seed(into: repository)
        seeded.rights.sourceURL = nil
        seeded.profile.intendedDestination = .librivox
        try await repository.save(seeded)

        let model = NarrationFlowModel(repository: repository, capture: TTSAudioCapture())
        await model.load(seeded)
        model.validationDestination = .librivox

        // Another screen writes the source URL behind this model's back.
        var repaired = try await repository.load(seeded.id)
        repaired.rights.sourceURL = URL(string: "https://example.org/the-source-edition")
        try await repository.save(repaired)

        await model.runValidation()
        XCTAssertFalse(
            model.validationIssues.contains { $0.code == .missingSourceURL },
            "the first check must not report a field the narrator can already see"
        )
    }

    // MARK: - Item 12: the check analyzes, and never loses the analysis

    func testCheckMyRecordingAnalyzesTakesAndTheAnalysisSurvivesSaving() async throws {
        let repository = makeRepository()
        let seeded = try await NarrationE2EFixture.seed(into: repository)

        let model = NarrationFlowModel(repository: repository, capture: TTSAudioCapture())
        await model.load(seeded)

        // Record two paragraphs so there is something real to measure.
        let paragraphs = Array(seeded.allParagraphs.prefix(2))
        for paragraph in paragraphs {
            await model.startRecordingParagraph(paragraph.id)
            XCTAssertTrue(model.isRecording, "speech synthesis produced no take")
            await model.stopRecordingParagraph(paragraph.id)
        }
        await model.persist()

        // Stamp every take with metrics from an older analyzer, which is what
        // the rule engine treats as "not analyzed". The check must measure them
        // again rather than merely reporting the problem.
        let store = repository.store(for: seeded.id)
        let recorded = try await repository.load(seeded.id)
        for take in recorded.allParagraphs.flatMap(\.takes) {
            var stale = take.metrics ?? AudioQualityMetrics(
                peakDBFS: -6, truePeakDBFS: -6, rmsDBFS: -24, noiseFloorDBFS: -60,
                noiseFloorReliable: true, replayGainDB: 0, clipCount: 0, dcOffset: 0,
                leadingSilence: 0, trailingSilence: 0, duration: take.duration,
                sampleRate: take.format.sampleRate, channels: take.format.channels
            )
            stale.analyzerVersion = AudioMetricsCalculator.analyzerVersion - 1
            try await store.setTakeMetrics(stale, forTake: take.id)
        }
        await model.reloadProjectFromStore()

        model.validationDestination = .personalMaster
        await model.runValidation()

        XCTAssertFalse(
            model.validationIssues.contains { $0.code == .missingMetrics },
            "the check must measure what is missing instead of reporting that it is missing"
        )
        let analyzed = try await repository.load(seeded.id)
        let recordedIDs = Set(paragraphs.map(\.id))
        for paragraph in analyzed.allParagraphs where recordedIDs.contains(paragraph.id) {
            XCTAssertEqual(
                paragraph.selectedTake?.metrics?.analyzerVersion,
                AudioMetricsCalculator.analyzerVersion,
                "paragraph \(paragraph.ordinal) was not re-analyzed"
            )
        }

        // A later whole-project save from a graph without metrics must not
        // erase them.
        await model.persist()
        let afterSave = try await repository.load(seeded.id)
        for paragraph in afterSave.allParagraphs where recordedIDs.contains(paragraph.id) {
            XCTAssertNotNil(paragraph.selectedTake?.metrics, "a save erased the analysis")
        }
    }

    // MARK: - Item 13: the narrator gets a control, and it does something

    func testNormalizeLoudnessTurnsOnRenderNormalizationAndPersists() async throws {
        let repository = makeRepository()
        let seeded = try await NarrationE2EFixture.seed(into: repository)
        XCTAssertFalse(seeded.profile.assembly.isNormalizingLoudness, "fixture starts with normalization off")

        let model = NarrationFlowModel(repository: repository, capture: TTSAudioCapture())
        await model.load(seeded)
        await model.normalizeLoudness()

        XCTAssertTrue(model.project?.profile.assembly.isNormalizingLoudness == true)
        XCTAssertTrue(model.assembly.isNormalizingLoudness, "the assembly screen's toggle must agree")
        let stored = try await repository.load(seeded.id)
        XCTAssertTrue(stored.profile.assembly.isNormalizingLoudness)
    }

    // MARK: - Phase 11: recording remains live until an explicit stop

    func testParagraphRecordingSerializesStartStopAndPersistsTake() async throws {
        let repository = makeRepository()
        let seeded = try await NarrationE2EFixture.seed(into: repository)
        let paragraph = try XCTUnwrap(seeded.allParagraphs.first)
        let capture = RecordingLifecycleCapture(startDelay: .milliseconds(150))
        let model = NarrationFlowModel(repository: repository, capture: capture)
        await model.load(seeded)

        let firstStart = Task { await model.startRecordingParagraph(paragraph.id) }
        await Task.yield()
        let duplicateStart = Task { await model.startRecordingParagraph(paragraph.id) }
        await firstStart.value
        await duplicateStart.value

        XCTAssertEqual(capture.startCallCount, 1, "duplicate taps must not start capture twice")
        XCTAssertTrue(model.isRecording)
        XCTAssertEqual(capture.state, .recording)
        XCTAssertNil(model.paragraph(at: paragraph.id)?.take, "a take is not created until Stop")

        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(model.isRecording, "returning from the start task must not stop capture")

        let firstStop = Task { await model.stopRecordingParagraph(paragraph.id) }
        await Task.yield()
        let duplicateStop = Task { await model.stopRecordingParagraph(paragraph.id) }
        await firstStop.value
        await duplicateStop.value

        XCTAssertEqual(capture.stopCallCount, 1, "duplicate taps must not finalize capture twice")
        XCTAssertFalse(model.isRecording)
        XCTAssertNotNil(model.paragraph(at: paragraph.id)?.take)
        let stored = try await repository.load(seeded.id)
        let persisted = try XCTUnwrap(stored.allParagraphs.first { $0.id == paragraph.id }?.selectedTake)
        XCTAssertGreaterThan(persisted.assetRef.byteCount, 0)
        XCTAssertFalse(persisted.assetRef.sha256.isEmpty)
    }

    func testParagraphRecordingSetupFailureStaysVisibleAndLeavesNoSession() async throws {
        let repository = makeRepository()
        let seeded = try await NarrationE2EFixture.seed(into: repository)
        let paragraph = try XCTUnwrap(seeded.allParagraphs.first)
        let capture = RecordingLifecycleCapture(failPrepare: true)
        let model = NarrationFlowModel(repository: repository, capture: capture)
        await model.load(seeded)

        await model.startRecordingParagraph(paragraph.id)

        XCTAssertFalse(model.isRecording)
        XCTAssertTrue(model.micPermissionDenied)
        XCTAssertTrue(model.importError?.contains("Microphone access is blocked") == true)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: repository.layout(for: seeded.id).autosaveSessionURL.path),
            "failed setup must not masquerade as a recoverable take"
        )
    }

    func testParagraphRecordingStopFailureStaysVisibleForRecovery() async throws {
        let repository = makeRepository()
        let seeded = try await NarrationE2EFixture.seed(into: repository)
        let paragraph = try XCTUnwrap(seeded.allParagraphs.first)
        let capture = RecordingLifecycleCapture(failStop: true)
        let model = NarrationFlowModel(repository: repository, capture: capture)
        await model.load(seeded)

        await model.startRecordingParagraph(paragraph.id)
        await model.stopRecordingParagraph(paragraph.id)

        XCTAssertFalse(model.isRecording)
        XCTAssertTrue(model.importError?.contains("Couldn't save this recording") == true)
        XCTAssertNil(model.paragraph(at: paragraph.id)?.take)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: repository.layout(for: seeded.id).autosaveSessionURL.path),
            "a failed finalization must retain the recovery session"
        )
    }

    func testSafetyStopRequestedDuringStartFinalizesExactlyOnce() async throws {
        let repository = makeRepository()
        let seeded = try await NarrationE2EFixture.seed(into: repository)
        let paragraph = try XCTUnwrap(seeded.allParagraphs.first)
        let capture = RecordingLifecycleCapture(startDelay: .milliseconds(150))
        let model = NarrationFlowModel(repository: repository, capture: capture)
        await model.load(seeded)

        let start = Task { await model.startRecordingParagraph(paragraph.id) }
        await Task.yield()
        await model.stopRecordingParagraph(paragraph.id)
        await start.value

        XCTAssertEqual(capture.startCallCount, 1)
        XCTAssertEqual(capture.stopCallCount, 1)
        XCTAssertFalse(model.isRecording)
        XCTAssertNotNil(model.paragraph(at: paragraph.id)?.take)
    }

    // MARK: - Item 6: an imported need reaches export with a description

    func testDescriptionBackfillRepairsAProjectSavedWithoutOne() async throws {
        let repository = makeRepository()
        var seeded = try await NarrationE2EFixture.seed(into: repository)
        seeded.metadata.description = ""
        try await repository.save(seeded)

        await repository.backfillProjectDetailsIfNeeded(knownNeeds: [])

        let repaired = try await repository.load(seeded.id)
        XCTAssertFalse(
            repaired.metadata.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "an empty description must be repaired, not carried into export"
        )
        XCTAssertTrue(repaired.metadata.description.contains(seeded.metadata.title))
    }

    // MARK: - Item 9 again, at the seam that used to overwrite the store

    func testDiscoverySaveRefusesAnOlderRevision() async throws {
        let repository = makeRepository()
        let seeded = try await NarrationE2EFixture.seed(into: repository)

        // Drain the one-shot details backfill first so it cannot race the
        // revisions this test is about.
        await repository.backfillProjectDetailsIfNeeded(knownNeeds: [])
        let discovery = DiscoveryEnvironment(
            sources: [],
            cache: InMemoryNeedsCache(),
            clock: NarrationE2EClock(),
            repository: repository
        )
        await discovery.reloadNarrations()

        var newer = try await repository.load(seeded.id)
        newer.metadata.language = "en-GB"
        newer.modifiedAt = seeded.modifiedAt.addingTimeInterval(60)
        try await repository.save(newer)

        // A screen still holding the pre-edit snapshot mirrors it back.
        var stale = seeded
        stale.metadata.language = "fr-FR"
        stale.modifiedAt = newer.modifiedAt.addingTimeInterval(-60)
        await discovery.save(stale)

        let stored = try await repository.load(seeded.id)
        XCTAssertEqual(stored.metadata.language, "en-GB", "a stale snapshot must never overwrite newer work")
    }
}

/// A deterministic hosted-capture seam for the paragraph lifecycle tests. It
/// delegates WAV creation to the app's UI-test capture while adding a suspended
/// start and injectable setup failure so MainActor reentrancy is exercised.
private final class RecordingLifecycleCapture: AudioCapturing, @unchecked Sendable {
    private let base = UITestAudioCapture()
    private let startDelay: Duration
    private let failPrepare: Bool
    private let failStop: Bool
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    init(startDelay: Duration = .zero, failPrepare: Bool = false, failStop: Bool = false) {
        self.startDelay = startDelay
        self.failPrepare = failPrepare
        self.failStop = failStop
    }

    var state: CaptureState { base.state }
    var levels: AsyncStream<CaptureLevels> { base.levels }
    var currentRouteInfo: CaptureRouteInfo { base.currentRouteInfo }
    var onInterruption: ((CaptureInterruptionReason) -> Void)? {
        get { base.onInterruption }
        set { base.onInterruption = newValue }
    }

    func availableInputDevices() async -> [AudioDeviceInfo] {
        await base.availableInputDevices()
    }

    func prepare(device: String?, format: RecordingDefaults) async throws {
        if failPrepare { throw CaptureError.permissionDenied }
        try await base.prepare(device: device, format: format)
    }

    func startMonitoring() async throws { try await base.startMonitoring() }
    func stopMonitoring() async { await base.stopMonitoring() }

    func startRecording(to destinationURL: URL) async throws {
        startCallCount += 1
        if startDelay != .zero { try await Task.sleep(for: startDelay) }
        try await base.startRecording(to: destinationURL)
    }

    func stopRecording() async throws -> CapturedTake {
        stopCallCount += 1
        if failStop { throw CaptureError.diskFull }
        return try await base.stopRecording()
    }

    func cancelRecording() async { await base.cancelRecording() }
    func punchIn(from offset: TimeInterval) async throws { try await base.punchIn(from: offset) }
}
