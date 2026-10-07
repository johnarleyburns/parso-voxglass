import Testing
import Foundation
@testable import VoxglassCore

@Suite struct PositionStoreTests {
    @Test func positionRoundTripsThroughSQLite() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "position-round-trip")
        let ids = try await seedBook(in: database)
        let store = SQLitePositionStore(database: database)
        let saved = PlaybackPosition(
            bookID: ids.bookID,
            chapterID: ids.chapterID,
            position: 42.5,
            duration: 300,
            updatedAt: Date(timeIntervalSince1970: 123),
            isFinished: false
        )

        try await store.save(saved)
        let fetchedOptional = try await store.position(for: ids.bookID, chapterID: ids.chapterID)
        let fetched = try try #require(fetchedOptional)

        #expect(fetched.bookID == ids.bookID)
        #expect(fetched.chapterID == ids.chapterID)
        #expect(abs((fetched.position) - (42.5)) <= 0.001)
        #expect(abs((fetched.duration ?? 0) - (300)) <= 0.001)
        #expect(fetched.isFinished == false)
    }

    @Test func latestPositionReturnsMostRecentlyUpdatedRecord() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "latest-position")
        let first = try await seedBook(in: database, title: "First")
        let second = try await seedBook(in: database, title: "Second")
        let store = SQLitePositionStore(database: database)

        try await store.save(PlaybackPosition(
            bookID: first.bookID,
            chapterID: first.chapterID,
            position: 5,
            duration: 10,
            updatedAt: Date(timeIntervalSince1970: 100)
        ))
        try await store.save(PlaybackPosition(
            bookID: second.bookID,
            chapterID: second.chapterID,
            position: 7,
            duration: 10,
            updatedAt: Date(timeIntervalSince1970: 200)
        ))

        let latestOptional = try await store.latestPosition()
        let latest = try try #require(latestOptional)

        #expect(latest.bookID == second.bookID)
        #expect(abs((latest.position) - (7)) <= 0.001)
    }

    @Test func olderPositionCannotOverwriteNewerPosition() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "position-last-writer-wins")
        let ids = try await seedBook(in: database)
        let store = SQLitePositionStore(database: database)

        try await store.save(PlaybackPosition(
            bookID: ids.bookID, chapterID: ids.chapterID, position: 90,
            duration: 300, updatedAt: Date(timeIntervalSince1970: 200)
        ))
        try await store.save(PlaybackPosition(
            bookID: ids.bookID, chapterID: ids.chapterID, position: 12,
            duration: 300, updatedAt: Date(timeIntervalSince1970: 100)
        ))

        let fetchedOptional = try await store.position(for: ids.bookID, chapterID: ids.chapterID)
        let fetched = try try #require(fetchedOptional)
        #expect(abs(fetched.position - 90) <= 0.001)
        #expect(fetched.updatedAt == Date(timeIntervalSince1970: 200))
    }

    @Test func updatingPositionQueuesItsPersistedRecordID() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "position-sync-stable-id")
        let ids = try await seedBook(in: database)
        let stateStore = CloudSyncStateStore(database: database)
        var store = SQLitePositionStore(database: database)
        store.mutationLog = SyncMutationLog(stateStore: stateStore)
        let original = PlaybackPosition(
            bookID: ids.bookID, chapterID: ids.chapterID, position: 10,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        try await store.save(original)
        let persistedOptional = try await store.position(for: ids.bookID, chapterID: ids.chapterID)
        let persisted = try #require(persistedOptional)
        try await stateStore.clearPending()

        let later = PlaybackPosition(
            bookID: ids.bookID, chapterID: ids.chapterID, position: 20,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        try await store.save(later)

        let pending = try await stateStore.dequeuePending(limit: 10)
        #expect(pending.count == 1)
        #expect(pending.first?.localID == persisted.id.uuidString)
        #expect(pending.first?.localID != later.id.uuidString)
    }

    @Test func localHandoffCheckpointDoesNotEchoOverTheNewerCloudPosition() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "position-local-checkpoint")
        let ids = try await seedBook(in: database)
        let stateStore = CloudSyncStateStore(database: database)
        var store = SQLitePositionStore(database: database)
        store.mutationLog = SyncMutationLog(stateStore: stateStore)

        try await store.saveLocalCheckpoint(PlaybackPosition(
            bookID: ids.bookID, chapterID: ids.chapterID, position: 37,
            updatedAt: Date(timeIntervalSince1970: 150)
        ))

        #expect(try await stateStore.pendingCount() == 0)
        let saved = try await store.position(for: ids.bookID, chapterID: ids.chapterID)
        #expect(abs((saved?.position ?? -1) - 37) <= 0.001)
    }

    private func seedBook(
        in database: AppDatabase,
        title: String = "Seed Book"
    ) async throws -> (sourceID: UUID, bookID: UUID, chapterID: UUID) {
        let sourceID = UUID()
        let bookID = UUID()
        let chapterID = UUID()
        let now = Date().timeIntervalSince1970

        try await database.execute("""
        INSERT INTO sources (id, kind, title, url, created_at)
        VALUES (?, ?, ?, ?, ?)
        """, [
            .string(sourceID.uuidString),
            .string(SourceKind.localFiles.rawValue),
            .string("Local Files"),
            .null,
            .double(now)
        ])
        try await database.execute("""
        INSERT INTO books (id, title, authors_json, summary, source_id, cover_url, created_at, updated_at, is_favorite)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .string(bookID.uuidString),
            .string(title),
            .string("[]"),
            .null,
            .string(sourceID.uuidString),
            .null,
            .double(now),
            .double(now),
            .bool(false)
        ])
        try await database.execute("""
        INSERT INTO chapters (id, book_id, title, sort_key, chapter_index, duration_seconds, remote_url, local_url)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .string(chapterID.uuidString),
            .string(bookID.uuidString),
            .string("Chapter 1"),
            .string("Chapter 1"),
            .int(0),
            .double(300),
            .null,
            .string(URL(fileURLWithPath: "/tmp/chapter.mp3").absoluteString)
        ])

        return (sourceID, bookID, chapterID)
    }
}
