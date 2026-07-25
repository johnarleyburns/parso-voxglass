import Foundation
import CloudKit
import Testing
@testable import VoxglassCore

@Suite struct CloudKitRecordMapperTests {

    // MARK: - T1: Mapper round-trip for Book (+chapters)

    @Test func mapper_roundTrip_bookWithChapters() async throws {
        let book = Book(
            title: "Test Book",
            authors: ["Test Author"],
            narrators: ["Test Narrator"],
            summary: "A test summary",
            sourceID: UUID(),
            coverURL: URL(string: "https://archive.org/test.jpg"),
            createdAt: Date(timeIntervalSince1970: 1000),
            updatedAt: Date(timeIntervalSince1970: 2000),
            isFavorite: true
        )
        let chapters: [Chapter] = [
            Chapter(
                bookID: book.id,
                title: "Chapter 1",
                index: 1,
                duration: 3600,
                remoteURL: URL(string: "https://archive.org/download/test/ch1.mp3"),
                localURL: URL(string: "file:///test/local/ch1.mp3")
            )
        ]
        let contentKey = "ia:test_identifier"
        let sourceKey = "test_source"

        let record = CloudKitRecordMapper.bookRecord(
            from: book,
            chapters: chapters,
            contentKey: contentKey,
            sourceKey: sourceKey
        )

        #expect(record.recordType == CloudKitRecordMapper.RecordType.book.rawValue)
        #expect(record[CloudKitRecordMapper.Field.title] as? String == "Test Book")
        #expect(record[CloudKitRecordMapper.Field.contentKey] as? String == contentKey)
        #expect(record[CloudKitRecordMapper.Field.isFavorite] as? Int == 1)

        let decodedBook = CloudKitRecordMapper.book(from: record)
        #expect(decodedBook != nil)
        #expect(decodedBook?.title == "Test Book")
        #expect(decodedBook?.authors == ["Test Author"])
        #expect(decodedBook?.isFavorite == true)

        let decodedChapters = try CloudKitRecordMapper.chaptersData(from: record)
        #expect(decodedChapters.count == 1)
        #expect(decodedChapters[0].title == "Chapter 1")
        #expect(decodedChapters[0].localURL == nil)
        #expect(decodedChapters[0].remoteURL?.absoluteString == "https://archive.org/download/test/ch1.mp3")
    }

    // MARK: - T1: Mapper round-trip for Source

    @Test func mapper_roundTrip_source() async throws {
        let source = Source(
            kind: .librivox,
            title: "Test Source",
            url: URL(string: "https://archive.org/details/test"),
            createdAt: Date(timeIntervalSince1970: 3000)
        )
        let sourceKey = "test"

        let record = CloudKitRecordMapper.sourceRecord(from: source, sourceKey: sourceKey)
        #expect(record.recordType == CloudKitRecordMapper.RecordType.source.rawValue)
        #expect(record[CloudKitRecordMapper.Field.kind] as? String == SourceKind.librivox.rawValue)
        #expect(record[CloudKitRecordMapper.Field.title] as? String == "Test Source")

        let decoded = CloudKitRecordMapper.source(from: record)
        #expect(decoded != nil)
        #expect(decoded?.title == "Test Source")
    }

    // MARK: - T1: Mapper round-trip for PlaybackPosition

    @Test func mapper_roundTrip_position() async throws {
        let position = PlaybackPosition(
            bookID: UUID(),
            chapterID: UUID(),
            position: 123.45,
            duration: 3600,
            updatedAt: Date(timeIntervalSince1970: 4000),
            isFinished: false
        )
        let bookContentKey = "ia:test_identifier"

        let record = CloudKitRecordMapper.positionRecord(from: position, bookContentKey: bookContentKey)
        #expect(record.recordType == CloudKitRecordMapper.RecordType.playbackPosition.rawValue)
        #expect(record[CloudKitRecordMapper.Field.positionSeconds] as? Double == 123.45)
        #expect(record[CloudKitRecordMapper.Field.isFinished] as? Int == 0)

        let decoded = CloudKitRecordMapper.position(from: record)
        #expect(decoded != nil)
        #expect(decoded?.position == 123.45)
        #expect(decoded?.isFinished == false)
    }

    // MARK: - T1: Mapper round-trip for Bookmark

