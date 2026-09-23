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
            // preserves the transport's idempotent event semantics.
            let report = try await sync.engine.pump()
            for remote in mergeRemoteRecords(report) {
                try await materializeRemoteProject(remote.projection, records: remote.records, report: report)
            }
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

    /// Turns the shared selected-take projection into the ordinary Mac project
    /// package when a project was created on another device. Existing local
    /// edits win: once the package's modified date moves past the last remote
    /// revision, a later sync never overwrites the narrator's local work.
    private func materializeRemoteProject(
        _ projection: SyncProjection,
        records: [SyncRecord],
        report: IngestReport
    ) async throws {
        let projectID = projection.project.id
        let remoteDateKey = "voxglass.mac.remoteProjectDate.\(projectID.uuidString)"
        if let existing = try? await repository.load(projectID) {
            let lastRemoteDate = UserDefaults.standard.double(forKey: remoteDateKey)
            if existing.modifiedAt.timeIntervalSince1970 > lastRemoteDate + 0.5 {
                return
            }
        }

        let codec = ProjectionRecordCodec()
        let mirrors: [String: AssetMirrorRecord] = Dictionary(uniqueKeysWithValues: records.compactMap { record in
            guard let mirror = codec.assetMirror(from: record) else { return nil }
            return (mirror.sha256, mirror)
        })
        let files = repository.fileStore(for: projectID)
        var refsBySHA: [String: AudioAssetReference] = [:]
        for mirror in mirrors.values {
            if let data = report.originalAssets[mirror.sha256], SHA256Hex.hex(data) == mirror.sha256 {
                refsBySHA[mirror.sha256] = try await files.put(
                    data,
                    ext: mirror.ext,
                    contentType: mirror.contentType,
                    subdirectory: .original
                )
            } else {
                let existing = AudioAssetReference(
                    sha256: mirror.sha256,
                    relativePath: Self.fanoutPath(sha: mirror.sha256, ext: mirror.ext, subdirectory: .original),
                    byteCount: Int(mirror.byteCount),
                    contentType: mirror.contentType
                )
                if files.exists(existing) {
                    refsBySHA[mirror.sha256] = existing
                }
            }
        }

        var chapters: [ProductionChapter] = []
        for chapter in projection.chapters.sorted(by: { $0.ordinal < $1.ordinal }) {
            var paragraphs: [Paragraph] = []
            for paragraph in projection.paragraphs
                .filter({ $0.chapterID == chapter.id })
                .sorted(by: { $0.ordinal < $1.ordinal }) {
                let text = paragraph.text ?? ""
                var takes: [Take] = []
                if let takeID = paragraph.takeID {
                    let ref: AudioAssetReference?
                    if let sha = paragraph.proxySourceSHA, let original = refsBySHA[sha] {
                        ref = original
                    } else if let data = report.proxyAssets[paragraph.id] {
                        ref = try? await awaitPutProxy(data, files: files)
                    } else if let sha = paragraph.proxySourceSHA, let mirror = mirrors[sha] {
                        ref = AudioAssetReference(
                            sha256: mirror.sha256,
                            relativePath: Self.fanoutPath(sha: mirror.sha256, ext: mirror.ext, subdirectory: .original),
                            byteCount: Int(mirror.byteCount),
                            contentType: mirror.contentType
                        )
                    } else {
                        ref = nil
                    }
                    if let ref {
                        takes.append(Take(
                            id: takeID,
                            paragraphID: paragraph.id,
                            assetRef: ref,
                            origin: Self.origin(for: paragraph.originKind),
                            recordedAt: projection.project.modifiedAt,
                            duration: paragraph.duration,
                            format: AudioFormatDescription(sampleRate: 48_000, channels: 1, bitDepth: 24, codec: "remote"),
                            textHashAtRecording: SHA256Hex.hex(Data(text.utf8))
                        ))
                    }
                }
                paragraphs.append(Paragraph(
                    id: paragraph.id,
                    ordinal: paragraph.ordinal,
                    text: text,
                    textHash: SHA256Hex.hex(Data(text.utf8)),
                    takes: takes,
                    selectedTakeID: takes.isEmpty ? nil : paragraph.takeID,
                    reviewState: paragraph.reviewState,
                    updatedAt: projection.project.modifiedAt
                ))
            }
            chapters.append(ProductionChapter(
                id: chapter.id,
                ordinal: chapter.ordinal,
                title: chapter.title,
                role: chapter.role,
                paragraphs: paragraphs
            ))
        }

        let project = AudiobookProject(
            id: projectID,
            metadata: BookMetadata(
                title: projection.project.title,
                author: projection.project.author,
                narrator: projection.project.narrator
            ),
            profile: ProductionProfile(purpose: projection.project.purpose),
            chapters: chapters,
            createdAt: projection.project.modifiedAt,
            modifiedAt: projection.project.modifiedAt
        )
        try await repository.save(project)

        let assets = SQLiteProductionAssetRepository(databaseURL: repository.layout(for: projectID).databaseURL)
        for mirror in mirrors.values {
            try await assets.upsert(ProductionAssetRecord(
                id: mirror.id,
                sha256: mirror.sha256,
                byteCount: mirror.byteCount,
                state: refsBySHA[mirror.sha256] == nil ? .remoteOnly : .localAndRemote,
                chapterID: mirror.chapterID,
                lastAccessedAt: projection.project.modifiedAt,
                remoteAssetID: ProductionRecordType.recordName(prefix: "asset", id: mirror.id)
            ))
        }
        UserDefaults.standard.set(projection.project.modifiedAt.timeIntervalSince1970, forKey: remoteDateKey)
    }

    /// CloudKit change fetches are deltas. Keep a metadata-only record mirror so
    /// a paragraph or asset update can rebuild the complete projection instead of
    /// replacing the local project with the incomplete batch returned by CloudKit.
    private func mergeRemoteRecords(_ report: IngestReport) -> [(projection: SyncProjection, records: [SyncRecord])] {
        let defaults = UserDefaults.standard
        let key = "voxglass.mac.remoteRecords"
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        var byName: [String: SyncRecord] = [:]
        if let data = defaults.data(forKey: key),
           let stored = try? decoder.decode([String: SyncRecord].self, from: data) {
            byName = stored
        }
        for record in report.records {
            var metadata = record
            metadata.assetFields = [:]
            byName[metadata.recordName] = metadata
        }
        for name in report.deletedRecordNames {
            byName.removeValue(forKey: name)
        }
        let records = Array(byName.values)
        if let data = try? encoder.encode(byName) {
            defaults.set(data, forKey: key)
        }
        let projectIDs = records.compactMap { record -> UUID? in
            guard record.recordType == ProductionRecordType.project.rawValue else { return nil }
            return record.fields[ProductionField.projectID]?.stringValue().flatMap(UUID.init(uuidString:))
        }
        let codec = ProjectionRecordCodec()
        return projectIDs.compactMap { projectID in
            let projectRecords = records.filter { record in
                guard record.recordType != ProductionRecordType.asset.rawValue else { return false }
                return record.fields[ProductionField.projectID]?.stringValue() == projectID.uuidString
            }
            guard let projection = codec.projection(from: projectRecords) else { return nil }
            return (projection, records)
        }
    }

    private func awaitPutProxy(_ data: Data, files: FileAssetStore) async throws -> AudioAssetReference {
        try await files.put(data, ext: "m4a", contentType: "audio/mp4", subdirectory: .proxy)
    }

    private static func fanoutPath(sha: String, ext: String, subdirectory: AssetSubdirectory) -> String {
        let first = String(sha.prefix(2))
        let second = String(sha.dropFirst(2).prefix(2))
        return "\(subdirectory.rawValue)/\(first)/\(second)/\(sha).\(ext)"
    }

    private static func origin(for kind: String) -> AudioOrigin {
        switch kind {
        case "recorded": return .recorded
        case "importedHuman": return .importedHuman(sourceFilename: "remote recording")
        case "aiImported": return .aiImported(providerLabel: "remote source")
        default: return .unknownImport(sourceFilename: "remote source")
        }
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
