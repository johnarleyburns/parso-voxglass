import Foundation

/// The upload outcome for one `uploadPending()` pass.
public struct CloudAssetUploadReport: Sendable, Equatable {
    /// Assets flipped to `.localAndRemote` with a persisted remote id.
    public var uploaded: [UUID]
    /// Assets skipped because they were already verified and remote.
    public var skipped: [UUID]
    /// Asset ids that failed, with a human-readable reason. Failed assets stay
    /// `.localOnly`/`.uploading` and are retried on the next pass.
    public var failed: [(UUID, String)]

    public init(uploaded: [UUID] = [], skipped: [UUID] = [], failed: [(UUID, String)] = []) {
        self.uploaded = uploaded
        self.skipped = skipped
        self.failed = failed
    }

    public static func == (lhs: CloudAssetUploadReport, rhs: CloudAssetUploadReport) -> Bool {
        lhs.uploaded == rhs.uploaded
            && lhs.skipped == rhs.skipped
            && lhs.failed.map(\.0) == rhs.failed.map(\.0)
            && lhs.failed.map(\.1) == rhs.failed.map(\.1)
    }
}

public enum CloudAssetUploadError: Error, Sendable, Equatable, LocalizedError {
    /// The asset is already `.localAndRemote`; upload is a deliberate no-op.
    case alreadyRemote
    /// No file for the content address was found in the original store.
    case noOriginalFile(sha256: String)
    /// The server record's `sha256` field did not match the local hash (§6.3
    /// step 3). The asset stays `.uploading` and un-evictable.
    case hashMismatch(recordName: String, localSHA: String, serverSHA: String)
    /// The pushed record could not be re-read from the server.
    case serverRecordMissing(recordName: String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRemote:
            return "The asset is already backed up and verified."
        case .noOriginalFile(let sha):
            return "No local file exists for asset \(sha)."
        case .hashMismatch:
            return "The iCloud copy did not match the local recording and was not accepted."
        case .serverRecordMissing(let name):
            return "The uploaded asset record \(name) could not be re-read for verification."
        }
    }
}

/// Uploads content-addressed originals to the private CloudKit zone with
/// SHA-256 verification (spec §6.3), so local storage becomes evictable only
/// after the remote copy is proven identical and the remote id is persisted.
///
/// The per-asset order of effects is fixed: mark `.uploading` in SQLite **before**
/// any network work; push the `VGProductionAsset` record; re-read the server
/// record and compare its `sha256` field to the local hash; then persist
/// `remoteAssetID` and flip to `.localAndRemote` in a single upsert. A kill
/// anywhere in that sequence leaves the record `.uploading` (never `.isEvictable`),
/// and the next launch re-pushes and re-verifies (idempotent by record name).
public actor CloudAssetUploader {
    private let repository: any ProductionAssetRepository
    private let transport: any ProductionSyncTransport
    private let assetStore: any ContentAddressedStore
    private let takeIDProvider: @Sendable (String) async throws -> UUID?
    private let clock: any Clock
    private let codec = ProjectionRecordCodec()

    public init(
        repository: any ProductionAssetRepository,
        transport: any ProductionSyncTransport,
        assetStore: any ContentAddressedStore,
        takeIDProvider: @escaping @Sendable (String) async throws -> UUID? = { _ in nil },
        clock: any Clock = SystemClock()
    ) {
        self.repository = repository
        self.transport = transport
        self.assetStore = assetStore
        self.takeIDProvider = takeIDProvider
        self.clock = clock
    }

    /// Uploads every asset that is not yet verified: `.localOnly` assets start
    /// their first upload, `.uploading` assets resume a previous in-flight or
    /// interrupted upload. Never evictable before verification.
    public func uploadPending() async throws -> CloudAssetUploadReport {
        let records = try await repository.records()
        var uploaded: [UUID] = []
        var skipped: [UUID] = []
        var failed: [(UUID, String)] = []

        for record in records where record.state == .localOnly || record.state == .uploading {
            do {
                try await upload(record)
                uploaded.append(record.id)
            } catch CloudAssetUploadError.alreadyRemote {
                skipped.append(record.id)
            } catch {
                failed.append((record.id, String(describing: error)))
            }
        }
        return CloudAssetUploadReport(uploaded: uploaded, skipped: skipped, failed: failed)
    }

    /// Uploads one asset through the §6.3 ordered path. Throws
    /// `CloudAssetUploadError.alreadyRemote` when the asset is already verified,
    /// and leaves the record `.uploading` on any failure.
    public func upload(_ record: ProductionAssetRecord) async throws {
        guard record.state == .localOnly || record.state == .uploading else {
            throw CloudAssetUploadError.alreadyRemote
        }

        guard let ref = try await originalReference(sha256: record.sha256) else {
            throw CloudAssetUploadError.noOriginalFile(sha256: record.sha256)
        }

        // 1. Mark `.uploading` before any network work (§6.3 step 1).
        if record.state != .uploading {
            var uploading = record
            uploading.state = .uploading
            uploading.lastAccessedAt = clock.now
            try await repository.upsert(uploading)
        }

        // 2. Push the `VGProductionAsset` record. The transport attaches the
        //    `CKAsset` by resolving the sha against the content-addressed store.
        let mirror = AssetMirrorRecord(
            id: record.id,
            sha256: record.sha256,
            byteCount: record.byteCount,
            ext: ext(from: ref),
            contentType: ref.contentType,
            takeID: try await takeIDProvider(record.sha256),
            chapterID: record.chapterID
        )
        let recordName = ProductionRecordType.recordName(prefix: "asset", id: record.id)
        try await transport.pushRecords([codec.assetRecord(from: mirror)])

        // 3. Re-read the server record's sha256 and compare to the local hash.
        //    A byte-count match is not sufficient (§6.3 step 3).
        let fetched = try await transport.fetchRecords([recordName])
        guard let server = fetched.first else {
            throw CloudAssetUploadError.serverRecordMissing(recordName: recordName)
        }
        let serverSHA = server.fields[ProductionField.assetSHA]?.stringValue() ?? ""
        guard serverSHA == record.sha256 else {
            throw CloudAssetUploadError.hashMismatch(
                recordName: recordName,
                localSHA: record.sha256,
                serverSHA: serverSHA
            )
        }

        // 4. Persist the remote id and flip to `.localAndRemote` in one upsert.
        //    If the app dies between 3 and 4 the state stays `.uploading` and the
        //    next launch re-verifies and re-flips — the safe failure (§6.3 step 4).
        var verified = record
        verified.state = .localAndRemote
        verified.remoteAssetID = recordName
        verified.lastAccessedAt = clock.now
        try await repository.upsert(verified)
    }

    // MARK: - Internals

    private func originalReference(sha256: String) async throws -> AudioAssetReference? {
        let refs = try await assetStore.allReferences(under: .original)
        return refs.first { $0.sha256 == sha256 }
    }

    private func ext(from ref: AudioAssetReference) -> String {
        let lastPathComponent = (ref.relativePath as NSString).lastPathComponent
        guard let dot = lastPathComponent.lastIndex(of: ".") else { return "wav" }
        return String(lastPathComponent[lastPathComponent.index(after: dot)...])
    }
}
