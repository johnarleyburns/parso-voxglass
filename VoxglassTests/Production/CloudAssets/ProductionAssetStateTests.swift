import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// P1 acceptance (§17 P1): the storage kernel — `production_asset` persistence,
/// the eviction executor, and the planner's protection rules.
@Suite struct ProductionAssetStateTests {

    /// The 1 GB working-cache cap from the acceptance scenario (§6.5 default
    /// is 10 GB; the scenario exercises a 1 GB cap directly).
    private let capBytes: Int64 = 1_024 * 1024 * 1024
    /// Nominal byte count for one recorded chapter's original.
    private let perChapterBytes: Int64 = 70 * 1024 * 1024

    // MARK: - Planner protections

    /// §6.1: `.localOnly`, `.uploading`, `.stagedForExport`, pinned, and
    /// working-set records are never returned by the planner, no matter how
    /// much pressure is applied.
    @Test func plannerNeverReturnsProtectedRecordsRegardlessOfPressure() {
        let planner = ProductionEvictionPlanner()
        let now = FixedClock().now

        func makeRecord(_ state: ProductionAssetState, ordinal: Int, pinned: Bool = false, working: Bool = false) -> ProductionAssetRecord {
            ProductionAssetRecord(
                id: UUID(),
                sha256: "sha-\(state.rawValue)-\(ordinal)",
                byteCount: perChapterBytes,
                state: state,
                chapterID: UUID(),
                chapterOrdinal: ordinal,
                isPinned: pinned,
                isWorkingSet: working,
                lastAccessedAt: now,
                remoteAssetID: state == .localAndRemote ? "ck://asset" : nil
            )
        }

        let localOnly = makeRecord(.localOnly, ordinal: 0)
        let uploading = makeRecord(.uploading, ordinal: 1)
        let staged = makeRecord(.stagedForExport, ordinal: 2)
        let pinned = makeRecord(.localAndRemote, ordinal: 3, pinned: true)
        let working = makeRecord(.localAndRemote, ordinal: 4, working: true)
        let evictable = makeRecord(.localAndRemote, ordinal: 5)

        // Int64.max pressure: the planner must still return only the one
        // genuinely evictable record.
        let candidates = planner.candidates(
            assets: [localOnly, uploading, staged, pinned, working, evictable],
            requiredFreeBytes: Int64.max
        )

        #expect(candidates.map(\.assetID) == [evictable.id])
    }

    /// Executor with nothing evictable evicts nothing, even at extreme pressure.
    @Test func executorEvictsNothingWhenOnlyProtectedRecordsExist() async throws {
        let repo = InMemoryProductionAssetRepository()
        let assetStore = InMemoryAssetStore()
        let now = FixedClock().now

        var records: [ProductionAssetRecord] = []
        for (index, state) in [ProductionAssetState.localOnly, .uploading, .stagedForExport].enumerated() {
            let record = ProductionAssetRecord(
                id: UUID(), sha256: "sha-\(index)", byteCount: perChapterBytes,
                state: state, chapterID: UUID(), chapterOrdinal: index,
                lastAccessedAt: now, remoteAssetID: nil
            )
            try await repo.upsert(record)
            records.append(record)
        }
        try await repo.upsert(ProductionAssetRecord(
            id: UUID(), sha256: "pinned", byteCount: perChapterBytes,
            state: .localAndRemote, chapterID: UUID(), chapterOrdinal: 9,
            isPinned: true, lastAccessedAt: now, remoteAssetID: "ck://asset"
        ))

        let executor = ProductionEvictionExecutor(repository: repo, assetStore: assetStore)
        let result = try await executor.evict(toFit: 0, activeChapterOrdinal: nil)

        #expect(result.evictedOriginalIDs.isEmpty)
        #expect(result.bytesReclaimed == 0)

        let reloaded = try await repo.records()
        #expect(reloaded.count == records.count + 1)
        for record in records {
            let persisted = try await repo.record(id: record.id)
            #expect(persisted?.state == record.state)
        }
    }

    // MARK: - P1 acceptance scenario (20-chapter fake project)

    /// §17 P1 acceptance: a 20-chapter fake project evicts non-working chapters
    /// under a 1 GB cap, never touches `localOnly`/`uploading`/pinned assets,
    /// and the state survives a relaunch (a fresh repository over the same DB).
    @Test func evictsNonWorkingChaptersUnderCapAndSurvivesRelaunch() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p1-acceptance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let layout = ProductionProjectLayout(root: tmp)
        let assetStore = FileAssetStore(root: tmp)
        let repo = SQLiteProductionAssetRepository(databaseURL: layout.databaseURL)

        // Chapters 0–15, 18, 19: one `.localAndRemote` original each. That is
        // 18 evictable originals at 70 MB = 1,260 MB nominal; the protected
        // chapter 16/17 records add another 280 MB, so the working cache
        // (1,540 MB) exceeds the 1 GB cap.
        var evictable: [(chapterID: UUID, record: ProductionAssetRecord, ref: AudioAssetReference)] = []
        for ordinal in 0..<16 {
            evictable.append(try await seedOriginal(
                repository: repo, assetStore: assetStore, ordinal: ordinal,
                state: .localAndRemote, remote: true
            ))
        }

