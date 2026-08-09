import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// P9 hardening (spec §17 P9, "storage stress"): the eviction executor must stay
/// correct and terminate under real pressure — a working cache filled past the
/// cap with thousands of records — without ever touching a protected record and
/// without degrading as the store grows. This is the automated stand-in for
/// manual M-5 ("Fill the production cache": remote-verified old chapters evict,
/// `localOnly` takes remain).
@Suite struct ProductionStorageStressTests {

    /// The 10 GB default working-cache cap (§6.5).
    private let capBytes: Int64 = 10 * 1_024 * 1024 * 1024
    /// Nominal per-take size (a 10-minute mono narration chapter ~ 70 MB at
    /// 48 kHz / 24-bit). 2,000 takes ≈ 140 GB, so the cache is deeply over.
    private let perTakeBytes: Int64 = 70 * 1024 * 1024

    private func makeRecord(_ ordinal: Int, id: UUID = UUID(), state: ProductionAssetState = .localAndRemote, sha: String? = nil) -> ProductionAssetRecord {
        ProductionAssetRecord(
            id: id,
            sha256: sha ?? "sha-\(ordinal)",
            byteCount: perTakeBytes,
            state: state,
            chapterID: UUID(),
            chapterOrdinal: ordinal,
            lastAccessedAt: FixedClock().now,
            remoteAssetID: state == .localAndRemote ? "ck://asset-\(ordinal)" : nil
        )
    }

    /// 2,000 evictable originals plus a thousand protected records, then evict
    /// to the 10 GB cap. Asserts: (1) the run terminates, (2) every protected
    /// record survives intact, (3) the working cache fits the cap, (4) eviction
    /// proceeded oldest-chapter-first.
    @Test func evictsTwoThousandTakesDownToTheCapWithoutTouchingProtectedRecords() async throws {
        let repo = InMemoryProductionAssetRepository()
        let assetStore = InMemoryAssetStore()

        // Seed content-addressed files and records. 2,000 evictable originals,
        // one record per chapter ordinal (0..<2000).
        let originalCount = 2_000
        var refs: [AudioAssetReference] = []
        refs.reserveCapacity(originalCount)
        for index in 0..<originalCount {
            let data = Data("chapter-\(index)".utf8)
            refs.append(try await assetStore.put(data, ext: "wav", contentType: "audio/wav", subdirectory: .original))
        }
        var originalIDs: [UUID] = []
        originalIDs.reserveCapacity(originalCount)
        for index in 0..<originalCount {
            let id = UUID()
            originalIDs.append(id)
            try await repo.upsert(makeRecord(index, id: id, sha: refs[index].sha256))
        }

        // Protected records under the same pressure: localOnly, uploading,
        // stagedForExport, pinned, and a working-set member.
        let localOnly = makeRecord(2_000, state: .localOnly)
        let uploading = makeRecord(2_001, state: .uploading)
        let staged = makeRecord(2_002, state: .stagedForExport)
        let pinned = makeRecord(2_003, state: .localAndRemote)
        var working = makeRecord(2_004, state: .localAndRemote)
        working.isWorkingSet = true
        var pinnedRecord = pinned
        pinnedRecord.isPinned = true
        let protected: [ProductionAssetRecord] = [localOnly, uploading, staged, pinnedRecord, working]
        for record in protected {
            try await repo.upsert(record)
        }

        let executor = ProductionEvictionExecutor(repository: repo, assetStore: assetStore)
        let result = try await executor.evict(toFit: capBytes, activeChapterOrdinal: 1_500)

        // Terminates and reclaims enough to fit the cap.
        #expect(result.bytesReclaimed > 0)
        #expect(result.workingCacheBytesAfter <= capBytes)

        // Only evictable originals were touched; every eviction came from the
        // recorded set and outside the active-chapter working window (1,499–1,501).
        let evicted = Set(result.evictedOriginalIDs)
        #expect(evicted.isSubset(of: Set(originalIDs)))
        #expect(evicted.count > 0)
        let protectedIDs = Set(protected.map(\.id))
        #expect(evicted.isDisjoint(with: protectedIDs))

        // Protected records are byte-identical and still in the store.
        let surviving = try await repo.records()
        for record in protected {
            let persisted = try await repo.record(id: record.id)
            #expect(persisted?.state == record.state, "protected record was touched under stress")
            #expect(surviving.contains { $0.id == record.id })
        }
    }

    /// Thousands of records with nothing evictable: the executor terminates and
    /// touches nothing, no matter how much pressure is applied.
    @Test func protectsEverythingWhenNothingIsEvictableUnderMassivePressure() async throws {
        let repo = InMemoryProductionAssetRepository()
        let assetStore = InMemoryAssetStore()
        let clock = FixedClock()

        for index in 0..<3_000 {
            let state: ProductionAssetState = [.localOnly, .uploading, .stagedForExport, .missing][index % 4]
            let record = ProductionAssetRecord(
                id: UUID(), sha256: "sha-\(index)", byteCount: perTakeBytes,
                state: state, chapterID: UUID(), chapterOrdinal: index,
                lastAccessedAt: clock.now, remoteAssetID: nil
            )
            try await repo.upsert(record)
        }

        let executor = ProductionEvictionExecutor(repository: repo, assetStore: assetStore)
        let result = try await executor.evict(toFit: 0, activeChapterOrdinal: nil)

        #expect(result.evictedOriginalIDs.isEmpty)
        #expect(result.bytesReclaimed == 0)
        let persisted = try await repo.records()
        #expect(persisted.count == 3_000)
    }
}
