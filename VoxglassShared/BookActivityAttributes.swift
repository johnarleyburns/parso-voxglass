import ActivityKit
import Foundation

struct BookActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var chapterTitle: String
        var chapterIndex: Int
        var chapterCount: Int
        var isPlaying: Bool
        var rate: Float
        var progressStart: Date?
        var progressEnd: Date?
        var chapterFraction: Double
        var bookRemaining: TimeInterval?
        var sleepUntil: Date?
        var sleepEndOfChapter: Bool
        var skipBack: Int
        var skipForward: Int
    }

    let bookID: UUID
    let title: String
    let author: String
    let narrator: String?
}
