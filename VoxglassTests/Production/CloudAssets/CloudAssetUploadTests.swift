import Foundation
import Testing
@testable import VoxglassCore
@testable import VoxglassCoreTestSupport

/// P3 acceptance (§17 P3, §6.3): upload-with-SHA-verification. An upload that
/// dies mid-flight must never make the asset evictable, and a relaunched
/// uploader re-verifies and flips it safely.
@Suite struct CloudAssetUploadTests {

    private var now: Date { FixedClock().now }

    private func makeUploader(
        repository: any ProductionAssetRepository,
        transport: FakeProductionSyncTransport,
        assetStore: any ContentAddressedStore,
        takeIDs: [String: UUID] = [:]
    ) -> CloudAssetUploader {
        CloudAssetUploader(
            repository: repository,
            transport: transport,
            assetStore: assetStore,
            takeIDProvider: { sha in takeIDs[sha] },
            clock: FixedClock()
        )
    }

    /// Writes a real (tiny) original into the store and returns its record.
    private func seedOriginal(
        repository: any ProductionAssetRepository,
        assetStore: any ContentAddressedStore,
        state: ProductionAssetState = .localOnly,
        remoteID: String? = nil,
        bytes: [UInt8] = Array("take-audio".utf8)
    ) async throws -> (record: ProductionAssetRecord, ref: AudioAssetReference) {
        let ref = try await assetStore.put(
            Data(bytes), ext: "wav", contentType: "audio/wav", subdirectory: .original
        )
        let record = ProductionAssetRecord(
            id: UUID(),
            sha256: ref.sha256,
            byteCount: Int64(ref.byteCount),
            state: state,
            chapterID: UUID(),
            chapterOrdinal: 0,
            lastAccessedAt: now,
            remoteAssetID: remoteID
        )
        try await repository.upsert(record)
        return (record, ref)
    }

    /// §6.3 success path: localOnly → uploading → verified → localAndRemote with
    /// a persisted remote id, after which the asset becomes evictable.
    @Test func upload_verifiesThenFlipsToLocalAndRemote() async throws {
        let repo = InMemoryProductionAssetRepository()
        let store = InMemoryAssetStore()
        let transport = FakeProductionSyncTransport()
        let takeID = UUID()
        let (record, _) = try await seedOriginal(repository: repo, assetStore: store)
        try await repo.upsert(ProductionAssetRecord(
            id: record.id, sha256: record.sha256, byteCount: record.byteCount,
            state: .localOnly, chapterID: record.chapterID, chapterOrdinal: 0,
            lastAccessedAt: now
        ))

        let uploader = makeUploader(repository: repo, transport: transport, assetStore: store, takeIDs: [record.sha256: takeID])
        let report = try await uploader.uploadPending()

        #expect(report.uploaded == [record.id])
        #expect(report.failed.isEmpty)
        let verified = try await repo.record(id: record.id)
        #expect(verified?.state == .localAndRemote)
        #expect(verified?.remoteAssetID == "asset-\(record.id.uuidString)")
        #expect(verified?.isEvictable == true)

        // The server record carried the take linkage (§6.2).
        let server = transport.record(named: "asset-\(record.id.uuidString)")
        #expect(server?.fields["sha256"] == .string(record.sha256))
        #expect(server?.fields["takeID"] == .string(takeID.uuidString))
    }

    /// §6.3 step 4 / §17 P3: a kill after the push but before the flip leaves the
    /// state `.uploading`, which `isEvictable` never accepts; a fresh uploader
    /// (relaunch) resumes, re-verifies, and flips.
    @Test func upload_survivesMidFlightKill_neverEvictable_thenResumes() async throws {
        let repo = InMemoryProductionAssetRepository()
        let store = InMemoryAssetStore()
        let transport = FakeProductionSyncTransport()
        let (record, _) = try await seedOriginal(repository: repo, assetStore: store)

        // Kill: the push succeeds but the app dies before the verify+flip step.
        // Simulate by leaving the record `.uploading` with no remote id.
        try await repo.upsert(ProductionAssetRecord(
            id: record.id, sha256: record.sha256, byteCount: record.byteCount,
            state: .uploading, chapterID: record.chapterID, chapterOrdinal: 0,
            lastAccessedAt: now, remoteAssetID: nil
        ))

        // Never evictable in the interrupted state.
        let interrupted = try await repo.record(id: record.id)
        #expect(interrupted?.isEvictable == false)

        // Relaunch: a fresh uploader over the same repository sees `.uploading`
        // and completes the upload (idempotent re-push, re-verify, re-flip).
        let relaunched = makeUploader(repository: repo, transport: transport, assetStore: store)
        let report = try await relaunched.uploadPending()

        #expect(report.uploaded == [record.id])
        let verified = try await repo.record(id: record.id)
        #expect(verified?.state == .localAndRemote)
        #expect(verified?.remoteAssetID == "asset-\(record.id.uuidString)")
        #expect(verified?.isEvictable == true)
    }