        // Chapter 16: `.localOnly` and `.uploading` — must never move.
        let localOnlyEntry = try await seedOriginal(
            repository: repo, assetStore: assetStore, ordinal: 16, state: .localOnly, remote: false
        )
        let uploadingEntry = try await seedOriginal(
            repository: repo, assetStore: assetStore, ordinal: 16, state: .uploading, remote: false
        )

        // Chapter 17: `.stagedForExport` and a pinned `.localAndRemote` — must never move.
        let stagedEntry = try await seedOriginal(
            repository: repo, assetStore: assetStore, ordinal: 17, state: .stagedForExport, remote: false
        )
        let pinnedEntry = try await seedOriginal(
            repository: repo, assetStore: assetStore, ordinal: 17, state: .localAndRemote,
            pinned: true, remote: true
        )

        for ordinal in [18, 19] {
            evictable.append(try await seedOriginal(
                repository: repo, assetStore: assetStore, ordinal: ordinal,
                state: .localAndRemote, remote: true
            ))
        }

        // Active chapter 10 → working set is chapters 9, 10, 11 (§6.4).
        let executor = ProductionEvictionExecutor(repository: repo, assetStore: assetStore)
        let result = try await executor.evict(toFit: capBytes, activeChapterOrdinal: 10)

        // Oldest chapter ordinal first, skipping the working set: exactly the
        // first eight evictable chapters (0–7) come out from under the cap.
        let evictedIDs = Set(result.evictedOriginalIDs)
        #expect(result.evictedOriginalIDs.count == 8)
        let evictedChapters = evictable.filter { evictedIDs.contains($0.record.id) }
        #expect(evictedChapters.map(\.chapterID) == evictable.prefix(8).map(\.chapterID))

        // Files for evicted chapters left Audio/Original and landed in Trash.
        for entry in evictedChapters {
            #expect(!assetStore.exists(entry.ref))
            let trashPath = tmp.appendingPathComponent("Trash/\(entry.ref.relativePath)")
            #expect(FileManager.default.fileExists(atPath: trashPath.path))
        }

        // Non-evicted evictable chapters keep their files.
        for entry in evictable.dropFirst(8) {
            #expect(assetStore.exists(entry.ref))
        }

        // Protected records never moved: state and file intact.
        for entry in [localOnlyEntry, uploadingEntry, stagedEntry, pinnedEntry] {
            #expect(assetStore.exists(entry.ref))
            let persisted = try await repo.record(id: entry.record.id)
            #expect(persisted?.state == entry.record.state)
        }

        // Working-set chapters 9, 10, 11 were not evicted.
        for ordinal in [9, 10, 11] {
            let chapterRecords = evictable.filter { $0.record.chapterOrdinal == ordinal }
            #expect(chapterRecords.allSatisfy { !evictedIDs.contains($0.record.id) })
        }

        // The working cache now fits the cap.
        #expect(result.workingCacheBytesAfter <= capBytes)

        // Relaunch survival: a fresh repository over the same database sees the
        // same state (evicted chapters remoteOnly, protected unchanged).
        let relaunchedRepo = SQLiteProductionAssetRepository(databaseURL: layout.databaseURL)
        for entry in evictedChapters {
            let persisted = try await relaunchedRepo.record(id: entry.record.id)
            #expect(persisted?.state == .remoteOnly)
        }
        for entry in [localOnlyEntry, uploadingEntry, stagedEntry, pinnedEntry] {
            let persisted = try await relaunchedRepo.record(id: entry.record.id)
            #expect(persisted?.state == entry.record.state)
        }
    }

    // MARK: - Helpers

    /// Writes a real (tiny) content-addressed original and a matching record so
    /// the executor's sha256 lookup finds a file to move.
    private func seedOriginal(
        repository: any ProductionAssetRepository,
        assetStore: FileAssetStore,
        ordinal: Int,
        state: ProductionAssetState,
        pinned: Bool = false,
        remote: Bool
    ) async throws -> (chapterID: UUID, record: ProductionAssetRecord, ref: AudioAssetReference) {
        let chapterID = UUID()
        let ref = try await assetStore.put(
            Data("chapter-\(ordinal)-\(state.rawValue)".utf8),
            ext: "wav",
            contentType: "audio/wav",
            subdirectory: .original
        )
        let record = ProductionAssetRecord(
            id: UUID(),
            sha256: ref.sha256,
            byteCount: perChapterBytes,
            state: state,
            chapterID: chapterID,
            chapterOrdinal: ordinal,
            isPinned: pinned,
            lastAccessedAt: FixedClock().now,
            remoteAssetID: remote ? "ck://remote-\(ordinal)" : nil
        )
        try await repository.upsert(record)
        return (chapterID, record, ref)
    }
}
