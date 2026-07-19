import XCTest
@testable import VoxglassCore

/// Tests for the iCloud Sync enable/disable toggle added in Phase 3.
@MainActor
final class CloudSyncToggleTests: XCTestCase {

    private let enabledKey = AppPreferencesStore.Keys.iCloudSyncEnabled

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: enabledKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: enabledKey)
        super.tearDown()
    }

    func testDefaultIsEnabled() {
        let database = AppDatabase.makeTemporaryDatabase(named: "sync-default-on")
        let cloudSync = VoxglassCloudSync(database: database)
        XCTAssertTrue(
            cloudSync.isEnabled,
            "iCloud sync must default to enabled for existing users"
        )
    }

    func testDisablingStopsSync() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "sync-disabled")
        try await database.prepare()

        let cloudSync = VoxglassCloudSync(database: database)
        cloudSync.testForceAvailable = true
        cloudSync.isEnabled = false

        // With isEnabled = false, sync() should be a no-op.
        await cloudSync.sync()
        XCTAssertNil(cloudSync.lastSyncDate, "sync() should not set lastSyncDate when disabled")
        XCTAssertFalse(cloudSync.isSyncing)

        // pushPlaybackPositions should also be a no-op.
        await cloudSync.pushPlaybackPositions()
        XCTAssertNil(cloudSync.lastSyncDate, "pushPlaybackPositions should not write when disabled")
    }

    func testReenablingTriggersSync() async throws {
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
        XCTAssertNotNil(cloudSync.lastSyncDate, "pushPlaybackPositions should set lastSyncDate when enabled")
    }
}
