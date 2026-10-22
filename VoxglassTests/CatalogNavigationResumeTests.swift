import Testing
import Foundation
@testable import VoxglassCore

/// Find/Discover routing contract: an existing library book keeps its exact
/// ID, ownership state, resume position, and bookmarks; only a genuinely new
/// result becomes a pending preview.
@MainActor
@Suite(.serialized) struct CatalogNavigationResumeTests {
    private final class CountingClient: InternetArchiveCatalogClient, @unchecked Sendable {
        let metadata: InternetArchiveMetadata
        private let lock = NSLock()
        private var count = 0
        var metadataCalls: Int { lock.withLock { count } }
        init(metadata: InternetArchiveMetadata) { self.metadata = metadata }
        func searchLibriVox(query: String, rows: Int) async throws -> [InternetArchiveSearchResult] { [] }
        func searchCollection(identifier: String, rows: Int) async throws -> [InternetArchiveSearchResult] { [] }
        func searchAdvancedPage(query: String, rows: Int, page: Int) async throws -> InternetArchivePage {
            InternetArchivePage(results: [], numFound: 0, page: page)
        }
        func metadata(for identifier: String) async throws -> InternetArchiveMetadata {
            lock.withLock { count += 1 }
            return metadata
        }
    }

    private func metadataFixture() throws -> InternetArchiveMetadata {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/InternetArchive/metadata_librivox_item.json")
        return try JSONDecoder().decode(InternetArchiveMetadata.self, from: Data(contentsOf: url))
    }

    private func searchResult(_ metadata: InternetArchiveMetadata) -> InternetArchiveSearchResult {
        InternetArchiveSearchResult(
            identifier: metadata.identifier, title: "Book", creators: [], description: nil,
            collections: ["librivoxaudio"], downloads: nil, date: nil
        )
    }

    @Test func ownedBookRoutesToExistingIDResumesAndKeepsBookmarks() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "catalog-nav-\(UUID().uuidString)")
        let repository = LibraryRepository(database: database)
        let library = LibraryStore(repository: repository)
        let metadata = try metadataFixture()
        let owned = try await repository.importInternetArchiveItem(metadata, sourceKind: .librivox)
        await library.refresh()
        let client = CountingClient(metadata: metadata)

        let positions = SQLitePositionStore(database: database)
        let bookmarks = SQLiteBookmarkStore(database: database)
        let chapterTwo = owned.chapters[1]
        try await positions.save(PlaybackPosition(
            bookID: owned.book.id, chapterID: chapterTwo.id, position: 77, duration: chapterTwo.duration
        ))
        _ = try await bookmarks.add(Bookmark(bookID: owned.book.id, chapterID: chapterTwo.id, position: 12, note: "n"))

        let routed = try await CatalogResultImporter.resolveForNavigation(
            searchResult(metadata), into: library, using: client
        )

        #expect(routed?.book.id == owned.book.id)
        #expect(routed?.book.isPending == false)
        #expect(client.metadataCalls == 0)
        #expect(library.book(withID: owned.book.id)?.book.isPending == false)

        let defaults = UserDefaults(suiteName: "catalog-nav-\(UUID().uuidString)")!
        let engine = FakeAudioEngine()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            positionStore: positions,
            snapshotStore: LastPlaybackSnapshotStore(defaults: defaults),
            rateStore: PlaybackRateStore(defaults: defaults)
        )
        await coordinator.play(try #require(routed))

        #expect(coordinator.currentSession?.book.id == owned.book.id)
        #expect(coordinator.currentSession?.chapter.id == chapterTwo.id)
        #expect(abs((engine.loadCalls.last?.startTime ?? -1) - 77) <= 0.001)
        #expect(try await bookmarks.bookmarks(forBookID: owned.book.id).count == 1)
    }

    @Test func resolverMissImportsOncePendingWithNoInheritedPosition() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "catalog-nav-\(UUID().uuidString)")
        let library = LibraryStore(repository: LibraryRepository(database: database))
        let metadata = try metadataFixture()
        let client = CountingClient(metadata: metadata)

        let routed = try #require(try await CatalogResultImporter.resolveForNavigation(
            searchResult(metadata), into: library, using: client
        ))

        #expect(client.metadataCalls == 1)
        #expect(routed.book.isPending)
        #expect(library.book(withID: routed.book.id)?.book.isPending == true)
        let saved = try await SQLitePositionStore(database: database).latestPosition(forBookID: routed.book.id)
        #expect(saved == nil)
    }

    @Test func navigationEntryPointsShareTheResolver() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for path in [
            "Voxglass/Features/Player/CatalogBookDestinationView.swift",
            "Voxglass/Features/Search/SearchView.swift",
            "Voxglass/Features/Listen/ListenView.swift",
            "Voxglass/Features/Player/CatalogDiscoveryView.swift"
        ] {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            #expect(text.contains("resolveForNavigation(result, into: libraryStore)"))
            #expect(!text.contains("markBookPending"))
        }
        let page = try String(
            contentsOf: root.appendingPathComponent("Voxglass/Features/Player/BookPageView.swift"), encoding: .utf8)
        #expect(page.contains("bookpage.inMyBooks"))
        #expect(page.contains("bookpage.addToLibrary"))
    }
}
