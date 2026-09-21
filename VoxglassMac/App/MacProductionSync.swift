import Foundation
import Observation
import VoxglassCore

/// Native-Mac peer for the existing production transport. Local project writes
/// never wait for this coordinator; a sync pass publishes verified projections,
/// uploads content-addressed originals, then pulls the current mirror.
@MainActor
final class MacProductionSync: ObservableObject {
    @Published private(set) var accountStatus: SyncAccountStatus = .unavailable
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var syncError: String?
    @Published private(set) var isChecking = false

    private let repository: NarrationProjectRepository
    private var core: MacSyncCore?

    init(repository: NarrationProjectRepository) {
        self.repository = repository
    }

    func checkForUpdates() async {
        isChecking = true
        defer {
            isChecking = false
            lastSyncDate = Date()
        }

        do {
            let sync = syncCore
            accountStatus = await sync.transport.accountStatus()
            guard accountStatus == .available else {
                syncError = accountStatus == .notAuthenticated
                    ? "Sign in to iCloud to sync narrations."
                    : "iCloud is not available right now. Local recording is still available."
                return
            }

            await sync.transport.ensureSubscription()
            for project in await repository.allProjects() {
                let store = repository.store(for: project.id)
                let counts = try await store.counts()
                _ = try await sync.publisher.publishIfNeeded(
                    reason: .appBackgrounded,
                    project: project,
                    counts: counts
                )
            }

            for project in await repository.allProjects() {
                let assetRepository = SQLiteProductionAssetRepository(
                    databaseURL: repository.layout(for: project.id).databaseURL
                )
                let takeIDs = Self.takeIDsBySHA(in: project)
                let uploader = CloudAssetUploader(
                    repository: assetRepository,
                    transport: sync.transport,
                    assetStore: repository.fileStore(for: project.id),
                    takeIDProvider: { sha in takeIDs[sha] }
                )
                _ = try await uploader.uploadPending()
            }

            // Pulling the projection advances the shared change token and
            // preserves the transport's idempotent event semantics. Local
            // project stores remain authoritative for unsynced edits.
            _ = try await sync.engine.pump()
            syncError = nil
        } catch {
            syncError = error.localizedDescription
        }
    }

    private var syncCore: MacSyncCore {
        if let core { return core }
        let newCore = MacSyncCore(projectsRoot: repository.projectsRoot)
        core = newCore
        return newCore
    }

    private static func takeIDsBySHA(in project: AudiobookProject) -> [String: UUID] {
        var result: [String: UUID] = [:]
        for paragraph in project.allParagraphs {
            for take in paragraph.takes {
                result[take.assetRef.sha256] = take.id
            }
        }
        return result
    }
}

private final class MacSyncCore: @unchecked Sendable {
    let transport: CloudKitProductionSync
    let engine: ProductionSyncEngine
    let publisher: ProjectionPublisher

    init(projectsRoot: URL) {
        let transport = CloudKitProductionSync(proxyFileProvider: Self.fileProvider(projectsRoot: projectsRoot))
        self.transport = transport
        self.engine = ProductionSyncEngine(transport: transport, state: DefaultsSyncStateStore())
        self.publisher = ProjectionPublisher(engine: engine)
    }

    private static func fileProvider(projectsRoot: URL) -> @Sendable (String) async throws -> URL? {
        { sha in
            let directories = (try? FileManager.default.contentsOfDirectory(
                at: projectsRoot,
                includingPropertiesForKeys: nil
            )) ?? []
            for directory in directories where directory.hasDirectoryPath {
                let original = ProductionProjectLayout(root: directory).originalAudioURL
                let files = (try? FileManager.default.contentsOfDirectory(
                    at: original,
                    includingPropertiesForKeys: nil
                )) ?? []
                if let match = files.first(where: { $0.lastPathComponent.hasPrefix(sha + ".") }) {
                    return match
                }
            }
            return nil
        }
    }
}
