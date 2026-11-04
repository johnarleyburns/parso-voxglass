import CloudKit
import Foundation
import Testing
@testable import VoxglassCore

@MainActor
@Suite struct CloudSyncRecoveryTests {
    private func seed(_ db: AppDatabase, books: Int = 1) async throws -> [(UUID, UUID)] {
        let source = UUID()
        try await db.execute("INSERT INTO sources (id, kind, title, url, created_at) VALUES (?, ?, ?, ?, ?)",
                             [.string(source.uuidString), .string(SourceKind.librivox.rawValue), .string("Source"), .string("https://archive.org/details/test_sync"), .double(0)])
        var ids: [(UUID, UUID)] = []
        for i in 0..<books {
            let book = UUID(), chapter = UUID()
            try await db.execute("INSERT INTO books (id, title, authors_json, source_id, created_at, updated_at, content_key) VALUES (?, ?, ?, ?, ?, ?, ?)",
                                 [.string(book.uuidString), .string("Book \(i)"), .string("[]"), .string(source.uuidString), .double(0), .double(0), .string("ia:test_sync-\(i)")])
            try await db.execute("INSERT INTO chapters (id, book_id, title, sort_key, chapter_index, duration_seconds, remote_url) VALUES (?, ?, ?, ?, ?, ?, ?)",
                                 [.string(chapter.uuidString), .string(book.uuidString), .string("Chapter"), .string("1"), .int(0), .double(100), .string("https://archive.org/download/test_sync/chapter.mp3")])
            ids.append((book, chapter))
        }
        return ids
    }

    private func engine(_ db: AppDatabase) async -> CloudKitSyncEngine {
        let defaults = UserDefaults(suiteName: "cloud-recovery-\(UUID())")!
        defaults.set(true, forKey: AppPreferencesStore.Keys.iCloudSyncEnabled)
        let engine = CloudKitSyncEngine(database: db, defaults: defaults)
        engine.testForceAccountAvailable = true
        await engine.refreshAccountStatus()
        return engine
    }

    @Test func repeatedSourceRefreshPreservesLocalBindingsAndChildren() async throws {
        let db = AppDatabase.makeTemporaryDatabase()
        try await db.prepare()
        let (localBook, localChapter) = try await seed(db)[0]
        let stableSource = CloudKitRecordMapper.stableUUID(from: "test_sync")
        try await db.execute("INSERT INTO sources (id, kind, title, url, created_at) VALUES (?, ?, ?, ?, ?)",
                             [.string(stableSource.uuidString), .string(SourceKind.librivox.rawValue), .string("Old"), .string("https://archive.org/details/test_sync"), .double(42)])
        try await db.execute("UPDATE books SET source_id=? WHERE id=?", [.string(stableSource.uuidString), .string(localBook.uuidString)])
        try await db.execute("UPDATE chapters SET local_url=?, local_bookmark=?, start_time_seconds=12 WHERE id=?",
                             [.string("file:///tmp/a.mp3"), ModelMapping.databaseValue(Data([1, 2, 3])), .string(localChapter.uuidString)])
        try await db.execute("INSERT INTO playback_positions (book_id, chapter_id, position_seconds, updated_at) VALUES (?, ?, 7, 0)",
                             [.string(localBook.uuidString), .string(localChapter.uuidString)])

        let sync = CloudKitSyncEngine(database: db)
        let source = Source(kind: .librivox, title: "Source", url: URL(string: "https://archive.org/details/test_sync"))
        let book = Book(title: "Book 0", authors: [], sourceID: source.id)
        let chapter = Chapter(bookID: book.id, title: "Chapter", index: 0, duration: 100,
                              remoteURL: URL(string: "https://archive.org/download/test_sync/chapter.mp3"))
        let sourceRecord = CloudKitRecordMapper.sourceRecord(from: source, sourceKey: "test_sync")
        let bookRecord = CloudKitRecordMapper.bookRecord(from: book, chapters: [chapter], contentKey: "ia:test_sync-0", sourceKey: "test_sync")
        for _ in 0..<3 { try await sync.applyFetchedLibraryChanges(records: [sourceRecord, bookRecord]) }
        try await sync.applyFetchedLibraryChanges(records: [sourceRecord])
        try await CloudKitSyncEngine(database: db).applyFetchedLibraryChanges(records: [sourceRecord, bookRecord])

        let chapters = try await db.query("SELECT id, local_url, local_bookmark FROM chapters")
        #expect(chapters.count == 1)
        #expect(chapters[0].string("id") == localChapter.uuidString)
        #expect(chapters[0].string("local_url") == "file:///tmp/a.mp3")
        #expect(ModelMapping.data(chapters[0], "local_bookmark") == Data([1, 2, 3]))
        #expect(try await db.query("SELECT id FROM books").count == 1)
        #expect(try await db.query("SELECT id FROM playback_positions WHERE book_id=?", [.string(localBook.uuidString)]).count == 1)
        let sources = try await db.query("SELECT title, created_at FROM sources WHERE id=?", [.string(stableSource.uuidString)])
        #expect(sources.first?.string("title") == "Source")
        #expect(sources.first?.double("created_at") == 42)
    }

