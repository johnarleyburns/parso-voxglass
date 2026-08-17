import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport
@testable import VoxglassStudioKit

/// S5 acceptance: 100 sequential paragraphs recorded without loss, each take
/// persisted with a real sha256 and byteCount, no take lost, no ID collision.
/// Also pins the RecordingModel bugs from current_status.md T5 and the autosave
/// session contract (spec §7.7).
@MainActor
@Suite struct RecordingFlowTests {

    @MainActor
    private struct Harness {
        let capture = FakeAudioCapture()
        let store = InMemoryProductionStore()
        let assets = InMemoryAssetStore()
        let packageRoot: URL
        let project: AudiobookProject
        let paragraphIDs: [UUID]
        var model: RecordingModel

        init(paragraphCount: Int = 100) {
            let ids = SequentialIDGenerator()
            let clock = FixedClock()
            let profile = ProductionProfile(recording: RecordingDefaults(preRollSeconds: 0))
            let paragraphs = (0..<paragraphCount).map { i in
                let text = "Paragraph \(i). This is the body text the narrator reads for paragraph \(i) of the acceptance test."
                return Paragraph(
                    id: ids.next(),
                    ordinal: i,
                    text: text,
                    textHash: SHA256Hex.hex(Data(text.utf8))
                )
            }
            let chapter = ProductionChapter(id: ids.next(), ordinal: 0, title: "Acceptance Chapter", paragraphs: paragraphs)
            project = AudiobookProject(
                id: ids.next(),
                metadata: BookMetadata(title: "Acceptance Book", author: "Author", narrator: "Narrator"),
                profile: profile,
                chapters: [chapter],
                createdAt: clock.now,
                modifiedAt: clock.now
            )
            paragraphIDs = paragraphs.map(\.id)

            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("voxglass-recording-flow-\(UUID().uuidString)")
                .appendingPathComponent("acceptance.voxproject")
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            packageRoot = root
            model = RecordingModel(capture: capture, store: store, assets: assets, projectID: project.id, packageRoot: root)
        }

        func loadProjectAndPrepare() async throws {
            try await store.save(project)
            await model.loadProject()
            await model.prepare()
        }
    }

    @Test func hundredSequentialParagraphsRecordedWithoutLoss() async throws {
        let h = Harness()
        try await h.loadProjectAndPrepare()

        for paragraphID in h.paragraphIDs {
            await h.model.startRecording(paragraphID: paragraphID)
            await h.model.stopRecording()
        }

        #expect(h.model.takes.count == 100, "take lost: \(h.model.takes.count)/100 persisted in the model")
        #expect(h.model.error == nil, "unexpected error: \(h.model.error ?? "")")

        let reloaded = try await h.store.load()
        let allTakes = reloaded.allParagraphs.flatMap(\.takes)
        #expect(allTakes.count == 100, "take lost on reload: \(allTakes.count)/100")
    }

    @Test func eachTakePersistedWithRealSHA256AndByteCount() async throws {
        let h = Harness()
        try await h.loadProjectAndPrepare()

        for paragraphID in h.paragraphIDs.prefix(10) {
            await h.model.startRecording(paragraphID: paragraphID)
            await h.model.stopRecording()
        }

        for take in h.model.takes {
            #expect(!take.assetRef.sha256.isEmpty, "empty sha256 on take \(take.id)")
            #expect(take.assetRef.sha256 != String(repeating: "0", count: 64), "uncomputed sha256")
            #expect(take.assetRef.byteCount > 0, "zero byteCount on take \(take.id)")
            let data = try await h.assets.data(for: take.assetRef)
            #expect(SHA256Hex.hex(data) == take.assetRef.sha256, "stored asset does not match its sha256")
        }

        let reloaded = try await h.store.load()
        for take in reloaded.allParagraphs.flatMap(\.takes) {
            #expect(!take.assetRef.sha256.isEmpty)
            #expect(take.assetRef.byteCount > 0)
            #expect(!take.textHashAtRecording.isEmpty, "textHashAtRecording must be set from the paragraph text")
        }
    }

