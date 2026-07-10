import Foundation
import SQLite3

extension AppDatabase {
    func migrate() throws {
        try executeRaw("""
        CREATE TABLE IF NOT EXISTS schema_migrations (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            applied_at REAL NOT NULL
        )
        """)

        let applied = try queryRaw("SELECT id FROM schema_migrations")
            .compactMap { $0.int("id") }
            .map(Int.init)
        let appliedSet = Set(applied)

        for migration in DatabaseMigration.all where !appliedSet.contains(migration.id) {
            try executeRaw("BEGIN IMMEDIATE TRANSACTION")
            do {
                for statement in migration.statements {
                    try executeRaw(statement)
                }
                try executeRaw("""
                INSERT INTO schema_migrations (id, name, applied_at)
                VALUES (\(migration.id), '\(migration.name)', \(Date().timeIntervalSince1970))
                """)
                try executeRaw("COMMIT")
            } catch {
                try? executeRaw("ROLLBACK")
                throw error
            }
        }
    }

    private func queryRaw(_ sql: String) throws -> [DatabaseRow] {
        let statement = try prepareStatement(sql)
        defer { sqlite3_finalize(statement) }

        var rows: [DatabaseRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(row(from: statement))
        }
        return rows
    }
}

private struct DatabaseMigration {
    let id: Int
    let name: String
    let statements: [String]

    static let all: [DatabaseMigration] = [
        DatabaseMigration(
            id: 1,
            name: "initial_library_and_playback",
            statements: [
                """
                CREATE TABLE sources (
                    id TEXT PRIMARY KEY,
                    kind TEXT NOT NULL,
                    title TEXT NOT NULL,
                    url TEXT,
                    created_at REAL NOT NULL
                )
                """,
                """
                CREATE TABLE books (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    authors_json TEXT NOT NULL,
                    summary TEXT,
                    source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                    cover_url TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    is_favorite INTEGER NOT NULL DEFAULT 0
                )
                """,
                """
                CREATE TABLE chapters (
                    id TEXT PRIMARY KEY,
                    book_id TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE,
                    title TEXT NOT NULL,
                    sort_key TEXT NOT NULL,
                    chapter_index INTEGER NOT NULL,
                    duration_seconds REAL,
                    remote_url TEXT,
                    local_url TEXT
                )
                """,
                "CREATE INDEX chapters_book_index ON chapters(book_id, chapter_index, sort_key)",
                """
                CREATE TABLE playback_positions (
                    id TEXT PRIMARY KEY,
                    book_id TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE,
                    chapter_id TEXT NOT NULL REFERENCES chapters(id) ON DELETE CASCADE,
                    position_seconds REAL NOT NULL,
                    duration_seconds REAL,
                    updated_at REAL NOT NULL,
                    is_finished INTEGER NOT NULL DEFAULT 0,
                    UNIQUE(book_id, chapter_id)
                )
                """,
                "CREATE INDEX playback_positions_updated_at ON playback_positions(updated_at DESC)",
                """
                CREATE TABLE bookmarks (
                    id TEXT PRIMARY KEY,
                    book_id TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE,
                    chapter_id TEXT NOT NULL REFERENCES chapters(id) ON DELETE CASCADE,
                    position_seconds REAL NOT NULL,
                    note TEXT,
                    created_at REAL NOT NULL
                )
                """,
                """
                CREATE TABLE playlists (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                )
                """,
                """
                CREATE TABLE playlist_books (
                    playlist_id TEXT NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
                    book_id TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE,
                    sort_index INTEGER NOT NULL,
                    PRIMARY KEY (playlist_id, book_id)
                )
                """,
                """
                CREATE TABLE download_records (
                    id TEXT PRIMARY KEY,
                    book_id TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE,
                    chapter_id TEXT REFERENCES chapters(id) ON DELETE CASCADE,
                    state TEXT NOT NULL,
                    local_url TEXT,
                    bytes_downloaded INTEGER NOT NULL DEFAULT 0,
                    bytes_expected INTEGER,
                    updated_at REAL NOT NULL
                )
                """
            ]
        ),
        DatabaseMigration(
            id: 2,
            name: "add_chapters_opus_url",
            statements: [
                "ALTER TABLE chapters ADD COLUMN opus_url TEXT"
            ]
        )
    ]
}
