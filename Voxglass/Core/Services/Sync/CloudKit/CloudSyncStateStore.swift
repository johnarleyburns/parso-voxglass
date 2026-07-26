import Foundation

public final class CloudSyncStateStore {
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

    public func dequeuePending(limit: Int = 50) async throws -> [(localID: String, recordType: String, changeType: String)] {
        try await database.prepare()
        let rows = try await database.query("""
        SELECT local_id, record_type, change_type FROM pending_sync
        ORDER BY enqueued_at ASC LIMIT ?
        """, [.int(Int64(limit))])
        return rows.compactMap { row in
            guard let localID = row.string("local_id"),
                  let recordType = row.string("record_type"),
                  let changeType = row.string("change_type") else { return nil }
            return (localID, recordType, changeType)
        }
    }

    public func removePending(localID: String, recordType: String) async throws {
        try await database.prepare()
        try await database.execute(
            "DELETE FROM pending_sync WHERE local_id = ? AND record_type = ?",
            [.string(localID), .string(recordType)]
        )
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
