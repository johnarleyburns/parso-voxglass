import Foundation

struct PlaybackSession: Equatable {
    var book: Book
    var chapters: [Chapter]
    var chapter: Chapter
    var position: TimeInterval
    var duration: TimeInterval?
    var isPlaying: Bool

    var progress: Double {
        guard let duration, duration > 0 else { return 0 }
        return PlaybackMath.clampedPosition(position, duration: duration) / duration
    }

    var chapterIndex: Int {
        chapters.firstIndex { $0.id == chapter.id } ?? 0
    }

    /// Total book duration, or `nil` when any chapter lacks a known duration.
    var totalBookDuration: TimeInterval? {
        let durations = chapters.compactMap(\.duration)
        guard !durations.isEmpty, durations.count == chapters.count else { return nil }
        return durations.reduce(0, +)
    }

    /// Remaining time across the whole book (all chapters), or `nil` when
    /// durations are unavailable. Counts down across chapter boundaries.
    var bookRemaining: TimeInterval? {
        guard let total = totalBookDuration else { return nil }
        let elapsedBefore = chapters[..<min(chapterIndex, chapters.count)]
            .compactMap(\.duration)
            .reduce(0, +)
        let bookElapsed = elapsedBefore + position
        return max(total - bookElapsed, 0)
    }
}