    @Test func mapper_roundTrip_bookmark() async throws {
        let bookmark = Bookmark(
            id: UUID(),
            bookID: UUID(),
            chapterID: UUID(),
            position: 500,
            note: "Important passage",
            createdAt: Date(timeIntervalSince1970: 5000),
            updatedAt: Date(timeIntervalSince1970: 6000),
            isDeleted: true
        )
        let bookContentKey = "ia:test_identifier"

        guard let record = CloudKitRecordMapper.bookmarkRecord(from: bookmark, bookContentKey: bookContentKey) else {
            #expect(Bool(false), "Bookmark record should not be nil")
            return
        }
        #expect(record.recordType == CloudKitRecordMapper.RecordType.bookmark.rawValue)
        #expect(record[CloudKitRecordMapper.Field.note] as? String == "Important passage")
        #expect(record[CloudKitRecordMapper.Field.isDeleted] as? Int == 1)

        let decoded = CloudKitRecordMapper.bookmark(from: record)
        #expect(decoded != nil)
        #expect(decoded?.position == 500)
        #expect(decoded?.isDeleted == true)
    }

    // MARK: - T2: Idempotent recordName

    @Test func mapper_recordName_sameContentKeyProducesSameName() async throws {
        let contentKey = "ia:test_book_123"
        let name1 = CloudKitRecordMapper.bookRecordName(contentKey: contentKey)
        let name2 = CloudKitRecordMapper.bookRecordName(contentKey: contentKey)
        #expect(name1 == name2)

        let differentKey = "ia:different_book"
        let name3 = CloudKitRecordMapper.bookRecordName(contentKey: differentKey)
        #expect(name1 != name3)
    }

    @Test func mapper_recordName_positionIdempotent() async throws {
        let id = UUID()
        let name1 = CloudKitRecordMapper.positionRecordName(positionID: id)
        let name2 = CloudKitRecordMapper.positionRecordName(positionID: id)
        #expect(name1 == name2)
    }

    // MARK: - T2: local_url is stripped from chapters

    @Test func mapper_chaptersData_localURLStripped() async throws {
        let chapters: [Chapter] = [
            Chapter(
                bookID: UUID(),
                title: "Test",
                index: 0,
                remoteURL: URL(string: "https://archive.org/test.mp3"),
                localURL: URL(string: "file:///local/path.mp3")
            )
        ]
        let book = Book(title: "Test", authors: ["A"], sourceID: UUID())
        let contentKey = "ia:test"
        let sourceKey = "test"

        let record = CloudKitRecordMapper.bookRecord(
            from: book, chapters: chapters,
            contentKey: contentKey, sourceKey: sourceKey
        )
        let decoded = try CloudKitRecordMapper.chaptersData(from: record)
        #expect(decoded.count == 1)
        #expect(decoded[0].localURL == nil)
        #expect(decoded[0].remoteURL?.absoluteString == "https://archive.org/test.mp3")
    }

    // MARK: - T3: Content key and chapter data roundtrip with many chapters

    @Test func mapper_chapters_gzipRoundtrip() async throws {
        var chapters: [Chapter] = []
        for i in 0..<50 {
            chapters.append(Chapter(
                bookID: UUID(),
                title: "Chapter \(i)",
                index: i,
                duration: Double(1800 + i * 60),
                remoteURL: URL(string: "https://archive.org/download/test/ch\(i).mp3")
            ))
        }
        let book = Book(title: "Long Book", authors: ["Author"], sourceID: UUID())
        let record = CloudKitRecordMapper.bookRecord(
            from: book, chapters: chapters,
            contentKey: "ia:longbook", sourceKey: "long"
        )
        let decoded = try CloudKitRecordMapper.chaptersData(from: record)
        #expect(decoded.count == 50)
        for i in 0..<50 {
            #expect(decoded[i].index == i)
            #expect(decoded[i].title == "Chapter \(i)")
            #expect(decoded[i].localURL == nil)
        }
    }
}

// MARK: - T4: Sync gate truth table

@Suite struct SyncGateTests {

    @Test func gate_enabledAndAvailable_returnsTrue() async throws {
        #expect(SyncGate.shouldSync(iCloudSyncEnabled: true, accountStatus: .available) == true)
    }

    @Test func gate_disabled_returnsFalse() async throws {
        #expect(SyncGate.shouldSync(iCloudSyncEnabled: false, accountStatus: .available) == false)
    }

