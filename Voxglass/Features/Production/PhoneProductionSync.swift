import Foundation
import Observation
import VoxglassCore

/// The phone's production sync coordinator (spec §4.2, §6.3). The phone is the
/// sole writer: it publishes each local project's projection to the private
/// CloudKit zone as a mirror backup, uploads content-addressed originals with
/// SHA-256 verification, fetches the mirror back (reinstall / second device),
/// hydrates `remoteOnly` originals, and folds watch/iPhone review events into
/// the local project store.
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

    /// Called after a successful sync so the app can relay the freshly applied
    /// projection down to the watch (spec §13.6).
    public var onProjectionsUpdated: (() -> Void)?

    @ObservationIgnored private var core: PhoneSyncCore?
    private let previewStore: ProductionPreviewStore
    private let narrationRepository: NarrationProjectRepository
    private let outbox: ReviewEventOutbox
    private let applicator = ProductionReviewEventApplicator()
    private let powerPolicy: ProductionPowerPolicy

    public init(
        previewStore: ProductionPreviewStore,
        narrationRepository: NarrationProjectRepository = NarrationProjectRepository(),
        powerPolicy: ProductionPowerPolicy = ProductionPowerPolicy()
    ) {
        self.previewStore = previewStore
        self.narrationRepository = narrationRepository
        self.powerPolicy = powerPolicy
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.outbox = ReviewEventOutbox(
            storage: FileWatchOutboxStorage(directory: directory.appendingPathComponent("ProductionOutbox", isDirectory: true))
        )
    }

    private var syncCore: PhoneSyncCore {
        if let core { return core }
        let newCore = PhoneSyncCore(projectsRoot: narrationRepository.projectsRoot)
        core = newCore
        return newCore
    }

    /// Enqueues a review action for the local fold. Safe to call offline; events
    /// are queued file-backed and folded on the next successful check.
    public func enqueue(_ event: ReviewEvent) {
        try? outbox.enqueue(event)
        refreshPendingCount()
    }

    public func refreshPendingCount() {
        pendingOutboxCount = (try? outbox.pending().count) ?? 0
    }

    /// One phone-as-writer sync pass: publish local projects, upload originals,
    /// fetch the mirror, and hydrate remote-only originals when iCloud is
    /// available; then fold queued review events — which is local-only and never
    /// waits on iCloud.
    public func checkForUpdates() async {
        isChecking = true
        defer { isChecking = false }

        accountStatus = await syncCore.transport.accountStatus()
        if accountStatus == .available {
            do {
                // P9 low-power hardening (§17 P9): on Low Power Mode, still pull
                // the mirror (cheap, small) and fold local events, but defer the
                // expensive upload/hydrate radio and disk work to a normal-power
                // pass. Nothing local is lost by deferring.
                let deferBackground = powerPolicy.shouldDeferBackgroundSync
                if deferBackground {
                    let report = try await syncCore.engine.pump()
                    if let projection = report.projection {
                        await previewStore.apply(projection)
                        lastReceivedRevision = projection.revision
                        for (paragraphID, data) in report.proxyAssets {
                            await previewStore.saveProxy(data: data, paragraphID: paragraphID, projectID: projection.project.id)
                        }
                    }
                } else {
                    await syncCore.transport.ensureSubscription()

                    // The phone is the writer: mirror every local project, then upload
                    // originals that are not yet verified.
                    let projects = await narrationRepository.allProjects()
                    for project in projects {
                        _ = try? await publishProject(project)
                    }
                    try await uploadPendingAssets()

                    // Fetch the mirror back (recovery / second device) and apply it.
                    let report = try await syncCore.engine.pump()
                    if let projection = report.projection {
                        await previewStore.apply(projection)
                        lastReceivedRevision = projection.revision
                        for (paragraphID, data) in report.proxyAssets {
                            await previewStore.saveProxy(data: data, paragraphID: paragraphID, projectID: projection.project.id)
                        }
                    }

                    // Restore any remote-only originals.
                    try await hydrateRemoteAssets()
                }
                syncError = nil
            } catch let error as SyncError where error == .quotaExceeded {
                // §6.5 quota behavior: the pass halts cleanly, the entitlement to
                // offload is unchanged (assets stay un-evictable), and the UI
                // surfaces a real quota message instead of a generic failure.
                accountStatus = .quotaExceeded
                syncError = error.localizedDescription
            } catch {
                syncError = error.localizedDescription
            }
        } else if accountStatus == .notAuthenticated {
            syncError = "Sign in to iCloud to back up your narrations."
        }

        // The fold is local-only and never waits on iCloud.
        await foldPendingReviewEvents()
        refreshPendingCount()
        lastSyncDate = Date()
        onProjectionsUpdated?()
    }

    /// Fetches proxy audio for a set of queue items. On the MVP the full fetch in
    /// `checkForUpdates` already downloads every proxy the mirror carries; this stays
    /// as the explicit prefetch seam for the opportunistic Wi-Fi policy.
    public func downloadProxies(paragraphIDs: [UUID], projectID: UUID) async {
        // Proxies arrive with the mirror fetch; nothing additional to do here.
        _ = paragraphIDs
        _ = projectID
    }

    // MARK: - Phone-as-writer internals

    private func publishProject(_ project: AudiobookProject) async throws -> PublishOutcome {
        let store = narrationRepository.store(for: project.id)
        let counts = try await store.counts()
        return try await syncCore.publisher.publishIfNeeded(
            reason: .appBackgrounded,
            project: project,
            counts: counts
        )
    }

    /// Uploads every unverified original for every project. A failed upload never
    /// aborts the pass and never makes the asset evictable (spec §6.3).
    private func uploadPendingAssets() async throws {
        for project in await narrationRepository.allProjects() {
            let repository = SQLiteProductionAssetRepository(databaseURL: narrationRepository.layout(for: project.id).databaseURL)
            let takeIDs = takeIDsBySHA(in: project)
            let uploader = CloudAssetUploader(
                repository: repository,
                transport: syncCore.transport,
                assetStore: narrationRepository.fileStore(for: project.id),
                takeIDProvider: { sha in takeIDs[sha] }
            )
            _ = try? await uploader.uploadPending()
        }
    }

    /// Hydrates `remoteOnly` originals for every project, SHA-verifying before
    /// the blob is written and before the record becomes `localAndRemote`.
    private func hydrateRemoteAssets() async throws {
        for project in await narrationRepository.allProjects() {
            let repository = SQLiteProductionAssetRepository(databaseURL: narrationRepository.layout(for: project.id).databaseURL)
            let records = (try? await repository.records()) ?? []
            let plan = ProductionHydrationPlanner().plan(for: records, purpose: .originalTake)
            guard !plan.assetIDs.isEmpty else { continue }
            let executor = AssetHydrationExecutor(
                repository: repository,
                transport: syncCore.transport,
                assetStore: narrationRepository.fileStore(for: project.id)
            )
            _ = try? await executor.hydrate(plan)
        }
    }

    /// Folds queued review events into the local project stores (idempotent by
    /// event id), re-projects changed projects into the preview store + watch,
    /// and attempts a mirror republish for anything whose state changed.
    private func foldPendingReviewEvents() async {
        guard let pending = try? outbox.pending(), !pending.isEmpty else { return }
        let byProject = Dictionary(grouping: pending) { $0.projectID }
        var consumed: [UUID] = []
        for (projectID, events) in byProject {
            let store = narrationRepository.store(for: projectID)
            guard let changed = try? await applicator.apply(events: events, to: store),
                  let project = try? await store.load() else { continue }
            consumed.append(contentsOf: events.map(\.id))
            if !changed.isEmpty {
                await applyToPreviewStore(project)
                _ = try? await publishProject(project)
            }
        }
        try? outbox.consume(ids: consumed)
    }

    /// Derives a fresh projection of a locally changed project so the review
    /// surfaces and the watch see the folded state immediately (spec §4.3).
    private func applyToPreviewStore(_ project: AudiobookProject) async {
        let store = narrationRepository.store(for: project.id)
        guard let counts = try? await store.counts() else { return }
        let revision = await narrationRepository.nextProjectionRevision(for: project.id)
        guard let projection = ProjectionBuilder().projection(from: project, counts: counts, revision: revision) else { return }
        await previewStore.apply(projection)
    }

    private func takeIDsBySHA(in project: AudiobookProject) -> [String: UUID] {
        var result: [String: UUID] = [:]
        for paragraph in project.allParagraphs {
            for take in paragraph.takes {
                result[take.assetRef.sha256] = take.id
            }
        }
        return result
    }
}

