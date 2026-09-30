import Foundation

/// Locale-aware duration strings shared by the phone, CarPlay, and Watch
/// surfaces. User-facing units must not be assembled from English suffixes.
public enum DurationFormatting {
    /// Formats a duration with localized abbreviated hours and minutes.
    public static func hoursAndMinutes(_ seconds: TimeInterval, minimumMinute: Bool = false) -> String {
        let totalSeconds = max(0, Int64(seconds.rounded()))
        let totalMinutes = max(minimumMinute ? 1 : 0, (totalSeconds + 59) / 60)
        return Duration.seconds(totalMinutes * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    /// Formats a duration with localized abbreviated seconds when it is under
    /// a minute, otherwise localized abbreviated minutes and hours.
    public static func compact(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        if totalSeconds < 60 {
            return Duration.seconds(Int64(totalSeconds))
                .formatted(.units(allowed: [.seconds], width: .abbreviated))
        }
        return hoursAndMinutes(TimeInterval(totalSeconds), minimumMinute: true)
    }

    /// Formats a remaining duration with a localized trailing label.
    public static func remaining(_ seconds: TimeInterval) -> String {
        String(localized: "\(hoursAndMinutes(seconds)) left", bundle: .module, comment: "Remaining playback duration")
    }
}
