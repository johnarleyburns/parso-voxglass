import Foundation

/// SQLite-backed `ProductionAssetRepository`. Each record is one row in the
/// `production_asset` table, added by migration 2. Two instances over the same
/// URL are safe: WAL mode plus `busy_timeout` in `ProjectDatabase` serialize
/// writers, and migrations are guarded by `schema_migrations`.
public final class SQLiteProductionAssetRepository: @unchecked Sendable, ProductionAssetRepository {
    private let db: ProjectDatabase

    public init(databaseURL: URL) {
        self.db = ProjectDatabase(url: databaseURL)
    }

    /// Shares an existing connection instead of opening a second one.
    public init(database: ProjectDatabase) {
        self.db = database
    }

    public func upsert(_ record: ProductionAssetRecord) async throws {
        try await db.prepare()
        try await db.execute("""
            INSERT INTO production_asset
                (id, sha256, byte_count, state, chapter_id, chapter_ordinal,
                 is_pinned, is_working_set, last_accessed_at, remote_asset_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                sha256 = excluded.sha256,
                byte_count = excluded.byte_count,
                state = excluded.state,
                chapter_id = excluded.chapter_id,
                chapter_ordinal = excluded.chapter_ordinal,
                is_pinned = excluded.is_pinned,
                is_working_set = excluded.is_working_set,
                last_accessed_at = excluded.last_accessed_at,
                remote_asset_id = excluded.remote_asset_id
            """, [
                .string(record.id.uuidString),
                .string(record.sha256),
                .int(record.byteCount),
                .string(record.state.rawValue),
                record.chapterID.map { .string($0.uuidString) } ?? .null,
                record.chapterOrdinal.map { .int(Int64($0)) } ?? .null,
                .bool(record.isPinned),
                .bool(record.isWorkingSet),
                .double(record.lastAccessedAt.timeIntervalSince1970),
                record.remoteAssetID.map { .string($0) } ?? .null
            ])
    }

    public func record(id: UUID) async throws -> ProductionAssetRecord? {
        try await db.prepare()
        let rows = try await db.query("SELECT * FROM production_asset WHERE id = ?", [.string(id.uuidString)])
        return try rows.first.map(rowToRecord)
    }

    public func records() async throws -> [ProductionAssetRecord] {
        try await db.prepare()
        let rows = try await db.query("""
            SELECT * FROM production_asset
            ORDER BY chapter_ordinal IS NOT NULL DESC, chapter_ordinal, last_accessed_at
            """)
        return try rows.map(rowToRecord)
    }

    public func records(chapterID: UUID) async throws -> [ProductionAssetRecord] {
        try await db.prepare()
        let rows = try await db.query(
            "SELECT * FROM production_asset WHERE chapter_id = ? ORDER BY last_accessed_at",
            [.string(chapterID.uuidString)]
        )
        return try rows.map(rowToRecord)
    }

    public func remove(id: UUID) async throws {
        try await db.prepare()
        try await db.execute("DELETE FROM production_asset WHERE id = ?", [.string(id.uuidString)])
    }

    private func rowToRecord(_ row: DatabaseRow) throws -> ProductionAssetRecord {
        guard let raw = row.string("id"), let id = UUID(uuidString: raw) else {
            throw StoreError.corruptRow("invalid production_asset id")
        }
        return ProductionAssetRecord(
            id: id,
            sha256: row.string("sha256") ?? "",
            byteCount: row.int("byte_count") ?? 0,
            state: ProductionAssetState(rawValue: row.string("state") ?? "") ?? .missing,
            chapterID: row.string("chapter_id").flatMap(UUID.init(uuidString:)),
            chapterOrdinal: row.int("chapter_ordinal").map(Int.init),
            isPinned: row.bool("is_pinned") ?? false,
            isWorkingSet: row.bool("is_working_set") ?? false,
            lastAccessedAt: Date(timeIntervalSince1970: row.double("last_accessed_at") ?? 0),
            remoteAssetID: row.string("remote_asset_id")
        )
    }
}
