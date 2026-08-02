import Foundation

/// Persistence for the sync engine's bookkeeping: the server change token and the
/// last published projection snapshot (the "delta only" baseline, spec §13.5).
/// Backed by UserDefaults by default; the Studio overrides with a per-project store.
public protocol SyncStateStore: Sendable {
    func changeToken() async throws -> SyncChangeToken?
    func setChangeToken(_ token: SyncChangeToken?) async throws

    func projectionSnapshot(projectID: UUID) async throws -> SyncProjection?
    func setProjectionSnapshot(_ projection: SyncProjection?, projectID: UUID) async throws

    func lastPublishDate(projectID: UUID) async throws -> Date?
    func setLastPublishDate(_ date: Date?, projectID: UUID) async throws
}

/// Default `SyncStateStore` over `UserDefaults`, JSON-encoded. Fine for the MVP
/// scale; the Studio may substitute a store inside the `.voxproject`.
public struct DefaultsSyncStateStore: SyncStateStore {
    private let defaults: UserDefaults
    private let suite: String

    public init(defaults: UserDefaults = .standard, suite: String = "voxglass.production.sync") {
        self.defaults = defaults
        self.suite = suite
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    private func key(_ name: String, _ projectID: UUID?) -> String {
        var result = suite
        if let projectID { result += ".\(projectID.uuidString)" }
        result += ".\(name)"
        return result
    }

    private func data(_ name: String, _ projectID: UUID?) throws -> Data? {
        defaults.data(forKey: key(name, projectID))
    }

    public func changeToken() async throws -> SyncChangeToken? {
        guard let data = try data("changeToken", nil) else { return nil }
        return try? Self.decoder.decode(SyncChangeToken.self, from: data)
    }

    public func setChangeToken(_ token: SyncChangeToken?) async throws {
        if let token, let data = try? Self.encoder.encode(token) {
            defaults.set(data, forKey: key("changeToken", nil))
        } else {
            defaults.removeObject(forKey: key("changeToken", nil))
        }
    }

    public func projectionSnapshot(projectID: UUID) async throws -> SyncProjection? {
        guard let data = try data("snapshot", projectID) else { return nil }
        return try? Self.decoder.decode(SyncProjection.self, from: data)
    }

    public func setProjectionSnapshot(_ projection: SyncProjection?, projectID: UUID) async throws {
        if let projection, let data = try? Self.encoder.encode(projection) {
            defaults.set(data, forKey: key("snapshot", projectID))
        } else {
            defaults.removeObject(forKey: key("snapshot", projectID))
        }
    }

    public func lastPublishDate(projectID: UUID) async throws -> Date? {
        defaults.object(forKey: key("lastPublish", projectID)) as? Date
    }

    public func setLastPublishDate(_ date: Date?, projectID: UUID) async throws {
        if let date {
            defaults.set(date, forKey: key("lastPublish", projectID))
        } else {
            defaults.removeObject(forKey: key("lastPublish", projectID))
        }
    }
}
