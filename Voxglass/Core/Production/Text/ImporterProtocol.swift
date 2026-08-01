import Foundation

public protocol SourceImporting: Sendable {
    var format: SourceFormat { get }
    func canImport(_ url: URL) -> Bool
    func extract(from url: URL) async throws -> ExtractedDocument
}

public struct ExtractedDocument: Sendable, Equatable {
    public var sections: [ExtractedSection]
    public var title: String?
    public var author: String?
    public var language: String?
    public var warnings: [ImportWarning]
    public var plainText: String

    public init(
        sections: [ExtractedSection] = [],
        title: String? = nil,
        author: String? = nil,
        language: String? = nil,
        warnings: [ImportWarning] = [],
        plainText: String = ""
    ) {
        self.sections = sections
        self.title = title
        self.author = author
        self.language = language
        self.warnings = warnings
        self.plainText = plainText
    }
}

public struct ExtractedSection: Sendable, Equatable {
    public var heading: String?
    public var blocks: [ExtractedBlock]
    public var sourceStart: Int

    public init(heading: String? = nil, blocks: [ExtractedBlock] = [], sourceStart: Int = 0) {
        self.heading = heading
        self.blocks = blocks
        self.sourceStart = sourceStart
    }
}

public struct ExtractedBlock: Sendable, Equatable {
    public var kind: BlockKind
    public var text: String
    public var sourceRange: Range<Int>
    public var headingLevel: Int?

    public init(kind: BlockKind, text: String, sourceRange: Range<Int>, headingLevel: Int? = nil) {
        self.kind = kind
        self.text = text
        self.sourceRange = sourceRange
        self.headingLevel = headingLevel
    }
}

public enum BlockKind: String, Sendable, CaseIterable {
    case paragraph
    case heading
    case sceneBreak
    case verse
    case listItem
    case blockquote
}