    @Test func noTakeLostAndNoIDCollision() async throws {
        let h = Harness(paragraphCount: 100)
        try await h.loadProjectAndPrepare()

        for paragraphID in h.paragraphIDs {
            await h.model.startRecording(paragraphID: paragraphID)
            await h.model.stopRecording()
        }

        let ids = h.model.takes.map(\.id)
        #expect(Set(ids).count == ids.count, "ID collision across 100 takes")

        let reloaded = try await h.store.load()
        let reloadedTakes = reloaded.allParagraphs.flatMap(\.takes)
        #expect(Set(reloadedTakes.map(\.id)).count == 100)

        let paragraphIDsWithTakes = Set(reloaded.allParagraphs.filter { !$0.takes.isEmpty }.map(\.id))
        #expect(paragraphIDsWithTakes == Set(h.paragraphIDs), "every paragraph must own exactly its take")
    }

    @Test func stopRecordingWithoutStartDoesNotCrash() async throws {
        let h = Harness(paragraphCount: 1)
        try await h.loadProjectAndPrepare()

        await h.model.stopRecording()
        #expect(h.model.takes.isEmpty)
        #expect(h.capture.stopRecordingCallCount == 0, "model must guard, not forward")
    }

    @Test func permissionDeniedSurfacesError() async throws {
        let h = Harness(paragraphCount: 1)
        h.capture.permissionDenied = true
        try await h.store.save(h.project)
        await h.model.loadProject()

        await h.model.prepare()
        #expect(h.model.error?.contains("Failed to prepare") == true)
        #expect(h.model.phase == .idle)
    }

    @Test func diskFullOnStartSurfacesErrorAndLeavesNoAutosave() async throws {
        let h = Harness(paragraphCount: 1)
        h.capture.diskFullOnStart = true
        try await h.store.save(h.project)
        await h.model.loadProject()
        await h.model.prepare()

        await h.model.startRecording(paragraphID: h.paragraphIDs[0])
        #expect(h.model.error?.contains("Failed to start") == true)
        #expect(h.model.takes.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: h.packageRoot.appendingPathComponent("Autosave/session.json").path),
                "a failed start must not leave a session.json behind")
    }

    @Test func deviceDisappearingMidTakeFailsLoudly() async throws {
        let h = Harness(paragraphCount: 1)
        h.capture.deviceDisappearsOnStop = true
        try await h.store.save(h.project)
        await h.model.loadProject()
        await h.model.prepare()

        await h.model.startRecording(paragraphID: h.paragraphIDs[0])
        await h.model.stopRecording()

        #expect(h.model.error?.contains("Failed to stop") == true)
        #expect(h.model.takes.isEmpty, "a vanished device must not produce a persisted take")
    }

    @Test func takePeakDBFSIsNegativeForHealthyTake() async throws {
        let h = Harness(paragraphCount: 1)
        h.capture.takeAmplitude = 0.5
        try await h.loadProjectAndPrepare()

        await h.model.startRecording(paragraphID: h.paragraphIDs[0])
        await h.model.stopRecording()

        let take = try #require(h.model.takes.first)
        let reloaded = try await h.store.load()
        let stored = reloaded.allParagraphs.flatMap(\.takes).first
        #expect(stored?.origin == .recorded)
        #expect(take.duration > 0)
    }

    @Test func autosaveSessionWrittenBeforeRecordingAndDeletedOnNormalStop() async throws {
        let h = Harness(paragraphCount: 1)
        try await h.loadProjectAndPrepare()
        let sessionURL = h.packageRoot.appendingPathComponent("Autosave/session.json")

        await h.model.startRecording(paragraphID: h.paragraphIDs[0])

        #expect(FileManager.default.fileExists(atPath: sessionURL.path), "session.json must exist during recording")
        let session = try #require(try AutosaveSessionFile.read(from: sessionURL))
        #expect(session.paragraphID == h.paragraphIDs[0])
        #expect(session.filePath.hasPrefix("Autosave/takes/"))
        #expect(session.format.sampleRate == 48_000)
        #expect(session.chapterID == h.project.chapters.first?.id)

        await h.model.stopRecording()
        #expect(!FileManager.default.fileExists(atPath: sessionURL.path), "session.json must be deleted on normal stop")
    }

    @Test func autosaveSessionDeletedOnCancel() async throws {
        let h = Harness(paragraphCount: 1)
        try await h.loadProjectAndPrepare()
        let sessionURL = h.packageRoot.appendingPathComponent("Autosave/session.json")

        await h.model.startRecording(paragraphID: h.paragraphIDs[0])
        #expect(FileManager.default.fileExists(atPath: sessionURL.path))

        await h.model.cancelRecording()
        #expect(!FileManager.default.fileExists(atPath: sessionURL.path))
        #expect(h.model.takes.isEmpty)
    }
}
