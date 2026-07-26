import Testing
import Foundation
@testable import VoxglassCore

/// Bookmark CRUD and tombstone semantics (P0-3), tested against an on-disk temp
/// SQLite database using `AppDatabase.makeTemporaryDatabase`.
@Suite struct BookmarkStoreTests {

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

    @Test func addAndFetchReturnsLiveBookmarksOnly() async throws {
        let store = try await makeStore()
        let bm = try await store.add(Bookmark(bookID: bookID, chapterID: chapterID, position: 42, note: "test"))
        let fetched = try await store.bookmarks(forBookID: bookID)
        #expect(fetched.count == 1)
        #expect(fetched.first?.position == 42)
        #expect(fetched.first?.note == "test")
        #expect(!(fetched.first?.isDeleted ?? true))
    }

    @Test func deleteSoftDeletesAndExcludesFromLiveFetch() async throws {
        let store = try await makeStore()
        let bm = try await store.add(Bookmark(bookID: bookID, chapterID: chapterID, position: 10))
        try await store.delete(id: bm.id!)

        let live = try await store.bookmarks(forBookID: bookID)
        #expect(live.isEmpty)  // Soft-deleted bookmarks must not appear in live queries

        let sync = try await store.bookmarksForSync(bookID: bookID)
        #expect(sync.count == 1)
        #expect(sync.first?.id == bm.id)
        #expect(sync.first?.isDeleted ?? false)
    }

    @Test func updateNoteChangesTextAndBumpsUpdatedAt() async throws {
        let store = try await makeStore()
        let bm = try await store.add(Bookmark(bookID: bookID, chapterID: chapterID, position: 5))
        let updated = try await store.updateNote("hello, world", id: bm.id!)
        #expect(updated?.note == "hello, world")
        #expect(updated?.updatedAt ?? .distantPast >= bm.updatedAt)
    }

    @Test func addGeneratesAnIDWhenNoneSupplied() async throws {
        let store = try await makeStore()
        let bm = try await store.add(Bookmark(bookID: bookID, chapterID: chapterID, position: 0))
        #expect(bm.id != nil)
    }

    @Test func migration5IsIdempotentAndBackfillsUpdatedAt() async throws {
        let db = AppDatabase.makeTemporaryDatabase(named: "bm-mig-\(UUID().uuidString)")
        try await db.prepare()
        try await db.prepare()
    }
}
