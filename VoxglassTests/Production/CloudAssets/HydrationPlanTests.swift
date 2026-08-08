import Foundation
import Testing
@testable import VoxglassCore
@testable import VoxglassCoreTestSupport

/// P3 acceptance (§17 P3, §6.3): the hydration plan's blocking/byte semantics
/// and a resumable, content-address-verified hydration executor. A `remoteOnly`
/// chapter hydrates and verifies; a partial run resumes where it stopped.
@Suite struct HydrationPlanTests {

    private var now: Date { FixedClock().now }

    private func makeRemoteRecord(
        id: UUID = UUID(),
        sha: String,
        byteCount: Int64 = 1_000,
        ordinal: Int = 0
    ) -> ProductionAssetRecord {
        ProductionAssetRecord(
            id: id, sha256: sha, byteCount: byteCount,
            state: .remoteOnly, chapterID: UUID(), chapterOrdinal: ordinal,
            lastAccessedAt: now, remoteAssetID: "asset-\(id.uuidString)"
        )
    }

    private func makeHydrator(
        repository: any ProductionAssetRepository,
        transport: FakeProductionSyncTransport,
        assetStore: any ContentAddressedStore
    ) -> AssetHydrationExecutor {
        AssetHydrationExecutor(repository: repository, transport: transport, assetStore: assetStore, clock: FixedClock())
    }

    /// Seeds a `VGProductionAsset` server record whose blob hash matches its
    /// `sha256` field, so the hydrator's verification passes.
    private func seedServerAsset(
        transport: FakeProductionSyncTransport,
        id: UUID,
        bytes: [UInt8],
        codec: ProjectionRecordCodec
    ) {
        let mirror = AssetMirrorRecord(
            id: id,
            sha256: SHA256Hex.hex(Data(bytes)),
            byteCount: Int64(bytes.count),
            ext: "wav",
            contentType: "audio/wav",
            takeID: UUID(),
            chapterID: UUID()
        )
        var record = codec.assetRecord(from: mirror)
        record.assetFields[ProductionAssetField.original] = Data(bytes)
        transport.seed([record])
    }

    // MARK: - Planner

    /// §6.3: blocking purposes (export staging, originals) mark every remote
    /// asset as blocking; cache purposes do not. Byte totals count only
    /// non-local assets, regardless of purpose.
    @Test func planner_distinguishesBlockingFromNonBlockingPurposes() {
        let planner = ProductionHydrationPlanner()
        let local = makeRemoteRecord(sha: "sha-local", byteCount: 1_000, ordinal: 0).then { $0.state = .localAndRemote }
        let remoteA = makeRemoteRecord(sha: "sha-a", byteCount: 5_000, ordinal: 1)
        let remoteB = makeRemoteRecord(sha: "sha-b", byteCount: 7_000, ordinal: 2)
        let missing = makeRemoteRecord(sha: "sha-missing", byteCount: 3_000, ordinal: 3).then { $0.state = .missing }
        let assets = [local, remoteA, remoteB, missing]

        let export = planner.plan(for: assets, purpose: .exportStaging)
        #expect(export.assetIDs == [remoteA.id, remoteB.id, missing.id])
        #expect(export.byteCount == 15_000)
        #expect(export.isRequired == true)
        #expect(export.blockingAssetIDs == [remoteA.id, remoteB.id, missing.id])

        let proxy = planner.plan(for: assets, purpose: .proxyReviewCache)
        #expect(proxy.byteCount == 15_000)
        #expect(proxy.blockingAssetIDs.isEmpty)
        #expect(proxy.isRequired == false)
    }

    // MARK: - Executor

    /// §17 P3 acceptance: a `remoteOnly` chapter hydrates, SHA-verifies, and
    /// flips to `.localAndRemote` with the blob durable in the content store.
    @Test func executor_hydratesRemoteOnlyChapterAndVerifies() async throws {
        let repo = InMemoryProductionAssetRepository()
        let store = InMemoryAssetStore()
        let transport = FakeProductionSyncTransport()
        let codec = ProjectionRecordCodec()

        let id = UUID()
        let bytes: [UInt8] = Array("hydrated-chapter-audio".utf8)
        let sha = SHA256Hex.hex(Data(bytes))
        try await repo.upsert(ProductionAssetRecord(
            id: id, sha256: sha, byteCount: Int64(bytes.count),
            state: .remoteOnly, chapterID: UUID(), chapterOrdinal: 0,
            lastAccessedAt: now, remoteAssetID: "asset-\(id.uuidString)"
        ))
        seedServerAsset(transport: transport, id: id, bytes: bytes, codec: codec)

        let plan = ProductionHydrationPlan(assetIDs: [id], byteCount: Int64(bytes.count), blockingAssetIDs: [id])
        let report = try await makeHydrator(repository: repo, transport: transport, assetStore: store).hydrate(plan)

        #expect(report.hydrated == [id])
        #expect(report.failed.isEmpty)
        let persisted = try await repo.record(id: id)
        #expect(persisted?.state == .localAndRemote)
        #expect(persisted?.isEvictable == true)

        // The blob is durable in the content store under its verified sha.
        let refs = try await store.allReferences(under: .original)
        #expect(refs.map(\.sha256) == [persisted?.sha256])
        #expect(try await store.data(for: refs[0]) == Data(bytes))
    }

