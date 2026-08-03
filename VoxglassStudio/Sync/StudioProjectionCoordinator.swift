import Foundation
import VoxglassCore

/// The Mac's production-sync coordinator (spec §13.1–§13.8): owns the engine,
/// publisher, and ingestor for the currently open project, generates proxies, and
/// exposes live status for the Device Preview screen. One per app; `@MainActor`
/// because it drives UI-observable state.
@MainActor
@Observable
public final class StudioProjectionCoordinator {

    public private(set) var accountStatus: SyncAccountStatus = .unavailable
    public private(set) var lastPublishedRevision: Int?
    public private(set) var lastSyncDate: Date?
    public private(set) var lastSyncError: String?
    public private(set) var isSyncing = false
    public private(set) var pendingFeedbackCount = 0

    @ObservationIgnored private var core: SyncCore?
    @ObservationIgnored private let clock: any Clock
    private let proxyResolver = ProxyResolver()
    private let proxyGenerator = ProxyGenerator()
    private let sinkBox = SinkBox()

    public var currentStore: (any ProductionStore)?
    public var currentAssets: (any ContentAddressedStore)?

    /// The CloudKit stack is created lazily on first sync/ingest use. Constructing
    /// `CKContainer` requires an entitled app process and traps otherwise; the
    /// coordinator is also created by `StudioEnvironment` in unit tests, where no
    /// CloudKit access is ever performed.
    public init(clock: any Clock = SystemClock()) {
        self.clock = clock
    }

    private var syncCore: SyncCore {
        if let core { return core }
        let newCore = SyncCore(proxyResolver: proxyResolver, sinkBox: sinkBox, clock: clock)
        core = newCore
        return newCore
    }

    private var transport: CloudKitProductionSync { syncCore.transport }
    private var engine: ProductionSyncEngine { syncCore.engine }
    private var publisher: ProjectionPublisher { syncCore.publisher }
    private var ingestor: EventIngestor { syncCore.ingestor }

    public func configure(project: AudiobookProject, store: any ProductionStore, assets: any ContentAddressedStore) {
        currentStore = store
        currentAssets = assets
        proxyResolver.configure(directory: proxyDirectory(for: project.id))
        sinkBox.set(StudioEventSink(store: store))
    }