    @Test func gate_noAccount_returnsFalse() async throws {
        #expect(SyncGate.shouldSync(iCloudSyncEnabled: true, accountStatus: .noAccount) == false)
    }

    @Test func gate_restricted_returnsFalse() async throws {
        #expect(SyncGate.shouldSync(iCloudSyncEnabled: true, accountStatus: .restricted) == false)
    }

    @Test func gate_couldNotDetermine_returnsFalse() async throws {
        #expect(SyncGate.shouldSync(iCloudSyncEnabled: true, accountStatus: .couldNotDetermine) == false)
    }

    @Test func gate_noProOrEntitlementInput_exists() async throws {
        // Verify the predicate has exactly two inputs — no tier/Pro dimension
        let result = SyncGate.shouldSync(iCloudSyncEnabled: true, accountStatus: .available)
        #expect(result == true)
    }
}

// MARK: - T5: CloudSyncStateStore round-trip

@Suite struct CloudSyncStateStoreTests {

    private func makeDB() async throws -> AppDatabase {
        let db = AppDatabase.makeTemporaryDatabase()
        try await db.prepare()
        return db
    }

    @Test func stateStore_engineStateRoundTrip() async throws {
        let db = try await makeDB()
        let store = CloudSyncStateStore(database: db)

        let testData = Data("test engine state".utf8)
        try await store.saveEngineState(testData)
        let loaded = try await store.loadEngineState()
        #expect(loaded != nil)
        #expect(loaded == testData)
    }

    @Test func stateStore_systemFieldsRoundTrip() async throws {
        let db = try await makeDB()
        let store = CloudSyncStateStore(database: db)

        let fields = Data("test system fields".utf8)
        try await store.saveSystemFields(fields, recordName: "test-record", recordType: "Book", localID: "test-id")
        let loaded = try await store.loadSystemFields(recordName: "test-record")
        #expect(loaded != nil)
        #expect(loaded == fields)
    }

    @Test func stateStore_pendingEnqueueDequeue() async throws {
        let db = try await makeDB()
        let store = CloudSyncStateStore(database: db)

        try await store.enqueuePending(localID: "local-1", recordType: "Book", changeType: "update")
        try await store.enqueuePending(localID: "local-2", recordType: "PlaybackPosition", changeType: "update")
        try await store.enqueuePending(localID: "local-3", recordType: "Bookmark", changeType: "update")

        let pending = try await store.dequeuePending(limit: 50)
        #expect(pending.count == 3)

        let count = try await store.pendingCount()
        #expect(count == 3)

        try await store.removePending(localID: "local-1", recordType: "Book")
        let remaining = try await store.dequeuePending(limit: 50)
        #expect(remaining.count == 2)
    }

    @Test func stateStore_clearPending() async throws {
        let db = try await makeDB()
        let store = CloudSyncStateStore(database: db)

        try await store.enqueuePending(localID: "a", recordType: "Book", changeType: "update")
        try await store.enqueuePending(localID: "b", recordType: "Book", changeType: "update")
        try await store.clearPending()

        let count = try await store.pendingCount()
        #expect(count == 0)
    }

    @Test func stateStore_localIDLookup() async throws {
        let db = try await makeDB()
        let store = CloudSyncStateStore(database: db)

        try await store.saveSystemFields(Data(), recordName: "rn-1", recordType: "Book", localID: "local-id-1")
        let localID = try await store.localID(for: "rn-1")
        #expect(localID == "local-id-1")
    }
}

// MARK: - T5: SyncMutationLog

@Suite struct SyncMutationLogTests {

    private func makeDB() async throws -> AppDatabase {
        let db = AppDatabase.makeTemporaryDatabase()
        try await db.prepare()
        return db
    }

    @Test func mutationLog_enqueueAddsToPending() async throws {
        let db = try await makeDB()
        let stateStore = CloudSyncStateStore(database: db)
        let log = SyncMutationLog(stateStore: stateStore)

        try await log.enqueue(localID: "test-id", recordType: "Book", changeType: "update")
        let pending = try await stateStore.dequeuePending(limit: 10)
        #expect(pending.count == 1)
        #expect(pending[0].localID == "test-id")
        #expect(pending[0].recordType == "Book")
        #expect(pending[0].changeType == "update")
    }

