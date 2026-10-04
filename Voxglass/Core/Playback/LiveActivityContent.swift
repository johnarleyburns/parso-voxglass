import Foundation

/// The sleep state rendered by the lock-screen activity.
public enum SleepState: Equatable, Sendable {
    case off
    case until(Date)
    case endOfChapter
}

/// Platform-free description of what the lock-screen Live Activity shows.
public struct LiveActivityContent: Equatable, Sendable {
    public var bookID: UUID
    public var title: String
    public var author: String
    public var narrator: String?
    public var chapterTitle: String
    public var chapterIndex: Int
    public var chapterCount: Int
    public var isPlaying: Bool
    public var rate: Float
    public var chapterElapsed: TimeInterval
    public var chapterDuration: TimeInterval?
    public var bookRemaining: TimeInterval?
    public var sleep: SleepState
    public var capturedAt: Date

    public init(
        bookID: UUID, title: String, author: String, narrator: String?, chapterTitle: String,
        chapterIndex: Int, chapterCount: Int, isPlaying: Bool, rate: Float,
        chapterElapsed: TimeInterval, chapterDuration: TimeInterval?, bookRemaining: TimeInterval?,
        sleep: SleepState, capturedAt: Date
    ) {
        self.bookID = bookID; self.title = title; self.author = author; self.narrator = narrator
        self.chapterTitle = chapterTitle; self.chapterIndex = chapterIndex; self.chapterCount = chapterCount
        self.isPlaying = isPlaying; self.rate = rate
        self.chapterElapsed = chapterElapsed.isFinite ? max(chapterElapsed, 0) : chapterElapsed
        self.chapterDuration = chapterDuration; self.bookRemaining = bookRemaining; self.sleep = sleep
        self.capturedAt = capturedAt
    }
}

/// Pure policy for deciding when ActivityKit needs a new payload.
public enum LiveActivityUpdatePolicy {
    public static func safeRate(_ rate: Float) -> Float {
        rate.isFinite && rate > 0 ? rate : 1
    }

    public static func safeElapsed(_ elapsed: TimeInterval) -> TimeInterval {
        elapsed.isFinite ? max(elapsed, 0) : 0
    }

    public static func shouldPush(previous: LiveActivityContent?, next: LiveActivityContent) -> Bool {
        guard let previous else { return true }
        guard previous.bookID == next.bookID,
              previous.chapterTitle == next.chapterTitle,
              previous.chapterIndex == next.chapterIndex,
              previous.isPlaying == next.isPlaying,
              previous.rate == next.rate,
              previous.sleep == next.sleep else { return true }

        let wallTime = max(next.capturedAt.timeIntervalSince(previous.capturedAt), 0)
        let expectedDrift = next.isPlaying ? Double(next.rate) * wallTime : 0
        return abs((next.chapterElapsed - previous.chapterElapsed) - expectedDrift) > 5
    }

    public static func progressInterval(for content: LiveActivityContent) -> ClosedRange<Date>? {
        guard content.isPlaying, content.rate > 0, content.chapterElapsed.isFinite,
              let duration = content.chapterDuration, duration.isFinite, duration > 0 else { return nil }
        let start = content.capturedAt.addingTimeInterval(-content.chapterElapsed / Double(content.rate))
        return start...start.addingTimeInterval(duration / Double(content.rate))
    }

    /// The chapter's played fraction, always finite and within 0...1. AVPlayer reports an unknown
    /// position or duration as NaN (paused, loading); a NaN fraction reached the Live Activity,
    /// whose `Int(fraction * 100)` trapped in the widget extension, so the lock screen showed only
    /// the grey placeholder.
    public static func chapterFraction(elapsed: TimeInterval, duration: TimeInterval?) -> Double {
        guard let duration, duration.isFinite, duration > 0, elapsed.isFinite else { return 0 }
        return min(max(elapsed / duration, 0), 1)
    }

    /// Time left in the book, or nil when it isn't a real, positive number.
    public static func bookRemaining(_ remaining: TimeInterval?) -> TimeInterval? {
        guard let remaining, remaining.isFinite, remaining > 0 else { return nil }
        return remaining
    }

    public static func staleDate(for content: LiveActivityContent) -> Date? {
        if let interval = progressInterval(for: content) {
            return interval.upperBound.addingTimeInterval(60)
        }
        return content.capturedAt.addingTimeInterval(15 * 60)
    }
}