    @Test func macLibraryPullImportsBooksSourcesChaptersAndPlaybackWithoutNarration() async throws {
        let db = AppDatabase.makeTemporaryDatabase()
        try await db.prepare()
        let sync = CloudKitSyncEngine(database: db)
        let sourceKey = "possessed_1404_librivox"
        let key = "ia:possessed_1404_librivox"
        let source = Source(kind: .librivox, title: "The Possessed", url: URL(string: "https://archive.org/details/possessed_1404_librivox"))
        let book = Book(title: "The Possessed", authors: ["Fyodor Dostoyevsky"], sourceID: source.id)
        let chapter = Chapter(bookID: book.id, title: "The Fête", index: 56, duration: 1232,
                              remoteURL: URL(string: "https://archive.org/download/possessed_1404_librivox/possessed_57_dostoyevsky_128kb.mp3"))
        let position = PlaybackPosition(bookID: book.id, chapterID: chapter.id, position: 176)
        let records = [
            CloudKitRecordMapper.positionRecord(from: position, bookContentKey: key),
            CloudKitRecordMapper.bookRecord(from: book, chapters: [chapter], contentKey: key, sourceKey: sourceKey),
            CloudKitRecordMapper.sourceRecord(from: source, sourceKey: sourceKey)
        ]
        try await sync.applyFetchedLibraryChanges(records: records, tokenData: Data([1]))
        // Repeated pulls must preserve the same library identities and resume row.
        try await sync.applyFetchedLibraryChanges(records: records, tokenData: Data([2]))
        let library = try await LibraryRepository(database: db).fetchBooks(filteredBy: .all)
        let imported = try #require(library.first)
        #expect(library.count == 1)
        #expect(imported.book.title == book.title)
        #expect(imported.chapters.count == 1)
        #expect(imported.chapters[0].remoteURL == chapter.remoteURL)
        #expect(imported.book.sourceID == CloudKitRecordMapper.stableUUID(from: sourceKey))
        let sourceRows = try await db.query("SELECT title, url FROM sources WHERE id=?", [.string(imported.book.sourceID.uuidString)])
        #expect(sourceRows.first?.string("url") == source.url?.absoluteString)
        #expect(sourceRows.first?.string("title") == source.title)
        let saved = try await SQLitePositionStore(database: db).position(for: imported.book.id, chapterID: chapter.id)
        #expect(saved?.position == 176)
        #expect(sync.lastFetchedCount == 3)
        #expect(try await CloudSyncStateStore(database: db).pendingCount() == 0)
    }