/// The lazily-created CloudKit stack: transport, engine, and the publisher that
/// mirrors phone-owned state. Built only when the first sync operation runs, so
/// app processes that never sync (UI smoke tests, hosted scene tests) never touch
/// `CKContainer`.
private final class PhoneSyncCore: @unchecked Sendable {
    let transport: CloudKitProductionSync
    let engine: ProductionSyncEngine
    let publisher: ProjectionPublisher

    init(projectsRoot: URL) {
        let transport = CloudKitProductionSync(proxyFileProvider: Self.makeFileProvider(projectsRoot: projectsRoot))
        self.transport = transport
        let state = DefaultsSyncStateStore()
        let engine = ProductionSyncEngine(transport: transport, state: state)
        self.engine = engine
        self.publisher = ProjectionPublisher(engine: engine)
    }

    /// Resolves a content address to the on-device file across every project
    /// package, so the transport can back a `CKAsset` for proxies and originals
    /// (§6.3). Content-addressed, so the sha IS the identity.
    private static func makeFileProvider(projectsRoot: URL) -> @Sendable (String) async throws -> URL? {
        { sha in
            let fm = FileManager.default
            guard let directories = try? fm.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: nil) else { return nil }
            for directory in directories where directory.hasDirectoryPath {
                let original = directory.appendingPathComponent("Audio/Original", isDirectory: true)
                guard let files = try? fm.contentsOfDirectory(at: original, includingPropertiesForKeys: nil) else { continue }
                if let match = files.first(where: { $0.lastPathComponent.hasPrefix(sha + ".") }) {
                    return match
                }
            }
            return nil
        }
    }
}
