import Foundation

public protocol PositionStore: Sendable {
    func save(_ position: PlaybackPosition) async throws
    func position(for bookID: UUID, chapterID: UUID) async throws -> PlaybackPosition?
    func latestPosition() async throws -> PlaybackPosition?
    func latestPosition(forBookID bookID: UUID) async throws -> PlaybackPosition?
}

public struct SQLitePositionStore: PositionStore {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func save(_ position: PlaybackPosition) async throws {
        let clamped = PlaybackPosition(
            id: position.id,
            bookID: position.bookID,
            chapterID: position.chapterID,
            position: position.position,
            duration: position.duration,
            updatedAt: position.updatedAt,
            isFinished: position.isFinished
        )

        try await database.execute("""
        INSERT INTO playback_positions
            (id, book_id, chapter_id, position_seconds, duration_seconds, updated_at, is_finished)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(book_id, chapter_id) DO UPDATE SET
            position_seconds = excluded.position_seconds,
            duration_seconds = excluded.duration_seconds,
            updated_at = excluded.updated_at,
            is_finished = excluded.is_finished
        """, [
            ModelMapping.databaseValue(clamped.id),
            ModelMapping.databaseValue(clamped.bookID),
            ModelMapping.databaseValue(clamped.chapterID),
            .double(clamped.position),
            ModelMapping.databaseValue(clamped.duration),
            ModelMapping.databaseValue(clamped.updatedAt),
            .bool(clamped.isFinished)
        ])
    }

    public func position(for bookID: UUID, chapterID: UUID) async throws -> PlaybackPosition? {
        let rows = try await database.query("""
        SELECT id, book_id, chapter_id, position_seconds, duration_seconds, updated_at, is_finished
        FROM playback_positions
        WHERE book_id = ? AND chapter_id = ?
        LIMIT 1
        """, [
            ModelMapping.databaseValue(bookID),
            ModelMapping.databaseValue(chapterID)
        ])
        return try rows.first.map(Self.position(from:))
    }

    public func latestPosition() async throws -> PlaybackPosition? {
        let rows = try await database.query("""
        SELECT id, book_id, chapter_id, position_seconds, duration_seconds, updated_at, is_finished
        FROM playback_positions
        ORDER BY updated_at DESC
        LIMIT 1
        """)
        return try rows.first.map(Self.position(from:))
    }

    public func latestPosition(forBookID bookID: UUID) async throws -> PlaybackPosition? {
        let rows = try await database.query("""
        SELECT id, book_id, chapter_id, position_seconds, duration_seconds, updated_at, is_finished
        FROM playback_positions
        WHERE book_id = ?
        ORDER BY updated_at DESC
        LIMIT 1
        """, [
            ModelMapping.databaseValue(bookID)
        ])
        return try rows.first.map(Self.position(from:))
    }

    private static func position(from row: DatabaseRow) throws -> PlaybackPosition {
        PlaybackPosition(
            id: try ModelMapping.uuid(row, "id"),
            bookID: try ModelMapping.uuid(row, "book_id"),
            chapterID: try ModelMapping.uuid(row, "chapter_id"),
            position: row.double("position_seconds") ?? 0,
            duration: row.double("duration_seconds"),
            updatedAt: ModelMapping.date(row, "updated_at"),
            isFinished: row.bool("is_finished") ?? false
        )
    }
}