    @Test func macPullMatchesExistingLocalChapterInsteadOfUsingPhoneUUID() async throws {
        let db = AppDatabase.makeTemporaryDatabase()
        let (localBook, localChapter) = try await seed(db)[0]
        let sync = CloudKitSyncEngine(database: db)
        let source = Source(kind: .librivox, title: "Source", url: URL(string: "https://archive.org/details/test_sync"))
        let phoneBook = Book(title: "Updated cloud title", authors: [], sourceID: source.id)
        let phoneChapter = Chapter(bookID: phoneBook.id, title: "Chapter", index: 0, duration: 100,
                                   remoteURL: URL(string: "https://archive.org/download/test_sync/chapter.mp3"))
        let position = PlaybackPosition(bookID: phoneBook.id, chapterID: phoneChapter.id, position: 47)
        let bookmark = Bookmark(id: UUID(), bookID: phoneBook.id, chapterID: phoneChapter.id, position: 43)
        let key = "ia:test_sync-0"
        let records = [
            CloudKitRecordMapper.sourceRecord(from: source, sourceKey: "test_sync"),
            CloudKitRecordMapper.bookRecord(from: phoneBook, chapters: [phoneChapter], contentKey: key, sourceKey: "test_sync"),
            CloudKitRecordMapper.positionRecord(from: position, bookContentKey: key),
            try #require(CloudKitRecordMapper.bookmarkRecord(from: bookmark, bookContentKey: key))
        ]
        try await sync.applyFetchedLibraryChanges(records: records)
        let saved = try await SQLitePositionStore(database: db).position(for: localBook, chapterID: localChapter)
        #expect(saved?.position == 47)
        #expect(sync.lastFetchedPlaybackPosition?.chapterID == localChapter)
        let bookmarks = try await db.query("SELECT chapter_id FROM bookmarks WHERE book_id=?", [.string(localBook.uuidString)])
        #expect(bookmarks.first?.string("chapter_id") == localChapter.uuidString)
        #expect(try await db.query("SELECT id FROM books").count == 1)
        #expect(try await db.query("SELECT id FROM chapters").count == 1)
        let bookRecord = records[1]
        try await sync.applyFetchedLibraryChanges(records: [], deletions: [bookRecord.recordID])
        #expect(try await db.query("SELECT id FROM books").isEmpty)
    }

    @Test func macPullAddsNewCloudChapterAndPreservesExistingDownload() async throws {
        let db = AppDatabase.makeTemporaryDatabase()
        let (localBook, localChapter) = try await seed(db)[0]
        let localURL = "file:///tmp/kept-offline.mp3"
        try await db.execute("UPDATE chapters SET local_url=? WHERE id=?", [.string(localURL), .string(localChapter.uuidString)])
        let sync = CloudKitSyncEngine(database: db)
        let source = Source(kind: .librivox, title: "Source", url: URL(string: "https://archive.org/details/test_sync"))
        let book = Book(title: "Book", authors: [], sourceID: source.id)
        let first = Chapter(bookID: book.id, title: "Chapter", index: 0, duration: 100,
                            remoteURL: URL(string: "https://archive.org/download/test_sync/chapter.mp3"))
        let second = Chapter(bookID: book.id, title: "New chapter", index: 1, duration: 100,
                             remoteURL: URL(string: "https://archive.org/download/test_sync/second.mp3"))
        let key = "ia:test_sync-0"
        try await sync.applyFetchedLibraryChanges(records: [
            CloudKitRecordMapper.sourceRecord(from: source, sourceKey: "test_sync"),
            CloudKitRecordMapper.bookRecord(from: book, chapters: [first, second], contentKey: key, sourceKey: "test_sync"),
            CloudKitRecordMapper.positionRecord(from: PlaybackPosition(bookID: book.id, chapterID: second.id, position: 20), bookContentKey: key)
        ])
        let chapters = try await db.query("SELECT id, local_url FROM chapters WHERE book_id=? ORDER BY chapter_index", [.string(localBook.uuidString)])
        #expect(chapters.count == 2)
        #expect(chapters[0].string("id") == localChapter.uuidString)
        #expect(chapters[0].string("local_url") == localURL)
        #expect(chapters[1].string("id") == second.id.uuidString)
        #expect(try await SQLitePositionStore(database: db).position(for: localBook, chapterID: second.id)?.position == 20)
    }

