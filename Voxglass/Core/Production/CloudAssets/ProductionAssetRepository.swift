import Foundation

/// Persistence for `ProductionAssetRecord` over the project SQLite
/// `production_asset` table (§6.1). The eviction executor reads the working
/// cache from here; upload/verify (P3) flips state through it as well.
public protocol ProductionAssetRepository: Sendable {
    /// Insert or replace a record by id (the primary key).
    func upsert(_ record: ProductionAssetRecord) async throws
    func record(id: UUID) async throws -> ProductionAssetRecord?
    /// All records, ordered by chapter ordinal then last access, so callers
    /// see the same oldest-first ordering the eviction planner assumes.
    func records() async throws -> [ProductionAssetRecord]
    func records(chapterID: UUID) async throws -> [ProductionAssetRecord]
    func remove(id: UUID) async throws
}
