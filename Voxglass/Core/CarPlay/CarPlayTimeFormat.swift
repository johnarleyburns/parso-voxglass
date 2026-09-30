import Foundation

/// Core-side compact time formatter for CarPlay detail text, so the pure
/// builder never reaches into the app-layer `TimeFormatting` (docs/CARPLAY_DESIGN.md §4.2).
public enum CarPlayTimeFormat {
    /// `"2h 14m"`, `"18 min"`, `"48s"`, `"0s"`.
    public static func compact(_ interval: TimeInterval) -> String {
        DurationFormatting.compact(interval)
    }
}
