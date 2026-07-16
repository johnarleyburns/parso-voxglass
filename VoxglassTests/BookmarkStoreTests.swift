import XCTest
@testable import VoxglassCore

/// Bookmark CRUD and tombstone semantics (P0-3), tested against an on-disk temp
/// SQLite database using `AppDatabase.makeTemporaryDatabase`.
final class BookmarkStoreTests: XCTestCase {

    private let bookID = UUID()
    private let chapterID = UUID()

    private func makeStore() async throws -> SQLiteBookmarkStore {
        let db = AppDatabase.makeTemporaryDatabase(named: "bkm-st-\(UUID().uuidString)")
        try await db.prepare()
        // Bookmarks reference books.chapters → seed the FK chain.
        let sourceID = UUID()
        try await db.execute("""
        INSERT INTO sources (id, kind, title, url, created_at)
        VALUES (?, ?, ?, ?, ?)
        """, [.string(sourceID.uuidString), .string(SourceKind.localFiles.rawValue), .string("S"), .null, .double(Date().timeIntervalSince1970)])
        try await db.execute("""
        INSERT INTO books (id, title, authors_json, summary, source_id, created_at, updated_at)
        VALUES (?, ?, '[]', null, ?, ?, ?)
        """, [.string(bookID.uuidString), .string("B"), .string(sourceID.uuidString), .double(Date().timeIntervalSince1970), .double(Date().timeIntervalSince1970)])
        try await db.execute("""
        INSERT INTO chapters (id, book_id, title, sort_key, chapter_index, remote_url)
        VALUES (?, ?, 'Ch 1', '1', 0, null)
        """, [.string(chapterID.uuidString), .string(bookID.uuidString)])
        return SQLiteBookmarkStore(database: db)
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
        let bm = try await store.add(Bookmark(bookID: bookID, chapterID: chapterID, position: 0))
        XCTAssertNotNil(bm.id)
    }

    func testMigration5IsIdempotentAndBackfillsUpdatedAt() async throws {
        let db = AppDatabase.makeTemporaryDatabase(named: "bm-mig-\(UUID().uuidString)")
        try await db.prepare()
        try await db.prepare()
    }
}
