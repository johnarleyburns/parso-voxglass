import Foundation

/// The whole CarPlay browse surface as a pure value tree. The app layer maps
/// these nodes mechanically onto `CP*` templates; every decision (ordering,
/// caps, empty states, gating) is made in `CarPlayMenuBuilder` so it is
/// host-testable with zero UIKit (see docs/CARPLAY_DESIGN.md §3).
public struct CarPlayInterface: Equatable, Sendable {
    public var tabs: [CarPlayTab]

    public init(tabs: [CarPlayTab]) {
        self.tabs = tabs
    }
}

public enum CarPlayTabID: String, Equatable, Sendable, CaseIterable {
    case continueListening, library, downloaded, discover, search
}

public struct CarPlayTab: Equatable, Sendable, Identifiable {
    public var id: CarPlayTabID
    public var title: String
    public var systemImage: String
    public var sections: [CarPlaySection]

    public init(id: CarPlayTabID, title: String, systemImage: String, sections: [CarPlaySection]) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.sections = sections
    }
}

public struct CarPlaySection: Equatable, Sendable {
    public var header: String?
    public var items: [CarPlayItem]

    public init(header: String? = nil, items: [CarPlayItem]) {
        self.header = header
        self.items = items
    }
}

public enum CarPlayArtwork: Equatable, Sendable {
    case url(URL)
    case symbol(String)
    case none
}

public enum CarPlayAccessory: Equatable, Sendable {
    case none
    case disclosure
    case cloud
    case downloaded
    case downloading(Double)
    case nowPlaying
}

public struct CarPlayItem: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var detailText: String?
    public var artwork: CarPlayArtwork
    public var progress: Double?
    public var accessory: CarPlayAccessory
    public var isEnabled: Bool
    public var action: CarPlayAction

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        detailText: String? = nil,
        artwork: CarPlayArtwork = .none,
        progress: Double? = nil,
        accessory: CarPlayAccessory = .none,
        isEnabled: Bool = true,
        action: CarPlayAction
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.detailText = detailText
        self.artwork = artwork
        self.progress = progress
        self.accessory = accessory
        self.isEnabled = isEnabled
        self.action = action
    }
}

public enum CarPlayBrowseRoute: Equatable, Sendable {
    case favorites
    case finished
    case inProgress
    case playlist(id: UUID, name: String)
    case author(String)
    case narrator(String)
    case genre(collectionID: String, name: String)
    case allPlaylists
    case browseByAuthor
    case browseByNarrator
}

public enum CarPlayAction: Equatable, Sendable {
    case resumeCurrent
    case playBook(bookID: UUID)
    case openBook(bookID: UUID)
    case playChapter(bookID: UUID, chapterID: UUID)
    case openTab(CarPlayTabID)
    case openRoute(CarPlayBrowseRoute)
    case playCatalogItem(identifier: String)
    case openCatalogItem(identifier: String)
    case download(bookID: UUID)
    case removeDownload(bookID: UUID)
    case beginSearch
    case runSearch(query: String)
    case setSleepTimer(SleepTimer.Mode)
    case addBookmark
    case showChapters
    case setRate(Float)
    case showProUpsell(ProFeature)
    case none
}