    @Test func missingChapterDoesNotBlockLibraryAndRetriesAfterRestart() async throws {
        let db = AppDatabase.makeTemporaryDatabase()
        let (localBook, _) = try await seed(db)[0]
        let key = "ia:test_sync-0"
        let source = Source(kind: .librivox, title: "Source", url: URL(string: "https://archive.org/details/test_sync"))
        let book = Book(title: "Book", authors: [], sourceID: source.id)
        let chapter = Chapter(bookID: book.id, title: "Later chapter", index: 1,
                              remoteURL: URL(string: "https://archive.org/download/test_sync/later.mp3"))
        let position = CloudKitRecordMapper.positionRecord(
            from: PlaybackPosition(bookID: book.id, chapterID: chapter.id, position: 42), bookContentKey: key)
        let bookmark = try #require(CloudKitRecordMapper.bookmarkRecord(
            from: Bookmark(id: UUID(), bookID: book.id, chapterID: chapter.id, position: 35), bookContentKey: key))
        let sync = CloudKitSyncEngine(database: db)
        try await sync.applyFetchedLibraryChanges(records: [position, bookmark], tokenData: Data([7]))
        #expect(try await CloudSyncStateStore(database: db).loadEngineState() == Data([7]))
        #expect(try await db.query("SELECT id FROM playback_positions").isEmpty)
        #expect(sync.importErrors.count == 2)

        let restarted = CloudKitSyncEngine(database: db)
        try await restarted.applyFetchedLibraryChanges(records: [
            CloudKitRecordMapper.sourceRecord(from: source, sourceKey: "test_sync"),
            CloudKitRecordMapper.bookRecord(from: book, chapters: [chapter], contentKey: key, sourceKey: "test_sync")
        ], tokenData: Data([8]))
        #expect(try await SQLitePositionStore(database: db).position(for: localBook, chapterID: chapter.id)?.position == 42)
        #expect(try await db.query("SELECT chapter_id FROM bookmarks").first?.string("chapter_id") == chapter.id.uuidString)
        #expect(restarted.importErrors.isEmpty)
        #expect(try await db.query("SELECT record_name FROM deferred_library_imports").isEmpty)
        try await restarted.applyFetchedLibraryChanges(records: [])
        #expect(try await db.query("SELECT id FROM playback_positions").count == 1)
    }

    @Test func failedMyBooksImportIsRetainedWhileOtherRecordsCheckpoint() async throws {
        let db = AppDatabase.makeTemporaryDatabase()
        try await db.prepare()
        let state = CloudSyncStateStore(database: db)
        try await state.saveEngineState(Data([1]))
        let sync = CloudKitSyncEngine(database: db)
        let malformed = CKRecord(recordType: "Book", recordID: .init(recordName: "book-invalid", zoneID: CloudKitRecordMapper.libraryZoneID))
        let source = Source(kind: .librivox, title: "Healthy source")
        let healthy = CloudKitRecordMapper.sourceRecord(from: source, sourceKey: "healthy")
        try await sync.applyFetchedLibraryChanges(records: [malformed, healthy], tokenData: Data([2]))
        #expect(try await state.loadEngineState() == Data([2]))
        #expect(sync.lastFetchedCount == 1)
        #expect(sync.importErrors.count == 1)
        #expect(sync.importErrors[0].contains("book-invalid"))
        #expect(try await db.query("SELECT record_name FROM deferred_library_imports").count == 1)
        let restarted = CloudKitSyncEngine(database: db)
        try await restarted.applyFetchedLibraryChanges(records: [])
        #expect(restarted.importErrors.count == 1)
        try await restarted.applyFetchedLibraryChanges(records: [], deletions: [malformed.recordID])
        #expect(restarted.importErrors.isEmpty)
        #expect(try await db.query("SELECT record_name FROM deferred_library_imports").isEmpty)
    }

    @Test func repeatedCheckpointsQueueOnePersistedIdentity() async throws {
        let db = AppDatabase.makeTemporaryDatabase()
        let ids = try await seed(db)[0]
        let state = CloudSyncStateStore(database: db)
        var positions = SQLitePositionStore(database: db)
        positions.mutationLog = SyncMutationLog(stateStore: state)
        for i in 0..<200 {
            try await positions.save(PlaybackPosition(bookID: ids.0, chapterID: ids.1,
                                                      position: Double(i), updatedAt: Date(timeIntervalSince1970: Double(i))))
        }
        let pending = try await state.dequeuePending()
        #expect(pending.count == 1)
        let actual = try await positions.position(for: ids.0, chapterID: ids.1)
        #expect(pending.first?.localID == actual?.id.uuidString)
        #expect(actual?.position == 199)
    }

    @Test func oldOrphanIdentitiesAreRemovedWithoutLosingResumePoint() async throws {
        let db = AppDatabase.makeTemporaryDatabase()
        let ids = try await seed(db)[0]
        let state = CloudSyncStateStore(database: db)
        let positions = SQLitePositionStore(database: db)
        let saved = PlaybackPosition(bookID: ids.0, chapterID: ids.1, position: 72)
        try await positions.save(saved)
        try await state.enqueuePending(localID: saved.id.uuidString, recordType: "PlaybackPosition", changeType: "update")
        for _ in 0..<75 { try await state.enqueuePending(localID: UUID().uuidString, recordType: "PlaybackPosition", changeType: "update") }
        #expect(try await state.pruneOrphanedPlaybackChanges() == 75)
        #expect(try await state.pendingCount() == 1)
        #expect(try await positions.position(for: ids.0, chapterID: ids.1)?.position == 72)
    }

    @Test func oneSyncDrainsMultipleBatchesAndSkipsUnbuildableRows() async throws {
        let db = AppDatabase.makeTemporaryDatabase()
        let ids = try await seed(db, books: 61)
        let state = CloudSyncStateStore(database: db)
        for _ in 0..<55 { try await state.enqueuePending(localID: UUID().uuidString, recordType: "Book", changeType: "delete") }
        for (book, _) in ids { try await state.enqueuePending(localID: book.uuidString, recordType: "Book", changeType: "update") }
        let sync = await engine(db)
        var sentBooks = 0
        try await sync.sendPendingChanges { records, _ in
            sentBooks += records.filter { $0.recordType == "Book" }.count
        }
        #expect(sentBooks == 61)
        #expect(try await state.pendingCount() == 55) // preserve unresolved deletions
    }

    @Test func failedUploadRetainsValidChanges() async throws {
        let db = AppDatabase.makeTemporaryDatabase()
        let ids = try await seed(db)[0]
        let state = CloudSyncStateStore(database: db)
        try await state.enqueuePending(localID: ids.0.uuidString, recordType: "Book", changeType: "update")
        let sync = await engine(db)
        await #expect(throws: URLError.self) {
            try await sync.sendPendingChanges { _, _ in throw URLError(.notConnectedToInternet) }
        }
        #expect(try await state.pendingCount() == 1)
        #expect(sync.lastUploadedCount == 0)
    }

    @Test func olderUploadReceiptDoesNotRemoveNewerLocalEdit() async throws {
        let db = AppDatabase.makeTemporaryDatabase()
        let state = CloudSyncStateStore(database: db)
        try await state.enqueuePending(localID: "book", recordType: "Book", changeType: "update")
        let first = try #require(try await state.dequeuePending().first)
        try await state.enqueuePending(localID: "book", recordType: "Book", changeType: "delete")
        try await state.removePending(localID: "book", recordType: "Book", enqueuedAt: first.enqueuedAt)
        #expect(try await state.dequeuePending().first?.changeType == "delete")
    }

    @Test func upsertPositionRefusesEarlierChapterThatWouldRegressBookProgress() async throws {
        let db = AppDatabase.makeTemporaryDatabase()
        try await db.prepare()
        let sync = CloudKitSyncEngine(database: db)
        let sourceKey = "regress-test"
        let contentKey = "ia:regress-test"
        let source = Source(kind: .librivox, title: "Source", url: URL(string: "https://archive.org/details/regress-test"))
        let book = Book(title: "Book", authors: ["Author"], sourceID: source.id)
        let chapter0 = Chapter(bookID: book.id, title: "Ch 1", index: 0, duration: 300,
                               remoteURL: URL(string: "https://archive.org/download/regress-test/ch1.mp3"))
        let chapter1 = Chapter(bookID: book.id, title: "Ch 2", index: 1, duration: 300,
                               remoteURL: URL(string: "https://archive.org/download/regress-test/ch2.mp3"))

        let libraryRecords = [
            CloudKitRecordMapper.bookRecord(from: book, chapters: [chapter0, chapter1], contentKey: contentKey, sourceKey: sourceKey),
            CloudKitRecordMapper.sourceRecord(from: source, sourceKey: sourceKey)
        ]
        // The user has already progressed to chapter 2, synced at t=200.
        let advancedPosition = PlaybackPosition(
            bookID: book.id, chapterID: chapter1.id, position: 500,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        try await sync.applyFetchedLibraryChanges(
            records: libraryRecords + [CloudKitRecordMapper.positionRecord(from: advancedPosition, bookContentKey: contentKey)],
            tokenData: Data([1])
        )

        // A stale record for chapter 1 arrives stamped *after* (t=300) the
        // real chapter-2 progress, simulating a sync "touch" of an old row.
        let stalePosition = PlaybackPosition(
            bookID: book.id, chapterID: chapter0.id, position: 30,
            updatedAt: Date(timeIntervalSince1970: 300)
        )
        try await sync.applyFetchedLibraryChanges(
            records: [CloudKitRecordMapper.positionRecord(from: stalePosition, bookContentKey: contentKey)],
            tokenData: Data([2])
        )

        let library = try await LibraryRepository(database: db).fetchBooks(filteredBy: .all)
        let imported = try #require(library.first)
        let store = SQLitePositionStore(database: db)
        let localChapter2 = try #require(imported.chapters.first { $0.index == 1 })
        let localChapter1 = try #require(imported.chapters.first { $0.index == 0 })

        let savedChapter2 = try await store.position(for: imported.book.id, chapterID: localChapter2.id)
        #expect(abs((savedChapter2?.position ?? -1) - 500) <= 0.001)

        let savedChapter1 = try await store.position(for: imported.book.id, chapterID: localChapter1.id)
        #expect(savedChapter1 == nil)
    }

    @Test func upsertPositionStillAcceptsGenuineForwardProgress() async throws {
        let db = AppDatabase.makeTemporaryDatabase()
        try await db.prepare()
        let sync = CloudKitSyncEngine(database: db)
        let sourceKey = "advance-test"
        let contentKey = "ia:advance-test"
        let source = Source(kind: .librivox, title: "Source", url: URL(string: "https://archive.org/details/advance-test"))
        let book = Book(title: "Book", authors: ["Author"], sourceID: source.id)
        let chapter0 = Chapter(bookID: book.id, title: "Ch 1", index: 0, duration: 300,
                               remoteURL: URL(string: "https://archive.org/download/advance-test/ch1.mp3"))
        let chapter1 = Chapter(bookID: book.id, title: "Ch 2", index: 1, duration: 300,
                               remoteURL: URL(string: "https://archive.org/download/advance-test/ch2.mp3"))

        let libraryRecords = [
            CloudKitRecordMapper.bookRecord(from: book, chapters: [chapter0, chapter1], contentKey: contentKey, sourceKey: sourceKey),
            CloudKitRecordMapper.sourceRecord(from: source, sourceKey: sourceKey)
        ]
        let startPosition = PlaybackPosition(
            bookID: book.id, chapterID: chapter0.id, position: 290,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        try await sync.applyFetchedLibraryChanges(
            records: libraryRecords + [CloudKitRecordMapper.positionRecord(from: startPosition, bookContentKey: contentKey)],
            tokenData: Data([1])
        )

        let advancePosition = PlaybackPosition(
            bookID: book.id, chapterID: chapter1.id, position: 15,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        try await sync.applyFetchedLibraryChanges(
            records: [CloudKitRecordMapper.positionRecord(from: advancePosition, bookContentKey: contentKey)],
            tokenData: Data([2])
        )

        let library = try await LibraryRepository(database: db).fetchBooks(filteredBy: .all)
        let imported = try #require(library.first)
        let localChapter2 = try #require(imported.chapters.first { $0.index == 1 })
        let saved = try await SQLitePositionStore(database: db).position(for: imported.book.id, chapterID: localChapter2.id)
        #expect(abs((saved?.position ?? -1) - 15) <= 0.001)
    }
}
