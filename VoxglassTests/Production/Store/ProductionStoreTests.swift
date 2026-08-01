import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

@Suite struct ProductionStoreTests {

    @Test func saveAndLoadRoundTrips() async throws {
        let store = InMemoryProductionStore()
        let project = ProjectFixtures.typical()
        try await store.save(project)
        let loaded = try await store.load()

        #expect(loaded.id == project.id)
        #expect(loaded.metadata.title == project.metadata.title)
        #expect(loaded.chapters.count == project.chapters.count)
        #expect(loaded.chapters[0].paragraphs.count == project.chapters[0].paragraphs.count)
    }

    @Test func countsMatchBruteForce() async throws {
        let store = InMemoryProductionStore()
        let project = ProjectFixtures.typical()
        try await store.save(project)
        let counts = try await store.counts()

        let totalParagraphs = project.allParagraphs.count
        #expect(counts.paragraphs == totalParagraphs)

        let recorded = project.allParagraphs.filter { $0.selectedTakeID != nil }.count
        #expect(counts.recorded == recorded)

        #expect(counts.chapters == project.chapters.count)
    }

    @Test func paragraphSummariesReturnCorrectCount() async throws {
        let store = InMemoryProductionStore()
        let project = ProjectFixtures.typical()
        try await store.save(project)

        let summaries = try await store.paragraphSummaries(chapterID: nil)
        #expect(summaries.count == project.allParagraphs.count)

        if let firstChapterID = project.chapters.first?.id {
            let chapterSummaries = try await store.paragraphSummaries(chapterID: firstChapterID)
            #expect(chapterSummaries.count == project.chapters.first?.paragraphs.count ?? 0)
        }
    }

    @Test func setSelectedTakeUpdatesSelection() async throws {
        let store = InMemoryProductionStore()
        let project = ProjectFixtures.typical()
        guard let firstPara = project.allParagraphs.first(where: { !$0.takes.isEmpty }) else { return }
        guard let takeID = firstPara.takes.first?.id else { return }

        try await store.save(project)
        try await store.setSelectedTake(takeID, forParagraph: firstPara.id)

        let loaded = try await store.load()
        let updated = loaded.allParagraphs.first { $0.id == firstPara.id }
        #expect(updated?.selectedTakeID == takeID)
    }

    @Test func archiveTakeFlagsRecord() async throws {
        let store = InMemoryProductionStore()
        let project = ProjectFixtures.typical()
        guard let firstTake = project.allParagraphs.first(where: { !$0.takes.isEmpty })?.takes.first else {
            return
        }
        let takeID = firstTake.id

        try await store.save(project)
        try await store.archiveTake(takeID, archived: true)

        let loaded = try await store.load()
        let take = loaded.allParagraphs.flatMap(\.takes).first { $0.id == takeID }
        #expect(take?.isArchived == true)
    }

    @Test func reviewEventAppendAndFold() async throws {
        let store = InMemoryProductionStore()
        let project = ProjectFixtures.typical()
        try await store.save(project)

        let para = project.chapters[0].paragraphs[0]
        let event = ReviewEvent(
            id: UUID(), projectID: project.id, paragraphID: para.id,
            type: .flag, device: .mac
        )
        try await store.appendEvents([event])

        let unapplied = try await store.unappliedEvents()
        #expect(unapplied.count == 1)
        #expect(unapplied[0].type == .flag)

        try await store.markEventsApplied([event.id], at: Date())

        let remaining = try await store.unappliedEvents()
        #expect(remaining.isEmpty)
    }

    @Test func insertAndRetrieveNotes() async throws {
        let store = InMemoryProductionStore()
        let project = ProjectFixtures.typical()
        try await store.save(project)

        let para = project.chapters[0].paragraphs[0]
        let note = ReviewNote(
            id: UUID(), paragraphID: para.id,
            text: "Pronunciation check needed", device: .mac
        )
        try await store.insertNote(note)
        let notes = try await store.notes(forParagraph: para.id)
        #expect(notes.count == 1)
        #expect(notes[0].text == "Pronunciation check needed")
    }

    @Test func updateParagraphTextChangesContent() async throws {
        let store = InMemoryProductionStore()
        let project = ProjectFixtures.tiny()
        let para = project.chapters[0].paragraphs[0]
        try await store.save(project)

        let newHash = SHA256Hex.hex(Data("new text".utf8))
        try await store.updateParagraphText(para.id, text: "new text", hash: newHash, at: Date())

        let loaded = try await store.load()
        let updated = loaded.chapters[0].paragraphs[0]
        #expect(updated.text == "new text")
        #expect(updated.textHash == newHash)
    }

