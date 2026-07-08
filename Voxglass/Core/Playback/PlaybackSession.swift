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
}

