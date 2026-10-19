import Foundation

public protocol PositionStore: Sendable {
    func save(_ position: PlaybackPosition) async throws
    func position(for bookID: UUID, chapterID: UUID) async throws -> PlaybackPosition?
    func latestPosition() async throws -> PlaybackPosition?
    func latestPosition(forBookID bookID: UUID) async throws -> PlaybackPosition?
}

/// The (book, chapter) a position write referenced no longer exists, or the
/// chapter no longer belongs to the book (deleted/reimported library rows).
public struct StalePlaybackReferenceError: Error, LocalizedError, Equatable {
    public let bookID: UUID
    public let chapterID: UUID

    public init(bookID: UUID, chapterID: UUID) {
        self.bookID = bookID
        self.chapterID = chapterID
    }

    public var errorDescription: String? { "The saved playback position refers to a removed item." }
}

public protocol LocalPlaybackCheckpointStore: Sendable {
    func saveLocalCheckpoint(_ position: PlaybackPosition) async throws
}

public enum NowPlayingHandoffPolicy {
    public static func shouldAdopt(
        remoteUpdatedAt: Date,
        localUpdatedAt: Date?,
        localIsPlaying: Bool
    ) -> Bool {
        guard !localIsPlaying else { return false }
        guard let localUpdatedAt else { return true }
        return remoteUpdatedAt > localUpdatedAt
    }
}

public struct SQLitePositionStore: PositionStore, LocalPlaybackCheckpointStore {
    private let database: AppDatabase
    var databaseForTests: AppDatabase { database }
    public var mutationLog: SyncMutationLog?

    public init(database: AppDatabase) {
        self.database = database
    }

    public func save(_ position: PlaybackPosition) async throws {
        try await persist(position, enqueueForCloudSync: true)
    }

    public func saveLocalCheckpoint(_ position: PlaybackPosition) async throws {
        try await persist(position, enqueueForCloudSync: false)
    }

    private func persist(_ position: PlaybackPosition, enqueueForCloudSync: Bool) async throws {
        let clamped = PlaybackPosition(
            id: position.id,
            bookID: position.bookID,
            chapterID: position.chapterID,
            position: position.position,
            duration: position.duration,
            updatedAt: position.updatedAt,
            isFinished: position.isFinished
        )

        let owners = try await database.query(
            "SELECT 1 AS ok FROM chapters WHERE id = ? AND book_id = ? LIMIT 1",
            [ModelMapping.databaseValue(clamped.chapterID), ModelMapping.databaseValue(clamped.bookID)]
        )
        guard !owners.isEmpty else {
            throw StalePlaybackReferenceError(bookID: clamped.bookID, chapterID: clamped.chapterID)
        }

        do {
            try await write(clamped)
        } catch DatabaseError.stepFailed(let message) where message.localizedCaseInsensitiveContains("FOREIGN KEY") {
            // Row vanished between the check and the write.
            throw StalePlaybackReferenceError(bookID: clamped.bookID, chapterID: clamped.chapterID)
        }
        if enqueueForCloudSync, let mutationLog {
            let storedRows = try await database.query(
                "SELECT id FROM playback_positions WHERE book_id = ? AND chapter_id = ? LIMIT 1",
                [ModelMapping.databaseValue(clamped.bookID), ModelMapping.databaseValue(clamped.chapterID)]
            )
            guard let storedID = storedRows.first?.string("id") else { return }
            try await mutationLog.enqueue(localID: storedID, recordType: "PlaybackPosition", changeType: "update")
        }
    }

    private func write(_ clamped: PlaybackPosition) async throws {
        try await database.execute("""
        INSERT INTO playback_positions
            (id, book_id, chapter_id, position_seconds, duration_seconds, updated_at, is_finished)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(book_id, chapter_id) DO UPDATE SET
            position_seconds = excluded.position_seconds,
            duration_seconds = excluded.duration_seconds,
            updated_at = excluded.updated_at,
            is_finished = excluded.is_finished
        WHERE excluded.updated_at >= playback_positions.updated_at
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