    /// Manual "Preview on Devices" / periodic publish + ingest.
    public func syncNow(project: AudiobookProject, store: any ProductionStore, assets: any ContentAddressedStore, reason: PublishReason = .manual) async {
        configure(project: project, store: store, assets: assets)
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await transport.ensureSubscription()
            let outcome = try await publishIfNeeded(reason: reason, project: project, store: store, assets: assets)
            await ingest()
            lastSyncDate = Date()
            lastSyncError = nil
            switch outcome {
            case let .published(revision, _, _): lastPublishedRevision = revision
            default: break
            }
        } catch {
            lastSyncError = error.localizedDescription
        }
    }

    /// Publishes the projection delta (spec §13.5). No-op if nothing changed.
    public func publishIfNeeded(
        reason: PublishReason,
        project: AudiobookProject,
        store: any ProductionStore,
        assets: any ContentAddressedStore,
        watchPinnedParagraphIDs: [UUID] = []
    ) async throws -> PublishOutcome {
        configure(project: project, store: store, assets: assets)
        await ensureProxies(project: project, store: store, assets: assets)
        let counts = try await store.counts()
        let notes = try await latestNotes(store: store, project: project)
        let outcome = try await publisher.publishIfNeeded(
            reason: reason,
            project: project,
            counts: counts,
            watchPinnedParagraphIDs: watchPinnedParagraphIDs,
            latestNotes: notes
        )
        Log.sync.info("projection publish (\(reason.rawValue)): \(String(describing: outcome))")
        return outcome
    }

    /// Ingests review events from devices (spec §13.7) and republishes if changed.
    public func ingest() async {
        do {
            let applied = try await ingestor.pump()
            Log.sync.info("review event ingest: \(applied.events.count) events, \(applied.eventRecordNames.count) records consumed")
            await refreshPendingFeedback()
        } catch {
            lastSyncError = error.localizedDescription
        }
    }

    /// Marks paragraphs for the watch's offline queue (spec §13.8).
    public func prepareOfflineQueue(_ pinned: [UUID], project: AudiobookProject, store: any ProductionStore, assets: any ContentAddressedStore) async {
        _ = try? await publishIfNeeded(
            reason: .manual,
            project: project,
            store: store,
            assets: assets,
            watchPinnedParagraphIDs: pinned
        )
    }

    public func hideFromDevices(_ hidden: Bool, project: AudiobookProject, store: any ProductionStore, assets: any ContentAddressedStore) async {
        var updated = project
        updated.profile.isHiddenFromDevices = hidden
        _ = try? await publishIfNeeded(reason: .manual, project: updated, store: store, assets: assets)
    }

    public func refreshAccountStatus() async {
        accountStatus = await transport.accountStatus()
    }

    // MARK: - Internals

    private func ensureProxies(project: AudiobookProject, store: any ProductionStore, assets: any ContentAddressedStore) async {
        let directory = proxyDirectory(for: project.id)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for paragraph in project.allParagraphs {
            guard let takeID = paragraph.selectedTakeID,
                  let take = paragraph.takes.first(where: { $0.id == takeID }) else { continue }
            let output = directory.appendingPathComponent("\(take.assetRef.sha256).m4a")
            guard !FileManager.default.fileExists(atPath: output.path) else { continue }
            let source = assets.url(for: take.assetRef)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try? await proxyGenerator.generate(from: source, to: output)
        }
    }

    private func latestNotes(store: any ProductionStore, project: AudiobookProject) async throws -> [UUID: ReviewNote] {
        // Notes only exist where the paragraph is under review; skip the untouched mass.
        var result: [UUID: ReviewNote] = [:]
        for paragraph in project.allParagraphs where paragraph.reviewState != .unreviewed {
            if let note = try await store.notes(forParagraph: paragraph.id).max(by: { $0.createdAt < $1.createdAt }) {
                result[paragraph.id] = note
            }
        }
        return result
    }

    private func refreshPendingFeedback() async {
        guard let store = currentStore else { return }
        let unapplied = (try? await store.unappliedEvents().count) ?? 0
        pendingFeedbackCount = unapplied
    }

    private func proxyDirectory(for projectID: UUID) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Productions/\(projectID.uuidString)/proxies", isDirectory: true)
    }
}

/// Lock-protected proxy file resolver captured by the transport's asset closure.
private final class ProxyResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var directory: URL?

    func configure(directory: URL) {
        locked { self.directory = directory }
    }

    func file(for sha: String) async -> URL? {
        locked {
            guard let directory else { return nil }
            let url = directory.appendingPathComponent("\(sha).m4a")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    /// `NSLock` is unavailable directly in async contexts (Swift 6); route every
    /// access through this synchronous helper.
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

/// Lock-protected holder for the current project's `ProductionEventSink`, so the
/// `EventIngestor` provider closure does not capture the coordinator during init.
private final class SinkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (any ProductionEventSink)?

    func set(_ sink: any ProductionEventSink) {
        locked { self.sink = sink }
    }

    func sink() async -> (any ProductionEventSink)? {
        locked { sink }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

/// The lazily-created CloudKit stack: transport, engine, publisher, and ingestor.
/// Built only when the first sync operation runs, so test processes that construct
/// the coordinator never touch `CKContainer`.
private final class SyncCore: @unchecked Sendable {
    let transport: CloudKitProductionSync
    let engine: ProductionSyncEngine
    let publisher: ProjectionPublisher
    let ingestor: EventIngestor

    init(proxyResolver: ProxyResolver, sinkBox: SinkBox, clock: any Clock) {
        let transport = CloudKitProductionSync(proxyFileProvider: { sha in
            await proxyResolver.file(for: sha)
        })
        self.transport = transport
        let state = DefaultsSyncStateStore()
        let engine = ProductionSyncEngine(transport: transport, state: state)
        self.engine = engine
        self.publisher = ProjectionPublisher(engine: engine, clock: clock)
        self.ingestor = EventIngestor(engine: engine, sinkProvider: { await sinkBox.sink() })
    }
}
