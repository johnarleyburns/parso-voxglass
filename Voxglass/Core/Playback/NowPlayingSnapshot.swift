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
    public let backgroundHex: UInt32?
    public let accentHex: UInt32?
    public let bookRemaining: TimeInterval?
    public let isPlaying: Bool
    public let updatedAt: Date

    public init(bookID: UUID, title: String, author: String, chapterEyebrow: String?, chapterTitle: String, fraction: Double, minutesLeftInChapter: Int, coverThumbnailPNG: Data? = nil, paletteIndex: Int, backgroundHex: UInt32? = nil, accentHex: UInt32? = nil, bookRemaining: TimeInterval? = nil, isPlaying: Bool = false, updatedAt: Date = Date(timeIntervalSince1970: 0)) {
        self.bookID = bookID; self.title = title; self.author = author; self.chapterEyebrow = chapterEyebrow; self.chapterTitle = chapterTitle
        self.fraction = min(max(fraction, 0), 1); self.minutesLeftInChapter = max(minutesLeftInChapter, 0); self.coverThumbnailPNG = coverThumbnailPNG; self.paletteIndex = paletteIndex
        self.backgroundHex = backgroundHex; self.accentHex = accentHex; self.bookRemaining = bookRemaining; self.isPlaying = isPlaying; self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case bookID, title, author, chapterEyebrow, chapterTitle, fraction, minutesLeftInChapter, coverThumbnailPNG, paletteIndex, backgroundHex, accentHex, bookRemaining, isPlaying, updatedAt }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            bookID: try values.decode(UUID.self, forKey: .bookID),
            title: try values.decode(String.self, forKey: .title),
            author: try values.decode(String.self, forKey: .author),
            chapterEyebrow: try values.decodeIfPresent(String.self, forKey: .chapterEyebrow),
            chapterTitle: try values.decode(String.self, forKey: .chapterTitle),
            fraction: try values.decode(Double.self, forKey: .fraction),
            minutesLeftInChapter: try values.decode(Int.self, forKey: .minutesLeftInChapter),
            coverThumbnailPNG: try values.decodeIfPresent(Data.self, forKey: .coverThumbnailPNG),
            paletteIndex: try values.decode(Int.self, forKey: .paletteIndex),
            backgroundHex: try values.decodeIfPresent(UInt32.self, forKey: .backgroundHex),
            accentHex: try values.decodeIfPresent(UInt32.self, forKey: .accentHex),
            bookRemaining: try values.decodeIfPresent(TimeInterval.self, forKey: .bookRemaining),
            isPlaying: try values.decodeIfPresent(Bool.self, forKey: .isPlaying) ?? false,
            updatedAt: try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
        )
    }
}
