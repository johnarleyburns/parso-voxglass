import Foundation

/// In-memory `ProductionAssetRepository` for tests and previews. Mirrors the
/// ordering contract of `SQLiteProductionAssetRepository.records()`: oldest
/// chapter ordinal first, then least-recently accessed.
public actor InMemoryProductionAssetRepository: ProductionAssetRepository {
    private var recordsByID: [UUID: ProductionAssetRecord] = [:]

    public init() {}

    public func upsert(_ record: ProductionAssetRecord) async throws {
        recordsByID[record.id] = record
    }

    public func record(id: UUID) async throws -> ProductionAssetRecord? {
        recordsByID[id]
    }

    public func records() async throws -> [ProductionAssetRecord] {
        recordsByID.values.sorted { lhs, rhs in
            let lo = lhs.chapterOrdinal ?? Int.max
            let ro = rhs.chapterOrdinal ?? Int.max
            if lo != ro { return lo < ro }
            return lhs.lastAccessedAt < rhs.lastAccessedAt
        }
    }

    public func records(chapterID: UUID) async throws -> [ProductionAssetRecord] {
        recordsByID.values.filter { $0.chapterID == chapterID }
    }

    public func remove(id: UUID) async throws {
        recordsByID.removeValue(forKey: id)
    }
}
