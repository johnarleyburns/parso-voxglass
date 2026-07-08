import Foundation

struct LastPlaybackSnapshotStore {
    private static let key = "org.voxglass.lastPlaybackSnapshot"

    func save(_ position: PlaybackPosition) {
        guard let data = try? JSONEncoder().encode(position) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    func load() -> PlaybackPosition? {
        guard let data = UserDefaults.standard.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(PlaybackPosition.self, from: data)
    }
}

