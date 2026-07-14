import XCTest
@testable import Voxglass

@MainActor
final class CloudSyncEntitlementTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Self.clearCloudSyncKeys()
    }

    override func tearDown() {
        EntitlementCache.shared.setTestEntitlement(nil)
        Self.clearCloudSyncKeys()
        super.tearDown()
    }

    /// `NSUbiquitousKeyValueStore.default` persists to disk on the simulator, so a
    /// prior run's `lastSync`/payload keys leak into the next unless cleared.
    static func clearCloudSyncKeys() {
        let store = NSUbiquitousKeyValueStore.default
        for key in store.dictionaryRepresentation.keys where key.hasPrefix("voxglass.cloudsync.") {
            store.removeObject(forKey: key)
        }
        store.synchronize()
    }

    // MARK: - Entitlements file (the "proper entitlements" ask, §1)

    func testEntitlementsFileExistsAndDeclaresUbiquityKVStore() throws {
        // `#filePath` resolves to the compile-time repo path, which the iOS
        // simulator can read from the host filesystem — mirroring the intent of
        // `HomeViewTests.testInfoPlistDeclaresBackgroundAudioMode`.
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let entitlements = repoRoot
            .appendingPathComponent("Voxglass/Resources/Voxglass.entitlements")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: entitlements.path),
            "Voxglass.entitlements must be committed at Voxglass/Resources/"
        )
        let contents = try String(contentsOf: entitlements, encoding: .utf8)
        XCTAssertTrue(
            contents.contains("com.apple.developer.ubiquity-kvstore-identifier"),
            "Entitlements must declare the iCloud key-value-store identifier"
        )
    }

    // MARK: - sync() gating

    func testSyncEarlyReturnsWhenNotEntitled() async {
        let database = AppDatabase.makeTemporaryDatabase(named: "cloudsync-not-entitled")
        let sync = VoxglassCloudSync(database: database)
        sync.testForceAvailable = true
        EntitlementCache.shared.setTestEntitlement(false)

        await sync.sync()

        XCTAssertFalse(sync.isSyncing)
        XCTAssertNil(sync.lastSyncDate, "Not-Pro sync must not push or stamp a sync date")
    }

    func testSyncEarlyReturnsWhenUnavailable() async {
        let database = AppDatabase.makeTemporaryDatabase(named: "cloudsync-unavailable")
        let sync = VoxglassCloudSync(database: database)
        sync.testForceAvailable = false
        EntitlementCache.shared.setTestEntitlement(true)

        await sync.sync()

        XCTAssertFalse(sync.isSyncing)
    }

    func testSyncPushesPlaybackPositionsWhenEntitledAndAvailable() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "cloudsync-roundtrip")
        try await database.prepare()

        // Seed a source, book, chapter, and a playback position to push.
        let sourceID = UUID(), bookID = UUID(), chapterID = UUID()
        let now = Date().timeIntervalSince1970
        try await database.execute(
            "INSERT INTO sources (id, kind, title, url, created_at) VALUES (?, ?, ?, ?, ?)",
            [.string(sourceID.uuidString), .string(SourceKind.localFiles.rawValue), .string("S"), .null, .double(now)]
        )
        try await database.execute("""
        INSERT INTO books (id, title, authors_json, summary, source_id, cover_url, created_at, updated_at, is_favorite)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .string(bookID.uuidString), .string("Book"), .string("[]"), .null,
            .string(sourceID.uuidString), .null, .double(now), .double(now), .bool(false)
        ])
        try await database.execute("""
        INSERT INTO chapters (id, book_id, title, sort_key, chapter_index, duration_seconds, remote_url, local_url)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .string(chapterID.uuidString), .string(bookID.uuidString), .string("Ch"), .string("Ch"),
            .int(0), .double(120), .null, .null
        ])

        let positionStore = SQLitePositionStore(database: database)
        try await positionStore.save(PlaybackPosition(
            bookID: bookID, chapterID: chapterID, position: 42, duration: 120,
            updatedAt: Date()
        ))

        let sync = VoxglassCloudSync(database: database)
        sync.testForceAvailable = true
        EntitlementCache.shared.setTestEntitlement(true)

        await sync.sync()

        XCTAssertNotNil(sync.lastSyncDate, "An entitled, available sync must stamp lastSyncDate after a push")
    }

    // MARK: - Free position sync (Phase 3)

    func testPositionSyncRunsWithoutProEntitlement() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "pos-free-\(UUID().uuidString)")
        let ids = try await seedBook(in: database)
        let positionStore = SQLitePositionStore(database: database)
        try await positionStore.save(PlaybackPosition(
            bookID: ids.bookID, chapterID: ids.chapterID, position: 55, duration: 120, updatedAt: Date()
        ))

        let sync = VoxglassCloudSync(database: database)
        sync.testForceAvailable = true
        EntitlementCache.shared.setTestEntitlement(false)

        await sync.sync()

        XCTAssertNotNil(sync.lastSyncDate,
                        "Playback-position sync must run for free users — never lose your place is not an upsell")
    }

    func testCloudPullResolvesForeignBookIDsViaContentKey() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "pos-foreign-\(UUID().uuidString)")
        let ids = try await seedBook(
            in: database,
            bookContentKey: "ia:foreign_book",
            chapterContentKey: "foreign-chapter-01"
        )
        EntitlementCache.shared.setTestEntitlement(false)

        // A payload from another install: raw UUIDs that do NOT exist locally, but
        // content keys that match. On today's tree this FK-throws / drops the row.
        let store = NSUbiquitousKeyValueStore.default
        let payload: [String: Any] = [
            "book_id": UUID().uuidString,
            "chapter_id": UUID().uuidString,
            "book_content_key": "ia:foreign_book",
            "chapter_content_key": "foreign-chapter-01",
            "position_seconds": 88.0,
            "duration_seconds": 120.0,
            "updated_at": Date().timeIntervalSince1970,
            "is_finished": false
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        store.set(data, forKey: "voxglass.cloudsync.pos.\(UUID().uuidString)")
        store.synchronize()

        let sync = VoxglassCloudSync(database: database)
        sync.testForceAvailable = true
        await sync.pullPlaybackPositions()

        let positionStore = SQLitePositionStore(database: database)
        let resolved = try await positionStore.position(for: ids.bookID, chapterID: ids.chapterID)
        XCTAssertEqual(resolved?.position ?? -1, 88, accuracy: 0.001,
                       "Foreign UUIDs must resolve to local ids via content key and upsert")
    }

    func testImportAdoptsCloudPositionForMatchingContentKey() async throws {
        // The reinstall scenario: the cloud position exists, then the book is
        // (re-)imported and its position is adopted by content key.
        let database = AppDatabase.makeTemporaryDatabase(named: "pos-adopt-\(UUID().uuidString)")
        let ids = try await seedBook(
            in: database,
            bookContentKey: "ia:reinstalled_book",
            chapterContentKey: "reinstalled-chapter-01"
        )
        EntitlementCache.shared.setTestEntitlement(false)

        let store = NSUbiquitousKeyValueStore.default
        let payload: [String: Any] = [
            "book_id": UUID().uuidString,
            "chapter_id": UUID().uuidString,
            "book_content_key": "ia:reinstalled_book",
            "chapter_content_key": "reinstalled-chapter-01",
            "position_seconds": 314.0,
            "duration_seconds": 600.0,
            "updated_at": Date().timeIntervalSince1970,
            "is_finished": false
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        store.set(data, forKey: "voxglass.cloudsync.pos.\(UUID().uuidString)")
        store.synchronize()

        let sync = VoxglassCloudSync(database: database)
        sync.testForceAvailable = true
        await sync.adoptCloudPositions(forBookID: ids.bookID)

        let positionStore = SQLitePositionStore(database: database)
        let adopted = try await positionStore.position(for: ids.bookID, chapterID: ids.chapterID)
        XCTAssertEqual(adopted?.position ?? -1, 314, accuracy: 0.001,
                       "Re-importing a book must adopt its stored cloud position — delete-and-reinstall works")
    }

    @discardableResult
    private func seedBook(
        in database: AppDatabase,
        bookContentKey: String? = nil,
        chapterContentKey: String? = nil
    ) async throws -> (sourceID: UUID, bookID: UUID, chapterID: UUID) {
        try await database.prepare()
        let sourceID = UUID(), bookID = UUID(), chapterID = UUID()
        let now = Date().timeIntervalSince1970
        try await database.execute(
            "INSERT INTO sources (id, kind, title, url, created_at) VALUES (?, ?, ?, ?, ?)",
            [.string(sourceID.uuidString), .string(SourceKind.librivox.rawValue), .string("S"), .null, .double(now)]
        )
        try await database.execute("""
        INSERT INTO books (id, title, authors_json, summary, source_id, cover_url, created_at, updated_at, is_favorite, content_key)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .string(bookID.uuidString), .string("Book"), .string("[]"), .null,
            .string(sourceID.uuidString), .null, .double(now), .double(now), .bool(false),
            bookContentKey.map { .string($0) } ?? .null
        ])
        try await database.execute("""
        INSERT INTO chapters (id, book_id, title, sort_key, chapter_index, duration_seconds, remote_url, local_url, content_key)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .string(chapterID.uuidString), .string(bookID.uuidString), .string("Ch"), .string("Ch"),
            .int(0), .double(120), .null, .null,
            chapterContentKey.map { .string($0) } ?? .null
        ])
        return (sourceID, bookID, chapterID)
    }
}
