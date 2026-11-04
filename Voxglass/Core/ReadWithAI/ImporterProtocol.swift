import Foundation

public protocol SourceImporting: Sendable {
    var format: SourceFormat { get }
    func canImport(_ url: URL) -> Bool
    func extract(from url: URL) async throws -> ExtractedDocument
}

/// A snapshot of a progressive parse (spec §8.2): large documents parse
/// incrementally, with a preview available before the parse completes, and the
/// import screen must never block on a full parse. Importers that can stream
/// (EPUB, whose spine items parse one at a time) yield an update per unit; the
/// final update carries the completed document. Simpler importers inherit the
/// single-update default.
public struct ProgressiveImportUpdate: Sendable, Equatable {
    /// Sections fully parsed so far.
    public var sections: [ExtractedSection]
    /// True on the final update, which carries `completedDocument`.
    public var isComplete: Bool
    /// The finished document on the final update.
    public var completedDocument: ExtractedDocument?

    public init(
        sections: [ExtractedSection],
        isComplete: Bool,
        completedDocument: ExtractedDocument? = nil
    ) {
        self.sections = sections
        self.isComplete = isComplete
        self.completedDocument = completedDocument
    }
}

public extension SourceImporting {
    /// Default streaming implementation: one update with the completed
    /// document. Importers that can parse progressively override this.
    func extractProgressively(from url: URL) async throws -> AsyncThrowingStream<ProgressiveImportUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let document = try await extract(from: url)
                    continuation.yield(ProgressiveImportUpdate(
                        sections: document.sections,
                        isComplete: true,
                        completedDocument: document
                    ))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
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
