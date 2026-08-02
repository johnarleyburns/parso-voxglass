import Foundation
import Observation
import VoxglassCore

/// Device Preview screen model (spec §13.8, mockup `12-device-preview`).
@MainActor
@Observable
public final class DevicePreviewModel {

    public private(set) var accountStatus: SyncAccountStatus = .unavailable
    public private(set) var lastPublishedRevision: Int?
    public private(set) var lastSyncDate: Date?
    public private(set) var isSyncing = false
    public private(set) var syncErrorMessage: String?
    public private(set) var pendingFeedbackCount = 0
    public private(set) var flaggedQueueSize = 0
    public private(set) var storageEstimateBytes: Int64 = 0

    public var autoSync: Bool
    public var includeText: Bool
    public var hideFromDevices: Bool
    public var proxyBitrateKbps: Int
    public var watchQueueItemCount = 0

    private let coordinator: StudioProjectionCoordinator
    private var project: AudiobookProject
    private let store: any ProductionStore
    private let assets: any ContentAddressedStore
    private let flagsQueueIDs: [UUID]

    public init(
        coordinator: StudioProjectionCoordinator,
        project: AudiobookProject,
        store: any ProductionStore,
        assets: any ContentAddressedStore,
        flagsQueueIDs: [UUID] = []
    ) {
        self.coordinator = coordinator
        self.project = project
        self.store = store
        self.assets = assets
        self.flagsQueueIDs = flagsQueueIDs
        self.autoSync = project.profile.autoSyncAcceptedTakes
        self.includeText = project.profile.includeSourceTextInProjection
        self.hideFromDevices = project.profile.isHiddenFromDevices
        self.proxyBitrateKbps = project.profile.proxyBitrateKbps
        coordinator.configure(project: project, store: store, assets: assets)
    }

    public var storageEstimateLabel: String {
        let bytes = Double(storageEstimateBytes)
        let mb = bytes / (1024 * 1024)
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }

    public func load() async {
        await coordinator.refreshAccountStatus()
        accountStatus = coordinator.accountStatus
        lastPublishedRevision = coordinator.lastPublishedRevision
        lastSyncDate = coordinator.lastSyncDate
        pendingFeedbackCount = coordinator.pendingFeedbackCount
        flaggedQueueSize = flagsQueueIDs.count
        watchQueueItemCount = flagsQueueIDs.count
        await refreshEstimate()
    }

    public func syncNow() async {
        isSyncing = true
        defer { isSyncing = false }
        await coordinator.syncNow(project: project, store: store, assets: assets)
        syncErrorMessage = coordinator.lastSyncError
        lastPublishedRevision = coordinator.lastPublishedRevision
        lastSyncDate = coordinator.lastSyncDate
        accountStatus = coordinator.accountStatus
        pendingFeedbackCount = coordinator.pendingFeedbackCount
    }

    public func prepareOfflineQueue() async {
        let pinned = flagsQueueIDs
        await coordinator.prepareOfflineQueue(pinned, project: project, store: store, assets: assets)
        watchQueueItemCount = pinned.count
    }

    public func toggleHide(_ hidden: Bool) async {
        hideFromDevices = hidden
        await coordinator.hideFromDevices(hidden, project: project, store: store, assets: assets)
    }

    public func updateIncludeText(_ include: Bool) async {
        includeText = include
        var updated = project
        updated.profile.includeSourceTextInProjection = include
        project = updated
        try? await store.save(updated)
        _ = try? await coordinator.publishIfNeeded(reason: .metadataChanged, project: updated, store: store, assets: assets)
    }

    public func updateBitrate(_ bitrate: Int) async {
        proxyBitrateKbps = bitrate
        var updated = project
        updated.profile.proxyBitrateKbps = bitrate
        project = updated
        try? await store.save(updated)
        await refreshEstimate()
    }

    public func updateAutoSync(_ enabled: Bool) async {
        autoSync = enabled
        var updated = project
        updated.profile.autoSyncAcceptedTakes = enabled
        project = updated
        try? await store.save(updated)
    }

    // MARK: - Internals

    private func refreshEstimate() async {
        guard let counts = try? await store.counts() else { return }
        let bytes = counts.totalRecordedDuration * Double(proxyBitrateKbps) * 1000 / 8
        storageEstimateBytes = Int64(bytes)
    }
}
