import Foundation

/// CRUD for playlist shelves (P1-3). Kept separate from `LibraryRepository`
/// (already 590+ lines). No cross-book continuous playback — playlists are
/// shelves: tap a book → normal per-book PlaybackSession.
final class PlaylistRepository {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func create(title: String) async throws -> Playlist {
        try await database.prepare()
        let id = UUID()
        let now = Date()
        try await database.execute("""
        INSERT INTO playlists (id, title, created_at, updated_at)
        VALUES (?, ?, ?, ?)
        """, [.string(id.uuidString), .string(title), .double(now.timeIntervalSince1970), .double(now.timeIntervalSince1970)])
        return Playlist(id: id, title: title, createdAt: now, updatedAt: now)
    }

    func fetchAll() async throws -> [Playlist] {
        try await database.prepare()
        return try await database.query("SELECT id, title, created_at, updated_at FROM playlists ORDER BY updated_at DESC")
            .map { Playlist(
                id: try ModelMapping.uuid($0, "id"),
                title: try $0.requiredString("title"),
                createdAt: Date(timeIntervalSince1970: $0.double("created_at") ?? 0),
                updatedAt: Date(timeIntervalSince1970: $0.double("updated_at") ?? 0)
            )}
    }

    func fetchBooks(for playlistID: UUID) async throws -> [BookWithChapters] {
        try await database.prepare()
        let rows = try await database.query("""
        SELECT pb.book_id, pb.sort_index, b.title, b.authors_json, b.summary, b.source_id, b.cover_url, b.created_at, b.updated_at, b.is_favorite
        FROM playlist_books pb JOIN books b ON pb.book_id = b.id
        WHERE pb.playlist_id = ? ORDER BY pb.sort_index ASC
        """, [.string(playlistID.uuidString)])
        return try rows.map { try LibraryPlaylistBook.book(from: $0) }
    }

    func addBook(_ bookID: UUID, to playlistID: UUID) async throws {
        try await database.prepare()
        let count = try await database.query(
            "SELECT MAX(sort_index) AS max_idx FROM playlist_books WHERE playlist_id = ?",
            [.string(playlistID.uuidString)]
        ).first?.int("max_idx") ?? 0
        try await database.execute("""
        INSERT OR IGNORE INTO playlist_books (playlist_id, book_id, sort_index)
        VALUES (?, ?, ?)
        """, [.string(playlistID.uuidString), .string(bookID.uuidString), .int(count + 1)])
    }

    func removeBook(_ bookID: UUID, from playlistID: UUID) async throws {
        try await database.prepare()
        try await database.execute("""
        DELETE FROM playlist_books WHERE playlist_id = ? AND book_id = ?
        """, [.string(playlistID.uuidString), .string(bookID.uuidString)])
    }

    func rename(_ playlistID: UUID, to title: String) async throws {
        try await database.prepare()
        try await database.execute("""
        UPDATE playlists SET title = ?, updated_at = ? WHERE id = ?
        """, [.string(title), .double(Date().timeIntervalSince1970), .string(playlistID.uuidString)])
    }

    func delete(_ playlistID: UUID) async throws {
        try await database.prepare()
        try await database.execute("DELETE FROM playlists WHERE id = ?", [.string(playlistID.uuidString)])
    }

    /// Reorder: assign sequential 0-based sort_index values so they stay dense and
    /// gap-free after any move.
    func reorder(_ playlistID: UUID, bookIDs: [UUID]) async throws {
        try await database.prepare()
        try await database.execute("DELETE FROM playlist_books WHERE playlist_id = ?", [.string(playlistID.uuidString)])
        for (index, bookID) in bookIDs.enumerated() {
            try await database.execute("""
            INSERT INTO playlist_books (playlist_id, book_id, sort_index)
            VALUES (?, ?, ?)
            """, [.string(playlistID.uuidString), .string(bookID.uuidString), .int(Int64(index))])
        }
    }
}

private enum LibraryPlaylistBook {
    static func book(from row: DatabaseRow) throws -> BookWithChapters {
        let book = Book(
            id: try ModelMapping.uuid(row, "book_id"),
            title: try row.requiredString("title"),
            authors: ModelMapping.authors(from: row),
            summary: row.string("summary"),
            sourceID: try ModelMapping.uuid(row, "source_id"),
            coverURL: ModelMapping.url(row, "cover_url"),
            createdAt: Date(timeIntervalSince1970: row.double("created_at") ?? 0),
            updatedAt: Date(timeIntervalSince1970: row.double("updated_at") ?? 0),
            isFavorite: row.bool("is_favorite") ?? false
        )
        return BookWithChapters(book: book, chapters: [])
    }
}
