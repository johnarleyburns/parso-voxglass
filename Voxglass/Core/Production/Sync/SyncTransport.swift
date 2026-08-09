import Foundation

// MARK: - SyncChangeToken

/// Opaque server change token (an archived `CKServerChangeToken` on the CloudKit
/// path). Stored as `Data` so the engine and its tests never touch CloudKit types.
public struct SyncChangeToken: Codable, Sendable, Equatable {
    public var data: Data

    public init(data: Data) {
        self.data = data
    }
}

// MARK: - SyncAccountStatus

public enum SyncAccountStatus: Sendable, Equatable {
    case available
    case notAuthenticated
    case quotaExceeded
    case unavailable
}

// MARK: - ZoneFetchResult

public struct ZoneFetchResult: Sendable, Equatable {
    public var records: [SyncRecord]
    public var deletedRecordNames: [String]
    public var newToken: SyncChangeToken?
    public var moreComing: Bool
    /// True when the stored change token was rejected (`.changeTokenExpired`) and
    /// the caller must discard it and refetch from scratch (spec §13.7).
    public var changeTokenExpired: Bool

    public init(
        records: [SyncRecord] = [],
        deletedRecordNames: [String] = [],
        newToken: SyncChangeToken? = nil,
        moreComing: Bool = false,
        changeTokenExpired: Bool = false
    ) {
        self.records = records
        self.deletedRecordNames = deletedRecordNames
        self.newToken = newToken
        self.moreComing = moreComing
        self.changeTokenExpired = changeTokenExpired
    }
}

// MARK: - ProductionSyncTransport

/// CloudKit-agnostic transport over the production zone (`VGProductionStudioZone`,
/// spec §5). The iPhone writes project records and relays watch event records;
/// concrete implementations map `SyncRecord` to/from
/// `CKRecord` (one per app target) — Core stays CloudKit-free so the watch never
/// links it and every path is testable with a fake.
public protocol ProductionSyncTransport: Sendable {
    func accountStatus() async -> SyncAccountStatus

    /// Fetches zone changes after the given token. Throws `SyncError.transient` for
    /// retryable failures (network, `retryAfterSeconds`) and `SyncError.auth` when
    /// the user is not authenticated.
    func fetchZoneChanges(after token: SyncChangeToken?) async throws -> ZoneFetchResult

    /// Modifies records with an if-server-record-unchanged policy. On a record whose
    /// server change tag differs, throws `SyncError.serverRecordChanged` carrying the
    /// server record's change tag so the engine can adopt it and retry once.
    func pushRecords(_ records: [SyncRecord]) async throws

    /// Fetches records by name, returning the current server copies. Used by the
    /// asset uploader to re-read a `VGProductionAsset` record after a push and
    /// verify its `sha256` field (spec §6.3 step 3), and by the hydration
    /// executor to download the blob (`assetFields`) it needs to restore a
    /// `remoteOnly` original. `CKAsset` payloads arrive in `assetFields`.
    func fetchRecords(_ recordNames: [String]) async throws -> [SyncRecord]

    /// Deletes records by name. Used to withdraw a hidden project and to consume
    /// `VGReviewEvent` records after they have been applied and folded.
    func deleteRecords(_ recordNames: [String]) async throws
}

// MARK: - SyncError

public enum SyncError: Error, Sendable, Equatable, LocalizedError {
    /// A pushed record conflicted (`serverRecordChanged`). Carries the server record
    /// name, its change tag, and — when available — the server record's revision, so
    /// the engine can adopt it and retry once (last-writer-wins on revision, §13.7).
    case serverRecordChanged(recordName: String, serverChangeTag: String, serverRevision: Int64?)
    /// Retryable failure; may carry a server-requested retry delay.
    case transient(reason: String, retryAfterSeconds: TimeInterval?)
    /// User is not signed into iCloud / CloudKit restricted.
    case auth
    /// CloudKit quota exceeded.
    case quotaExceeded
    /// The zone does not exist (first publish may need to create it).
    case zoneNotFound
    /// A non-retryable transport failure.
    case transport(String)
    /// Stale token: callers must discard the token and refetch from scratch.
    case changeTokenExpired

    public var errorDescription: String? {
        switch self {
        case .serverRecordChanged(let recordName, _, _):
            return "A conflicting change was received for \(recordName); adopting the server copy."
        case .transient(let reason, _):
            return reason
        case .auth:
            return "Not signed in to iCloud."
        case .quotaExceeded:
            return "Your iCloud storage is full. Narration data could not be backed up. Free up iCloud space or change the iCloud plan in Settings."
        case .zoneNotFound:
            return "The narration backup zone does not exist yet."
        case .transport(let reason):
            return reason
        case .changeTokenExpired:
            return "The sync token expired; refreshing from scratch."
        }
    }
}

// MARK: - PublishReason

public enum PublishReason: String, Sendable, Equatable {
    case takeSelected
    case reviewStateChanged
    case metadataChanged
    case manual
    case appBackgrounded
    case periodic
}

// MARK: - PublishOutcome

public enum PublishOutcome: Sendable, Equatable {
    case published(revision: Int, recordsPushed: Int, assetsPushed: Int)
    case noChanges
    case withdrawn
    case skipped(reason: String)
}

// MARK: - IngestReport

public struct IngestReport: Sendable, Equatable {
    /// Review events decoded from fetched `VGReviewEvent` records, in fetch order.
    public var events: [ReviewEvent]
    /// Record names of the consumed events; the consumer deletes them after applying.
    public var eventRecordNames: [String]
    /// The freshest projection in the zone (nil until the phone has published once).
    public var projection: SyncProjection?
    /// Proxy audio downloaded with the fetch, keyed by paragraph ID (phone side).
    public var proxyAssets: [UUID: Data]
    /// Paragraph records withdrawn from devices (hidden project).
    public var deletedParagraphNames: [String]
    /// True when a stale change token was recovered by refetching from scratch.
    public var fullRefetchUsed: Bool

    public init(
        events: [ReviewEvent] = [],
        eventRecordNames: [String] = [],
        projection: SyncProjection? = nil,
        proxyAssets: [UUID: Data] = [:],
        deletedParagraphNames: [String] = [],
        fullRefetchUsed: Bool = false
    ) {
        self.events = events
        self.eventRecordNames = eventRecordNames
        self.projection = projection
        self.proxyAssets = proxyAssets
        self.deletedParagraphNames = deletedParagraphNames
        self.fullRefetchUsed = fullRefetchUsed
    }
}
