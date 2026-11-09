import Testing
import Foundation
import CloudKit
@testable import VoxglassCore

private struct PlainResolver: LocalMediaFileResolver {
    func resolve(localURL: URL?, bookmark: Data?) -> URL? {
        guard let localURL, FileManager.default.fileExists(atPath: localURL.path) else { return nil }
        return localURL
    }
}

private struct InjectedFault: Error {}

private final class StepCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = 0
    func tick(failAt: Int) throws {
        lock.lock(); defer { lock.unlock() }
        seen += 1
        if seen == failAt { throw InjectedFault() }
    }
}

@Suite(.serialized) struct LocalSyncMigrationTests {
    private let root: URL
    private let db: AppDatabase
    private let state: CloudSyncStateStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lsm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        db = AppDatabase.makeTemporaryDatabase(named: "lsm-\(UUID().uuidString)")
        state = CloudSyncStateStore(database: db)
    }

    private struct Fixture {
        var bookID: String
        var chapterID: String
        var bookmarkID: String
        var positionID: String
        var file: URL
    }

    private func makeBook(fingerprinted: Bool = true, fileExists: Bool = true, bytes: String = "AUDIO") async throws -> Fixture {
        try await db.prepare()
        let dir = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("a.m4b")
        if fileExists { try Data(bytes.utf8).write(to: file) }
        let f = Fixture(bookID: UUID().uuidString, chapterID: UUID().uuidString,
                        bookmarkID: UUID().uuidString, positionID: UUID().uuidString, file: file)
        let sourceID = UUID().uuidString
        try await db.execute("INSERT INTO sources (id, kind, title, url, created_at) VALUES (?, 'localFiles', 'S', NULL, 0)", [.string(sourceID)])
        try await db.execute("INSERT INTO books (id, title, authors_json, source_id, created_at, updated_at, is_favorite, content_key) VALUES (?, 'T', '[]', ?, 0, 0, 1, ?)",
                             [.string(f.bookID), .string(sourceID), .string("local:legacy-\(f.bookID)")])
        try await db.execute("INSERT INTO chapters (id, book_id, title, sort_key, chapter_index, start_time_seconds, duration_seconds, local_url) VALUES (?, ?, 'c', '0000', 0, 0, 60, ?)",
                             [.string(f.chapterID), .string(f.bookID), .string(file.absoluteString)])
        try await db.execute("INSERT INTO bookmarks (id, book_id, chapter_id, position_seconds, note, created_at, updated_at, is_deleted) VALUES (?, ?, ?, 5, 'n', 0, 0, 0)",
                             [.string(f.bookmarkID), .string(f.bookID), .string(f.chapterID)])
        try await db.execute("INSERT INTO playback_positions (id, book_id, chapter_id, position_seconds, duration_seconds, updated_at, is_finished) VALUES (?, ?, ?, 12, 60, 0, 0)",
                             [.string(f.positionID), .string(f.bookID), .string(f.chapterID)])
        if fingerprinted {
            let svc = LocalMediaFingerprintService(database: db, resolver: PlainResolver())
            _ = try await svc.fingerprint(bookID: f.bookID)
        }
        return f
    }

    private func seedLegacyQueue(_ f: Fixture) async throws {
        try await state.enqueuePending(localID: f.bookID, recordType: "Book", changeType: "update")
        try await state.enqueuePending(localID: f.bookmarkID, recordType: "Bookmark", changeType: "update")
        try await state.enqueuePending(localID: f.positionID, recordType: "PlaybackPosition", changeType: "update")
    }

    private func pending() async throws -> Set<String> {
        Set(try await state.dequeuePending(limit: 1000).map { "\($0.recordType):\($0.localID):\($0.changeType)" })
    }

    private func n(_ sql: String) async throws -> Int64 {
        try await db.query(sql).first?.int("n") ?? -1
    }

    @Test func eligibleLegacyBookEnqueuesCanonicalBookBookmarkAndPosition() async throws {
        let f = try await makeBook()
        let plans = try await LocalSyncMigrationCoordinator(database: db).plans()
        let plan = try #require(plans.first)
        #expect(plan.bookID == UUID(uuidString: f.bookID))
        #expect(plan.legacyContentKey == "local:legacy-\(f.bookID)")
        #expect(CloudKitRecordMapper.isPortableLocalContentKey(plan.portableContentKey))
        #expect(Set(plan.mutationsToEnqueue) == [
            SyncMutation(localID: f.bookID, recordType: "Book"),
            SyncMutation(localID: f.bookmarkID, recordType: "Bookmark"),
            SyncMutation(localID: f.positionID, recordType: "PlaybackPosition")])
        try await LocalSyncMigrationCoordinator(database: db).migrate()
        #expect(try await pending() == ["Book:\(f.bookID):update", "Bookmark:\(f.bookmarkID):update", "PlaybackPosition:\(f.positionID):update"])
        let key = try await db.query("SELECT content_key FROM books WHERE id=?", [.string(f.bookID)]).first?.string("content_key")
        #expect(key == plan.portableContentKey)
    }

    @Test func migrationRetainsBookFilesBookmarksPositionsAndFavorite() async throws {
        let f = try await makeBook()
        try await seedLegacyQueue(f)
        try await state.enqueuePending(localID: f.bookID, recordType: "Bookmark", changeType: "update")
        try await LocalSyncMigrationCoordinator(database: db).migrate()
        #expect(FileManager.default.fileExists(atPath: f.file.path))
        #expect(try await n("SELECT COUNT(*) AS n FROM books WHERE is_favorite = 1") == 1)
        #expect(try await n("SELECT COUNT(*) AS n FROM chapters") == 1)
        #expect(try await n("SELECT COUNT(*) AS n FROM bookmarks") == 1)
        #expect(try await n("SELECT COUNT(*) AS n FROM playback_positions") == 1)
        #expect(try await n("SELECT COUNT(*) AS n FROM local_media_fingerprints") == 1)
    }

    @Test func inaccessibleBookLeavesLegacyQueueUntouched() async throws {
        let noFingerprint = try await makeBook(fingerprinted: false)
        let missing = try await makeBook(fileExists: false)
        try await seedLegacyQueue(noFingerprint)
        try await seedLegacyQueue(missing)
        let before = try await pending()
        let report = try await LocalSyncMigrationCoordinator(database: db).migrate()
        #expect(report.migratedBookIDs.isEmpty)
        #expect(try await pending() == before)
        #expect(try await n("SELECT COUNT(*) AS n FROM books WHERE content_key LIKE 'local:legacy-%'") == 2)
    }

    @Test func ambiguousFingerprintIsNotMigrated() async throws {
        _ = try await makeBook(bytes: "SAME")
        _ = try await makeBook(bytes: "SAME")
        let plans = try await LocalSyncMigrationCoordinator(database: db).plans()
        #expect(plans.isEmpty)
    }

    @Test func migrationIsIdempotent() async throws {
        let f = try await makeBook()
        try await seedLegacyQueue(f)
        let coordinator = LocalSyncMigrationCoordinator(database: db)
        try await coordinator.migrate()
        let first = try await pending()
        let key = try await db.query("SELECT content_key FROM books").first?.string("content_key")
        try await coordinator.migrate()
        try await coordinator.migrate()
        #expect(try await pending() == first)
        #expect(try await state.pendingCount() == 3)
        #expect(try await db.query("SELECT content_key FROM books").first?.string("content_key") == key)
    }

    @Test func failedCanonicalEnqueueDoesNotRetireLegacyRow() async throws {
        let f = try await makeBook()
        try await seedLegacyQueue(f)
        try await state.enqueuePending(localID: f.bookID, recordType: "Bookmark", changeType: "update")
        let before = try await pending()
        let counter = StepCounter()
        let faulty = LocalSyncMigrationCoordinator(database: db) { _ in try counter.tick(failAt: 1) }
        await #expect(throws: InjectedFault.self) { try await faulty.migrate() }
        #expect(try await pending() == before)
        #expect(try await db.query("SELECT content_key FROM books").first?.string("content_key") == "local:legacy-\(f.bookID)")
    }

    @Test func faultAfterEveryDurableWriteIsRetriedWithoutLoss() async throws {
        // 3 enqueues + key update + 1 retirement = 5 durable writes.
        for failAt in 1...5 {
            let f = try await makeBook(bytes: "FAULT-\(failAt)")
            try await seedLegacyQueue(f)
            try await state.enqueuePending(localID: f.bookID, recordType: "Bookmark", changeType: "update")
            let counter = StepCounter()
            let faulty = LocalSyncMigrationCoordinator(database: db) { _ in try counter.tick(failAt: failAt) }
            await #expect(throws: InjectedFault.self) { try await faulty.migrate() }
            let afterFault = try await pending()
            for row in ["Book:\(f.bookID):update", "Bookmark:\(f.bookmarkID):update", "PlaybackPosition:\(f.positionID):update"] {
                #expect(afterFault.contains(row))
            }
            try await LocalSyncMigrationCoordinator(database: db).migrate()
            let final = try await pending()
            #expect(!final.contains("Bookmark:\(f.bookID):update"))
            for row in ["Book:\(f.bookID):update", "Bookmark:\(f.bookmarkID):update", "PlaybackPosition:\(f.positionID):update"] {
                #expect(final.contains(row))
            }
            try await db.execute("DELETE FROM pending_sync")
            try await db.execute("DELETE FROM books WHERE id = ?", [.string(f.bookID)])
            try await db.execute("DELETE FROM local_media_fingerprints WHERE book_id = ?", [.string(f.bookID)])
        }
    }

    @Test func onlyProvenReplacedBlockedRowsAreRetired() async throws {
        let f = try await makeBook()
        try await seedLegacyQueue(f)
        try await state.enqueuePending(localID: f.bookID, recordType: "Bookmark", changeType: "update")   // stale
        try await state.enqueuePending(localID: f.bookID, recordType: "PlaybackPosition", changeType: "update") // stale
        try await state.enqueuePending(localID: "unrelated", recordType: "Bookmark", changeType: "update")
        let report = try await LocalSyncMigrationCoordinator(database: db).migrate()
        #expect(Set(report.retiredRows.map(\.recordType)) == ["Bookmark", "PlaybackPosition"])
        let left = try await pending()
        #expect(left.contains("Bookmark:unrelated:update"))
        #expect(left.contains("Bookmark:\(f.bookmarkID):update"))
        #expect(!left.contains("Bookmark:\(f.bookID):update"))
    }

    @Test func migrationNeverCallsClearPending() async throws {
        let sources = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Voxglass/Core/Library/LocalSyncMigration.swift"), encoding: .utf8)
        #expect(!sources.contains("clearPending"))
        #expect(!sources.contains("DELETE FROM pending_sync"))
        // Behavioral: unrelated rows survive a full migration.
        let f = try await makeBook()
        try await seedLegacyQueue(f)
        try await state.enqueuePending(localID: "other", recordType: "Book", changeType: "update")
        try await LocalSyncMigrationCoordinator(database: db).migrate()
        #expect(try await pending().contains("Book:other:update"))
    }

    @Test func remoteAndNonlocalPendingRowsAreUntouched() async throws {
        let f = try await makeBook()
        try await db.execute("INSERT INTO sources (id, kind, title, url, created_at) VALUES ('rs', 'librivox', 'R', 'https://librivox.org/x', 0)")
        try await db.execute("INSERT INTO books (id, title, authors_json, source_id, created_at, updated_at, content_key) VALUES ('remote-book', 'R', '[]', 'rs', 0, 0, 'rk')")
        try await seedLegacyQueue(f)
        try await state.enqueuePending(localID: "remote-book", recordType: "Book", changeType: "update")
        try await state.enqueuePending(localID: "remote-book", recordType: "Book", changeType: "delete")
        try await LocalSyncMigrationCoordinator(database: db).migrate()
        #expect(try await pending().contains("Book:remote-book:delete"))
        #expect(try await db.query("SELECT content_key FROM books WHERE id='remote-book'").first?.string("content_key") == "rk")
    }

    @Test func pendingBookDeleteIsNotOverwrittenByCanonicalUpdate() async throws {
        let f = try await makeBook()
        try await state.enqueuePending(localID: f.bookID, recordType: "Book", changeType: "delete")
        try await LocalSyncMigrationCoordinator(database: db).migrate()
        #expect(try await pending().contains("Book:\(f.bookID):delete"))
    }

    @Test func upgradedBookCanSyncToFreshSecondDatabase() async throws {
        let f = try await makeBook()
        try await seedLegacyQueue(f)
        try await LocalSyncMigrationCoordinator(database: db).migrate()
        let key = try #require(try await db.query("SELECT content_key FROM books").first?.string("content_key"))
        let book = Book(id: UUID(uuidString: f.bookID)!, title: "T", authors: [], sourceID: UUID(), isFavorite: true)
        let chapter = Chapter(id: UUID(uuidString: f.chapterID)!, bookID: book.id, title: "c", index: 0, startTime: 0, duration: 60)
        let record = try #require(CloudKitRecordMapper.portableLocalBookRecord(from: book, chapters: [chapter], contentKey: key))
        #expect(CloudKitRecordMapper.contentKey(from: record) == key)
        let placeholder = try #require(CloudKitRecordMapper.portableLocalPlaceholder(from: record))

        let second = AppDatabase.makeTemporaryDatabase(named: "lsm2-\(UUID().uuidString)")
        let svc = PortableLocalMetadataService(database: second)
        try await svc.retainBook(placeholder)
        #expect(try await svc.unresolvedContentKeys() == [key])
        #expect(try await second.query("SELECT COUNT(*) AS n FROM books").first?.int("n") == 0)
    }
}
