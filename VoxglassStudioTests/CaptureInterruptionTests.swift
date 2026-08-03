import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport
@testable import VoxglassStudioKit

/// WP-D interruption handling: device change, sleep, and disk full each
/// finalize and preserve the in-flight take and surface the specific banner
/// (mockup `17`, §11.2 rules 6 and 8). The engine-level observers
/// (`AVAudioEngineConfigurationChange`, `NSWorkspace.willSleepNotification`)
/// are hardware-bound; the model's finalize-and-preserve contract is what
/// these tests pin.
@MainActor
@Suite struct CaptureInterruptionTests {

    private struct Harness {
        let capture = FakeAudioCapture()
        let store = InMemoryProductionStore()
        let assets = InMemoryAssetStore()
        let project: AudiobookProject
        let paragraphID: UUID
        var model: RecordingModel

        @MainActor
        init() {
            let ids = SequentialIDGenerator()
            let clock = FixedClock()
            let paragraph = Paragraph(id: ids.next(), ordinal: 0, text: "Paragraph one.", textHash: "h")
            paragraphID = paragraph.id
            project = AudiobookProject(
                id: ids.next(),
                metadata: BookMetadata(title: "T", author: "A", narrator: "N"),
                profile: ProductionProfile(recording: RecordingDefaults(preRollSeconds: 0)),
                chapters: [ProductionChapter(id: ids.next(), ordinal: 0, title: "Ch", paragraphs: [paragraph])],
                createdAt: clock.now,
                modifiedAt: clock.now
            )
            model = RecordingModel(capture: capture, store: store, assets: assets, projectID: project.id)
        }

        func startTake() async throws -> CapturedTake {
            try await store.save(project)
            await model.loadProject()
            await model.loadParagraph(paragraphID)
            await model.prepare()
            await model.startRecording(paragraphID: paragraphID)
            // Finalize through the fake directly — the model's own
            // stopRecording would ingest the file, but an interruption is
            // exactly the path where the capture finalizes instead.
            return try await capture.stopRecording()
        }
    }

    @Test func deviceChangeFinalizesAndPreservesTake() async throws {
        let h = Harness()
        let captured = try await h.startTake()
        let takeCountBefore = try await h.store.load().allParagraphs.first?.takes.count ?? 0

        await h.model.handleCaptureInterruption(CaptureInterruption(
            kind: .deviceChanged(name: "USB Interface"),
            take: captured
        ))

        let stored = try await h.store.load()
        #expect(stored.allParagraphs.first?.takes.count == takeCountBefore + 1, "the interrupted take must be ingested")
        #expect(h.model.interruptionBanner != nil)
        #expect(h.model.interruptionBanner?.title == "Your input device changed.")
        #expect(h.model.interruptionBanner?.message == "The take was saved.")
        if case .deviceChanged(let name) = h.model.interruptionBanner?.kind {
            #expect(name == "USB Interface")
        } else {
            Issue.record("banner kind must be deviceChanged")
        }
        #expect(h.model.interruptionBanner?.takeID != nil, "Reveal Take needs the preserved take")
    }

    @Test func sleepFinalizesAndPreservesTake() async throws {
        let h = Harness()
        let captured = try await h.startTake()
        let takeCountBefore = try await h.store.load().allParagraphs.first?.takes.count ?? 0

        await h.model.handleCaptureInterruption(CaptureInterruption(kind: .sleep, take: captured))

        let stored = try await h.store.load()
        #expect(stored.allParagraphs.first?.takes.count == takeCountBefore + 1)
        #expect(h.model.interruptionBanner?.title == "Your Mac went to sleep.")
        #expect(h.model.interruptionBanner?.takeID != nil)
    }

    @Test func diskFullPreservesExistingAudioAndReportsError() async throws {
        let h = Harness()
        let captured = try await h.startTake()
        let takeCountBefore = try await h.store.load().allParagraphs.first?.takes.count ?? 0

        // Disk full with no finalizable audio: existing audio must be intact
        // and the banner must carry the specific error.
        await h.model.handleCaptureInterruption(CaptureInterruption(kind: .diskFull, take: nil))

        let stored = try await h.store.load()
        #expect(stored.allParagraphs.first?.takes.count == takeCountBefore, "disk-full must destroy nothing")
        #expect(h.model.interruptionBanner?.title == "The disk filled up while recording.")
        #expect(h.model.interruptionBanner?.message == "Everything recorded up to that point was saved.")
        if case .diskFull = h.model.interruptionBanner?.kind {
        } else {
            Issue.record("banner kind must be diskFull")
        }
    }

    @Test func interruptionBannerDismissAndResume() async throws {
        let h = Harness()
        let captured = try await h.startTake()
        await h.model.handleCaptureInterruption(CaptureInterruption(kind: .sleep, take: captured))
        #expect(h.model.interruptionBanner != nil)

        h.model.dismissInterruptionBanner()
        #expect(h.model.interruptionBanner == nil)

        // Resume restarts the capture on the same paragraph without error.
        await h.model.resumeAfterInterruption()
        #expect(h.model.currentParagraphID == h.paragraphID)
        #expect(h.capture.state == .recording || h.capture.state == .prepared)
    }
}
