import Foundation

/// UserDefaults-backed position snapshots — the store with the good crash
/// profile: `cfprefsd` survives the app being killed, whereas the SQLite write
/// is an enqueued actor hop that may never run. Promoted from a single global
/// slot to a bounded per-book map so switching books doesn't discard another
/// book's safety net. The legacy single-slot key is still read on load so an
/// upgrading user's in-flight position is preserved.
public struct LastPlaybackSnapshotStore {
    private static let legacyKey = "guru.parso.voxglass.lastPlaybackSnapshot"
    private static let mapKey = "guru.parso.voxglass.positionSnapshots"
    public static let maxSnapshots = 50

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func save(_ position: PlaybackPosition) {
        var map = loadMap()
        map[position.bookID.uuidString] = position
        if map.count > Self.maxSnapshots {
            let newest = map.values
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(Self.maxSnapshots)
            map = Dictionary(uniqueKeysWithValues: newest.map { ($0.bookID.uuidString, $0) })
        }
        persist(map)
    }

    public func position(forBookID bookID: UUID) -> PlaybackPosition? {
        loadMap()[bookID.uuidString]
    }

    public func latest() -> PlaybackPosition? {
        loadMap().values.max { $0.updatedAt < $1.updatedAt }
    }

    public func all() -> [PlaybackPosition] {
        Array(loadMap().values)
    }

    public func clear(bookID: UUID) {
        if let legacy = legacySnapshot(), legacy.bookID == bookID {
            defaults.removeObject(forKey: Self.legacyKey)
        }
        var map = loadMap()
        map.removeValue(forKey: bookID.uuidString)
        persist(map)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.mapKey)
        defaults.removeObject(forKey: Self.legacyKey)
    }

    private func loadMap() -> [String: PlaybackPosition] {
        var map: [String: PlaybackPosition] = [:]
        if let data = defaults.data(forKey: Self.mapKey),
           let decoded = try? JSONDecoder().decode([String: PlaybackPosition].self, from: data) {
            map = decoded
        }
        if let legacy = legacySnapshot() {
            let key = legacy.bookID.uuidString
            if let existing = map[key] {
                if legacy.updatedAt > existing.updatedAt {
                    map[key] = legacy
                }
            } else {
                map[key] = legacy
            }
        }
        return map
    }

    private func legacySnapshot() -> PlaybackPosition? {
        guard let data = defaults.data(forKey: Self.legacyKey) else { return nil }
        return try? JSONDecoder().decode(PlaybackPosition.self, from: data)
    }

    private func persist(_ map: [String: PlaybackPosition]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: Self.mapKey)
    }
}
