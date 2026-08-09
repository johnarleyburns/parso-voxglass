import Foundation
import VoxglassCore

/// Drives the working-cache eviction executor (§6.5) from the app: after a take
/// is saved, checks the project's local working-cache footprint against the
/// configured cap and evicts remote-verified originals (oldest chapter first)
/// until it fits. `localOnly`, `uploading`, staged, pinned, and working-set
/// records are never touched (hard constraint 2 — the executor itself enforces
/// this; this coordinator just supplies the cap and the active chapter).
@MainActor
public struct ProductionStorageCoordinator: Sendable {
    private let repository: NarrationProjectRepository
    private let settings: ProductionCacheSettings

    public init(
        repository: NarrationProjectRepository,
        settings: ProductionCacheSettings = ProductionCacheSettings()
    ) {
        self.repository = repository
        self.settings = settings
    }

    /// Evicts originals until the project's working cache fits the cap. Safe to
    /// call after any take write; a failure is swallowed because eviction is
    /// best-effort and never blocks recording or export.
    public func evictIfOverLimit(projectID: UUID, activeChapterOrdinal: Int?) async {
        let layout = repository.layout(for: projectID)
        let assetRepository = SQLiteProductionAssetRepository(databaseURL: layout.databaseURL)
        guard let records = try? await assetRepository.records() else { return }
        let localBytes = records
            .filter { $0.state != .remoteOnly && $0.state != .missing }
            .reduce(Int64(0)) { $0 + $1.byteCount }
        guard localBytes > settings.workingCacheBytes else { return }
        let executor = ProductionEvictionExecutor(
            repository: assetRepository,
            assetStore: repository.fileStore(for: projectID)
        )
        _ = try? await executor.evict(
            toFit: settings.workingCacheBytes,
            activeChapterOrdinal: activeChapterOrdinal
        )
    }

    /// The on-device working-cache footprint for one project (originals only;
    /// renders and proxies are tracked separately in the flow).
    public func onDeviceBytes(projectID: UUID) async -> Int64 {
        let layout = repository.layout(for: projectID)
        let assetRepository = SQLiteProductionAssetRepository(databaseURL: layout.databaseURL)
        guard let records = try? await assetRepository.records() else { return 0 }
        return records
            .filter { $0.state != .remoteOnly && $0.state != .missing }
            .reduce(Int64(0)) { $0 + $1.byteCount }
    }
}
