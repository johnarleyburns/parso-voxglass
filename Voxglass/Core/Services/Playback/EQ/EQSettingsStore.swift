import Foundation

/// Persists the user's EQ engaged-state and per-band gains so the equalizer
/// survives relaunch and is re-applied when a track loads.
final class EQSettingsStore {
    private let defaults: UserDefaults
    private let engagedKey = "voxglass.eq.engaged"
    private let gainsKey = "voxglass.eq.gains"

    static let bandCount = 10

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEngaged: Bool {
        get { defaults.bool(forKey: engagedKey) }
        set { defaults.set(newValue, forKey: engagedKey) }
    }

    var gains: [Float] {
        get {
            guard let data = defaults.data(forKey: gainsKey),
                  let stored = try? JSONDecoder().decode([Float].self, from: data),
                  stored.count == Self.bandCount else {
                return Array(repeating: 0, count: Self.bandCount)
            }
            return stored
        }
        set {
            let normalized = newValue.count == Self.bandCount
                ? newValue
                : Array(repeating: 0, count: Self.bandCount)
            if let data = try? JSONEncoder().encode(normalized) {
                defaults.set(data, forKey: gainsKey)
            }
        }
    }
}
