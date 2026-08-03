import Foundation

public enum SourceFormat: String, Codable, Sendable {
    case epub
    case txt
    case markdown
    case docx
    case manual
}

public struct ImportWarning: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var kind: ImportWarningKind
    public var message: String
    public var paragraphIndex: Int?

    public init(id: UUID = UUID(), kind: ImportWarningKind, message: String, paragraphIndex: Int? = nil) { // determinism-exempt: convenience default for new warnings; import passes IDGenerator values
        self.id = id
        self.kind = kind
        self.message = message
        self.paragraphIndex = paragraphIndex
    }
}

public enum ImportWarningKind: String, Codable, Sendable {
    case possibleSceneBreak
    case veryLongParagraph
    case veryShortParagraph
    case unrecognizedHeading
    case emptySection
    case encodingFallback
    case imageOnlyContent
    case skippedNonProse
}

public struct SourceDocument: Codable, Sendable, Equatable {
    public var format: SourceFormat
    public var originalFilename: String
    public var originalRef: AudioAssetReference
    public var extractedTextRef: AudioAssetReference
    public var sourceMapRef: AudioAssetReference?
    public var textHash: String
    public var importedAt: Date
    public var detectedSectionCount: Int
    public var importWarnings: [ImportWarning]

    public init(
        format: SourceFormat,
        originalFilename: String,
        originalRef: AudioAssetReference,
        extractedTextRef: AudioAssetReference,
        sourceMapRef: AudioAssetReference? = nil,
        textHash: String,
        importedAt: Date,
        detectedSectionCount: Int,
        importWarnings: [ImportWarning] = []
    ) {
        self.format = format
        self.originalFilename = originalFilename
        self.originalRef = originalRef
        self.extractedTextRef = extractedTextRef
        self.sourceMapRef = sourceMapRef
        self.textHash = textHash
        self.importedAt = importedAt
        self.detectedSectionCount = detectedSectionCount
        self.importWarnings = importWarnings
    }
}
