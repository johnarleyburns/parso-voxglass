import Testing
import Foundation
@testable import VoxglassCore

/// Tests for the iCloud Sync enable/disable toggle added in Phase 3.
@MainActor
@Suite(.serialized) struct CloudSyncToggleTests {

    private let enabledKey = AppPreferencesStore.Keys.iCloudSyncEnabled

    init() {UserDefaults.standard.removeObject(forKey: enabledKey)
    }

    @Test func defaultIsEnabled() {
        let database = AppDatabase.makeTemporaryDatabase(named: "sync-default-on")
        let cloudSync = VoxglassCloudSync(database: database)
        #expect(cloudSync.isEnabled)  // iCloud sync must default to enabled for existing users
    }

    @Test func disablingStopsSync() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "sync-disabled")
        try await database.prepare()

        let cloudSync = VoxglassCloudSync(database: database)
        cloudSync.testForceAvailable = true
        cloudSync.isEnabled = false

        // With isEnabled = false, sync() should be a no-op.
        await cloudSync.sync()
        #expect(cloudSync.lastSyncDate == nil)  // sync() should not set lastSyncDate when disabled
        #expect(!(cloudSync.isSyncing))

        // pushPlaybackPositions should also be a no-op.
        await cloudSync.pushPlaybackPositions()
        #expect(cloudSync.lastSyncDate == nil)  // pushPlaybackPositions should not write when disabled
    }

    @Test func reenablingTriggersSync() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "sync-reenable")
        try await database.prepare()

        let cloudSync = VoxglassCloudSync(database: database)
        cloudSync.testForceAvailable = true

        // Seed data while sync is on.
        cloudSync.isEnabled = true

        let sourceID = UUID()
        try await database.execute("""
        INSERT INTO sources (id, kind, title, created_at)
        VALUES (?, ?, ?, ?)
        """, [
            .string(sourceID.uuidString),
            .string(SourceKind.librivox.rawValue),
            .string("Sync Test Source"),
            .double(Date().timeIntervalSince1970)
        ])

        let bookID = UUID()
        let chapterID = UUID()
        let now = Date().timeIntervalSince1970
        let contentKey = "librivox:test-sync-\(UUID().uuidString)"
        try await database.execute("""
        INSERT INTO books (id, title, authors_json, source_id, created_at, updated_at, content_key)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """, [
            .string(bookID.uuidString),
            .string("Sync Test Book"),
            .string("[]"),
            .string(sourceID.uuidString),
            .double(now),
            .double(now),
            .string(contentKey)
        ])
        try await database.execute("""
        INSERT INTO chapters (id, book_id, title, sort_key, chapter_index, remote_url, content_key)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """, [
            .string(chapterID.uuidString),
            .string(bookID.uuidString),
            .string("Chapter 1"),
            .string("Chapter 1"),
            .int(0),
            .string("https://archive.org/test.mp3"),
            .string("librivox:chapter-\(UUID().uuidString)")
        ])
        try await database.execute("""
        INSERT INTO playback_positions (id, book_id, chapter_id, position_seconds, updated_at)
        VALUES (?, ?, ?, ?, ?)
        """, [
            .string(UUID().uuidString),
            .string(bookID.uuidString),
            .string(chapterID.uuidString),
            .double(30),
            .double(now + 1000)
        ])

        await cloudSync.pushPlaybackPositions()

        // Verify lastSyncDate is set (push succeeded).
        #expect(cloudSync.lastSyncDate != nil)  // pushPlaybackPositions should set lastSyncDate when enabled
    }

    private func seedTwoChapterBook(
        _ database: AppDatabase
    ) async throws -> (bookID: UUID, chapter1: UUID, chapter2: UUID) {
        let sourceID = UUID(), bookID = UUID(), chapter1 = UUID(), chapter2 = UUID()
        let now = Date().timeIntervalSince1970
        try await database.execute(
            "INSERT INTO sources (id, kind, title, created_at) VALUES (?, ?, ?, ?)",
            [.string(sourceID.uuidString), .string(SourceKind.librivox.rawValue), .string("Source"), .double(now)]
        )
        try await database.execute("""
        INSERT INTO books (id, title, authors_json, source_id, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """, [.string(bookID.uuidString), .string("Book"), .string("[]"), .string(sourceID.uuidString), .double(now), .double(now)])
        try await database.execute("""
        INSERT INTO chapters (id, book_id, title, sort_key, chapter_index, duration_seconds)
        VALUES (?, ?, ?, ?, ?, ?)
        """, [.string(chapter1.uuidString), .string(bookID.uuidString), .string("Ch1"), .string("1"), .int(0), .double(300)])
        try await database.execute("""
        INSERT INTO chapters (id, book_id, title, sort_key, chapter_index, duration_seconds)
        VALUES (?, ?, ?, ?, ?, ?)
        """, [.string(chapter2.uuidString), .string(bookID.uuidString), .string("Ch2"), .string("2"), .int(1), .double(300)])
        return (bookID, chapter1, chapter2)
    }

    @Test func applyCloudPositionRefusesEarlierChapterThatWouldRegressBookProgress() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "sync-regress-\(UUID().uuidString)")
        try await database.prepare()
        let cloudSync = VoxglassCloudSync(database: database)
        cloudSync.testForceAvailable = true
        let (bookID, chapter1, chapter2) = try await seedTwoChapterBook(database)

        // The user has already progressed to chapter 2, saved durably at t=200.
        try await database.execute(
            "INSERT INTO playback_positions (id, book_id, chapter_id, position_seconds, updated_at) VALUES (?, ?, ?, ?, ?)",
            [.string(UUID().uuidString), .string(bookID.uuidString), .string(chapter2.uuidString), .double(500), .double(200)]
        )

        // A stale cloud payload for chapter 1 arrives stamped after the real progress.
        let staleChapter1Payload: [String: Any] = [
            "book_id": bookID.uuidString,
            "chapter_id": chapter1.uuidString,
            "position_seconds": 30.0,
            "updated_at": 300.0,
            "is_finished": false
        ]
        let applied = await cloudSync.applyCloudPosition(staleChapter1Payload)
        #expect(!applied)  // Must refuse: chapter 1 is behind the book's furthest known chapter 2

        let chapter1Rows = try await database.query(
            "SELECT id FROM playback_positions WHERE book_id = ? AND chapter_id = ?",
            [.string(bookID.uuidString), .string(chapter1.uuidString)]
        )
        #expect(chapter1Rows.isEmpty)  // No row must be created for the regressed chapter

        let chapter2Row = try await database.query(
            "SELECT position_seconds FROM playback_positions WHERE book_id = ? AND chapter_id = ?",
            [.string(bookID.uuidString), .string(chapter2.uuidString)]
        )
        #expect(abs((chapter2Row.first?.double("position_seconds") ?? -1) - 500) <= 0.001)
    }

    @Test func applyCloudPositionStillAcceptsGenuineForwardProgress() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "sync-advance-\(UUID().uuidString)")
        try await database.prepare()
        let cloudSync = VoxglassCloudSync(database: database)
        cloudSync.testForceAvailable = true
        let (bookID, chapter1, chapter2) = try await seedTwoChapterBook(database)
        try await database.execute(
            "INSERT INTO playback_positions (id, book_id, chapter_id, position_seconds, updated_at) VALUES (?, ?, ?, ?, ?)",
            [.string(UUID().uuidString), .string(bookID.uuidString), .string(chapter1.uuidString), .double(290), .double(100)]
        )

        let advancePayload: [String: Any] = [
            "book_id": bookID.uuidString,
            "chapter_id": chapter2.uuidString,
            "position_seconds": 15.0,
            "updated_at": 200.0,
            "is_finished": false
        ]
        let applied = await cloudSync.applyCloudPosition(advancePayload)
        #expect(applied)  // A later chapter must still be accepted as forward progress

        let chapter2Row = try await database.query(
            "SELECT position_seconds FROM playback_positions WHERE book_id = ? AND chapter_id = ?",
            [.string(bookID.uuidString), .string(chapter2.uuidString)]
        )
        #expect(abs((chapter2Row.first?.double("position_seconds") ?? -1) - 15) <= 0.001)
    }
}
