import Foundation

/// Pure playback-rate policy (P0-1): bounds and the allowed-rate ladders. The
/// in-app menu spans 0.5–3.5x; only a subset is surfaced in the system UI
/// (Control Center / lock screen / future CarPlay) via `changePlaybackRateCommand`.
public enum PlaybackRate {
    public static let minimum: Float = 0.5
    public static let maximum: Float = 3.5
    public static let normal: Float = 1.0

    /// Rates offered in the in-app speed menu.
    public static let menuLadder: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 3.5]

    /// Rates advertised to `MPRemoteCommandCenter.changePlaybackRateCommand` — the
    /// only ones the system UI (and CarPlay's rate button) will show.
    public static let systemLadder: [Float] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    public static func clamp(_ rate: Float) -> Float {
        Swift.min(Swift.max(rate, minimum), maximum)
    }

    /// Compact label like "1×", "1.5×".
    public static func label(_ rate: Float) -> String {
        if rate == rate.rounded() {
            return "\(Int(rate))×"
        }
        return "\(String(format: "%g", rate))×"
    }
}

/// Persists per-book playback rate so reopening a book restores its speed
/// (mirrors `EQSettingsStore`). Books with no stored rate fall back to 1.0×.
public final class PlaybackRateStore {
    private let defaults: UserDefaults
    private let prefix = "voxglass.rate."

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func rate(forBookID bookID: UUID) -> Float {
        let key = prefix + bookID.uuidString
        guard defaults.object(forKey: key) != nil else { return PlaybackRate.normal }
        return PlaybackRate.clamp(defaults.float(forKey: key))
    }

    public func setRate(_ rate: Float, forBookID bookID: UUID) {
        defaults.set(PlaybackRate.clamp(rate), forKey: prefix + bookID.uuidString)
    }
}
