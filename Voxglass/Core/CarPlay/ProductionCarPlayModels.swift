import Foundation

/// The CarPlay production surface as a pure value tree, mirroring the consumer
/// `CarPlayMenuBuilder` pattern: every decision (tab order, item cap, empty states)
/// is made host-side so it can run under `swift test` with zero CarPlay/UIKit.
/// The app layer translates these nodes mechanically onto `CP*` templates.
public enum ProductionQueueType: String, Codable, Sendable, CaseIterable, Identifiable {
    case flagged
    case needsPickup
    case unapproved

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .flagged: "Flagged"
        case .needsPickup: "Needs Pickup"
        case .unapproved: "Unapproved"
        }
    }
}

/// A user action on the CarPlay review player. The controller is the single place
/// that maps these to `ReviewEvent`s (spec §18.3 rule 7).
public enum CarPlayReviewCommand: String, Sendable, CaseIterable, Equatable {
    case approveAndNext
    case needsPickupAndNext
    case keepFlaggedAndNext
    case playNext
    case undo
}

/// How the system prev/next-track remote commands are mapped right now. While a
/// production queue is active they mean **paragraph** boundaries; otherwise they
/// revert to the consumer app's chapter behavior (spec §18.3 rule 3 — the most
/// likely regression point, so it is asserted in tests).
public enum RemoteCommandMapping: Sendable, Equatable {
    case paragraphBoundaries
    case consumer
}

public enum ProductionCarPlayAction: Equatable, Sendable {
    case openProduction(UUID)
    case startQueue(ProductionQueueType)
    case playWholeBook
    case openQueueBrowser
    case openNoteSummary
    case openSettings
    case playNext
    case undo
    case toggleAutoAdvance
    case toggleContext
    case toggleVoiceConfirmations
    case none
}

public struct ProductionCarPlayItem: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var detailText: String?
    public var symbol: String
    public var isEnabled: Bool
    public var action: ProductionCarPlayAction

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        detailText: String? = nil,
        symbol: String = "circle.fill",
        isEnabled: Bool = true,
        action: ProductionCarPlayAction
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.detailText = detailText
        self.symbol = symbol
        self.isEnabled = isEnabled
        self.action = action
    }
}

public struct ProductionCarPlaySection: Equatable, Sendable {
    public var header: String?
    public var items: [ProductionCarPlayItem]

    public init(header: String? = nil, items: [ProductionCarPlayItem]) {
        self.header = header
        self.items = items
    }
}

public struct ProductionCarPlayTab: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var systemImage: String
    public var badge: Int?
    public var sections: [ProductionCarPlaySection]

    public init(
        id: String,
        title: String,
        systemImage: String,
        badge: Int? = nil,
        sections: [ProductionCarPlaySection]
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.badge = badge
        self.sections = sections
    }
}

/// The note-summary screen's content (mockup `05-review-note-summary`).
public struct ProductionCarPlayNoteSummary: Equatable, Sendable {
    public var chapterLabel: String
    public var paragraphText: String?
    public var noteText: String?
    public var tag: ReviewTag?
    public var sourceLabel: String
    public var timeLabel: String

    public init(
        chapterLabel: String,
        paragraphText: String? = nil,
        noteText: String? = nil,
        tag: ReviewTag? = nil,
        sourceLabel: String = "iPhone",
        timeLabel: String = ""
    ) {
        self.chapterLabel = chapterLabel
        self.paragraphText = paragraphText
        self.noteText = noteText
        self.tag = tag
        self.sourceLabel = sourceLabel
        self.timeLabel = timeLabel
    }
}

/// The post-action confirmation content (mockup `06-voice-action-confirmation`).
public struct ProductionCarPlayConfirmation: Equatable, Sendable {
    public var title: String
    public var message: String
    public var nextParagraphLabel: String?

    public init(title: String, message: String, nextParagraphLabel: String? = nil) {
        self.title = title
        self.message = message
        self.nextParagraphLabel = nextParagraphLabel
    }
}
