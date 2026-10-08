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

    @Test func failedMyBooksImportDoesNotCheckpointPastMissingRecords() async throws {
        let db = AppDatabase.makeTemporaryDatabase()
        try await db.prepare()
        let state = CloudSyncStateStore(database: db)
        try await state.saveEngineState(Data([1]))
        let sync = CloudKitSyncEngine(database: db)
        let malformed = CKRecord(recordType: "Book", recordID: .init(recordName: "book-invalid", zoneID: CloudKitRecordMapper.libraryZoneID))
        await #expect(throws: (any Error).self) {
            try await sync.applyFetchedLibraryChanges(records: [malformed], tokenData: Data([2]))
        }
        #expect(try await state.loadEngineState() == Data([1]))
        #expect(sync.lastFetchedCount == 0)
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

    @Test func productionWritesAndParentReferencesUseVerificationZone() async throws {
        let zone = CKRecordZone.ID(zoneName: CloudKitProductionSync.zoneName)
        let records = try await CloudKitProductionSync.records(from: [
            SyncRecord(recordType: "VGProductionAsset", recordName: "asset-one", fields: [:]),
            SyncRecord(recordType: ProductionRecordType.paragraph.rawValue, recordName: "paragraph-one", parentName: "project-one", fields: [:])
        ], zoneID: zone, proxyFileProvider: { _ in nil })
        #expect(records.allSatisfy { $0.recordID.zoneID == zone })
        #expect(records[1].parent?.recordID.zoneID == zone)
    }

    @Test func recordingCannotBeBackedUpWithoutItsAudioAttachment() async throws {
        let zone = CKRecordZone.ID(zoneName: CloudKitProductionSync.zoneName)
        await #expect(throws: SyncError.self) {
            _ = try await CloudKitProductionSync.records(from: [
                SyncRecord(recordType: ProductionRecordType.asset.rawValue, recordName: "asset-one",
                           fields: [ProductionField.assetSHA: .string("missing-sha")])
            ], zoneID: zone, proxyFileProvider: { _ in nil })
        }
    }

    @Test func narrationCheckpointRepairPreservesPendingEditsAndReceipts() async throws {
        let store = AuthoringLocalStore(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("authoring-repair-\(UUID()).sqlite"))
        let uploadedID = UUID()
        let uploaded = try await store.commitLocalMutation(entityId: uploadedID, entityKind: "project", payload: Data(#"{"title":"Uploaded"}"#.utf8), changedFields: ["title"])
        try await store.acknowledgeUpload(entityId: uploadedID, operationId: uploaded.operationId, changeTag: "receipt", systemFields: Data([10]))
        let id = UUID()
        _ = try await store.commitLocalMutation(entityId: id, entityKind: "project", payload: Data(#"{"title":"Keep me"}"#.utf8), changedFields: ["title"])
        try await store.saveEngineState(scope: "account", state: Data([1, 2, 3]))
        #expect(try await store.hasSyncRepair(scope: "account", repair: "scope-v1") == false)
        try await store.resetEngineStateForRepair(scope: "account", repair: "scope-v1")
        #expect(try await store.engineState(scope: "account") == nil)
        #expect(try await store.systemFields(entityId: uploadedID) == Data([10]))
        #expect(try await store.pendingMutations().count == 1)
        #expect(try await store.hasSyncRepair(scope: "account", repair: "scope-v1"))
        #expect(try await store.hasSyncRepair(scope: "other-account", repair: "scope-v1") == false)
    }
}
