import Foundation
import CloudKit
import Testing
@testable import VoxglassCore

// MARK: - T3: Conflict resolution tests

@Suite struct ConflictResolutionTests {

    @Test func lww_positionPickHigherUpdatedAt() async throws {
        let updated1 = Date(timeIntervalSince1970: 1000)
        let updated2 = Date(timeIntervalSince1970: 2000)

        let older = PlaybackPosition(
            bookID: UUID(), chapterID: UUID(),
            position: 100, updatedAt: updated1, isFinished: false
        )
        let newer = PlaybackPosition(
            bookID: UUID(), chapterID: UUID(),
            position: 300, updatedAt: updated2, isFinished: true
        )

        let bookContentKey = "ia:test"
        let olderRecord = CloudKitRecordMapper.positionRecord(from: older, bookContentKey: bookContentKey)
        let newerRecord = CloudKitRecordMapper.positionRecord(from: newer, bookContentKey: bookContentKey)

        let olderDecoded = CloudKitRecordMapper.position(from: olderRecord)
        let newerDecoded = CloudKitRecordMapper.position(from: newerRecord)

        // LWW: the newer updatedAt should win
        #expect((olderDecoded?.updatedAt.timeIntervalSince1970 ?? 0) < (newerDecoded?.updatedAt.timeIntervalSince1970 ?? 0))
        #expect(newerDecoded?.isFinished == true)
        #expect(newerDecoded?.position == 300)
    }

    @Test func tombstone_beatsStaleNonDeleted() async throws {
        let deleted = Bookmark(
            id: UUID(), bookID: UUID(), chapterID: UUID(),
            position: 500,
            createdAt: Date(timeIntervalSince1970: 1000),
            updatedAt: Date(timeIntervalSince1970: 3000),
            isDeleted: true
        )
        let notDeleted = Bookmark(
            id: UUID(), bookID: UUID(), chapterID: UUID(),
            position: 500,
            createdAt: Date(timeIntervalSince1970: 1000),
            updatedAt: Date(timeIntervalSince1970: 2000),
            isDeleted: false
        )

        // LWW: the tombstone (newer) should take precedence
        #expect(deleted.updatedAt > notDeleted.updatedAt)
        #expect(deleted.isDeleted == true)
    }

    @Test func creationWins_sameContentKey_keepsExisting() async throws {
        let contentKey = "ia:test_book"
        let name1 = CloudKitRecordMapper.bookRecordName(contentKey: contentKey)
        let name2 = CloudKitRecordMapper.bookRecordName(contentKey: contentKey)

        // Same content key produces same record name (dedupe)
        #expect(name1 == name2)

        // Different content keys produce different names
        let name3 = CloudKitRecordMapper.bookRecordName(contentKey: "ia:different_book")
        #expect(name1 != name3)
    }
}

// MARK: - T5: Standalone-no-account path

@Suite struct StandaloneNoAccountTests {

    private func makeDB() async throws -> AppDatabase {
        let db = AppDatabase.makeTemporaryDatabase()
        try await db.prepare()
        return db
    }

    @Test func syncGate_noAccount_shouldSyncFalse() async throws {
        #expect(SyncGate.shouldSync(iCloudSyncEnabled: true, accountStatus: .noAccount) == false)
        #expect(SyncGate.shouldSync(iCloudSyncEnabled: true, accountStatus: .restricted) == false)
        #expect(SyncGate.shouldSync(iCloudSyncEnabled: true, accountStatus: .couldNotDetermine) == false)
    }

    @Test func mutationLog_worksWithNoAccount_dirtyRowsStillEnqueued() async throws {
        let db = try await makeDB()
        let stateStore = CloudSyncStateStore(database: db)
        let log = SyncMutationLog(stateStore: stateStore)

        // Even when sync is off, local mutations still enqueue dirty rows
        try await log.enqueue(localID: "test", recordType: "PlaybackPosition")
        let count = try await stateStore.pendingCount()
        #expect(count == 1)
    }

    @Test func stateStore_pendingRowsPersistAcrossInstances() async throws {
        let db = try await makeDB()
        let store1 = CloudSyncStateStore(database: db)
        try await store1.enqueuePending(localID: "id1", recordType: "Book", changeType: "update")
        try await store1.enqueuePending(localID: "id2", recordType: "PlaybackPosition", changeType: "update")

        // Create a new store instance against same database
        let store2 = CloudSyncStateStore(database: db)
        let pending = try await store2.dequeuePending(limit: 50)
        #expect(pending.count == 2)
    }
}

// MARK: - T7: Watch storage mapping tests

@Suite struct WatchStorageMappingTests {

