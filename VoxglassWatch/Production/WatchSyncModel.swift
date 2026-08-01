import Foundation
import Observation
import VoxglassCore

/// Sync status (mockup 09): how many review actions are queued, when the phone last
/// acknowledged, how much production audio is stored, and the reachability banner.
@MainActor
@Observable
public final class WatchSyncModel {

    public var pendingEventCount = 0
    public var lastSyncAt: Date?
    public var storageBytes = 0
    public var isReachable = false

    private let environment: ProductionWatchEnvironment

    public init(environment: ProductionWatchEnvironment) {
        self.environment = environment
    }

    public func refresh() {
        pendingEventCount = environment.pendingEventCount
        lastSyncAt = environment.lastSyncAt
        storageBytes = environment.audioStore.usedBytes
        isReachable = environment.isReachable
        environment.refreshPendingCount()
    }
}
