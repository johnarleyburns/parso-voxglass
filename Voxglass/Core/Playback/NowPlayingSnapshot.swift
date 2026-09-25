import Foundation

/// Codable, on-device state shared with widgets and controls.
public struct NowPlayingSnapshot: Codable, Equatable, Sendable {
    public let bookID: UUID
    public let title: String
    public let author: String
    public let chapterEyebrow: String?
    public let chapterTitle: String
    public let fraction: Double
    public let minutesLeftInChapter: Int
    public let coverThumbnailPNG: Data?
    public let paletteIndex: Int

    public init(bookID: UUID, title: String, author: String, chapterEyebrow: String?, chapterTitle: String, fraction: Double, minutesLeftInChapter: Int, coverThumbnailPNG: Data? = nil, paletteIndex: Int) {
        self.bookID = bookID; self.title = title; self.author = author; self.chapterEyebrow = chapterEyebrow; self.chapterTitle = chapterTitle
        self.fraction = min(max(fraction, 0), 1); self.minutesLeftInChapter = max(minutesLeftInChapter, 0); self.coverThumbnailPNG = coverThumbnailPNG; self.paletteIndex = paletteIndex
    }
}
