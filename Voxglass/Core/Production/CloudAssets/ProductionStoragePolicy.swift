import Foundation

/// The local state of a production asset.  `localAndRemote` is deliberately
/// stronger than "upload finished": it means the remote blob was verified with
/// the same SHA-256 recorded by the phone before eviction is allowed.
public enum ProductionAssetState: String, Codable, Sendable, Equatable {
    case localOnly
    case uploading
    case localAndRemote
    case remoteOnly
    case stagedForExport
    case missing
}

public struct ProductionAssetRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sha256: String
    public let byteCount: Int64
    public var state: ProductionAssetState
    public var chapterID: UUID?
    public var chapterOrdinal: Int?
    public var isPinned: Bool
    public var isWorkingSet: Bool
    public var lastAccessedAt: Date
    public var remoteAssetID: String?

    public init(
        id: UUID,
        sha256: String,
        byteCount: Int64,
        state: ProductionAssetState,
        chapterID: UUID? = nil,
        chapterOrdinal: Int? = nil,
        isPinned: Bool = false,
        isWorkingSet: Bool = false,
        lastAccessedAt: Date,
        remoteAssetID: String? = nil
    ) {
        self.id = id
        self.sha256 = sha256
        self.byteCount = byteCount
        self.state = state
        self.chapterID = chapterID
        self.chapterOrdinal = chapterOrdinal
        self.isPinned = isPinned
        self.isWorkingSet = isWorkingSet
        self.lastAccessedAt = lastAccessedAt
        self.remoteAssetID = remoteAssetID
    }

    /// An original recording is evictable only after remote identity and verified
    /// remote state have both been persisted by the phone's database.
    public var isEvictable: Bool {
        state == .localAndRemote && !isPinned && !isWorkingSet && remoteAssetID != nil
    }
}

public struct ProductionCacheLimits: Codable, Sendable, Equatable {
    public static let defaultWorkingCacheBytes: Int64 = 10 * 1024 * 1024 * 1024
    public static let defaultWatchQueueBytes: Int64 = 200 * 1024 * 1024

    public var workingCacheBytes: Int64
    public var watchQueueBytes: Int64

    public init(
        workingCacheBytes: Int64 = ProductionCacheLimits.defaultWorkingCacheBytes,
        watchQueueBytes: Int64 = ProductionCacheLimits.defaultWatchQueueBytes
    ) {
        self.workingCacheBytes = workingCacheBytes
        self.watchQueueBytes = watchQueueBytes
    }

    public static func isValidWorkingCacheSize(_ bytes: Int64) -> Bool {
        bytes >= 2 * 1024 * 1024 * 1024 && bytes <= 100 * 1024 * 1024 * 1024
    }
}

public enum ProductionAssetKind: String, Codable, Sendable, Equatable {
    case renderCache
    case exportStaging
    case proxyReviewCache
    case originalTake
}

public struct ProductionEvictionCandidate: Sendable, Equatable {
    public let assetID: UUID
    public let kind: ProductionAssetKind
    public let byteCount: Int64
    public let chapterID: UUID?

    public init(assetID: UUID, kind: ProductionAssetKind, byteCount: Int64, chapterID: UUID?) {
        self.assetID = assetID
        self.kind = kind
        self.byteCount = byteCount
        self.chapterID = chapterID
    }
}

/// Pure eviction planner. It never chooses local-only/uploading assets or any
/// current, pinned, staged, or working-set asset. Callers perform the actual file
/// moves and update SQLite only after the move succeeds.
public struct ProductionEvictionPlanner: Sendable {
    public init() {}

    public func candidates(
        assets: [ProductionAssetRecord],
        renderCache: [ProductionEvictionCandidate] = [],
        completedExportStaging: [ProductionEvictionCandidate] = [],
        proxyCache: [ProductionEvictionCandidate] = [],
        requiredFreeBytes: Int64
    ) -> [ProductionEvictionCandidate] {
        guard requiredFreeBytes > 0 else { return [] }

        let originals = assets
            .filter(\.isEvictable)
            .map {
                ProductionEvictionCandidate(
                    assetID: $0.id,
                    kind: .originalTake,
                    byteCount: $0.byteCount,
                    chapterID: $0.chapterID
                )
            }
            .sorted { leftCandidate, rightCandidate in
                let left = assets.first(where: { $0.id == leftCandidate.assetID })?.chapterOrdinal ?? Int.max
                let right = assets.first(where: { $0.id == rightCandidate.assetID })?.chapterOrdinal ?? Int.max
                return left == right
                    ? (leftCandidate.chapterID?.uuidString ?? "") < (rightCandidate.chapterID?.uuidString ?? "")
                    : left < right
            }

        let ordered = renderCache + completedExportStaging + proxyCache + originals
        var remaining = requiredFreeBytes
        var result: [ProductionEvictionCandidate] = []
        for candidate in ordered where remaining > 0 {
            guard candidate.byteCount > 0 else { continue }
            result.append(candidate)
            remaining -= candidate.byteCount
        }
        return result
    }
}

public struct ProductionHydrationPlan: Codable, Sendable, Equatable {
    public let assetIDs: [UUID]
    public let byteCount: Int64
    public let blockingAssetIDs: [UUID]

    public init(assetIDs: [UUID], byteCount: Int64, blockingAssetIDs: [UUID]) {
        self.assetIDs = assetIDs
        self.byteCount = byteCount
        self.blockingAssetIDs = blockingAssetIDs
    }

    public var isRequired: Bool { !blockingAssetIDs.isEmpty }
}

/// Builds the explicit preflight plan required before playback or export. Metadata
/// can remain usable while this plan runs; the selected audio itself must be local
/// and hash-verified before either operation begins.
public struct ProductionHydrationPlanner: Sendable {
    public init() {}

    public func plan(for assets: [ProductionAssetRecord], purpose: ProductionAssetKind) -> ProductionHydrationPlan {
        let remote = assets.filter { $0.state == .remoteOnly || $0.state == .missing }
        let ids = remote.map(\.id)
        let bytes = remote.reduce(Int64(0)) { $0 + $1.byteCount }
        let blocking = purpose == .exportStaging || purpose == .originalTake ? ids : []
        return ProductionHydrationPlan(assetIDs: ids, byteCount: bytes, blockingAssetIDs: blocking)
    }
}
