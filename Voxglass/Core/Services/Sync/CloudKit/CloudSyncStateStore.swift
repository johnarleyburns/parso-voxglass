import Foundation

public final class CloudSyncStateStore: @unchecked Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func saveEngineState(_ data: Data) async throws {
        try await database.prepare()
        try await database.execute("""
        INSERT INTO sync_engine_state (id, state, updated_at) VALUES (1, ?, ?)
        ON CONFLICT(id) DO UPDATE SET state = excluded.state, updated_at = excluded.updated_at
        """, [
            .string(data.base64EncodedString()),
            .double(Date().timeIntervalSince1970)
        ])
    }

    public func clearEngineState() async throws {
        try await database.prepare()
        try await database.execute("DELETE FROM sync_engine_state WHERE id = 1")
    }

    public func loadEngineState() async throws -> Data? {
        try await database.prepare()
        let rows = try await database.query(
            "SELECT state FROM sync_engine_state WHERE id = 1 LIMIT 1"
        )
        guard let b64 = rows.first?.string("state") else { return nil }
        return Data(base64Encoded: b64)
    }

    public func saveSystemFields(_ fields: Data, recordName: String, recordType: String, localID: String) async throws {
        try await database.prepare()
        try await database.execute("""
        INSERT INTO cloud_records (record_name, record_type, local_id, system_fields, updated_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(record_name) DO UPDATE SET
            system_fields = excluded.system_fields,
            updated_at = excluded.updated_at
        """, [
            .string(recordName),
            .string(recordType),
            .string(localID),
            .string(fields.base64EncodedString()),
            .double(Date().timeIntervalSince1970)
        ])
    }

    public func loadSystemFields(recordName: String) async throws -> Data? {
        try await database.prepare()
        let rows = try await database.query(
            "SELECT system_fields FROM cloud_records WHERE record_name = ? LIMIT 1",
            [.string(recordName)]
        )
        guard let b64 = rows.first?.string("system_fields") else { return nil }
        return Data(base64Encoded: b64)
    }

    public func localID(for recordName: String) async throws -> String? {
        try await database.prepare()
        let rows = try await database.query(
            "SELECT local_id FROM cloud_records WHERE record_name = ? LIMIT 1",
            [.string(recordName)]
        )
        return rows.first?.string("local_id")
    }

    public func enqueuePending(localID: String, recordType: String, changeType: String) async throws {
        try await database.prepare()
        try await database.execute("""
        INSERT OR REPLACE INTO pending_sync (local_id, record_type, change_type, enqueued_at)
        VALUES (?, ?, ?, ?)
        """, [
            .string(localID),
            .string(recordType),
            .string(changeType),
            .double(Date().timeIntervalSince1970)
        ])
    }

    public func dequeuePending(limit: Int = 50, offset: Int = 0) async throws -> [(localID: String, recordType: String, changeType: String, enqueuedAt: Double)] {
        try await database.prepare()
        let rows = try await database.query("""
        SELECT local_id, record_type, change_type, enqueued_at FROM pending_sync
        ORDER BY CASE WHEN record_type = 'Book' AND change_type != 'delete' THEN 0 ELSE 1 END,
                 enqueued_at ASC, local_id ASC
        LIMIT ? OFFSET ?
        """, [.int(Int64(limit)), .int(Int64(offset))])
        return rows.compactMap { row in
            guard let localID = row.string("local_id"),
                  let recordType = row.string("record_type"),
                  let changeType = row.string("change_type") else { return nil }
            return (localID, recordType, changeType, row.double("enqueued_at") ?? 0)
        }
    }

    public func removePending(localID: String, recordType: String, enqueuedAt: Double? = nil) async throws {
        try await database.prepare()
        try await database.execute(
            "DELETE FROM pending_sync WHERE local_id = ? AND record_type = ? AND (? IS NULL OR enqueued_at = ?)",
            [.string(localID), .string(recordType), enqueuedAt.map(DatabaseValue.double) ?? .null, enqueuedAt.map(DatabaseValue.double) ?? .null]
        )
    }

    /// Removes historical queue identities that cannot describe a saved position.
    /// Playback rows and their actual resume offsets are never deleted.
    @discardableResult
    public func pruneOrphanedPlaybackChanges() async throws -> Int {
        try await database.prepare()
        let before = try await pendingCount()
        try await database.execute("""
        DELETE FROM pending_sync
        WHERE record_type = 'PlaybackPosition'
          AND NOT EXISTS (SELECT 1 FROM playback_positions WHERE id = pending_sync.local_id)
        """)
        return max(0, before - (try await pendingCount()))
    }

    public func clearPending() async throws {
        try await database.prepare()
        try await database.execute("DELETE FROM pending_sync")
    }

    public func pendingCount() async throws -> Int {
        try await database.prepare()
        let rows = try await database.query("SELECT COUNT(*) AS count FROM pending_sync")
        return Int(rows.first?.int("count") ?? 0)
    }
}
