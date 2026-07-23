import Foundation

public struct PlaybackSession: Equatable, Sendable {
    public var book: Book
    public var chapters: [Chapter]
    public var chapter: Chapter
    public var position: TimeInterval
    public var duration: TimeInterval?
    public var isPlaying: Bool

    public init(
        book: Book,
        chapters: [Chapter],
        chapter: Chapter,
        position: TimeInterval,
        duration: TimeInterval? = nil,
        isPlaying: Bool = false
    ) {
        self.book = book
        self.chapters = chapters
        self.chapter = chapter
        self.position = position
        self.duration = duration
        self.isPlaying = isPlaying
    }

    public var progress: Double {
        guard let duration, duration > 0 else { return 0 }
        return PlaybackMath.clampedPosition(position, duration: duration) / duration
    }

    public var chapterIndex: Int {
        chapters.firstIndex { $0.id == chapter.id } ?? 0
    }

    /// Total book duration, or `nil` when any chapter lacks a known duration.
    public var totalBookDuration: TimeInterval? {
        let durations = chapters.compactMap(\.duration)
        guard !durations.isEmpty, durations.count == chapters.count else { return nil }
        return durations.reduce(0, +)
    }

    /// Remaining time across the whole book (all chapters), or `nil` when
    /// durations are unavailable. Counts down across chapter boundaries.
    public var bookRemaining: TimeInterval? {
        guard let total = totalBookDuration else { return nil }
        let elapsedBefore = chapters[..<min(chapterIndex, chapters.count)]
            .compactMap(\.duration)
            .reduce(0, +)
        let bookElapsed = elapsedBefore + position
        return max(total - bookElapsed, 0)
    }
}