    @Test func summaryReturnsCorrectData() async throws {
        let store = InMemoryProductionStore()
        let project = ProjectFixtures.typical()
        try await store.save(project)

        let summary = try await store.summary()
        #expect(summary.id == project.id)
        #expect(summary.title == project.metadata.title)
        #expect(summary.author == project.metadata.author)
    }

    @Test func syncStatePersists() async throws {
        let store = InMemoryProductionStore()
        try await store.setSyncValue("changeToken", "abc123")
        let val = try await store.syncValue("changeToken")
        #expect(val == "abc123")

        try await store.setSyncValue("changeToken", nil)
        let cleared = try await store.syncValue("changeToken")
        #expect(cleared == nil)
    }

    @Test func renderCacheStoresAndRetrieves() async throws {
        let store = InMemoryProductionStore()
        let project = ProjectFixtures.typical()
        try await store.save(project)

        let ref = AudioAssetReference(sha256: "abc", relativePath: "Render/abc.caf", byteCount: 100, contentType: "audio/x-caf")
        try await store.storeRender(ref, key: "ch1", chapterID: project.chapters[0].id, duration: 60.0)

        let cached = try await store.cachedRender(forKey: "ch1")
        #expect(cached?.sha256 == "abc")
    }

    @Test func stressRoundTripReturnsCorrectCounts() async throws {
        let store = InMemoryProductionStore()
        let project = ProjectFixtures.stress(paragraphs: 100)
        try await store.save(project)
        let loaded = try await store.load()

        #expect(loaded.allParagraphs.count == 100)
        let counts = try await store.counts()
        #expect(counts.paragraphs == 100)
    }

    @Test func upsertChapterKeepsTakesAndParagraphs() async throws {
        let store = try await makeSQLiteStore()
        let project = ProjectFixtures.typical()
        try await store.save(project)

        let chapter = project.chapters[0]
        let paragraph = chapter.paragraphs[0]
        let takesBefore = try await store.counts().recorded

        let takeID = UUID()
        try await store.insertTake(Take(
            id: takeID, paragraphID: paragraph.id,
            assetRef: AudioAssetReference(sha256: "a", relativePath: "Audio/Original/a.wav", byteCount: 1, contentType: "audio/wav"),
            origin: .recorded,
            recordedAt: Date(), duration: 1.0,
            format: AudioFormatDescription(sampleRate: 48000, channels: 1, bitDepth: 16, codec: "pcm"),
            textHashAtRecording: paragraph.textHash
        ))

        var changed = chapter
        changed.title = "Renamed Chapter"
        try await store.upsertChapter(changed)

        var changedPara = paragraph
        changedPara.text = "Edited text"
        changedPara.textHash = SHA256Hex.hex(Data("Edited text".utf8))
        try await store.upsertParagraph(changedPara)

        let counts = try await store.counts()
        #expect(counts.paragraphs == project.allParagraphs.count)
        #expect(counts.recorded == takesBefore)

        let loaded = try await store.load()
        let loadedPara = loaded.chapters.first { $0.id == chapter.id }?.paragraphs.first { $0.id == paragraph.id }
        #expect(loadedPara?.takes.contains { $0.id == takeID } == true)
        #expect(loadedPara?.text == "Edited text")
    }

    @Test func paragraphIDsMatchesReviewQueueResolver() async throws {
        for store: any ProductionStore in [InMemoryProductionStore(), try await makeSQLiteStore()] {
            let project = ProjectFixtures.typical()
            try await store.save(project)

            let definitions: [ReviewPredicate] = [
                .allRecorded, .flagged, .needsPickup, .unapproved, .unreviewed,
                .chapter(project.chapters[0].id)
            ]
            let orders: [QueueOrder] = [.documentOrder, .byChapter, .flaggedFirst, .shortestFirst]

            let resolver = ReviewQueueResolver()
            for predicate in definitions {
                for order in orders {
                    let definition = ReviewQueueDefinition(projectID: project.id, predicate: predicate, order: order)
                    let expected = resolver.resolve(definition, in: project)
                    let actual = try await store.paragraphIDs(matching: predicate, order: order)
                    #expect(Set(actual) == Set(expected), "predicate \(predicate) order \(order) mismatch")
                }
            }
        }
    }

    private func makeSQLiteStore() async throws -> SQLiteProductionStore {
        let db = ProjectDatabase.makeTemporary(named: "store-\(UUID().uuidString)")
        try await db.prepare()
        return SQLiteProductionStore(databaseURL: db.url)
    }
}
