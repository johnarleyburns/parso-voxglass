import Foundation

// MARK: - ChapterRole

public enum ChapterRole: String, Codable, Sendable {
    case body
    case frontMatter
    case backMatter
    case openingCredits
    case closingCredits
}

// MARK: - Chapter

public struct ProductionChapter: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var ordinal: Int
    public var title: String
    public var role: ChapterRole
    public var paragraphs: [Paragraph]
    public var headSilenceOverride: TimeInterval?
    public var tailSilenceOverride: TimeInterval?
    public var notes: String?

    public init(
        id: UUID,
        ordinal: Int,
        title: String,
        role: ChapterRole = .body,
        paragraphs: [Paragraph] = [],
        headSilenceOverride: TimeInterval? = nil,
        tailSilenceOverride: TimeInterval? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.ordinal = ordinal
        self.title = title
        self.role = role
        self.paragraphs = paragraphs
        self.headSilenceOverride = headSilenceOverride
        self.tailSilenceOverride = tailSilenceOverride
        self.notes = notes
    }
}
