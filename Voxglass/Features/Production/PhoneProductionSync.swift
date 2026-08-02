import Foundation
import Observation
import VoxglassCore

/// The phone's production sync coordinator (spec §13.1, §18.2.8): fetches the Mac's
/// projection from the private CloudKit zone into `ProductionPreviewStore`, pushes
/// the local review-event outbox (with the §13.7 retry policy), and exposes sync
/// status for the Production Sync & Storage screen. The phone is a consumer only —
/// it never writes projection records.
///
/// The CloudKit transport stack is created lazily on first sync use: constructing
/// `CKContainer` traps in an unentitled test process, and this coordinator is also
/// created by the app's production environment in contexts that never touch
/// CloudKit (mirrors `StudioProjectionCoordinator`).
@MainActor
@Observable
public final class PhoneProductionSync {

    public private(set) var accountStatus: SyncAccountStatus = .unavailable
    public private(set) var lastReceivedRevision: Int?
    public private(set) var lastSyncDate: Date?
    public private(set) var syncError: String?
    public private(set) var pendingOutboxCount = 0
    public private(set) var isChecking = false

    /// Called after a successful pull and outbox flush so the app can relay the
    /// freshly applied projection down to the watch (§13.6).
    public var onProjectionsUpdated: (() -> Void)?

    @ObservationIgnored private var core: PhoneSyncCore?
    private let previewStore: ProductionPreviewStore
    private let outbox: ReviewEventOutbox

    public init(previewStore: ProductionPreviewStore) {
        self.previewStore = previewStore
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.outbox = ReviewEventOutbox(
            storage: FileWatchOutboxStorage(directory: directory.appendingPathComponent("ProductionOutbox", isDirectory: true))
        )
    }

    private var syncCore: PhoneSyncCore {
        if let core { return core }
        let newCore = PhoneSyncCore()
        core = newCore
        return newCore
    }

    /// Enqueues a review action for push to the Mac. Safe to call offline; events
    /// are queued file-backed and flushed on the next successful check.
    public func enqueue(_ event: ReviewEvent) {
        try? outbox.enqueue(event)
        refreshPendingCount()
    }

    public func refreshPendingCount() {
        pendingOutboxCount = (try? outbox.pending().count) ?? 0
    }

    /// Pulls the latest projection and flushes the outbox (spec §14.5 Flow A).
    public func checkForUpdates() async {
        isChecking = true
        defer { isChecking = false }

        accountStatus = await syncCore.transport.accountStatus()
        guard accountStatus == .available else {
            if accountStatus == .notAuthenticated {
                syncError = "Sign in to iCloud to preview on your devices."
            }
            return
        }

        do {
            await syncCore.transport.ensureSubscription()
            let report = try await syncCore.engine.pump()

            if let projection = report.projection {
                await previewStore.apply(projection)
                lastReceivedRevision = projection.revision
                for (paragraphID, data) in report.proxyAssets {
                    await previewStore.saveProxy(data: data, paragraphID: paragraphID, projectID: projection.project.id)
                }
            }

            _ = try await outbox.flush(over: syncCore.engine)
            refreshPendingCount()
            lastSyncDate = Date()
            syncError = nil
            onProjectionsUpdated?()
        } catch {
            syncError = error.localizedDescription
        }
    }

    /// Fetches proxy audio for a set of queue items. On the MVP the full fetch in
    /// `checkForUpdates` already downloads every proxy the Mac pushed; this stays as
    /// the explicit prefetch seam for §18.2.8's opportunistic Wi-Fi policy.
    public func downloadProxies(paragraphIDs: [UUID], projectID: UUID) async {
        // Proxies arrive with the projection fetch; nothing additional to do here.
        _ = paragraphIDs
        _ = projectID
    }
}

/// The lazily-created CloudKit stack: transport and engine. Built only when the
/// first sync operation runs, so app processes that never sync (UI smoke tests,
/// hosted scene tests) never touch `CKContainer`.
private final class PhoneSyncCore: @unchecked Sendable {
    let transport: CloudKitProductionSync
    let engine: ProductionSyncEngine

    init() {
        let transport = CloudKitProductionSync()
        self.transport = transport
        let state = DefaultsSyncStateStore()
        self.engine = ProductionSyncEngine(transport: transport, state: state)
    }
}
