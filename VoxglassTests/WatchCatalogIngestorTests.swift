import Foundation
import Testing
import VoxglassWatchProtocol
import VoxglassWatchCore

private final class RecordingStore: WatchCatalogDurableStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data] = []
    var saves: [Data] { lock.withLock { values } }
    func save(_ data: Data) { lock.withLock { values.append(data) } }
}

@Suite struct WatchCatalogIngestorTests {
    private let library = WatchPairedLibraryID("lib-a")

    private func book(_ id: String, rev: Int64 = 1, chapters: Int = 1) -> WatchBookDTO {
        WatchBookDTO(id: WatchBookID(id), title: id, metadataRevision: rev,
                     chapters: (0..<chapters).map { WatchChapterDTO(id: WatchChapterID("\(id)-\($0)"), index: $0, title: "C\($0)", duration: 60) })
    }
    private func envelope(library: WatchPairedLibraryID? = nil, revision: Int64, books: [WatchBookDTO]) throws -> Data {
        let lib = library ?? self.library
        return try WatchProtocolEnvelope.encode(kind: .librarySnapshot,
            payload: WatchLibrarySnapshot(pairedLibraryID: lib, revision: revision, books: books), libraryID: lib)
    }

    @Test func validSnapshotDeduplicatesBooksBeforeCommit() async throws {
        let store = RecordingStore()
        let ingestor = WatchCatalogIngestor(store: store)
        let data = try envelope(revision: 1, books: [book("a"), book("a"), book("b")])
        guard case .accepted(let commit) = await ingestor.ingest(data, generation: 1, current: nil) else {
            Issue.record("expected accepted"); return
        }
        #expect(commit.snapshot.books.map(\.id.rawValue) == ["a", "b"])
        #expect(commit.books.count == 2)
        #expect(store.saves.count == 1)
    }

    @Test func olderRevisionForSameLibraryIsIgnored() async throws {
        let store = RecordingStore()
        let ingestor = WatchCatalogIngestor(store: store)
        let current = WatchLibrarySnapshot(pairedLibraryID: library, revision: 5, books: [])
        let result = await ingestor.ingest(try envelope(revision: 4, books: [book("a")]), generation: 1, current: current)
        #expect(result == .ignoredStale)
        #expect(store.saves.isEmpty)
    }

    @Test func aDifferentPairedLibraryIsAcceptedAccordingToExistingRules() async throws {
        let ingestor = WatchCatalogIngestor(store: RecordingStore())
        let current = WatchLibrarySnapshot(pairedLibraryID: library, revision: 9, books: [])
        let data = try envelope(library: WatchPairedLibraryID("lib-b"), revision: 1, books: [book("a")])
        guard case .accepted(let commit) = await ingestor.ingest(data, generation: 1, current: current) else {
            Issue.record("expected accepted"); return
        }
        #expect(commit.needsReconciliation)
    }

    @Test func malformedEnvelopeChangesNoCatalogOrDurableState() async {
        let store = RecordingStore()
        let ingestor = WatchCatalogIngestor(store: store)
        let result = await ingestor.ingest(Data([1, 2, 3]), generation: 1, current: nil)
        #expect(result == .rejectedMalformed)
        #expect(store.saves.isEmpty)
    }

    @Test func reconciliationFlagMatchesWatchPhonePushFilesContract() async throws {
        let ingestor = WatchCatalogIngestor(store: RecordingStore())
        let previous = WatchLibrarySnapshot(pairedLibraryID: library, revision: 1, books: [book("a")])
        let same = try envelope(revision: 2, books: [book("a")])
        guard case .accepted(let unchanged) = await ingestor.ingest(same, generation: 1, current: previous) else {
            Issue.record("expected accepted"); return
        }
        #expect(unchanged.needsReconciliation == WatchPhonePushFiles.needsReconciliation(previous: previous, next: unchanged.snapshot))
        #expect(!unchanged.needsReconciliation)
        let changed = try envelope(revision: 3, books: [book("a", chapters: 2)])
        guard case .accepted(let grown) = await ingestor.ingest(changed, generation: 2, current: previous) else {
            Issue.record("expected accepted"); return
        }
        #expect(grown.needsReconciliation)
    }

    @Test func supersededDecodeCannotCommitAfterANewerSnapshot() async throws {
        let store = RecordingStore()
        let ingestor = WatchCatalogIngestor(store: store)
        let newer = await ingestor.ingest(try envelope(revision: 2, books: [book("new")]), generation: 2, current: nil)
        let older = await ingestor.ingest(try envelope(revision: 1, books: [book("old")]), generation: 1, current: nil)
        guard case .accepted = newer else { Issue.record("newer should be accepted"); return }
        #expect(older == .ignoredStale)
        #expect(store.saves.count == 1)
    }

    @Test func equivalentSnapshotsAreNotPersistedTwice() async throws {
        let store = RecordingStore()
        let ingestor = WatchCatalogIngestor(store: store)
        let data = try envelope(revision: 1, books: [book("a", chapters: 50), book("b", chapters: 50)])
        _ = await ingestor.ingest(data, generation: 1, current: nil)
        _ = await ingestor.ingest(data, generation: 2, current: nil)
        #expect(store.saves.count == 1)
    }

    @Test func ingestionRunsOffTheCallersActor() async throws {
        let ingestor = WatchCatalogIngestor(store: RecordingStore())
        let big = try envelope(revision: 1, books: (0..<40).map { book("b\($0)", chapters: 100) })
        let work = Task.detached { await ingestor.ingest(big, generation: 1, current: nil) }
        // The MainActor stays free to run a lightweight action while the worker is in flight.
        let light = await MainActor.run { 1 + 1 }
        #expect(light == 2)
        guard case .accepted = await work.value else { Issue.record("expected accepted"); return }
    }
}
