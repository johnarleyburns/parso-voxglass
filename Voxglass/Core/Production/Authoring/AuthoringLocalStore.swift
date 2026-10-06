import CryptoKit
import Foundation

public struct AuthoringRemoteRecord: Codable, Sendable, Equatable {
    public var id: UUID
    public var kind: String
    public var changeTag: String
    public var payload: Data
    public var systemFields: Data?
    public var isDeleted: Bool

    public init(id: UUID, kind: String, changeTag: String, payload: Data, systemFields: Data? = nil, isDeleted: Bool = false) {
        self.id = id; self.kind = kind; self.changeTag = changeTag; self.payload = payload
        self.systemFields = systemFields; self.isDeleted = isDeleted
    }
}

public struct AuthoringMutation: Codable, Sendable, Equatable {
    public var operationId: UUID
    public var entityId: UUID
    public var entityKind: String
    public var baseChangeTag: String?
    public var changedFields: [String]
    public var payload: Data
    public var payloadSha256: String

    public init(operationId: UUID, entityId: UUID, entityKind: String, baseChangeTag: String?, changedFields: [String], payload: Data) {
        self.operationId = operationId; self.entityId = entityId; self.entityKind = entityKind
        self.baseChangeTag = baseChangeTag; self.changedFields = changedFields; self.payload = payload
        self.payloadSha256 = Self.sha256(payload)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Durable multiwriter state kept separate from the legacy selected-take projection.
public actor AuthoringLocalStore {
    private let database: ProjectDatabase
    private let clock: any Clock
    private let ids: any IDGenerator

    public init(databaseURL: URL, clock: any Clock = SystemClock(), ids: any IDGenerator = UUIDGenerator()) {
        database = ProjectDatabase(url: databaseURL, clock: clock)
        self.clock = clock; self.ids = ids
    }

    public func prepareForSync() async throws { try await database.prepare() }

    /// Writes local entity data and its outbox operation atomically.
    public func commitLocalMutation(
        entityId: UUID, entityKind: String, payload: Data,
        baseChangeTag: String? = nil, changedFields: [String]
    ) async throws -> AuthoringMutation {
        try await database.prepare()
        let storedChangeTag = try await database.query(
            "SELECT server_change_tag FROM authoring_entity WHERE id=?", [.string(entityId.uuidString)]
        ).first?.string("server_change_tag")
        let effectiveBaseChangeTag = baseChangeTag ?? storedChangeTag
        let mutation = AuthoringMutation(
            operationId: ids.next(), entityId: entityId, entityKind: entityKind,
            baseChangeTag: effectiveBaseChangeTag, changedFields: changedFields, payload: payload
        )
        let encoded = String(decoding: payload, as: UTF8.self)
        let fields = try JSONEncoder().encode(changedFields)
        let fieldsJSON = String(decoding: fields, as: UTF8.self)
        let modifiedAt = clock.now.timeIntervalSince1970
        try await database.transaction { transaction in
            try await transaction.execute("""
                INSERT INTO authoring_entity(id, kind, payload_json, modified_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET kind=excluded.kind, payload_json=excluded.payload_json,
                    local_revision=authoring_entity.local_revision+1, tombstoned=0, modified_at=excluded.modified_at
                """, [.string(entityId.uuidString), .string(entityKind), .string(encoded), .double(modifiedAt)])
            try await transaction.execute("""
                INSERT INTO authoring_outbox(operation_id, entity_id, entity_kind, base_change_tag,
                    changed_fields_json, payload_json, payload_sha256, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, [
                    .string(mutation.operationId.uuidString), .string(entityId.uuidString), .string(entityKind),
                    effectiveBaseChangeTag.map(DatabaseValue.string) ?? .null, .string(fieldsJSON), .string(encoded),
                    .string(mutation.payloadSha256), .double(modifiedAt)
                ])
        }
        return mutation
    }

    /// Applies a remote page and checkpoints the cursor/CKSyncEngine state in one transaction.
    public func applyRemotePage(
        scope: String, pageId: UUID, records: [AuthoringRemoteRecord], cursor: Data?,
        engineState: Data? = nil
    ) async throws {
        try await database.prepare()
        let cursorJSON = cursor.map { String(decoding: $0, as: UTF8.self) }
        let engineState = engineState?.base64EncodedString()
        let modifiedAt = clock.now.timeIntervalSince1970
        let ids = self.ids
        try await database.transaction { transaction in
            for record in records {
                let payload = String(decoding: record.payload, as: UTF8.self)
                try await transaction.execute("""
                    INSERT OR IGNORE INTO authoring_inbox(scope, page_id, record_id, entity_kind, change_tag, payload_json, applied)
                    VALUES (?, ?, ?, ?, ?, ?, 0)
                    """, [.string(scope), .string(pageId.uuidString), .string(record.id.uuidString), .string(record.kind), .string(record.changeTag), .string(payload)])
                let current = try await transaction.query("""
                    SELECT payload_json, server_base_json, server_change_tag FROM authoring_entity WHERE id = ?
                    """, [.string(record.id.uuidString)]).first
                let alreadyApplied = current?.string("server_change_tag") == record.changeTag
                if !alreadyApplied {
                    let hasPending = try await transaction.query("""
                        SELECT operation_id FROM authoring_outbox WHERE entity_id = ? AND state='pending' LIMIT 1
                        """, [.string(record.id.uuidString)]).first != nil
                    if record.isDeleted {
                        let current = try await transaction.query("SELECT payload_json, server_base_json FROM authoring_entity WHERE id=?", [.string(record.id.uuidString)]).first
                        let hasPending = try await transaction.query("SELECT operation_id FROM authoring_outbox WHERE entity_id=? AND state='pending' LIMIT 1", [.string(record.id.uuidString)]).first != nil
                        if hasPending, let localJSON = current?.string("payload_json") {
                            let encoder = JSONEncoder()
                            let local = try JSONDecoder().decode(AuthoringValue.self, from: Data(localJSON.utf8))
                            let base = try current?.string("server_base_json").map { try JSONDecoder().decode(AuthoringValue.self, from: Data($0.utf8)) }
                            try await transaction.execute("""
                                INSERT OR IGNORE INTO authoring_conflict(id, entity_id, field, base_json, local_json, remote_json, remote_change_tag, created_at)
                                VALUES (?, ?, '$deleted', ?, ?, 'null', ?, ?)
                                """, [
                                    .string(ids.next().uuidString), .string(record.id.uuidString),
                                    try base.map { .string(String(decoding: try encoder.encode($0), as: UTF8.self)) } ?? .null,
                                    .string(String(decoding: try encoder.encode(local), as: UTF8.self)),
                                    .string(record.changeTag), .double(modifiedAt)
                                ])
                            try await transaction.execute("UPDATE authoring_entity SET server_change_tag=?, server_system_fields_b64=NULL, modified_at=? WHERE id=?", [.string(record.changeTag), .double(modifiedAt), .string(record.id.uuidString)])
                        } else {
                            try await transaction.execute("UPDATE authoring_entity SET tombstoned=1, server_change_tag=?, server_system_fields_b64=NULL, modified_at=? WHERE id=?", [.string(record.changeTag), .double(modifiedAt), .string(record.id.uuidString)])
                        }
                        let tombstoneID = ids.next()
                        try await transaction.execute("INSERT OR IGNORE INTO authoring_tombstone(operation_id, entity_id, entity_kind, deleted_at, payload_json) VALUES (?, ?, ?, ?, ?)", [
                            .string(tombstoneID.uuidString), .string(record.id.uuidString), .string(record.kind),
                            .double(modifiedAt), .string("{}")
                        ])
                        try await transaction.execute("UPDATE authoring_inbox SET applied=1 WHERE scope=? AND record_id=? AND change_tag=?", [.string(scope), .string(record.id.uuidString), .string(record.changeTag)])
                        continue
                    }
                    let remoteValue = try JSONDecoder().decode(AuthoringValue.self, from: record.payload)
                    let localValue = try current?.string("payload_json").map { try JSONDecoder().decode(AuthoringValue.self, from: Data($0.utf8)) }
                    let baseValue = try current?.string("server_base_json").map { try JSONDecoder().decode(AuthoringValue.self, from: Data($0.utf8)) }
                    let merged: AuthoringValue
                    let conflicts: [(String, AuthoringValue, AuthoringValue, AuthoringValue?)]
                    if hasPending, let localValue {
                        (merged, conflicts) = Self.merge(base: baseValue ?? localValue, local: localValue, remote: remoteValue)
                    } else {
                        merged = remoteValue
                        conflicts = []
                    }
                    let encoder = JSONEncoder()
                    let mergedJSON = String(decoding: try encoder.encode(merged), as: UTF8.self)
                    try await transaction.execute("""
                        INSERT INTO authoring_entity(id, kind, payload_json, server_change_tag, server_system_fields_b64, server_base_json, modified_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET kind=excluded.kind, payload_json=excluded.payload_json,
                            server_change_tag=excluded.server_change_tag, server_system_fields_b64=excluded.server_system_fields_b64,
                            server_base_json=excluded.server_base_json,
                            tombstoned=0, modified_at=excluded.modified_at
                        """, [.string(record.id.uuidString), .string(record.kind), .string(mergedJSON), .string(record.changeTag),
                               record.systemFields.map { .string($0.base64EncodedString()) } ?? .null,
                               .string(payload), .double(modifiedAt)])
                    for (field, local, remote, base) in conflicts {
                        try await transaction.execute("""
                            INSERT OR IGNORE INTO authoring_conflict(id, entity_id, field, base_json, local_json, remote_json, remote_change_tag, created_at)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            """, [
                                .string(ids.next().uuidString), .string(record.id.uuidString), .string(field),
                                try base.map { .string(String(decoding: try encoder.encode($0), as: UTF8.self)) } ?? .null,
                                .string(String(decoding: try encoder.encode(local), as: UTF8.self)),
                                .string(String(decoding: try encoder.encode(remote), as: UTF8.self)),
                                .string(record.changeTag), .double(modifiedAt)
                            ])
                    }
                }
                try await transaction.execute("UPDATE authoring_inbox SET applied=1 WHERE scope=? AND record_id=? AND change_tag=?", [.string(scope), .string(record.id.uuidString), .string(record.changeTag)])
            }
            try await transaction.execute("""
                INSERT INTO authoring_sync_state(scope, cursor_json, ck_engine_state_b64, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(scope) DO UPDATE SET cursor_json=excluded.cursor_json,
                    ck_engine_state_b64=COALESCE(excluded.ck_engine_state_b64, authoring_sync_state.ck_engine_state_b64),
                    updated_at=excluded.updated_at
                """, [.string(scope), cursorJSON.map(DatabaseValue.string) ?? .null, engineState.map(DatabaseValue.string) ?? .null, .double(modifiedAt)])
        }
    }

    public func pendingMutations() async throws -> [AuthoringMutation] {
        try await database.prepare()
        let rows = try await database.query("""
            SELECT operation_id, entity_id, entity_kind, base_change_tag, changed_fields_json, payload_json
            FROM authoring_outbox WHERE state='pending' ORDER BY rowid
            """)
        return try rows.map { row in
            guard let operationId = row.string("operation_id").flatMap({ UUID(uuidString: $0) }),
                  let entityId = row.string("entity_id").flatMap({ UUID(uuidString: $0) }),
                  let kind = row.string("entity_kind"), let fields = row.string("changed_fields_json"),
                  let payload = row.string("payload_json")?.data(using: .utf8) else { throw StoreError.corruptRow("authoring outbox payload") }
            return AuthoringMutation(
                operationId: operationId, entityId: entityId, entityKind: kind,
                baseChangeTag: row.string("base_change_tag"),
                changedFields: try JSONDecoder().decode([String].self, from: Data(fields.utf8)), payload: payload
            )
        }
    }

    public func cursor(scope: String) async throws -> String? {
        try await database.prepare()
        return try await database.query("SELECT cursor_json FROM authoring_sync_state WHERE scope=?", [.string(scope)]).first?.string("cursor_json")
    }

    public func engineState(scope: String) async throws -> Data? {
        try await database.prepare()
        guard let encoded = try await database.query("SELECT ck_engine_state_b64 FROM authoring_sync_state WHERE scope=?", [.string(scope)])
            .first?.string("ck_engine_state_b64") else { return nil }
        return Data(base64Encoded: encoded)
    }

    /// Checkpoints CKSyncEngine state only after fetched records have been applied.
    public func saveEngineState(scope: String, state: Data) async throws {
        try await database.prepare()
        let now = clock.now.timeIntervalSince1970
        try await database.execute("""
            INSERT INTO authoring_sync_state(scope, cursor_json, ck_engine_state_b64, updated_at)
            VALUES (?, NULL, ?, ?)
            ON CONFLICT(scope) DO UPDATE SET ck_engine_state_b64=excluded.ck_engine_state_b64, updated_at=excluded.updated_at
            """, [.string(scope), .string(state.base64EncodedString()), .double(now)])
    }

    public func systemFields(entityId: UUID) async throws -> Data? {
        try await database.prepare()
        guard let encoded = try await database.query("SELECT server_system_fields_b64 FROM authoring_entity WHERE id=?", [.string(entityId.uuidString)])
            .first?.string("server_system_fields_b64") else { return nil }
        return Data(base64Encoded: encoded)
    }

    public func hasUnresolvedConflicts(entityId: UUID) async throws -> Bool {
        try await database.prepare()
        return try await database.query("SELECT id FROM authoring_conflict WHERE entity_id=? AND resolved_at IS NULL LIMIT 1", [.string(entityId.uuidString)]).first != nil
    }

    /// A successful CKSyncEngine save acknowledges the immutable outbox prefix represented by that record.
    public func acknowledgeUpload(entityId: UUID, operationId: UUID, changeTag: String, systemFields: Data) async throws {
        try await database.prepare()
        let now = clock.now.timeIntervalSince1970
        try await database.transaction { transaction in
            guard let operation = try await transaction.query("SELECT rowid AS outbox_order, payload_json FROM authoring_outbox WHERE operation_id=? AND entity_id=?", [.string(operationId.uuidString), .string(entityId.uuidString)]).first,
                  let order = operation.int("outbox_order"), let acceptedPayload = operation.string("payload_json") else { return }
            try await transaction.execute("""
                UPDATE authoring_entity SET server_change_tag=?, server_system_fields_b64=?,
                    server_base_json=?, modified_at=? WHERE id=?
                """, [.string(changeTag), .string(systemFields.base64EncodedString()), .string(acceptedPayload), .double(now), .string(entityId.uuidString)])
            let acknowledged = try await transaction.query("SELECT operation_id, payload_sha256 FROM authoring_outbox WHERE entity_id=? AND state='pending' AND rowid<=?", [.string(entityId.uuidString), .int(order)])
            for row in acknowledged {
                guard let acknowledgedID = row.string("operation_id"), let digest = row.string("payload_sha256") else { continue }
                try await transaction.execute("INSERT OR IGNORE INTO authoring_receipt(operation_id, payload_sha256, accepted_at) VALUES (?, ?, ?)", [.string(acknowledgedID), .string(digest), .double(now)])
            }
            try await transaction.execute("UPDATE authoring_outbox SET state='sent' WHERE entity_id=? AND state='pending' AND rowid<=?", [.string(entityId.uuidString), .int(order)])
        }
    }

    private static func merge(
        base: AuthoringValue, local: AuthoringValue, remote: AuthoringValue
    ) -> (AuthoringValue, [(String, AuthoringValue, AuthoringValue, AuthoringValue?)]) {
        guard case .object(let baseObject) = base, case .object(let localObject) = local,
              case .object(let remoteObject) = remote else {
            return (local, [("$", local, remote, base)])
        }
        var merged = remoteObject
        var conflicts: [(String, AuthoringValue, AuthoringValue, AuthoringValue?)] = []
        for key in Set(baseObject.keys).union(localObject.keys).union(remoteObject.keys).sorted() {
            let original = baseObject[key]
            let ours = localObject[key]
            let theirs = remoteObject[key]
            guard ours != original else { continue }
            if theirs == original || ours == theirs {
                if let ours { merged[key] = ours } else { merged.removeValue(forKey: key) }
            } else {
                conflicts.append((key, ours ?? .null, theirs ?? .null, original))
                if let ours { merged[key] = ours } else { merged.removeValue(forKey: key) }
            }
        }
        return (.object(merged), conflicts)
    }
}
