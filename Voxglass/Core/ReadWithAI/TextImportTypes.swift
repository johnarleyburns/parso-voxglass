import Foundation

public enum SourceFormat: String, Codable, Sendable { case epub }

public struct ImportWarning: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var kind: ImportWarningKind
    public var message: String
    public var paragraphIndex: Int?
    public init(id: UUID = UUID(), kind: ImportWarningKind, message: String, paragraphIndex: Int? = nil) {
        self.id = id; self.kind = kind; self.message = message; self.paragraphIndex = paragraphIndex
    }
}

public enum ImportWarningKind: String, Codable, Sendable {
    case emptySection, imageOnlyContent, skippedNonProse
}

enum ImportError: Error { case malformedXML(String) }
