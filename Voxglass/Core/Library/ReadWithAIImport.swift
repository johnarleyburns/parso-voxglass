import Foundation

/// The durable, app-owned text chapter passed from the Files/Gutenberg importer
/// into the library.  Text lives in Application Support, so it is available to
/// the speech engine without holding a Files security-scoped bookmark open.
public struct ReadWithAIChapterImport: Sendable {
    public var title: String
    public var textURL: URL

    public init(title: String, textURL: URL) {
        self.title = title
        self.textURL = textURL
    }
}

public struct ReadWithAIImport: Sendable {
    public var title: String
    public var authors: [String]
    public var summary: String?
    public var sourceTitle: String
    public var sourceURL: URL?
    public var stableIdentifier: String?
    /// Files imports are explicit user additions and belong in My Books.
    /// Gutenberg's preview flow opts in to pending status until confirmation.
    public var isPending: Bool
    public var chapters: [ReadWithAIChapterImport]

    public init(
        title: String,
        authors: [String],
        summary: String? = nil,
        sourceTitle: String,
        sourceURL: URL? = nil,
        stableIdentifier: String? = nil,
        isPending: Bool = false,
        chapters: [ReadWithAIChapterImport]
    ) {
        self.title = title
        self.authors = authors
        self.summary = summary
        self.sourceTitle = sourceTitle
        self.sourceURL = sourceURL
        self.stableIdentifier = stableIdentifier
        self.isPending = isPending
        self.chapters = chapters
    }
}