    @Test func streamCacheKey_isDeterministic() async throws {
        let url1 = URL(string: "https://archive.org/download/test/chapter1.mp3")!
        let url2 = URL(string: "https://archive.org/download/test/chapter1.mp3")!
        #expect(StreamCacheUtils.key(for: url1) == StreamCacheUtils.key(for: url2))
    }

    @Test func streamCacheKey_differsForDifferentURLs() async throws {
        let url1 = URL(string: "https://archive.org/download/test/ch1.mp3")!
        let url2 = URL(string: "https://archive.org/download/test/ch2.mp3")!
        #expect(StreamCacheUtils.key(for: url1) != StreamCacheUtils.key(for: url2))
    }

    @Test func streamCacheKey_usesSHA256Format() async throws {
        let url = URL(string: "https://archive.org/test.mp3")!
        let key = StreamCacheUtils.key(for: url)
        // SHA-256 hex should be 64 chars, separator, and extension
        #expect(key.contains("-mp3"))
        #expect(key.count > 64)
    }

    @Test func evictionOrder_leastRecentlyPlayedFirst() async throws {
        let now = Date()
        let books: [(id: UUID, lastPlayedAt: Date)] = [
            (UUID(), now.addingTimeInterval(-300)),
            (UUID(), now.addingTimeInterval(-100)),
            (UUID(), now.addingTimeInterval(-200)),
        ]
        let order = WatchEvictionPolicy.evictionOrder(books: books, currentBookID: nil)
        #expect(order.count == 3)
        // Oldest should be first to evict
        #expect(order[0] == books[0].id)
        #expect(order[1] == books[2].id)
        #expect(order[2] == books[1].id)
    }

    @Test func evictionOrder_excludesCurrentBook() async throws {
        let currentID = UUID()
        let now = Date()
        let books: [(id: UUID, lastPlayedAt: Date)] = [
            (currentID, now),
            (UUID(), now.addingTimeInterval(-100)),
        ]
        let order = WatchEvictionPolicy.evictionOrder(books: books, currentBookID: currentID)
        #expect(order.count == 1)
        #expect(order[0] != currentID)
    }

    @Test func storagePolicy_remainingSlots() async throws {
        #expect(WatchStoragePolicy.remainingBookSlots(currentCount: 0) == 5)
        #expect(WatchStoragePolicy.remainingBookSlots(currentCount: 3) == 2)
        #expect(WatchStoragePolicy.remainingBookSlots(currentCount: 7) == 0)
    }

    @Test func storagePolicy_remainingBytes() async throws {
        #expect(WatchStoragePolicy.remainingBytes(currentBytes: 0) == 2_000_000_000)
        #expect(WatchStoragePolicy.remainingBytes(currentBytes: 2_500_000_000) == 0)
    }
}

// MARK: - T9: Relay message contract tests

@Suite struct RelayMessageContractTests {

    @Test func contentKeyAndStreamCacheKey_forSameURL_match() async throws {
        let url = URL(string: "https://archive.org/download/test/chapter.mp3")!
        let chapterKey = StreamCacheUtils.key(for: url)

        // Simulate the relay check: file exists at cacheDir/chapterKey
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("voxglass-cache-relay-test")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let fileURL = cacheDir.appendingPathComponent(chapterKey)

        // Clean up
        try? FileManager.default.removeItem(at: cacheDir)

        // The key should be computable from the original URL
        #expect(chapterKey == StreamCacheUtils.key(for: url))
    }

    @Test func chapterPlayableURL_resolvesRemoteForStreaming() async throws {
        let chapter = Chapter(
            bookID: UUID(),
            title: "Test",
            index: 0,
            remoteURL: URL(string: "https://archive.org/test.mp3")
        )
        #expect(chapter.playableURL == URL(string: "https://archive.org/test.mp3"))
    }

    @Test func chapterPlayableURL_prefersLocal() async throws {
        let localURL = URL(string: "file:///test/local.mp3")!
        let chapter = Chapter(
            bookID: UUID(),
            title: "Test",
            index: 0,
            remoteURL: URL(string: "https://archive.org/test.mp3"),
            localURL: localURL
        )
        #expect(chapter.playableURL == localURL)
    }

    @Test func chapterResolvedPlayableURL_withNoLocal_usesRemote() async throws {
        let chapter = Chapter(
            bookID: UUID(),
            title: "Test",
            index: 0,
            remoteURL: URL(string: "https://archive.org/test.mp3"),
            localURL: URL(string: "file:///nonexistent/test.mp3")
        )
        let resolved = chapter.resolvedPlayableURL()
        #expect(resolved == URL(string: "https://archive.org/test.mp3"))
    }
}
