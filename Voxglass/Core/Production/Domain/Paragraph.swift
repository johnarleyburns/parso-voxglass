import Foundation

// MARK: - ParagraphRole

public enum ParagraphRole: String, Codable, Sendable {
    case body
    case chapterHeading
    case libriVoxIntro
    case libriVoxOutro
    case retailOpeningCredits
    case retailClosingCredits
}

// MARK: - SourceRange

public struct SourceRange: Codable, Sendable, Equatable {
    public var startOffset: Int
    public var endOffset: Int
    public var sourceFileHash: String

    public init(startOffset: Int, endOffset: Int, sourceFileHash: String) {
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.sourceFileHash = sourceFileHash
    }
}

// MARK: - PronunciationNote

public struct PronunciationNote: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var term: String
    public var guidance: String

    public init(id: UUID = UUID(), term: String, guidance: String) { // determinism-exempt: convenience default for new entries; import passes IDGenerator values
        self.id = id
        self.term = term
        self.guidance = guidance
    }
}

// MARK: - ReviewState

public enum ReviewState: String, Codable, Sendable, CaseIterable {
    case unreviewed
    case flagged
    case needsPickup
    case approved
}

// MARK: - ReviewNote

public struct ReviewNote: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var paragraphID: UUID
    public var text: String
    public var tag: ReviewTag?
    public var device: DeviceKind
    public var timecode: TimeInterval?
    public var createdAt: Date
    public var resolvedAt: Date?

    public init(
        id: UUID = UUID(), // determinism-exempt: convenience default for new entities; persistence passes IDGenerator values
        paragraphID: UUID,
        text: String,
        tag: ReviewTag? = nil,
        device: DeviceKind,
        timecode: TimeInterval? = nil,
        createdAt: Date = Date(), // determinism-exempt: convenience default for new entities; persistence passes Clock values
        resolvedAt: Date? = nil
    ) {
        self.id = id
        self.paragraphID = paragraphID
        self.text = text
        self.tag = tag
        self.device = device
        self.timecode = timecode
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
    }
}

public enum ReviewTag: String, Codable, Sendable, CaseIterable {
    case misread, pronunciation, pacing, noise, performance, edit
}

public enum DeviceKind: String, Codable, Sendable { case mac, iPhone, watch, carPlay }

// MARK: - Paragraph

public struct Paragraph: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var ordinal: Int
    public var text: String
    public var textHash: String
    public var role: ParagraphRole
    public var directionNote: String?
    public var pronunciationRefs: [UUID]
    public var takes: [Take]
    public var selectedTakeID: UUID?
    public var reviewState: ReviewState
    public var sourceRange: SourceRange?
    public var isSceneBreak: Bool
    public var updatedAt: Date

    public init(
        id: UUID,
        ordinal: Int,
        text: String,
        textHash: String,
        role: ParagraphRole = .body,
        directionNote: String? = nil,
        pronunciationRefs: [UUID] = [],
        takes: [Take] = [],
        selectedTakeID: UUID? = nil,
        reviewState: ReviewState = .unreviewed,
        sourceRange: SourceRange? = nil,
        isSceneBreak: Bool = false,
        updatedAt: Date = Date() // determinism-exempt: convenience default for new entities; persistence passes Clock values
    ) {
        self.id = id
        self.ordinal = ordinal
        self.text = text
        self.textHash = textHash
        self.role = role
        self.directionNote = directionNote
        self.pronunciationRefs = pronunciationRefs
        self.takes = takes
        self.selectedTakeID = selectedTakeID
        self.reviewState = reviewState
        self.sourceRange = sourceRange
        self.isSceneBreak = isSceneBreak
        self.updatedAt = updatedAt
    }
}
