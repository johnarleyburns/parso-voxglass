import Foundation

/// One queue row (`pending_sync`) to be durably enqueued.
public struct SyncMutation: Equatable, Sendable, Hashable {
    public let localID: String
    public let recordType: String
    public let changeType: String

    public init(localID: String, recordType: String, changeType: String = "update") {
        self.localID = localID
        self.recordType = recordType
        self.changeType = changeType
    }
}

public struct LocalSyncMigrationPlan: Equatable, Sendable {
    public let bookID: UUID
    public let legacyContentKey: String?
    public let portableContentKey: String
    public let mutationsToEnqueue: [SyncMutation]
}

public struct LocalSyncMigrationReport: Equatable, Sendable {
    public var migratedBookIDs: [UUID] = []
    public var skippedBookIDs: [UUID] = []
    public var retiredRows: [SyncMutation] = []
}

/// Durable write points, exposed so tests can inject a fault after each one.
public enum LocalSyncMigrationStep: Equatable, Sendable {
    case enqueued(SyncMutation)
    case contentKeyUpdated(bookID: UUID)
    case retired(SyncMutation)
}

/// Upgrades local-file books that have an exact cached `local-media-v1`
/// fingerprint to the portable content key and queues canonical replacements.
/// Order: enqueue canonical rows -> switch content key -> retire proven-stale rows.
/// Every step is idempotent, so a failure at any point is safe to retry and never
/// removes a row before its replacement is durable. Never clears the whole queue.
public actor LocalSyncMigrationCoordinator {
    private let database: AppDatabase
    private let stateStore: CloudSyncStateStore
    private let fingerprints: LocalMediaFingerprintService
    private let afterStep: (@Sendable (LocalSyncMigrationStep) throws -> Void)?

    public init(
        database: AppDatabase,
        afterStep: (@Sendable (LocalSyncMigrationStep) throws -> Void)? = nil
    ) {
        self.database = database
        self.stateStore = CloudSyncStateStore(database: database)
        self.fingerprints = LocalMediaFingerprintService(database: database)
        self.afterStep = afterStep
    }

    /// Plans from cached fingerprints only (never hashes files). Unfingerprinted
    /// and ambiguous (shared fingerprint) books are omitted.
    public func plans() async throws -> [LocalSyncMigrationPlan] {
        try await database.prepare()
        var cached: [(id: String, key: String)] = []
        for id in try await fingerprints.candidateBookIDs() {
            guard let fp = try await fingerprints.cachedFingerprint(bookID: id) else { continue }
            cached.append((id, LocalMediaIdentity.contentKey(fp)))
        }
        var counts: [String: Int] = [:]
        for item in cached { counts[item.key, default: 0] += 1 }

        var result: [LocalSyncMigrationPlan] = []
        for item in cached where counts[item.key] == 1 {
            guard let bookID = UUID(uuidString: item.id) else { continue }
            let legacy = try await database.query("SELECT content_key FROM books WHERE id = ?", [.string(item.id)])
                .first?.string("content_key")
            result.append(LocalSyncMigrationPlan(
                bookID: bookID,
                legacyContentKey: legacy,
                portableContentKey: item.key,
                mutationsToEnqueue: try await mutations(bookID: item.id)
            ))
        }
        return result
    }

    @discardableResult
    public func migrate() async throws -> LocalSyncMigrationReport {
        var report = LocalSyncMigrationReport()
        let planned = try await plans()
        let plannedIDs = Set(planned.map(\.bookID))
        for id in try await fingerprints.candidateBookIDs() {
            if let uuid = UUID(uuidString: id), !plannedIDs.contains(uuid) { report.skippedBookIDs.append(uuid) }
        }
        for plan in planned {
            try Task.checkCancellation()
            let alreadyPortable = plan.legacyContentKey == plan.portableContentKey
            if !alreadyPortable {
                for mutation in plan.mutationsToEnqueue {
                    try await stateStore.enqueuePending(
                        localID: mutation.localID, recordType: mutation.recordType, changeType: mutation.changeType)
                    try afterStep?(.enqueued(mutation))
                }
                try await database.execute(
                    "UPDATE books SET content_key = ? WHERE id = ?",
                    [.string(plan.portableContentKey), .string(plan.bookID.uuidString)])
                try afterStep?(.contentKeyUpdated(bookID: plan.bookID))
            }
            for stale in try await provenStaleRows(bookID: plan.bookID.uuidString) {
                try await stateStore.removePending(localID: stale.localID, recordType: stale.recordType)
                report.retiredRows.append(stale)
                try afterStep?(.retired(stale))
            }
            report.migratedBookIDs.append(plan.bookID)
        }
        return report
    }

    /// Canonical Book + every Bookmark and PlaybackPosition of the book. A pending
    /// delete for the Book is preserved (not overwritten by an update).
    private func mutations(bookID: String) async throws -> [SyncMutation] {
        var out: [SyncMutation] = []
        let pendingDelete = try await database.query(
            "SELECT 1 FROM pending_sync WHERE local_id = ? AND record_type = 'Book' AND change_type = 'delete'",
            [.string(bookID)]
        ).isEmpty == false
        if !pendingDelete { out.append(SyncMutation(localID: bookID, recordType: "Book")) }
        for row in try await database.query("SELECT id FROM bookmarks WHERE book_id = ? ORDER BY id", [.string(bookID)]) {
            if let id = row.string("id") { out.append(SyncMutation(localID: id, recordType: "Bookmark")) }
        }
        for row in try await database.query("SELECT id FROM playback_positions WHERE book_id = ? ORDER BY id", [.string(bookID)]) {
            if let id = row.string("id") { out.append(SyncMutation(localID: id, recordType: "PlaybackPosition")) }
        }
        return out
    }

    /// Rows keyed by the book's id but typed as a bookmark/position that does not
    /// exist: they can never be built, and the real entities are queued under
    /// their own ids. Nothing else is ever retired.
    private func provenStaleRows(bookID: String) async throws -> [SyncMutation] {
        var stale: [SyncMutation] = []
        for (type, table) in [("Bookmark", "bookmarks"), ("PlaybackPosition", "playback_positions")] {
            let queued = try await database.query(
                "SELECT change_type FROM pending_sync WHERE local_id = ? AND record_type = ?",
                [.string(bookID), .string(type)])
            guard let change = queued.first?.string("change_type") else { continue }
            let exists = try await database.query("SELECT 1 FROM \(table) WHERE id = ?", [.string(bookID)])
            if exists.isEmpty { stale.append(SyncMutation(localID: bookID, recordType: type, changeType: change)) }
        }
        return stale
    }
}
