import Foundation
import VoxglassCore

enum TimeFormatting {
    static func clock(_ interval: TimeInterval?) -> String {
        guard let interval, interval.isFinite else { return "--:--" }
        let totalSeconds = max(0, Int(interval.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func compactDuration(_ interval: TimeInterval?) -> String {
        guard let interval, interval.isFinite else { return "Unknown length" }
        let totalMinutes = max(1, Int((interval / 60).rounded()))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0, minutes > 0 {
            return "\(hours)h \(minutes)m"
        }
        if hours > 0 {
            return "\(hours)h"
        }
        return "\(minutes)m"
    }
}

enum ByteFormatting {
    private static func formatter() -> ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .binary
        return formatter
    }

    static func string(_ bytes: Int64) -> String {
        formatter().string(fromByteCount: max(0, bytes))
    }

    /// A rough download-size estimate for a book we haven't downloaded yet —
    /// there's no real byte count to show until the transfer finishes, but a
    /// space-usage warning needs *some* number before the user commits. Most
    /// LibriVox/local audiobook audio this app handles is ~128kbps.
    static func estimatedAudiobookBytes(duration: TimeInterval) -> Int64 {
        Int64(max(0, duration) * 16_000)
    }
}
