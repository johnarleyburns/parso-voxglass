import Foundation
import VoxglassWatchProtocol

// Watch redesign (docs/plans/watch-redesign/DESIGN.md §5–§6): the spoken-audio rules the player
// face is built on — skip intervals, playback speed, the sleep timer, resume rewind, time left at
// the current speed, and the failure kinds the Problem Cards present. Pure and host-tested.

/// Audiobook skip intervals (§5 P1): back 15 s, forward 30 s — on the face, on AirPods
/// double/triple-press (`skipBackwardCommand`/`skipForwardCommand`), and on VoiceOver adjust.
public enum WatchSkip {
    public static let backward: TimeInterval = 15
    public static let forward: TimeInterval = 30

    /// The new chapter position after a skip, clamped to the chapter.
    public static func position(from position: TimeInterval, by delta: TimeInterval,
                                duration: TimeInterval) -> TimeInterval {
        let target = (position.isFinite ? position : 0) + delta
        let upper = duration.isFinite && duration > 0 ? duration : max(0, target)
        return min(max(0, target), upper)
    }
}

/// Playback speed (§5 C2): 0.5×–3.0× in 0.05 steps, detents every 0.25, two presets.
public enum WatchSpeed {
    public static let minimum = 0.5
    public static let maximum = 3.0
    public static let step = 0.05
    public static let presets: [Double] = [1.0, 1.5]

    /// Clamp and snap to the 0.05 grid so a Crown value never produces 1.2349999×.
    public static func normalized(_ rate: Double) -> Double {
        guard rate.isFinite else { return 1 }
        let clamped = min(max(rate, minimum), maximum)
        return (clamped / step).rounded() * step
    }

    /// True when the rate sits on a 0.25 detent (a stronger haptic).
    public static func isDetent(_ rate: Double) -> Bool {
        abs((normalized(rate) / 0.25).rounded() * 0.25 - normalized(rate)) < 0.001
    }

    /// The toolbar label: "1×", "1.2×", "1.25×".
    public static func label(_ rate: Double) -> String {
        let value = normalized(rate)
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return "\(text)×"
    }
}

/// Remembers the chosen speed per book (§5 C2 "Remembered per book").
public actor WatchSpeedStore {
    private let url: URL
    private var rates: [String: Double]

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: Double].self, from: data) {
            rates = decoded
        } else {
            rates = [:]
        }
    }

    public func rate(for bookID: WatchBookID) -> Double {
        WatchSpeed.normalized(rates[bookID.rawValue] ?? 1)
    }

    public func setRate(_ rate: Double, for bookID: WatchBookID) throws {
        rates[bookID.rawValue] = WatchSpeed.normalized(rate)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(rates).write(to: url, options: .atomic)
    }
}

/// The sleep timer (§5 C3): end of chapter, or a fixed number of minutes. The last 10 seconds fade.
public struct WatchSleepTimer: Equatable, Sendable {
    public enum Mode: Equatable, Sendable, Hashable {
        case endOfChapter
        case minutes(Int)
    }

    public static let fadeSeconds: TimeInterval = 10
    public static let choices: [Mode] = [.endOfChapter, .minutes(15), .minutes(30), .minutes(45), .minutes(60)]

    public let mode: Mode
    public let armedAt: Date

    public init(mode: Mode, armedAt: Date) {
        self.mode = mode
        self.armedAt = armedAt
    }

    /// Seconds until the timer fires. End of chapter uses the chapter's remaining *wall-clock*
    /// time at the current rate.
    public func remaining(at now: Date, chapterRemaining: TimeInterval, rate: Double) -> TimeInterval {
        switch mode {
        case .endOfChapter:
            let effectiveRate = rate.isFinite && rate > 0 ? rate : 1
            return max(0, chapterRemaining / effectiveRate)
        case .minutes(let minutes):
            return max(0, armedAt.addingTimeInterval(TimeInterval(minutes * 60)).timeIntervalSince(now))
        }
    }

