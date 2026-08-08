import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// Persistence contract for `ProductionAssetRepository` over the
/// `production_asset` table (migration 2, §6.1).
@Suite struct ProductionAssetRepositoryTests {

    @Test func sqliteRoundTripsEveryField() async throws {
        let db = ProjectDatabase.makeTemporary(named: "asset-repo")
        let repo = SQLiteProductionAssetRepository(database: db)
        let now = FixedClock().now

        let record = ProductionAssetRecord(
            id: UUID(),
            sha256: "deadbeef",
            byteCount: 12_345,
            state: .localAndRemote,
            chapterID: UUID(),
            chapterOrdinal: 7,
            isPinned: true,
            isWorkingSet: true,
            lastAccessedAt: now,
            remoteAssetID: "ck://asset-1"
        )
        try await repo.upsert(record)

        let loaded = try await repo.record(id: record.id)
        #expect(loaded == record)
    }

    @Test func sqliteUpsertOverwritesInPlace() async throws {
        let db = ProjectDatabase.makeTemporary(named: "asset-repo-update")
        let repo = SQLiteProductionAssetRepository(database: db)

        let id = UUID()
        try await repo.upsert(ProductionAssetRecord(
            id: id, sha256: "a", byteCount: 1, state: .uploading, lastAccessedAt: FixedClock().now
        ))
        try await repo.upsert(ProductionAssetRecord(
            id: id, sha256: "a", byteCount: 1, state: .localAndRemote,
            lastAccessedAt: FixedClock().now, remoteAssetID: "ck://remote"
        ))

        let loaded = try await repo.record(id: id)
        #expect(loaded?.state == .localAndRemote)
        #expect(loaded?.remoteAssetID == "ck://remote")

        let all = try await repo.records()
        #expect(all.count == 1)
    }

    @Test func sqliteRemoveDeletesRecord() async throws {
        let db = ProjectDatabase.makeTemporary(named: "asset-repo-remove")
        let repo = SQLiteProductionAssetRepository(database: db)
        let id = UUID()
        try await repo.upsert(ProductionAssetRecord(
            id: id, sha256: "a", byteCount: 1, state: .localOnly, lastAccessedAt: FixedClock().now
        ))
        try await repo.remove(id: id)
        #expect(try await repo.record(id: id) == nil)
    }

    @Test func sqliteRecordsOrderOldestChapterFirst() async throws {
        let db = ProjectDatabase.makeTemporary(named: "asset-repo-order")
        let repo = SQLiteProductionAssetRepository(database: db)
        let now = FixedClock().now

        let third = ProductionAssetRecord(
            id: UUID(), sha256: "c", byteCount: 1, state: .localAndRemote,
            chapterOrdinal: 10, lastAccessedAt: now, remoteAssetID: "ck://3"
        )
        let first = ProductionAssetRecord(
            id: UUID(), sha256: "a", byteCount: 1, state: .localAndRemote,
            chapterOrdinal: 1, lastAccessedAt: now, remoteAssetID: "ck://1"
        )
        let second = ProductionAssetRecord(
            id: UUID(), sha256: "b", byteCount: 1, state: .localAndRemote,
            chapterOrdinal: 5, lastAccessedAt: now, remoteAssetID: "ck://2"
        )
        for record in [third, first, second] {
            try await repo.upsert(record)
        }

        let loaded = try await repo.records()
        #expect(loaded.map(\.sha256) == ["a", "b", "c"])
    }

    @Test func sqliteSchemaIncludesProductionAssetTable() async throws {
        let db = ProjectDatabase.makeTemporary(named: "asset-repo-schema")
        try await db.prepare()
        let rows = try await db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='production_asset'")
        #expect(rows.count == 1)
    }

    @Test func inMemoryMirrorsSQLiteContract() async throws {
        let repo = InMemoryProductionAssetRepository()
        let now = FixedClock().now
        let record = ProductionAssetRecord(
            id: UUID(), sha256: "sha", byteCount: 42, state: .localAndRemote,
            chapterID: UUID(), chapterOrdinal: 3, lastAccessedAt: now, remoteAssetID: "ck://x"
        )
        try await repo.upsert(record)
        #expect(try await repo.record(id: record.id) == record)
        #expect(try await repo.records().count == 1)
        try await repo.remove(id: record.id)
        #expect(try await repo.record(id: record.id) == nil)
    }
}
