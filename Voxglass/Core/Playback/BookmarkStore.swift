import Foundation

public protocol BookmarkStore: Sendable {
    func add(_ bookmark: Bookmark) async throws -> Bookmark
    func bookmarks(forBookID: UUID) async throws -> [Bookmark]
    func allBookmarks() async throws -> [Bookmark]
    /// Soft-deletes by setting `is_deleted = 1` and bumping `updated_at`, so a
    /// later re-import can distinguish a deletion from a bookmark that never
    /// existed.
    func delete(id: UUID) async throws
    func updateNote(_ note: String, id: UUID) async throws -> Bookmark?
}

public struct SQLiteBookmarkStore: BookmarkStore {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func add(_ bookmark: Bookmark) async throws -> Bookmark {
        try await database.prepare()
        var b = bookmark
        if b.id == nil {
            b.id = .init()
        }
        let now = Date()
        try await database.execute("""
        INSERT INTO bookmarks (id, book_id, chapter_id, position_seconds, note, created_at, updated_at, is_deleted)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .string(b.id!.uuidString),
            .string(b.bookID.uuidString),
            .string(b.chapterID.uuidString),
            .double(b.position),
            .string(b.note ?? ""),
            .double(b.createdAt.timeIntervalSince1970),
            .double(now.timeIntervalSince1970),
            .bool(false)
        ])
        return Bookmark(id: b.id!, bookID: b.bookID, chapterID: b.chapterID,
                         position: b.position, note: b.note,
                         createdAt: b.createdAt, updatedAt: now, isDeleted: false)
    }

    public func bookmarks(forBookID bookID: UUID) async throws -> [Bookmark] {
        try await database.prepare()
        return try await database.query("""
        SELECT id, book_id, chapter_id, position_seconds, note, created_at, updated_at, is_deleted
        FROM bookmarks WHERE book_id = ? AND is_deleted = 0 ORDER BY created_at DESC
        """, [.string(bookID.uuidString)]).map(Self.rowToBookmark)
    }

    public func allBookmarks() async throws -> [Bookmark] {
        try await database.prepare()
        return try await database.query("""
        SELECT id, book_id, chapter_id, position_seconds, note, created_at, updated_at, is_deleted
        FROM bookmarks ORDER BY created_at DESC
        """).map(Self.rowToBookmark)
    }

    public func delete(id: UUID) async throws {
        try await database.prepare()
        try await database.execute("""
        UPDATE bookmarks SET is_deleted = 1, updated_at = ? WHERE id = ?
        """, [.double(Date().timeIntervalSince1970), .string(id.uuidString)])
    }

    public func updateNote(_ note: String, id: UUID) async throws -> Bookmark? {
        try await database.prepare()
        try await database.execute("""
        UPDATE bookmarks SET note = ?, updated_at = ? WHERE id = ? AND is_deleted = 0
        """, [.string(note), .double(Date().timeIntervalSince1970), .string(id.uuidString)])
        let rows = try await database.query("""
        SELECT id, book_id, chapter_id, position_seconds, note, created_at, updated_at, is_deleted
        FROM bookmarks WHERE id = ? LIMIT 1
        """, [.string(id.uuidString)])
        return try rows.first.map(Self.rowToBookmark)
    }

    private static func rowToBookmark(_ row: DatabaseRow) throws -> Bookmark {
        Bookmark(
            id: UUID(uuidString: try row.requiredString("id")),
            bookID: try ModelMapping.uuid(row, "book_id"),
            chapterID: try ModelMapping.uuid(row, "chapter_id"),
            position: row.double("position_seconds") ?? 0,
            note: row.string("note"),
            createdAt: Date(timeIntervalSince1970: row.double("created_at") ?? 0),
            updatedAt: Date(timeIntervalSince1970: row.double("updated_at") ?? 0),
            isDeleted: row.bool("is_deleted") ?? false
        )
    }
}
