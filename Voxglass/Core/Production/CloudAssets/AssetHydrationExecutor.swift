import Foundation

/// The hydration outcome for one `hydrate(_:)` run.
public struct AssetHydrationReport: Sendable, Equatable {
    /// Assets restored to `.localAndRemote` with content-address verification.
    public var hydrated: [UUID]
    /// Assets that were already local when the plan ran (idempotent resume).
    public var alreadyLocal: [UUID]
    /// Asset ids that failed; they stay `.remoteOnly` and are retried next run.
    public var failed: [(UUID, String)]

    public init(hydrated: [UUID] = [], alreadyLocal: [UUID] = [], failed: [(UUID, String)] = []) {
        self.hydrated = hydrated
        self.alreadyLocal = alreadyLocal
        self.failed = failed
    }

    public static func == (lhs: AssetHydrationReport, rhs: AssetHydrationReport) -> Bool {
        lhs.hydrated == rhs.hydrated
            && lhs.alreadyLocal == rhs.alreadyLocal
            && lhs.failed.map(\.0) == rhs.failed.map(\.0)
            && lhs.failed.map(\.1) == rhs.failed.map(\.1)
    }
}

public enum AssetHydrationError: Error, Sendable, Equatable, LocalizedError {
    /// The local record has no persisted remote id, so there is nothing to fetch.
    case noRemoteID(assetID: UUID)
    /// The server had no `VGProductionAsset` record at the persisted remote id.
    case recordMissing(recordName: String)
    /// The fetched record carried no blob under the original asset field.
    case noBlob(recordName: String)
    /// The fetched blob's SHA-256 did not match the recorded hash; the asset is
    /// not written locally and stays `.remoteOnly`.
    case hashMismatch(assetID: UUID, expectedSHA: String, fetchedSHA: String)

    public var errorDescription: String? {
        switch self {
        case .noRemoteID:
            return "This recording has no verified iCloud copy yet."
        case .recordMissing(let name):
            return "The iCloud copy \(name) could not be found."
        case .noBlob:
            return "The iCloud copy carried no audio data."
        case .hashMismatch:
            return "The downloaded recording did not verify against its checksum."
        }
    }
}

/// Restores `.remoteOnly` originals from the private CloudKit zone (spec §6.3
/// hydration path). Resumable across launches: state lives in the
/// `production_asset` table, so a partial run skips whatever is already local
/// and re-fetches only the rest, and a hash mismatch is never written to disk.
///
/// Every hydrated blob is content-address verified (SHA-256 of the bytes equals
/// the recorded `sha256`) before the store write and before the record flips to
/// `.localAndRemote`, which is what makes it eligible for playback/export.
public actor AssetHydrationExecutor {
    private let repository: any ProductionAssetRepository
    private let transport: any ProductionSyncTransport
    private let assetStore: any ContentAddressedStore
    private let clock: any Clock
    private let codec = ProjectionRecordCodec()

    public init(
        repository: any ProductionAssetRepository,
        transport: any ProductionSyncTransport,
        assetStore: any ContentAddressedStore,
        clock: any Clock = SystemClock()
    ) {
        self.repository = repository
        self.transport = transport
        self.assetStore = assetStore
        self.clock = clock
    }

    /// Hydrates every asset in the plan. Assets already `.localAndRemote` are
    /// reported as `alreadyLocal` and never re-fetched; failed assets stay
    /// `.remoteOnly` so a relaunch resumes exactly where this run stopped.
    public func hydrate(_ plan: ProductionHydrationPlan) async throws -> AssetHydrationReport {
        var report = AssetHydrationReport()
        for assetID in plan.assetIDs {
            guard let record = try await repository.record(id: assetID) else { continue }
            guard record.state == .remoteOnly || record.state == .missing else {
                report.alreadyLocal.append(assetID)
                continue
            }
            guard let remoteID = record.remoteAssetID else {
                report.failed.append((assetID, String(describing: AssetHydrationError.noRemoteID(assetID: assetID))))
                continue
            }
            do {
                try await hydrateOne(record: record, remoteID: remoteID)
                report.hydrated.append(assetID)
            } catch {
                report.failed.append((assetID, String(describing: error)))
            }
        }
        return report
    }

    // MARK: - Internals

    private func hydrateOne(record: ProductionAssetRecord, remoteID: String) async throws {
        // 1. Fetch the server record by its persisted remote id.
        let fetched = try await transport.fetchRecords([remoteID])
        guard let server = fetched.first, let mirror = codec.assetMirror(from: server) else {
            throw AssetHydrationError.recordMissing(recordName: remoteID)
        }
        guard let blob = server.assetFields[ProductionAssetField.original] else {
            throw AssetHydrationError.noBlob(recordName: remoteID)
        }

        // 2. Content-address verify BEFORE any local write (§6.3 hydration step 4).
        let blobSHA = SHA256Hex.hex(blob)
        guard blobSHA == record.sha256 && blobSHA == mirror.sha256 else {
            throw AssetHydrationError.hashMismatch(assetID: record.id, expectedSHA: record.sha256, fetchedSHA: blobSHA)
        }

        // 3. Write into the content-addressed store; the ref sha is the verified
        //    hash by construction. Idempotent: same bytes → same file.
        let ref = try await assetStore.put(blob, ext: mirror.ext, contentType: mirror.contentType, subdirectory: .original)
        guard ref.sha256 == blobSHA else {
            throw AssetHydrationError.hashMismatch(assetID: record.id, expectedSHA: blobSHA, fetchedSHA: ref.sha256)
        }

        // 4. Flip to `.localAndRemote` only after the file is durable.
        var hydrated = record
        hydrated.state = .localAndRemote
        hydrated.lastAccessedAt = clock.now
        try await repository.upsert(hydrated)
    }
}