    /// The output volume multiplier: 1 until the last `fadeSeconds`, then a linear fade to 0.
    public static func fadeMultiplier(remaining: TimeInterval) -> Double {
        guard remaining < fadeSeconds else { return 1 }
        return max(0, remaining / fadeSeconds)
    }
}

/// Resume rewind (§5): resuming after more than five minutes paused starts five seconds earlier.
public enum WatchResumeRewind {
    public static let threshold: TimeInterval = 5 * 60
    public static let rewind: TimeInterval = 5

    public static func position(_ saved: TimeInterval, pausedAt: Date?, now: Date) -> TimeInterval {
        guard let pausedAt, now.timeIntervalSince(pausedAt) > threshold else { return max(0, saved) }
        return max(0, saved - rewind)
    }
}

/// Time left (§5 P1/P2/H1): chapter or whole book, in wall-clock time at the current speed.
public enum WatchBookTime {
    public static func remainingInBook(chapterDurations: [TimeInterval], chapterIndex: Int,
                                       position: TimeInterval, rate: Double) -> TimeInterval {
        guard chapterDurations.indices.contains(chapterIndex) else { return 0 }
        let current = max(0, chapterDurations[chapterIndex] - max(0, position))
        let after = chapterDurations.dropFirst(chapterIndex + 1).reduce(0, +)
        let effectiveRate = rate.isFinite && rate > 0 ? rate : 1
        return (current + after) / effectiveRate
    }

    /// Fraction of the whole book listened, for the Home hero and library progress.
    public static func bookProgress(chapterDurations: [TimeInterval], chapterIndex: Int,
                                    position: TimeInterval) -> Double {
        let total = chapterDurations.reduce(0, +)
        guard total > 0, chapterDurations.indices.contains(chapterIndex) else { return 0 }
        let before = chapterDurations.prefix(chapterIndex).reduce(0, +)
        return min(1, max(0, (before + max(0, position)) / total))
    }
}

/// What a failure *is*, so the Problem Card can pick its title and action (§5 S1–S3). The
/// message stays human; the code is the diagnostic shown in small type.
public enum WatchPlaybackFailureKind: String, Codable, Equatable, Sendable {
    /// The audio session couldn't be activated: no Bluetooth output (S2).
    case noOutput
    /// The item loaded but audio never started, or stopped advancing (S1).
    case stalled
    /// The chapter isn't on the watch and can't be streamed right now (S3).
    case chapterUnavailable
    /// Anything else (S1 with its code).
    case other
}

/// The stall code shared with Platterhead's watch app: `stalled-<status>-<reason>`, with the
/// AVFoundation wait reason trimmed to its distinguishing words.
public enum WatchStallCode {
    public static func make(timeControlStatus: Int, reason: String?) -> String {
        let trimmed = (reason ?? "none")
            .replacingOccurrences(of: "AVPlayerWaiting", with: "")
            .replacingOccurrences(of: "Reason", with: "")
        return "stalled-\(timeControlStatus)-\(trimmed.isEmpty ? "none" : trimmed)"
    }
}

/// One book's download as "Downloads" shows it (§5 D1): how far along and the specific reason it
/// is waiting. The watch downloads approved chapters itself, or receives them from the iPhone.
public struct WatchBookDownload: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// The watch is fetching chapters itself.
        case downloading
        /// The iPhone is pushing chapter files (paused or stopped from the iPhone).
        case sendingFromPhone
        /// Nothing can start until the iPhone transfers or approves the chapters.
        case waitingForPhone
        case paused
        case failed(String)
    }

    public var done: Int
    public var total: Int
    public var state: State

    public init(done: Int, total: Int, state: State) {
        self.done = max(0, done)
        self.total = max(0, total)
        self.state = state
    }

    public var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }

    /// Pause/resume applies only to downloads the watch is doing itself.
    public var canPause: Bool {
        switch state {
        case .downloading: true
        default: false
        }
    }
}
