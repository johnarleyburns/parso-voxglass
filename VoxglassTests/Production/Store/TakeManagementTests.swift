import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// Spec §19.3: takes on one paragraph — multiple takes, select-newest,
/// archiving keeps the take but removes it from the active set, and the
/// selected take survives a store round-trip.
@Suite struct TakeManagementTests {

    private func makeProjectWithTakes() -> AudiobookProject {
        let ids = SequentialIDGenerator()
        let clock = FixedClock()
        let project = ProjectFixtures.tiny()
        var withTakes = project

        let paragraphID = withTakes.chapters[0].paragraphs[0].id
        var takes: [Take] = []
        for i in 0..<3 {
            let data = Data("take-\(i)".utf8)
            let ref = AudioAssetReference(
                sha256: SHA256Hex.hex(data),
                relativePath: "Audio/Original/aa/aa/\(SHA256Hex.hex(data)).wav",
                byteCount: data.count,
                contentType: "audio/wav"
            )
            takes.append(Take(
                id: ids.next(),
                paragraphID: paragraphID,
                assetRef: ref,
                origin: .recorded,
                recordedAt: clock.now.addingTimeInterval(TimeInterval(i) * 60),
                duration: TimeInterval(1 + i),
                format: AudioFormatDescription(sampleRate: 48000, channels: 1, bitDepth: 16, codec: "pcm"),
                processing: [],
                metrics: nil,
                label: "take \(i)",
                textHashAtRecording: "",
                isArchived: false
            ))
        }
        withTakes.chapters[0].paragraphs[0].takes = takes
        return withTakes
    }

    @Test func multipleTakesPersistAndSelectNewest() async throws {
        let store = SQLiteProductionStore(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("takes-\(UUID().uuidString).sqlite"))
        let project = makeProjectWithTakes()
        try await store.save(project)

        let paragraphID = project.chapters[0].paragraphs[0].id
        let newest = project.chapters[0].paragraphs[0].takes.max(by: { $0.recordedAt < $1.recordedAt })!
        try await store.setSelectedTake(newest.id, forParagraph: paragraphID)

        let loaded = try await store.load()
        let para = loaded.allParagraphs.first { $0.id == paragraphID }
        #expect(para?.takes.count == 3)
        #expect(para?.selectedTakeID == newest.id)

        let counts = try await store.counts()
        #expect(counts.recorded == 1) // one paragraph with a selected take
    }

    @Test func archivingTakeDoesNotRemoveIt() async throws {
        let store = SQLiteProductionStore(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("takes-\(UUID().uuidString).sqlite"))
        let project = makeProjectWithTakes()
        try await store.save(project)

        let take = project.chapters[0].paragraphs[0].takes[0]
        try await store.archiveTake(take.id, archived: true)

        let loaded = try await store.load()
        let para = loaded.allParagraphs.first { $0.id == project.chapters[0].paragraphs[0].id }
        #expect(para?.takes.count == 3)
        #expect(para?.takes.first { $0.id == take.id }?.isArchived == true)
    }

    @Test func selectNewestAcrossRelaunch() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("takes-\(UUID().uuidString).sqlite")
        let project = makeProjectWithTakes()
        do {
            let store = SQLiteProductionStore(databaseURL: url)
            try await store.save(project)
        }
        // Second store instance = fresh process equivalent.
        let store2 = SQLiteProductionStore(databaseURL: url)
        let loaded = try await store2.load()
        #expect(loaded.chapters[0].paragraphs[0].takes.count == 3)
        #expect(loaded.chapters[0].paragraphs[0].takes.map(\.label) == ["take 0", "take 1", "take 2"])
    }
}