    /// §6.3 step 3: the server's sha256 field does not match the local hash. The
    /// uploader refuses to verify, the asset stays `.uploading`, and nothing was
    /// written to the store.
    @Test func upload_hashMismatch_staysUploading() async throws {
        let repo = InMemoryProductionAssetRepository()
        let store = InMemoryAssetStore()
        let transport = FakeProductionSyncTransport()
        let (record, _) = try await seedOriginal(repository: repo, assetStore: store)
        let name = "asset-\(record.id.uuidString)"
        transport.rewrittenSHAOnFetch[name] = "corrupt-server-hash"

        let uploader = makeUploader(repository: repo, transport: transport, assetStore: store)
        do {
            try await uploader.upload(record)
            Issue.record("expected the hash mismatch to surface")
        } catch let error as CloudAssetUploadError {
            guard case .hashMismatch(recordName: name, localSHA: record.sha256, serverSHA: "corrupt-server-hash") = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        }

        let persisted = try await repo.record(id: record.id)
        #expect(persisted?.state == .uploading)
        #expect(persisted?.remoteAssetID == nil)
        #expect(persisted?.isEvictable == false)
    }

    /// §16.2: a duplicate upload of an already-verified asset is a no-op — no
    /// push, no state change. `uploadPending` skips it entirely, and a direct
    /// `upload(_:)` reports `.alreadyRemote`.
    @Test func upload_alreadyRemote_isNoOp() async throws {
        let repo = InMemoryProductionAssetRepository()
        let store = InMemoryAssetStore()
        let transport = FakeProductionSyncTransport()
        let (record, _) = try await seedOriginal(
            repository: repo, assetStore: store,
            state: .localAndRemote, remoteID: "asset-\(UUID().uuidString)"
        )

        let uploader = makeUploader(repository: repo, transport: transport, assetStore: store)
        let report = try await uploader.uploadPending()
        #expect(report.uploaded.isEmpty)
        #expect(report.failed.isEmpty)
        #expect(transport.snapshot().isEmpty, "no asset record may be pushed")

        do {
            try await uploader.upload(record)
            Issue.record("expected .alreadyRemote for a verified asset")
        } catch let error as CloudAssetUploadError {
            guard error == .alreadyRemote else {
                Issue.record("unexpected error \(error)")
                return
            }
        }

        let persisted = try await repo.record(id: record.id)
        #expect(persisted?.state == .localAndRemote)
    }

    /// §6.3 step 1: the state is marked `.uploading` before any network work, so
    /// a failed push leaves the asset protected.
    @Test func upload_marksUploadingBeforeNetwork() async throws {
        let repo = InMemoryProductionAssetRepository()
        let store = InMemoryAssetStore()
        let transport = FakeProductionSyncTransport()
        let (record, _) = try await seedOriginal(repository: repo, assetStore: store)
        // The phone is offline: every push fails.
        transport.accountStatusValue = .unavailable

        let uploader = makeUploader(repository: repo, transport: transport, assetStore: store)
        do {
            try await uploader.upload(record)
            Issue.record("expected the offline push to fail")
        } catch {}

        let persisted = try await repo.record(id: record.id)
        #expect(persisted?.state == .uploading)
        #expect(persisted?.remoteAssetID == nil)
        #expect(persisted?.isEvictable == false)
    }

    /// A single failed asset does not abort the rest of the pass; the failed one
    /// stays protected and the successful one completes.
    @Test func uploadPending_isolatesFailures() async throws {
        let repo = InMemoryProductionAssetRepository()
        let store = InMemoryAssetStore()
        let transport = FakeProductionSyncTransport()
        let good = try await seedOriginal(repository: repo, assetStore: store)
        // A record whose file was already evicted: nothing to upload.
        let missingID = UUID()
        try await repo.upsert(ProductionAssetRecord(
            id: missingID, sha256: "missing-sha", byteCount: 10, state: .localOnly,
            chapterID: UUID(), chapterOrdinal: 1, lastAccessedAt: now
        ))

        let uploader = makeUploader(repository: repo, transport: transport, assetStore: store)
        let report = try await uploader.uploadPending()

        #expect(report.uploaded == [good.record.id])
        #expect(report.failed.count == 1)
        #expect(report.failed[0].0 == missingID)
        let failed = try await repo.record(id: missingID)
        #expect(failed?.state == .localOnly)
        #expect(failed?.isEvictable == false)
    }
}
