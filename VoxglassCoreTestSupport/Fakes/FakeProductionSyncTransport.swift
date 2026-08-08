import Foundation
import VoxglassCore

/// Deterministic, in-memory `ProductionSyncTransport` for engine tests. Simulates a
/// single-writer CloudKit zone: incremental fetch by change token, one-shot conflicts
/// and transient failures, and token expiry on demand.
public final class FakeProductionSyncTransport: ProductionSyncTransport, @unchecked Sendable {

    private let lock = NSLock()
    private var serverRecords: [String: (record: SyncRecord, generation: Int)] = [:]
    private var pushLog: [SyncRecord] = []
    private var generationCounter = 0
    private var lastChangeTag = 0

    public var accountStatusValue: SyncAccountStatus = .available
    /// When set, the next fetch with a non-nil token returns `changeTokenExpired`.
    public var expireTokenOnce = false
    /// When set, the next `pushRecords` that includes this record name throws
    /// `serverRecordChanged` once and does not store the batch.
    public var conflictOnRecord: String?
    public var serverRevisionOnConflict: Int64?
    /// Number of consecutive `pushRecords` calls that throw `.transient` first.
    public var transientFailuresRemaining = 0
    /// The change tag the fake reports for a conflict.
    public var conflictChangeTag = "server-tag-1"

    /// Simulates a server that stored different bytes than the phone pushed: on a
    /// fetch, the `sha256` field of the named record is rewritten, so the uploader's
    /// re-read verification (spec §6.3 step 3) sees a mismatch and refuses to mark
    /// the asset `localAndRemote`.
    public var rewrittenSHAOnFetch: [String: String] = [:]

    /// When set, the next `fetchRecords` that includes this record name throws a
    /// transient error once (a mid-download interruption for the resume tests).
    public var failFetchOnceForRecord: String?

    public init() {}

    public func seed(_ records: [SyncRecord]) {
        locked {
            for record in records {
                generationCounter += 1
                serverRecords[record.recordName] = (record, generationCounter)
                lastChangeTag += 1
            }
        }
    }

    public func snapshot() -> [SyncRecord] {
        locked {
            serverRecords.values.map(\.record).sorted { $0.recordName < $1.recordName }
        }
    }

    public func pushedEventRecords() -> [SyncRecord] {
        locked {
            pushLog.filter { $0.recordType == "VGReviewEvent" }
        }
    }

    public func pushedProjectionRecords() -> [SyncRecord] {
        snapshot().filter { $0.recordType != "VGReviewEvent" }
    }

    public func record(named name: String) -> SyncRecord? {
        locked { serverRecords[name]?.record }
    }

    // MARK: - ProductionSyncTransport

    public func accountStatus() async -> SyncAccountStatus {
        accountStatusValue
    }

    public func fetchZoneChanges(after token: SyncChangeToken?) async throws -> ZoneFetchResult {
        locked {
            if expireTokenOnce, token != nil {
                expireTokenOnce = false
                return ZoneFetchResult(changeTokenExpired: true)
            }

            let fromGeneration = token.flatMap(generation(of:)) ?? 0
            let changed = serverRecords.values
                .filter { $0.generation > fromGeneration }
                .map(\.record)
                .sorted { $0.recordName < $1.recordName }
            let newToken = SyncChangeToken(data: Data("g\(generationCounter)".utf8))
            return ZoneFetchResult(records: changed, newToken: newToken, moreComing: false, changeTokenExpired: false)
        }
    }

    public func pushRecords(_ records: [SyncRecord]) async throws {
        try locked {
            // Simulates the phone being offline: nothing can be pushed.
            if accountStatusValue == .unavailable {
                throw SyncError.auth
            }

            if transientFailuresRemaining > 0 {
                transientFailuresRemaining -= 1
                throw SyncError.transient(reason: "fake transient", retryAfterSeconds: nil)
            }

            if let conflict = conflictOnRecord, records.contains(where: { $0.recordName == conflict }) {
                conflictOnRecord = nil
                let tag = records.first(where: { $0.recordName == conflict })?.recordChangeTag
                let serverTag = tag.map { "conflict-after-\($0)" } ?? conflictChangeTag
                throw SyncError.serverRecordChanged(
                    recordName: conflict,
                    serverChangeTag: serverTag,
                    serverRevision: serverRevisionOnConflict
                )
            }

            for record in records {
                pushLog.append(record)
                let effectiveTag = record.recordChangeTag ?? "tag-\(lastChangeTag + 1)"
                lastChangeTag = max(lastChangeTag, Int(effectiveTag.split(separator: "-").last.map(String.init) ?? "0") ?? 0)
                generationCounter += 1
                serverRecords[record.recordName] = (record, generationCounter)
            }
        }
    }

    public func deleteRecords(_ recordNames: [String]) async throws {
        locked {
            for name in recordNames {
                serverRecords[name] = nil
            }
        }
    }

    public func fetchRecords(_ recordNames: [String]) async throws -> [SyncRecord] {
        try locked {
            if let failing = failFetchOnceForRecord, recordNames.contains(failing) {
                failFetchOnceForRecord = nil
                throw SyncError.transient(reason: "fake mid-fetch interruption", retryAfterSeconds: nil)
            }
            var result: [SyncRecord] = []
            for name in recordNames {
                guard var record = serverRecords[name]?.record else { continue }
                if let rewritten = rewrittenSHAOnFetch[name] {
                    record.fields[ProductionField.assetSHA] = .string(rewritten)
                }
                result.append(record)
            }
            return result
        }
    }

    private func generation(of token: SyncChangeToken) -> Int? {
        guard let string = String(data: token.data, encoding: .utf8), string.hasPrefix("g") else { return nil }
        return Int(string.dropFirst())
    }

    /// `NSLock` is unavailable directly in async contexts (Swift 6); route every
    /// mutation through this synchronous helper.
    private func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

/// In-memory `SyncStateStore` for engine tests.
public actor InMemorySyncStateStore: SyncStateStore {
    private var token: SyncChangeToken?
    private var snapshots: [UUID: SyncProjection] = [:]
    private var publishDates: [UUID: Date] = [:]

    public init() {}

    public func changeToken() async throws -> SyncChangeToken? { token }
    public func setChangeToken(_ token: SyncChangeToken?) async throws { self.token = token }

    public func projectionSnapshot(projectID: UUID) async throws -> SyncProjection? {
        snapshots[projectID]
    }

    public func setProjectionSnapshot(_ projection: SyncProjection?, projectID: UUID) async throws {
        snapshots[projectID] = projection
    }

    public func lastPublishDate(projectID: UUID) async throws -> Date? {
        publishDates[projectID]
    }

    public func setLastPublishDate(_ date: Date?, projectID: UUID) async throws {
        publishDates[projectID] = date
    }
}
