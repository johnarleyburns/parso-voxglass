import Foundation

public enum ReviewPredicate: Codable, Sendable, Equatable, Hashable {
    case allRecorded
    case flagged
    case needsPickup
    case unapproved
    case unreviewed
    case selectedParagraphs(Set<UUID>)
    case chapter(UUID)
    case tag(ReviewTag)

    /// Stable, URL-safe identifier for UI accessibility labels and identifiers.
    public var debugDescription: String {
        switch self {
        case .allRecorded: return "all"
        case .flagged: return "flagged"
        case .needsPickup: return "pickup"
        case .unapproved: return "unapproved"
        case .unreviewed: return "unreviewed"
        case .selectedParagraphs: return "selected"
        case .chapter: return "chapter"
        case .tag: return "tag"
        }
    }
}

public enum QueueOrder: String, Codable, Sendable {
    case documentOrder
    case byChapter
    case flaggedFirst
    case shortestFirst
}

public struct ReviewQueueDefinition: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var projectID: UUID
    public var chapterIDs: Set<UUID>?
    public var predicate: ReviewPredicate
    public var order: QueueOrder
    public var autoAdvance: Bool
    public var skipApprovedImmediately: Bool
    public var playContextSecond: Bool

    public init(
        id: UUID = UUID(), // determinism-exempt: convenience default for new events; sync paths pass SequentialIDGenerator values
        projectID: UUID,
        chapterIDs: Set<UUID>? = nil,
        predicate: ReviewPredicate,
        order: QueueOrder,
        autoAdvance: Bool = true,
        skipApprovedImmediately: Bool = false,
        playContextSecond: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.chapterIDs = chapterIDs
        self.predicate = predicate
        self.order = order
        self.autoAdvance = autoAdvance
        self.skipApprovedImmediately = skipApprovedImmediately
        self.playContextSecond = playContextSecond
    }
}
