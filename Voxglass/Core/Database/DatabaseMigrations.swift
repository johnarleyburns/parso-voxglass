import Foundation
import SQLite3

public extension AppDatabase {
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
    public let id: Int
    public let name: String
    public let statements: [String]

    public static let all: [DatabaseMigration] = [
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
        ),
        DatabaseMigration(
            id: 3,
            name: "taste_profile_and_book_metadata",
            statements: [
                """
                CREATE TABLE book_taste (
                    book_id TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE,
                    axis TEXT NOT NULL,
                    term TEXT NOT NULL,
                    PRIMARY KEY (book_id, axis, term)
                )
                """,
                """
                CREATE TABLE taste_profile_terms (
                    axis TEXT NOT NULL,
                    term TEXT NOT NULL,
                    weight REAL NOT NULL DEFAULT 0,
                    last_ts REAL NOT NULL DEFAULT 0,
                    PRIMARY KEY (axis, term)
                )
                """,
                "CREATE INDEX taste_profile_terms_weight ON taste_profile_terms(axis, weight DESC)",
                """
                CREATE TABLE reco_surfaced (
                    identifier TEXT PRIMARY KEY,
                    ts REAL NOT NULL DEFAULT 0
                )
                """,
                "CREATE INDEX reco_surfaced_ts ON reco_surfaced(ts DESC)"
            ]
        ),
        DatabaseMigration(
            id: 4,
            name: "listening_events",
            statements: [
                """
                CREATE TABLE listening_events (
                    id TEXT PRIMARY KEY,
                    book_id TEXT REFERENCES books(id) ON DELETE SET NULL,
                    seconds REAL NOT NULL,
                    occurred_at REAL NOT NULL
                )
                """,
                "CREATE INDEX listening_events_occurred_at ON listening_events(occurred_at DESC)"
            ]
        ),
        DatabaseMigration(
            id: 5,
            name: "bookmarks_updated_at_tombstone",
            statements: [
                "ALTER TABLE bookmarks ADD COLUMN updated_at REAL NOT NULL DEFAULT 0",
                "ALTER TABLE bookmarks ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0",
                "UPDATE bookmarks SET updated_at = created_at",
                "CREATE INDEX bookmarks_book_created ON bookmarks(book_id, created_at DESC)"
            ]
        ),
        DatabaseMigration(
            id: 6,
            name: "narrators_json",
            statements: [
                "ALTER TABLE chapters ADD COLUMN narrators_json TEXT NOT NULL DEFAULT '[]'",
                "ALTER TABLE books ADD COLUMN narrators_json TEXT NOT NULL DEFAULT '[]'"
            ]
        ),
        DatabaseMigration(
            id: 7,
            name: "content_keys",
            statements: [
                "ALTER TABLE books ADD COLUMN content_key TEXT",
                "ALTER TABLE chapters ADD COLUMN content_key TEXT",
                "CREATE INDEX books_content_key ON books(content_key)",
                "CREATE INDEX chapters_content_key ON chapters(book_id, content_key)"
            ]
        ),
        DatabaseMigration(
            id: 8,
            name: "taste_signal_state",
            statements: [
                """
                CREATE TABLE taste_signal_state (
                    book_id TEXT PRIMARY KEY REFERENCES books(id) ON DELETE CASCADE,
                    max_completion REAL NOT NULL DEFAULT 0,
                    applied_increment REAL NOT NULL DEFAULT 0,
                    updated_at REAL NOT NULL
                )
                """
            ]
        )
    ]
}