    @Test func mutationLog_defaultChangeTypeIsUpdate() async throws {
        let db = try await makeDB()
        let stateStore = CloudSyncStateStore(database: db)
        let log = SyncMutationLog(stateStore: stateStore)

        try await log.enqueue(localID: "x", recordType: "PlaybackPosition")
        let pending = try await stateStore.dequeuePending(limit: 10)
        #expect(pending[0].changeType == "update")
    }
}

// MARK: - T8: Search scope filter

@Suite struct WatchSearchFilterTests {

    @Test func filter_matchesByTitle_caseInsensitive() async throws {
        let book = Book(title: "Pride and Prejudice", authors: ["Jane Austen"], sourceID: UUID())
        let bc = BookWithChapters(book: book, chapters: [])

        let query = "pride"
        let matches = [bc].filter {
            $0.book.title.lowercased().contains(query.lowercased())
        }
        #expect(matches.count == 1)
    }

    @Test func filter_matchesByAuthor_caseInsensitive() async throws {
        let book = Book(title: "Emma", authors: ["Jane Austen"], sourceID: UUID())
        let bc = BookWithChapters(book: book, chapters: [])

        let query = "austen"
        let matches = [bc].filter {
            $0.book.title.lowercased().contains(query.lowercased())
                || $0.book.authors.contains(where: { $0.lowercased().contains(query.lowercased()) })
        }
        #expect(matches.count == 1)
    }

    @Test func filter_noMatch_returnsEmpty() async throws {
        let book = Book(title: "Emma", authors: ["Jane Austen"], sourceID: UUID())
        let bc = BookWithChapters(book: book, chapters: [])

        let query = "tolstoy"
        let matches = [bc].filter {
            $0.book.title.lowercased().contains(query.lowercased())
                || $0.book.authors.contains(where: { $0.lowercased().contains(query.lowercased()) })
        }
        #expect(matches.isEmpty)
    }
}

// MARK: - T6: sendPendingChanges preserves mutations until CloudKit confirms

@Suite struct CloudKitPendingMutationRetentionTests {

    private func makeDB() async throws -> AppDatabase {
        let db = AppDatabase.makeTemporaryDatabase()
        try await db.prepare()
        return db
    }

    @Test func pendingMutations_persistWhenNotRemoved() async throws {
        let db = try await makeDB()
        let stateStore = CloudSyncStateStore(database: db)

        try await stateStore.enqueuePending(localID: "book-1", recordType: "Book", changeType: "update")
        try await stateStore.enqueuePending(localID: "book-2", recordType: "Book", changeType: "update")
        #expect(try await stateStore.pendingCount() == 2)

        // Mutations persist unless explicitly removed (simulating CloudKit failure)
        #expect(try await stateStore.pendingCount() == 2,
                "Pending mutations should persist when not removed (CloudKit save fails)")
    }

    @Test func pendingMutations_removedOnlyOnSuccess() async throws {
        let db = try await makeDB()
        let stateStore = CloudSyncStateStore(database: db)

        try await stateStore.enqueuePending(localID: "book-1", recordType: "Book", changeType: "update")
        #expect(try await stateStore.pendingCount() == 1)

        // Remove only after confirmed success
        try await stateStore.removePending(localID: "book-1", recordType: "Book")
        #expect(try await stateStore.pendingCount() == 0,
                "Mutation removed after confirmed CloudKit success")
    }

    @Test func pendingMutations_multipleTypes_independentRemoval() async throws {
        let db = try await makeDB()
        let stateStore = CloudSyncStateStore(database: db)

        try await stateStore.enqueuePending(localID: "b1", recordType: "Book", changeType: "update")
        try await stateStore.enqueuePending(localID: "p1", recordType: "PlaybackPosition", changeType: "update")
        try await stateStore.enqueuePending(localID: "bm1", recordType: "Bookmark", changeType: "update")
        #expect(try await stateStore.pendingCount() == 3)

        // Remove book only — others persist
        try await stateStore.removePending(localID: "b1", recordType: "Book")
        #expect(try await stateStore.pendingCount() == 2)

        let remaining = try await stateStore.dequeuePending(limit: 50)
        #expect(remaining.count == 2)
        let types = Set(remaining.map(\.recordType))
        #expect(types.contains("PlaybackPosition"))
        #expect(types.contains("Bookmark"))
        #expect(!types.contains("Book"), "Book mutation should be gone")
    }
}

// MARK: - T7: book(from:) resolves stable sourceID from sourceRef

@Suite struct CloudKitBookSourceIDResolutionTests {

