import XCTest
@testable import VoxglassCore

/// Phase 2 — survive the crash and the force-quit. The per-book snapshot map and
/// the durable-store tie-break are asserted directly (radio's I4, ported).
@MainActor
final class PositionDurabilityTests: XCTestCase {

    private func makeSnapshotStore() -> LastPlaybackSnapshotStore {
        LastPlaybackSnapshotStore(defaults: UserDefaults(suiteName: "durability-\(UUID().uuidString)")!)
    }

    func testSnapshotStoreKeepsAPositionPerBook() {
        let store = makeSnapshotStore()
        let bookA = UUID(), bookB = UUID()
        let posA = PlaybackPosition(bookID: bookA, chapterID: UUID(), position: 30, updatedAt: Date(timeIntervalSince1970: 100))
        let posB = PlaybackPosition(bookID: bookB, chapterID: UUID(), position: 90, updatedAt: Date(timeIntervalSince1970: 200))

        store.save(posA)
        store.save(posB)

        XCTAssertEqual(store.position(forBookID: bookA)?.position ?? -1, 30, accuracy: 0.001,
                       "Switching books must not discard the other book's snapshot")
        XCTAssertEqual(store.position(forBookID: bookB)?.position ?? -1, 90, accuracy: 0.001)
        XCTAssertEqual(store.latest()?.bookID, bookB)
    }

    func testSnapshotStoreCapsAtFifty() {
        let store = makeSnapshotStore()
        for i in 0..<60 {
            store.save(PlaybackPosition(
                bookID: UUID(), chapterID: UUID(), position: Double(i),
                updatedAt: Date(timeIntervalSince1970: Double(i))
            ))
        }
        XCTAssertLessThanOrEqual(store.all().count, LastPlaybackSnapshotStore.maxSnapshots)
    }

    func testRestorePrefersDurableSnapshotOverStaleDatabaseRow() {
        // DB row @ 40 s, UserDefaults snapshot @ 137 s for the same (book, chapter):
        // the durable snapshot wins even though a lost SQLite write is why it is
        // ahead. Radio's I4 test, ported.
        let bookID = UUID(), chapterID = UUID()
        let row = PlaybackPosition(bookID: bookID, chapterID: chapterID, position: 40, updatedAt: Date(timeIntervalSince1970: 300))
        let snapshot = PlaybackPosition(bookID: bookID, chapterID: chapterID, position: 137, updatedAt: Date(timeIntervalSince1970: 100))

        XCTAssertTrue(PlaybackCoordinator.snapshotWins(row: row, snapshot: snapshot),
                      "The durable snapshot must beat the stale DB position even when the row's timestamp is newer")
        let preferred = PlaybackCoordinator.preferredPosition(row: row, snapshot: snapshot)
        XCTAssertEqual(preferred?.position ?? -1, 137, accuracy: 0.001)
    }

    func testNewerDatabaseRowBeatsOlderSnapshotWithinEpsilon() {
        let bookID = UUID(), chapterID = UUID()
        let row = PlaybackPosition(bookID: bookID, chapterID: chapterID, position: 100, updatedAt: Date(timeIntervalSince1970: 300))
        let snapshot = PlaybackPosition(bookID: bookID, chapterID: chapterID, position: 99, updatedAt: Date(timeIntervalSince1970: 100))
        XCTAssertFalse(PlaybackCoordinator.snapshotWins(row: row, snapshot: snapshot))
        XCTAssertEqual(PlaybackCoordinator.preferredPosition(row: row, snapshot: snapshot)?.position ?? -1, 100, accuracy: 0.001)
    }

    func testReconcileReplaysSnapshotsIntoDatabaseOnLaunch() async throws {
        let db = AppDatabase.makeTemporaryDatabase(named: "reconcile-\(UUID().uuidString)")
        let store = SQLitePositionStore(database: db)
        let defaults = UserDefaults(suiteName: "reconcile-\(UUID().uuidString)")!
        let snapshotStore = LastPlaybackSnapshotStore(defaults: defaults)

        let bookID = UUID(), chapterID = UUID()
        try await seedBook(in: db, bookID: bookID, chapterID: chapterID)

        // DB has a stale row; the snapshot is 137 (a lost SQLite write).
        try await store.save(PlaybackPosition(bookID: bookID, chapterID: chapterID, position: 40, updatedAt: Date(timeIntervalSince1970: 100)))
        snapshotStore.save(PlaybackPosition(bookID: bookID, chapterID: chapterID, position: 137, updatedAt: Date(timeIntervalSince1970: 100)))

        let coordinator = PlaybackCoordinator(
            engine: FakeAudioEngine(),
            positionStore: store,
            snapshotStore: snapshotStore,
            rateStore: PlaybackRateStore(defaults: defaults)
        )
        await coordinator.reconcileSnapshots()

        let reconciled = try await store.position(for: bookID, chapterID: chapterID)
        XCTAssertEqual(reconciled?.position ?? -1, 137, accuracy: 0.001,
                       "Reconcile must replay the durable snapshot over the stale DB row")
    }

    private func seedBook(in db: AppDatabase, bookID: UUID, chapterID: UUID) async throws {
        let sourceID = UUID()
        let now = Date().timeIntervalSince1970
        try await db.execute(
            "INSERT INTO sources (id, kind, title, url, created_at) VALUES (?, ?, ?, ?, ?)",
            [.string(sourceID.uuidString), .string(SourceKind.localFiles.rawValue), .string("S"), .null, .double(now)]
        )
        try await db.execute("""
        INSERT INTO books (id, title, authors_json, summary, source_id, cover_url, created_at, updated_at, is_favorite)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .string(bookID.uuidString), .string("Book"), .string("[]"), .null,
            .string(sourceID.uuidString), .null, .double(now), .double(now), .bool(false)
        ])
        try await db.execute("""
        INSERT INTO chapters (id, book_id, title, sort_key, chapter_index, duration_seconds, remote_url, local_url)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .string(chapterID.uuidString), .string(bookID.uuidString), .string("Ch"), .string("Ch"),
            .int(0), .double(300), .null, .null
        ])
    }
}
