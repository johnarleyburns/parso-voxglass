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

    private final class FakeLibriVox: LibriVoxRecordingIdentityClient, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var ids: [Int] = []
        var calls: Int { lock.withLock { count } }
        var recordingRequests: [String] { lock.withLock { ids.map(String.init) } }
        let recording: LibriVoxRecording
        init(listenURLs: [String]) {
            recording = LibriVoxRecording(bookURL: nil, sections: listenURLs.map {
                LibriVoxSection(sectionNumber: nil, listenURL: $0, fileName: nil, readers: [], urlIArchive: nil)
            })
        }
        func fetchRecording(bookID: Int) async throws -> LibriVoxRecording {
            lock.withLock { count += 1; ids.append(bookID) }
            return recording
        }
    }

    private final class PagedClient: InternetArchiveCatalogClient, @unchecked Sendable {
        let pages: [[InternetArchiveSearchResult]]
        init(pages: [[InternetArchiveSearchResult]]) { self.pages = pages }
        func searchLibriVox(query: String, rows: Int) async throws -> [InternetArchiveSearchResult] { [] }
        func searchCollection(identifier: String, rows: Int) async throws -> [InternetArchiveSearchResult] { [] }
        func searchAdvanced(query: String, rows: Int) async throws -> [InternetArchiveSearchResult] { [] }
        func searchAdvanced(query: String, rows: Int, sort: CatalogSort) async throws -> [InternetArchiveSearchResult] { [] }
        func searchAdvancedPage(query: String, rows: Int, page: Int) async throws -> InternetArchivePage {
            try await searchAdvancedPage(query: query, rows: rows, page: page, sort: .popularity)
        }
        func searchAdvancedPage(query: String, rows: Int, page: Int, sort: CatalogSort) async throws -> InternetArchivePage {
            let index = page - 1
            return InternetArchivePage(
                results: pages.indices.contains(index) ? pages[index] : [],
                numFound: pages.reduce(0) { $0 + $1.count }, page: page)
        }
        func metadata(for identifier: String) async throws -> InternetArchiveMetadata {
            throw URLError(.badServerResponse)
        }
    }

    private struct FailingPageClient: InternetArchiveCatalogClient {
        func searchLibriVox(query: String, rows: Int) async throws -> [InternetArchiveSearchResult] { throw URLError(.notConnectedToInternet) }
        func searchCollection(identifier: String, rows: Int) async throws -> [InternetArchiveSearchResult] { throw URLError(.notConnectedToInternet) }
        func searchAdvanced(query: String, rows: Int) async throws -> [InternetArchiveSearchResult] { throw URLError(.notConnectedToInternet) }
        func searchAdvanced(query: String, rows: Int, sort: CatalogSort) async throws -> [InternetArchiveSearchResult] { throw URLError(.notConnectedToInternet) }
        func searchAdvancedPage(query: String, rows: Int, page: Int) async throws -> InternetArchivePage { throw URLError(.notConnectedToInternet) }
        func searchAdvancedPage(query: String, rows: Int, page: Int, sort: CatalogSort) async throws -> InternetArchivePage { throw URLError(.notConnectedToInternet) }
        func metadata(for identifier: String) async throws -> InternetArchiveMetadata { throw URLError(.notConnectedToInternet) }
    }

    private let exactURLs = ["https://librivox.org/audio/0.mp3", "https://librivox.org/audio/1.mp3"]

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
        #expect(CatalogResultImporter.opensNowPlayingDirectly(try #require(routed)))

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
        #expect(!CatalogResultImporter.opensNowPlayingDirectly(routed))
        #expect(library.book(withID: routed.book.id)?.book.isPending == true)
        let saved = try await SQLitePositionStore(database: database).latestPosition(forBookID: routed.book.id)
        #expect(saved == nil)
    }

    // MARK: Legacy LibriVox alias resolution

    private let blackstone = "commentaries_blackstone_0810_librivox"

    private func blackstoneMetadata(callNumber: String?) -> InternetArchiveMetadata {
        InternetArchiveMetadata(
            metadata: InternetArchiveItemMetadata(
                identifier: blackstone,
                title: "Commentaries on the Laws of England (1765)",
                creators: ["William Blackstone"],
                mediatype: "audio",
                collections: ["librivoxaudio"],
                language: "eng",
                callNumber: callNumber
            ),
            files: [
                InternetArchiveFile(
                    name: "01 Chapter.mp3", source: "original", format: "VBR MP3",
                    title: "Chapter 1", length: "100", track: "1", size: "1000")
            ],
            server: "ia.example.org",
            dir: "/1/items/\(blackstone)"
        )
    }

    private func blackstoneResult() -> InternetArchiveSearchResult {
        InternetArchiveSearchResult(
            identifier: blackstone, title: "Commentaries on the Laws of England (1765)",
            creators: ["William Blackstone"], description: nil,
            collections: ["librivoxaudio"], downloads: nil, date: nil
        )
    }

    private struct Legacy {
        let bookID: UUID
        let chapterTwo: UUID
    }

    /// A pre-identity-era owned book: non-Archive URLs, LibriVox alias only,
    /// saved position in chapter two, one bookmark.
    private func seedLegacy(_ database: AppDatabase, alias: String? = "1735", title: String = "Legacy") async throws -> Legacy {
        try await database.prepare()
        let sourceID = UUID(), bookID = UUID(), c1 = UUID(), c2 = UUID()
        let now = Date().timeIntervalSince1970
        try await database.execute(
            "INSERT INTO sources (id, kind, title, url, created_at) VALUES (?, 'librivox', 'S', 'https://librivox.org/old', ?)",
            [.string(sourceID.uuidString), .double(now)])
        try await database.execute("""
        INSERT INTO books (id, title, authors_json, source_id, created_at, updated_at, is_favorite)
        VALUES (?, ?, '[]', ?, ?, ?, 0)
        """, [.string(bookID.uuidString), .string(title), .string(sourceID.uuidString), .double(now), .double(now)])
        for (index, id) in [c1, c2].enumerated() {
            try await database.execute("""
            INSERT INTO chapters (id, book_id, title, sort_key, chapter_index, duration_seconds, remote_url)
            VALUES (?, ?, ?, ?, ?, 600, ?)
            """, [.string(id.uuidString), .string(bookID.uuidString), .string("C\(index)"),
                  .string("C\(index)"), .int(Int64(index)), .string("https://librivox.org/audio/\(index).mp3")])
        }
        try await database.execute("""
        INSERT INTO playback_positions (id, book_id, chapter_id, position_seconds, duration_seconds, updated_at, is_finished)
        VALUES (?, ?, ?, 77, 600, ?, 0)
        """, [.string(UUID().uuidString), .string(bookID.uuidString), .string(c2.uuidString), .double(now)])
        try await database.execute(
            "INSERT INTO bookmarks (id, book_id, chapter_id, position_seconds, note, created_at) VALUES (?, ?, ?, 12, NULL, ?)",
            [.string(UUID().uuidString), .string(bookID.uuidString), .string(c2.uuidString), .double(now)])
        if let alias {
            try await database.execute(
                "INSERT INTO book_recording_identities (book_id, scheme, value, created_at) VALUES (?, 'librivox', ?, ?)",
                [.string(bookID.uuidString), .string(alias), .double(now)])
        }
        return Legacy(bookID: bookID, chapterTwo: c2)
    }

    private func count(_ database: AppDatabase, _ table: String) async throws -> Int {
        Int(try await database.query("SELECT COUNT(*) AS n FROM \(table)").first?.int("n") ?? -1)
    }

    @Test func legacyLibriVoxAliasResolvesOriginalBookAndResumes() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "catalog-nav-\(UUID().uuidString)")
        let repository = LibraryRepository(database: database)
        let library = LibraryStore(repository: repository)
        let legacy = try await seedLegacy(database)
        await library.refresh()
        let client = CountingClient(metadata: blackstoneMetadata(callNumber: "1735"))
        let before = (try await count(database, "books"), try await count(database, "sources"),
                      try await count(database, "chapters"))

        let routed = try #require(try await CatalogResultImporter.resolveForNavigation(
            blackstoneResult(), into: library, using: client))

        #expect(routed.book.id == legacy.bookID)
        #expect(routed.book.isPending == false)
        #expect(client.metadataCalls == 1)
        #expect(library.book(withID: legacy.bookID)?.book.isPending == false)
        #expect(try await count(database, "books") == before.0)
        #expect(try await count(database, "sources") == before.1)
        #expect(try await count(database, "chapters") == before.2)
        let bookmarks = SQLiteBookmarkStore(database: database)
        #expect(try await bookmarks.bookmarks(forBookID: legacy.bookID).count == 1)

        let defaults = UserDefaults(suiteName: "catalog-nav-\(UUID().uuidString)")!
        let engine = FakeAudioEngine()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            positionStore: SQLitePositionStore(database: database),
            snapshotStore: LastPlaybackSnapshotStore(defaults: defaults),
            rateStore: PlaybackRateStore(defaults: defaults))
        await coordinator.play(routed)
        #expect(coordinator.currentSession?.chapter.id == legacy.chapterTwo)
        #expect(abs((engine.loadCalls.last?.startTime ?? -1) - 77) <= 0.001)
    }

    @Test func exactInternetArchiveIdentityStaysZeroMetadataFastPath() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "catalog-nav-\(UUID().uuidString)")
        let repository = LibraryRepository(database: database)
        let library = LibraryStore(repository: repository)
        let metadata = blackstoneMetadata(callNumber: "1735")
        let owned = try await repository.importInternetArchiveItem(metadata, sourceKind: .librivox)
        await library.refresh()
        let client = CountingClient(metadata: metadata)
        let routed = try await CatalogResultImporter.resolveForNavigation(
            blackstoneResult(), into: library, using: client)
        #expect(routed?.book.id == owned.book.id)
        #expect(client.metadataCalls == 0)
    }

    @Test func unmatchedAliasImportsExactlyOnePendingPreview() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "catalog-nav-\(UUID().uuidString)")
        let library = LibraryStore(repository: LibraryRepository(database: database))
        let legacy = try await seedLegacy(database, alias: "999")
        await library.refresh()
        let client = CountingClient(metadata: blackstoneMetadata(callNumber: "1735"))
        let routed = try #require(try await CatalogResultImporter.resolveForNavigation(
            blackstoneResult(), into: library, using: client,
            legacyIdentityClient: FakeLibriVox(listenURLs: ["https://example.org/other.mp3"])))
        #expect(routed.book.id != legacy.bookID)
        #expect(routed.book.isPending)
        #expect(client.metadataCalls == 1)
        #expect(try await count(database, "books") == 2)
    }

    @Test func invalidOrMissingCallNumberNeverMatchesByTitleAndImportsPreview() async throws {
        for callNumber in [nil, "", "abc", "17.35", "-1735"] {
            let database = AppDatabase.makeTemporaryDatabase(named: "catalog-nav-\(UUID().uuidString)")
            let library = LibraryStore(repository: LibraryRepository(database: database))
            // Same title as the result, to prove title is never used.
            let legacy = try await seedLegacy(database, title: "Commentaries on the Laws of England (1765)")
            await library.refresh()
            let client = CountingClient(metadata: blackstoneMetadata(callNumber: callNumber))
            let routed = try #require(try await CatalogResultImporter.resolveForNavigation(
                blackstoneResult(), into: library, using: client))
            #expect(routed.book.id != legacy.bookID)
            #expect(routed.book.isPending)
            #expect(try await count(database, "books") == 2)
        }
    }

    @Test func ambiguousAliasThrowsWithoutImportingOrChoosing() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "catalog-nav-\(UUID().uuidString)")
        let library = LibraryStore(repository: LibraryRepository(database: database))
        let first = try await seedLegacy(database, alias: nil)
        let second = try await seedLegacy(database, alias: nil)
        // Simulate a corrupt store that lost UNIQUE(scheme, value).
        try await database.execute("DROP TABLE book_recording_identities")
        try await database.execute("""
        CREATE TABLE book_recording_identities (
            book_id TEXT NOT NULL, scheme TEXT NOT NULL, value TEXT NOT NULL, created_at REAL NOT NULL)
        """)
        for id in [first.bookID, second.bookID] {
            try await database.execute(
                "INSERT INTO book_recording_identities VALUES (?, 'librivox', '1735', 0)",
                [.string(id.uuidString)])
        }
        await library.refresh()
        let client = CountingClient(metadata: blackstoneMetadata(callNumber: "1735"))
        await #expect(throws: LibraryRepository.RecordingIdentityError.self) {
            _ = try await CatalogResultImporter.resolveForNavigation(
                blackstoneResult(), into: library, using: client)
        }
        #expect(try await count(database, "books") == 2)
        #expect(try await count(database, "bookmarks") == 2)
    }

    @Test func aliaslessLegacyRecordReconcilesToOriginalBookThenUsesAlias() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "catalog-nav-\(UUID().uuidString)")
        let library = LibraryStore(repository: LibraryRepository(database: database))
        let legacy = try await seedLegacy(database, alias: nil)
        await library.refresh()
        let client = CountingClient(metadata: blackstoneMetadata(callNumber: "1735"))
        let librivox = FakeLibriVox(listenURLs: exactURLs)
        let before = (try await count(database, "books"), try await count(database, "sources"),
                      try await count(database, "chapters"))

        let routed = try #require(try await CatalogResultImporter.resolveForNavigation(
            blackstoneResult(), into: library, using: client, legacyIdentityClient: librivox))

        #expect(routed.book.id == legacy.bookID)
        #expect(routed.book.isPending == false)
        #expect(client.metadataCalls == 1)
        #expect(librivox.calls == 1)
        #expect(try await count(database, "books") == before.0)
        #expect(try await count(database, "sources") == before.1)
        #expect(try await count(database, "chapters") == before.2)
        let alias = try await database.query(
            "SELECT book_id FROM book_recording_identities WHERE scheme = 'librivox' AND value = '1735'")
        #expect(alias.first?.string("book_id") == legacy.bookID.uuidString)
        #expect(try await SQLiteBookmarkStore(database: database).bookmarks(forBookID: legacy.bookID).count == 1)

        let defaults = UserDefaults(suiteName: "catalog-nav-\(UUID().uuidString)")!
        let engine = FakeAudioEngine()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            positionStore: SQLitePositionStore(database: database),
            snapshotStore: LastPlaybackSnapshotStore(defaults: defaults),
            rateStore: PlaybackRateStore(defaults: defaults))
        await coordinator.play(routed)
        #expect(coordinator.currentSession?.chapter.id == legacy.chapterTwo)
        #expect(abs((engine.loadCalls.last?.startTime ?? -1) - 77) <= 0.001)

        // Second route: IA lookup still misses, alias now resolves without LibriVox.
        let again = try #require(try await CatalogResultImporter.resolveForNavigation(
            blackstoneResult(), into: library, using: client, legacyIdentityClient: librivox))
        #expect(again.book.id == legacy.bookID)
        #expect(librivox.calls == 1)
        #expect(client.metadataCalls == 2)
    }

    @Test func sameTitleWithoutExactProofCreatesOnePendingPreview() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "catalog-nav-\(UUID().uuidString)")
        let library = LibraryStore(repository: LibraryRepository(database: database))
        let legacy = try await seedLegacy(
            database, alias: nil, title: "Commentaries on the Laws of England (1765)")
        await library.refresh()
        let client = CountingClient(metadata: blackstoneMetadata(callNumber: "1735"))
        let routed = try #require(try await CatalogResultImporter.resolveForNavigation(
            blackstoneResult(), into: library, using: client,
            legacyIdentityClient: FakeLibriVox(listenURLs: ["https://example.org/x.mp3"])))
        #expect(routed.book.id != legacy.bookID)
        #expect(routed.book.isPending)
        #expect(try await count(database, "books") == 2)
    }

    @Test func ambiguousLegacyProofShowsErrorAndImportsNoPreview() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "catalog-nav-\(UUID().uuidString)")
        let library = LibraryStore(repository: LibraryRepository(database: database))
        _ = try await seedLegacy(database, alias: nil)
        _ = try await seedLegacy(database, alias: nil)
        await library.refresh()
        let client = CountingClient(metadata: blackstoneMetadata(callNumber: "1735"))
        let catalog = CatalogStore(client: client, legacyIdentityClient: FakeLibriVox(listenURLs: exactURLs))
        let routed = await catalog.resolveForNavigation(blackstoneResult(), into: library)
        #expect(routed == nil)
        #expect(catalog.catalogError?.isEmpty == false)
        #expect(try await count(database, "books") == 2)
        #expect(try await count(database, "book_recording_identities") == 0)
    }

    @Test func findResultCallNumberRoutesToOwnedBookWithoutMetadata() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "catalog-nav-\(UUID().uuidString)")
        let library = LibraryStore(repository: LibraryRepository(database: database))
        let legacy = try await seedLegacy(database)
        await library.refresh()
        let client = CountingClient(metadata: blackstoneMetadata(callNumber: "1735"))
        let before = (try await count(database, "books"), try await count(database, "sources"),
                      try await count(database, "chapters"))

        let routed = try #require(try await CatalogResultImporter.resolveForNavigation(
            callResult("1735"), into: library, using: client))

        #expect(routed.book.id == legacy.bookID)
        #expect(routed.book.isPending == false)
        #expect(client.metadataCalls == 0)
        #expect(try await count(database, "books") == before.0)
        #expect(try await count(database, "sources") == before.1)
        #expect(try await count(database, "chapters") == before.2)
        #expect(try await SQLiteBookmarkStore(database: database).bookmarks(forBookID: legacy.bookID).count == 1)
        let position = try await SQLitePositionStore(database: database)
            .position(for: legacy.bookID, chapterID: legacy.chapterTwo)
        #expect(abs((position?.position ?? -1) - 77) <= 0.001)
    }

    @Test func findResultCallNumberReconcilesAliaslessLegacyOnce() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "catalog-nav-\(UUID().uuidString)")
        let library = LibraryStore(repository: LibraryRepository(database: database))
        let legacy = try await seedLegacy(database, alias: nil)
        await library.refresh()
        let client = CountingClient(metadata: blackstoneMetadata(callNumber: "1735"))
        let routed = try #require(try await CatalogResultImporter.resolveForNavigation(
            callResult("1735"), into: library, using: client,
            legacyIdentityClient: FakeLibriVox(listenURLs: exactURLs)))
        #expect(routed.book.id == legacy.bookID)
        #expect(routed.book.isPending == false)
        #expect(client.metadataCalls == 0)
        #expect(try await count(database, "books") == 1)
        #expect(try await count(database, "book_recording_identities") == 1)
    }

    @Test func findResultMalformedOrUnmatchedCallNumberImportsOnePendingPreview() async throws {
        for callNumber in [nil, "", "abc", "9999"] {
            let database = AppDatabase.makeTemporaryDatabase(named: "catalog-nav-\(UUID().uuidString)")
            let library = LibraryStore(repository: LibraryRepository(database: database))
            let legacy = try await seedLegacy(database, title: "Commentaries on the Laws of England (1765)")
            await library.refresh()
            let client = CountingClient(metadata: blackstoneMetadata(callNumber: nil))
            let routed = try #require(try await CatalogResultImporter.resolveForNavigation(
                callResult(callNumber, id: blackstoneResult().identifier), into: library, using: client,
                legacyIdentityClient: FakeLibriVox(listenURLs: ["https://example.org/x.mp3"])))
            #expect(routed.book.id != legacy.bookID)
            #expect(routed.book.isPending)
            #expect(try await count(database, "books") == 2)
        }
    }

    @Test func findResultAmbiguousLegacyProofImportsNoPreview() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "catalog-nav-\(UUID().uuidString)")
        let library = LibraryStore(repository: LibraryRepository(database: database))
        _ = try await seedLegacy(database, alias: nil)
        _ = try await seedLegacy(database, alias: nil)
        await library.refresh()
        let client = CountingClient(metadata: blackstoneMetadata(callNumber: nil))
        let catalog = CatalogStore(client: client, legacyIdentityClient: FakeLibriVox(listenURLs: exactURLs))
        let routed = await catalog.resolveForNavigation(callResult("1735"), into: library)
        #expect(routed == nil)
        #expect(catalog.catalogError?.isEmpty == false)
        #expect(client.metadataCalls == 0)
        #expect(try await count(database, "books") == 2)
    }

    // MARK: Find ownership preflight

    private func callResult(_ callNumber: String?, id: String = "other_item_librivox") -> InternetArchiveSearchResult {
        InternetArchiveSearchResult(
            identifier: id, title: "Commentaries", creators: [], description: nil,
            collections: ["librivoxaudio"], downloads: nil, date: nil, libriVoxRecordingID: callNumber)
    }

    @Test func preflightBadgesExactLegacyBookOncePerNormalizedID() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "catalog-nav-\(UUID().uuidString)")
        let library = LibraryStore(repository: LibraryRepository(database: database))
        let legacy = try await seedLegacy(database, alias: nil)
        await library.refresh()
        let fake = FakeLibriVox(listenURLs: exactURLs)
        let catalog = CatalogStore(
            client: CountingClient(metadata: blackstoneMetadata(callNumber: "1735")), legacyIdentityClient: fake)
        let rows = [callResult("1735", id: "a"), callResult("01735", id: "b"), callResult("1735", id: "c")]
        #expect(rows.allSatisfy { library.cachedOwnedBook(for: $0) == nil })
        await catalog.reconcileLegacyOwnership(results: rows, into: library)
        #expect(fake.calls == 1)
        #expect(rows.allSatisfy { library.cachedOwnedBook(for: $0)?.book.id == legacy.bookID })
        #expect(!catalog.isSearching)
    }

    @Test func preflightLeavesInvalidUnmatchedAndAmbiguousUnbadged() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "catalog-nav-\(UUID().uuidString)")
        let library = LibraryStore(repository: LibraryRepository(database: database))
        _ = try await seedLegacy(database, alias: nil)
        await library.refresh()
        let unmatched = CatalogStore(legacyIdentityClient: FakeLibriVox(listenURLs: ["https://example.org/x.mp3"]))
        let rows = [callResult(nil), callResult("abc"), callResult("1735")]
        await unmatched.reconcileLegacyOwnership(results: rows, into: library)
        #expect(rows.allSatisfy { library.cachedOwnedBook(for: $0) == nil })

        _ = try await seedLegacy(database, alias: nil)
        await library.refresh()
        let ambiguous = CatalogStore(legacyIdentityClient: FakeLibriVox(listenURLs: exactURLs))
        await ambiguous.reconcileLegacyOwnership(results: [callResult("1735")], into: library)
        #expect(library.cachedOwnedBook(for: callResult("1735")) == nil)
        #expect(try await count(database, "book_recording_identities") == 0)
        #expect(try await count(database, "books") == 2)
    }

    @Test func cancelledPreflightAddsNoAlias() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "catalog-nav-\(UUID().uuidString)")
        let library = LibraryStore(repository: LibraryRepository(database: database))
        _ = try await seedLegacy(database, alias: nil)
        await library.refresh()
        let fake = FakeLibriVox(listenURLs: exactURLs)
        let catalog = CatalogStore(legacyIdentityClient: fake)
        let task = Task { @MainActor in
            await catalog.reconcileLegacyOwnership(results: [callResult("1735")], into: library)
        }
        task.cancel()
        await task.value
        #expect(fake.calls == 0)
        #expect(try await count(database, "book_recording_identities") == 0)
        #expect(library.cachedOwnedBook(for: callResult("1735")) == nil)
    }

    @Test func bootstrapRepairThenRefreshPublishesBadgeIndex() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "catalog-nav-\(UUID().uuidString)")
        let repository = LibraryRepository(database: database)
        let library = LibraryStore(repository: repository)
        let owned = try await repository.importInternetArchiveItem(
            blackstoneMetadata(callNumber: nil), sourceKind: .librivox)
        try await database.execute("DELETE FROM book_recording_identities")
        await library.refresh()
        let row = callResult(nil, id: blackstone)
        let repaired = await repository.backfillRecordingIdentitiesIfNeeded()
        #expect(repaired > 0)
        await library.refresh()
        #expect(library.cachedOwnedBook(for: row)?.book.id == owned.book.id)
    }

    /// Mirrors the Find hosts' `.onChange(of: catalogStore.results)` observer.
    private func preflightPublished(_ catalog: CatalogStore, _ library: LibraryStore) async {
        guard !catalog.results.isEmpty, catalog.catalogError == nil else { return }
        await catalog.reconcileLegacyOwnership(results: catalog.results, into: library)
    }

    private func pagedFixture(pages: [[InternetArchiveSearchResult]], listenURLs: [String]? = nil) async throws
        -> (CatalogStore, LibraryStore, FakeLibriVox) {
        let database = AppDatabase.makeTemporaryDatabase(named: "catalog-nav-\(UUID().uuidString)")
        let library = LibraryStore(repository: LibraryRepository(database: database))
        _ = try await seedLegacy(database, alias: nil)
        await library.refresh()
        let fake = FakeLibriVox(listenURLs: listenURLs ?? exactURLs)
        return (CatalogStore(client: PagedClient(pages: pages), legacyIdentityClient: fake), library, fake)
    }

    @Test func preflightAttemptsAnAliasOnlyOnceAcrossTwoPages() async throws {
        let (catalog, library, fake) = try await pagedFixture(pages: [
            [callResult("1735", id: "a")],
            [callResult("1735", id: "b"), callResult("1736", id: "c")]
        ])
        await catalog.searchAdvanced("q")
        await preflightPublished(catalog, library)
        await catalog.loadMore()
        #expect(catalog.results.count == 3)
        await preflightPublished(catalog, library)
        #expect(fake.recordingRequests == ["1735", "1736"])
    }

    @Test func collectionAndPaginatedRowsBadgeWithoutTap() async throws {
        let (catalog, library, _) = try await pagedFixture(pages: [
            [callResult("1735", id: "a")]
        ])
        let row = callResult("1735", id: "a")
        #expect(library.cachedOwnedBook(for: row) == nil)
        await catalog.searchAdvanced("collection:x", collectionID: "unknown-collection")
        await preflightPublished(catalog, library)
        #expect(library.cachedOwnedBook(for: row) != nil)

        let (pagedCatalog, pagedLibrary, _) = try await pagedFixture(pages: [
            [callResult(nil, id: "first")],
            [callResult("1735", id: "a")]
        ])
        await pagedCatalog.searchAdvanced("q")
        await pagedCatalog.loadMore()
        await preflightPublished(pagedCatalog, pagedLibrary)
        #expect(pagedCatalog.results.map(\.identifier) == ["first", "a"])
        #expect(pagedLibrary.cachedOwnedBook(for: row) != nil)
    }

    @Test func newRootQueryResetsAttemptsButLoadMoreDoesNot() async throws {
        let (catalog, library, fake) = try await pagedFixture(pages: [
            [callResult("1736", id: "a")],
            [callResult("1736", id: "b")]
        ], listenURLs: ["https://example.org/nomatch.mp3"])
        // Non-matching proof leaves the row unbadged, so only the attempt set prevents a retry.
        await catalog.searchAdvanced("q")
        await catalog.reconcileLegacyOwnership(results: catalog.results, into: library)
        await catalog.loadMore()
        await catalog.reconcileLegacyOwnership(results: catalog.results, into: library)
        #expect(fake.recordingRequests == ["1736"])
        await catalog.searchAdvanced("q2")
        await catalog.reconcileLegacyOwnership(results: catalog.results, into: library)
        #expect(fake.recordingRequests == ["1736", "1736"])
        catalog.resetResultsForNavigation()
        await catalog.reconcileLegacyOwnership(results: [callResult("1736", id: "z")], into: library)
        #expect(fake.recordingRequests.count == 3)
    }

    @Test func emptyAndErrorResultsMakeNoIdentityRequests() async throws {
        let (empty, library, fake) = try await pagedFixture(pages: [[]])
        await empty.searchAdvanced("q")
        await preflightPublished(empty, library)
        #expect(fake.calls == 0)

        let failing = CatalogStore(client: FailingPageClient(), legacyIdentityClient: fake)
        await failing.searchAdvanced("q")
        #expect(failing.catalogError != nil)
        await preflightPublished(failing, library)
        #expect(fake.calls == 0)
    }

    @Test func findHostsObserveResultsWithoutBespokePreflight() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for path in ["Voxglass/Features/Discover/DiscoverView.swift", "Voxglass/Features/Search/SearchView.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            #expect(text.contains("startOwnershipPreflight(for: results)"))
            #expect(text.contains(".onChange(of: catalogStore.results)"))
            #expect(!text.contains("startOwnershipPreflight()"))
        }
        let store = try String(
            contentsOf: root.appendingPathComponent("Voxglass/Core/Catalog/CatalogStore.swift"), encoding: .utf8)
        let loadMore = try #require(store.range(of: "public func loadMore() async"))
        #expect(!store.suffix(from: loadMore.lowerBound).prefix(900).contains("reconcileLegacyOwnership"))
        let browse = try String(
            contentsOf: root.appendingPathComponent("Voxglass/Features/Discover/DiscoverView.swift"), encoding: .utf8)
        let collectionLoad = try #require(browse.range(of: "private func loadSelectedCollection"))
        let body = browse[collectionLoad.lowerBound...].prefix(400)
        #expect(!body.contains("Preflight"))
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
