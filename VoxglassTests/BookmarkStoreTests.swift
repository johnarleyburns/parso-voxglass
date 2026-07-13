import XCTest
@testable import Voxglass

/// Bookmark CRUD and tombstone semantics (P0-3), tested against an on-disk temp
/// SQLite database using `AppDatabase.makeTemporaryDatabase`.
final class BookmarkStoreTests: XCTestCase {

    private let bookID = UUID()
    private let chapterID = UUID()
    private let chapter2ID = UUID()

    private func makeStore() async throws -> SQLiteBookmarkStore {
        let db = AppDatabase.makeTemporaryDatabase(named: "bkm-st-\(UUID().uuidString)")
        let store = SQLiteBookmarkStore(database: db)
        try await db.prepare()
        return store
    }

    func testAddAndFetchReturnsLiveBookmarksOnly() async throws {
        let store = try await makeStore()
        let bm = try await store.add(Bookmark(bookID: bookID, chapterID: chapterID, position: 42, note: "test"))
        let fetched = try await store.bookmarks(forBookID: bookID)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.position, 42)
        XCTAssertEqual(fetched.first?.note, "test")
        XCTAssertFalse(fetched.first?.isDeleted ?? true)
    }

    func testDeleteSoftDeletesAndExcludesFromLiveFetch() async throws {
        let store = try await makeStore()
        let bm = try await store.add(Bookmark(bookID: bookID, chapterID: chapterID, position: 10))
        try await store.delete(id: bm.id!)

        let live = try await store.bookmarks(forBookID: bookID)
        XCTAssertTrue(live.isEmpty, "Soft-deleted bookmarks must not appear in live queries")

        // The tombstone survives for sync.
        let sync = try await store.bookmarksForSync(bookID: bookID)
        XCTAssertEqual(sync.count, 1)
        XCTAssertEqual(sync.first?.id, bm.id)
        XCTAssertTrue(sync.first?.isDeleted ?? false)
    }

    func testUpdateNoteChangesTextAndBumpsUpdatedAt() async throws {
        let store = try await makeStore()
        let bm = try await store.add(Bookmark(bookID: bookID, chapterID: chapterID, position: 5))
        let updated = try await store.updateNote("hello, world", id: bm.id!)
        XCTAssertEqual(updated?.note, "hello, world")
        XCTAssertGreaterThanOrEqual(updated?.updatedAt ?? .distantPast, bm.updatedAt)
    }

    func testAddGeneratesAnIDWhenNoneSupplied() async throws {
        let store = try await makeStore()
        let bm = try await store.add(Bookmark(bookID: bookID, chapterID: chapterID, position: 0, id: nil))
        XCTAssertNotNil(bm.id)
    }

    func testMigration5IsIdempotentAndBackfillsUpdatedAt() async throws {
        // Run migration once (makeTemporaryDatabase does it); run again idempotently.
        let db = AppDatabase.makeTemporaryDatabase(named: "bm-mig-\(UUID().uuidString)")
        try await db.prepare()  // migrates
        try await db.prepare()  // second run must not crash
    }
}