    /// A corrupt blob (hash mismatch) is never written locally and the record
    /// stays `.remoteOnly` so it can be re-fetched.
    @Test func executor_rejectsCorruptBlob() async throws {
        let repo = InMemoryProductionAssetRepository()
        let store = InMemoryAssetStore()
        let transport = FakeProductionSyncTransport()
        let codec = ProjectionRecordCodec()

        let id = UUID()
        try await repo.upsert(makeRemoteRecord(id: id, sha: "recorded-sha"))
        // The server record's sha256 field claims one hash but the blob is other.
        let claimed = AssetMirrorRecord(id: id, sha256: "claimed-sha", byteCount: 10, ext: "wav", contentType: "audio/wav")
        var record = codec.assetRecord(from: claimed)
        record.assetFields[ProductionAssetField.original] = Data("different".utf8)
        transport.seed([record])

        let plan = ProductionHydrationPlan(assetIDs: [id], byteCount: 10, blockingAssetIDs: [id])
        let report = try await makeHydrator(repository: repo, transport: transport, assetStore: store).hydrate(plan)

        #expect(report.hydrated.isEmpty)
        #expect(report.failed.count == 1)
        let persisted = try await repo.record(id: id)
        #expect(persisted?.state == .remoteOnly)
        #expect(persisted?.isEvictable == false)
        #expect((try? await store.allReferences(under: .original).count) ?? 0 == 0)
    }

    /// §6.3: hydration is resumable across launches. A mid-run failure leaves the
    /// remaining asset `.remoteOnly`; the next run hydrates it and skips the one
    /// that already completed.
    @Test func executor_resumesAfterPartialRun() async throws {
        let repo = InMemoryProductionAssetRepository()
        let store = InMemoryAssetStore()
        let transport = FakeProductionSyncTransport()
        let codec = ProjectionRecordCodec()

        let firstID = UUID()
        let secondID = UUID()
        let firstBytes: [UInt8] = Array("first".utf8)
        let secondBytes: [UInt8] = Array("second".utf8)
        try await repo.upsert(makeRemoteRecord(id: firstID, sha: SHA256Hex.hex(Data(firstBytes)), byteCount: 5, ordinal: 0))
        try await repo.upsert(makeRemoteRecord(id: secondID, sha: SHA256Hex.hex(Data(secondBytes)), byteCount: 6, ordinal: 1))
        seedServerAsset(transport: transport, id: firstID, bytes: firstBytes, codec: codec)
        seedServerAsset(transport: transport, id: secondID, bytes: secondBytes, codec: codec)

        let hydrator = makeHydrator(repository: repo, transport: transport, assetStore: store)
        let plan = ProductionHydrationPlan(
            assetIDs: [firstID, secondID],
            byteCount: 11,
            blockingAssetIDs: [firstID, secondID]
        )

        // First run: the second download is interrupted mid-flight.
        transport.failFetchOnceForRecord = "asset-\(secondID.uuidString)"
        let first = try await hydrator.hydrate(plan)
        #expect(first.hydrated == [firstID])
        #expect(first.failed.count == 1)
        #expect(try await repo.record(id: secondID)?.state == .remoteOnly)

        // Second run (relaunch): the first is already local, the second resumes.
        let second = try await hydrator.hydrate(plan)
        #expect(second.alreadyLocal == [firstID])
        #expect(second.hydrated == [secondID])
        #expect(second.failed.isEmpty)
        #expect(try await repo.record(id: firstID)?.state == .localAndRemote)
        #expect(try await repo.record(id: secondID)?.state == .localAndRemote)

        // A third run is a total no-op: everything already local.
        let third = try await hydrator.hydrate(plan)
        #expect(third.hydrated.isEmpty)
        #expect(third.alreadyLocal == [firstID, secondID])
    }
}

private extension ProductionAssetRecord {
    func then(_ mutate: (inout ProductionAssetRecord) -> Void) -> ProductionAssetRecord {
        var copy = self
        mutate(&copy)
        return copy
    }
}
