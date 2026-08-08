import Foundation

/// The set of records the app keeps local no matter the cache pressure
/// (§6.4): the chapter being recorded, its immediate neighbors, and anything
/// the user pinned. `ProductionEvictionExecutor` derives `isWorkingSet` from
/// this before planning, so the planner's `isEvictable` sees current state.
public struct ProductionWorkingSet: Sendable {
    public let activeChapterOrdinal: Int?
    public let chapterRadius: Int

    public init(activeChapterOrdinal: Int?, chapterRadius: Int = 1) {
        self.activeChapterOrdinal = activeChapterOrdinal
        self.chapterRadius = max(0, chapterRadius)
    }

    public func contains(_ record: ProductionAssetRecord) -> Bool {
        guard let active = activeChapterOrdinal, let ordinal = record.chapterOrdinal else { return false }
        return abs(ordinal - active) <= chapterRadius
    }
}

/// What `ProductionEvictionExecutor.evict` did, for storage surfaces and tests.
public struct ProductionEvictionResult: Sendable, Equatable {
    /// Original records flipped to `.remoteOnly` (files moved to Trash).
    public let evictedOriginalIDs: [UUID]
    /// Regenerable cache assets (render/proxy/staging) moved to Trash.
    public let trashedCacheRefs: [AudioAssetReference]
    public let bytesReclaimed: Int64
    /// The logical working-cache footprint after eviction (local originals +
    /// remaining cache candidates), always `>= 0`.
    public let workingCacheBytesAfter: Int64

    public init(
        evictedOriginalIDs: [UUID],
        trashedCacheRefs: [AudioAssetReference],
        bytesReclaimed: Int64,
        workingCacheBytesAfter: Int64
    ) {
        self.evictedOriginalIDs = evictedOriginalIDs
        self.trashedCacheRefs = trashedCacheRefs
        self.bytesReclaimed = bytesReclaimed
        self.workingCacheBytesAfter = workingCacheBytesAfter
    }
}

/// Executes the eviction plan §6.5 against the real store. The pure planner
/// chooses candidates; this executor performs the file moves and the SQLite
/// writes in the safe order: **files leave the working set before any state is
/// mutated**, and only `.isEvictable` originals are ever touched. It never
/// re-derives the eviction condition — `ProductionAssetRecord.isEvictable` is
/// the single authority (hard constraint 2).
public struct ProductionEvictionExecutor: Sendable {
    private let repository: any ProductionAssetRepository
    private let assetStore: any ContentAddressedStore
    private let planner: ProductionEvictionPlanner
    private let clock: any Clock

    public init(
        repository: any ProductionAssetRepository,
        assetStore: any ContentAddressedStore,
        planner: ProductionEvictionPlanner = ProductionEvictionPlanner(),
        clock: any Clock = SystemClock()
    ) {
        self.repository = repository
        self.assetStore = assetStore
        self.planner = planner
        self.clock = clock
    }

    /// Evicts until the local working cache fits `capBytes`. `activeChapterOrdinal`
    /// keeps that chapter and its neighbors local (§6.4). Regenerable cache
    /// classes (render, completed export staging, proxy) are evicted first via
    /// `cacheFile`, which the caller uses to map a candidate to its asset file;
    /// originals follow, oldest chapter ordinal first.
    ///
    /// Order of effects per candidate: move the file to Trash, then persist the
    /// record/cache change. A move failure aborts that candidate without any
    /// state mutation, leaving the working cache unchanged.
    public func evict(
        toFit capBytes: Int64,
        activeChapterOrdinal: Int?,
        renderCache: [ProductionEvictionCandidate] = [],
        completedExportStaging: [ProductionEvictionCandidate] = [],
        proxyCache: [ProductionEvictionCandidate] = [],
        cacheFile: @Sendable (ProductionEvictionCandidate) -> AudioAssetReference? = { _ in nil }
    ) async throws -> ProductionEvictionResult {
        var records = try await repository.records()

        // 1. Refresh the derived working-set flag and persist it before the
        //    planner runs, so `.isEvictable` reflects the live working set.
        let workingSet = ProductionWorkingSet(activeChapterOrdinal: activeChapterOrdinal)
        for index in records.indices {
            let inWindow = workingSet.contains(records[index])
            if records[index].isWorkingSet != inWindow {
                records[index].isWorkingSet = inWindow
                try await repository.upsert(records[index])
            }
        }

        // 2. Current working-cache footprint: local originals + the caller's
        //    regenerable cache inventory. The planner sizes the eviction to
        //    bring this under `capBytes`.
        let localBytes = records
            .filter { $0.state != .remoteOnly && $0.state != .missing }
            .reduce(Int64(0)) { $0 + $1.byteCount }
        let cacheBytes = (renderCache + completedExportStaging + proxyCache)
            .reduce(Int64(0)) { $0 + $1.byteCount }
        let currentBytes = localBytes + cacheBytes
        let requiredFreeBytes = max(0, currentBytes - capBytes)

        var evictedOriginalIDs: [UUID] = []
        var trashedCacheRefs: [AudioAssetReference] = []
        var reclaimed: Int64 = 0

        if requiredFreeBytes > 0 {
            let plan = planner.candidates(
                assets: records,
                renderCache: renderCache,
                completedExportStaging: completedExportStaging,
                proxyCache: proxyCache,
                requiredFreeBytes: requiredFreeBytes
            )

            // Index the content-addressed store once by sha256 so an original's
            // file is found without scanning per record; the planner already
            // guarantees each record is evictable, and we double-check with the
            // record's own `isEvictable` rather than re-deriving the condition.
            let originalRefs = try await assetStore.allReferences(under: .original)
            let refBySHA = Dictionary(
                originalRefs.map { ($0.sha256, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let recordByID = Dictionary(
                records.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            var trashedSHAs: Set<String> = []

            for candidate in plan where reclaimed < requiredFreeBytes {
                switch candidate.kind {
                case .originalTake:
                    guard var record = recordByID[candidate.assetID], record.isEvictable else { continue }
                    guard let ref = refBySHA[record.sha256] else { continue }
                    if !trashedSHAs.contains(record.sha256) {
                        try await assetStore.trash(ref)
                        trashedSHAs.insert(record.sha256)
                    }
                    record.state = .remoteOnly
                    record.lastAccessedAt = clock.now
                    try await repository.upsert(record)
                    evictedOriginalIDs.append(record.id)
                    reclaimed += record.byteCount
                case .renderCache, .exportStaging, .proxyReviewCache:
                    guard let ref = cacheFile(candidate) else { continue }
                    try await assetStore.trash(ref)
                    trashedCacheRefs.append(ref)
                    reclaimed += candidate.byteCount
                }
            }
        }

        return ProductionEvictionResult(
            evictedOriginalIDs: evictedOriginalIDs,
            trashedCacheRefs: trashedCacheRefs,
            bytesReclaimed: reclaimed,
            workingCacheBytesAfter: max(0, currentBytes - reclaimed)
        )
    }
}