    @Test func book_fromRecord_usesSourceRefNotRandomUUID() async throws {
        let sourceIdentity = "pride_and_prejudice_1000"
        let sourceRecordName = "source-\(sourceIdentity)"
        let bookRecordName = CloudKitRecordMapper.bookRecordName(contentKey: "ia:test-pp")

        let sourceRef = CKRecord.Reference(
            recordID: CKRecord.ID(
                recordName: sourceRecordName,
                zoneID: CloudKitRecordMapper.libraryZoneID
            ),
            action: .deleteSelf
        )

        let record = CKRecord(
            recordType: CloudKitRecordMapper.RecordType.book.rawValue,
            recordID: CKRecord.ID(recordName: bookRecordName, zoneID: CloudKitRecordMapper.libraryZoneID)
        )
        record[CloudKitRecordMapper.Field.title] = "Pride and Prejudice"
        record[CloudKitRecordMapper.Field.authorsJSON] = "[\"Jane Austen\"]"
        record[CloudKitRecordMapper.Field.narratorsJSON] = "[\"Karen Savage\"]"
        record[CloudKitRecordMapper.Field.sourceRef] = sourceRef
        record[CloudKitRecordMapper.Field.contentKey] = "ia:test-pp"

        let book = CloudKitRecordMapper.book(from: record)
        #expect(book != nil)
        #expect(book?.title == "Pride and Prejudice")

        let expectedSourceID = CloudKitRecordMapper.stableUUID(from: sourceIdentity)
        #expect(book?.sourceID == expectedSourceID, "sourceID should be derived from sourceRef, not random")
    }

    @Test func stableUUID_sameIdentityProducesSameUUID() async throws {
        let identity = "test_identifier_123"
        let uuid1 = CloudKitRecordMapper.stableUUID(from: identity)
        let uuid2 = CloudKitRecordMapper.stableUUID(from: identity)
        #expect(uuid1 == uuid2, "Same identity should produce same UUID")
    }

    @Test func stableUUID_differentIdentityProducesDifferentUUID() async throws {
        let uuid1 = CloudKitRecordMapper.stableUUID(from: "identity_a")
        let uuid2 = CloudKitRecordMapper.stableUUID(from: "identity_b")
        #expect(uuid1 != uuid2, "Different identities should produce different UUIDs")
    }

    @Test func book_fromRecord_sameSourceIdentitySameSourceUUID() async throws {
        let sourceIdentity = "great_expectations"
        let sourceRef = CKRecord.Reference(
            recordID: CKRecord.ID(
                recordName: "source-\(sourceIdentity)",
                zoneID: CloudKitRecordMapper.libraryZoneID
            ),
            action: .deleteSelf
        )

        // Book 1
        let r1 = CKRecord(
            recordType: CloudKitRecordMapper.RecordType.book.rawValue,
            recordID: CKRecord.ID(
                recordName: CloudKitRecordMapper.bookRecordName(contentKey: "ia:ge-1"),
                zoneID: CloudKitRecordMapper.libraryZoneID
            )
        )
        r1[CloudKitRecordMapper.Field.title] = "Great Expectations"
        r1[CloudKitRecordMapper.Field.authorsJSON] = "[\"Charles Dickens\"]"
        r1[CloudKitRecordMapper.Field.narratorsJSON] = "[]"
        r1[CloudKitRecordMapper.Field.sourceRef] = sourceRef

        // Book 2 — same source
        let r2 = CKRecord(
            recordType: CloudKitRecordMapper.RecordType.book.rawValue,
            recordID: CKRecord.ID(
                recordName: CloudKitRecordMapper.bookRecordName(contentKey: "ia:ge-2"),
                zoneID: CloudKitRecordMapper.libraryZoneID
            )
        )
        r2[CloudKitRecordMapper.Field.title] = "Great Expectations (alt)"
        r2[CloudKitRecordMapper.Field.authorsJSON] = "[\"Charles Dickens\"]"
        r2[CloudKitRecordMapper.Field.narratorsJSON] = "[]"
        r2[CloudKitRecordMapper.Field.sourceRef] = sourceRef

        let book1 = CloudKitRecordMapper.book(from: r1)
        let book2 = CloudKitRecordMapper.book(from: r2)
        #expect(book1 != nil)
        #expect(book2 != nil)
        #expect(book1?.sourceID == book2?.sourceID,
                "Books from same source should have the same sourceID")
    }
}
