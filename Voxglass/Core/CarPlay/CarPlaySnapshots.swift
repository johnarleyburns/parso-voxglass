import Foundation

/// The DTOs the app layer fills from live stores so `CarPlayMenuBuilder` never
/// imports a store. Pure values: the builder is a function of these snapshots.
public struct CarPlayBookSnapshot: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var authorLine: String
    public var authors: [String]
    public var narrators: [String]
    public var coverURL: URL?
    public var chapterCount: Int
    public var isFavorite: Bool
    public var lastPlayedAt: Date?
    public var progress: CarPlayProgress?
    public var download: CarPlayDownloadState

    public init(
        id: UUID,
        title: String,
        authorLine: String,
        authors: [String] = [],
        narrators: [String] = [],
        coverURL: URL? = nil,
        chapterCount: Int,
        isFavorite: Bool = false,
        lastPlayedAt: Date? = nil,
        progress: CarPlayProgress? = nil,
        download: CarPlayDownloadState = .notDownloaded
    ) {
        self.id = id
        self.title = title
        self.authorLine = authorLine
        self.authors = authors
        self.narrators = narrators
        self.coverURL = coverURL
        self.chapterCount = chapterCount
        self.isFavorite = isFavorite
        self.lastPlayedAt = lastPlayedAt
        self.progress = progress
        self.download = download
    }
}

public struct CarPlayProgress: Equatable, Sendable {
    public var chapterIndex: Int
    public var chapterCount: Int
    public var chapterTitle: String
    public var position: TimeInterval
    public var chapterDuration: TimeInterval?
    public var bookRemaining: TimeInterval?
    public var isFinished: Bool

    public init(
        chapterIndex: Int,
        chapterCount: Int,
        chapterTitle: String,
        position: TimeInterval,
        chapterDuration: TimeInterval? = nil,
        bookRemaining: TimeInterval? = nil,
        isFinished: Bool = false
    ) {
        self.chapterIndex = chapterIndex
        self.chapterCount = chapterCount
        self.chapterTitle = chapterTitle
        self.position = position
        self.chapterDuration = chapterDuration
        self.bookRemaining = bookRemaining
        self.isFinished = isFinished
    }

    /// The 0…1 fraction shown as the row's progress bar.
    public var fraction: Double {
        if isFinished { return 1 }
        guard chapterCount > 0 else { return 0 }
        var withinChapter = 0.0
        if let chapterDuration, chapterDuration > 0 {
            withinChapter = min(1, max(0, position / chapterDuration))
        }
        return min(1, (Double(chapterIndex) + withinChapter) / Double(chapterCount))
    }

    /// Derives chapter-level progress from a cumulative book position (the shape
    /// `LibraryStore.progressByBook` exposes) by walking the chapter durations.
    public static func derive(
        cumulativePosition: TimeInterval,
        isFinished: Bool,
        chapterTitles: [String],
        chapterDurations: [TimeInterval?]
    ) -> CarPlayProgress? {
        let count = chapterTitles.count
        guard count > 0 else { return nil }
        guard cumulativePosition > 0 || isFinished else { return nil }

        var remainingPosition = cumulativePosition
        var index = 0
        for (i, duration) in chapterDurations.enumerated() {
            guard let duration, duration > 0 else { break }
            if remainingPosition < duration {
                index = i
                break
            }
            remainingPosition -= duration
            index = min(i + 1, count - 1)
        }

        let knownDurations = chapterDurations.compactMap { $0 }
        let bookRemaining: TimeInterval? = knownDurations.count == count
            ? max(0, knownDurations.reduce(0, +) - cumulativePosition)
            : nil

        return CarPlayProgress(
            chapterIndex: index,
            chapterCount: count,
            chapterTitle: chapterTitles[index],
            position: max(0, remainingPosition),
            chapterDuration: chapterDurations[index] ?? nil,
            bookRemaining: bookRemaining,
            isFinished: isFinished
        )
    }
}

public enum CarPlayDownloadState: Equatable, Sendable {
    case notDownloaded
    case downloading(Double)
    case downloaded
}

public struct CarPlayChapterSnapshot: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var index: Int
    public var duration: TimeInterval?
    public var hasPlayableURL: Bool

    public init(id: UUID, title: String, index: Int, duration: TimeInterval? = nil, hasPlayableURL: Bool = true) {
        self.id = id
        self.title = title
        self.index = index
        self.duration = duration
        self.hasPlayableURL = hasPlayableURL
    }
}

public struct CarPlayPlaylistSnapshot: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var bookIDs: [UUID]

    public init(id: UUID, name: String, bookIDs: [UUID]) {
        self.id = id
        self.name = name
        self.bookIDs = bookIDs
    }
}

public struct CarPlayCatalogSnapshot: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var authorLine: String
    public var coverURL: URL?
    public var alreadyInLibrary: UUID?

    public init(id: String, title: String, authorLine: String, coverURL: URL? = nil, alreadyInLibrary: UUID? = nil) {
        self.id = id
        self.title = title
        self.authorLine = authorLine
        self.coverURL = coverURL
        self.alreadyInLibrary = alreadyInLibrary
    }
}

/// The single injected snapshot bag the controller rebuilds from live stores
/// and hands to the pure builder — pure in, pure out.
public struct CarPlayState: Equatable, Sendable {
    public var books: [CarPlayBookSnapshot]
    public var recentlyPlayed: [CarPlayBookSnapshot]
    public var playlists: [CarPlayPlaylistSnapshot]
    public var recommendations: [CarPlayCatalogSnapshot]
    public var searchResults: [CarPlayCatalogSnapshot]
    public var isDownloadsPro: Bool
    public var hasCurrentSession: Bool
    public var currentBookID: UUID?

    public init(
        books: [CarPlayBookSnapshot] = [],
        recentlyPlayed: [CarPlayBookSnapshot] = [],
        playlists: [CarPlayPlaylistSnapshot] = [],
        recommendations: [CarPlayCatalogSnapshot] = [],
        searchResults: [CarPlayCatalogSnapshot] = [],
        isDownloadsPro: Bool = false,
        hasCurrentSession: Bool = false,
        currentBookID: UUID? = nil
    ) {
        self.books = books
        self.recentlyPlayed = recentlyPlayed
        self.playlists = playlists
        self.recommendations = recommendations
        self.searchResults = searchResults
        self.isDownloadsPro = isDownloadsPro
        self.hasCurrentSession = hasCurrentSession
        self.currentBookID = currentBookID
    }

    /// A representative fixture: one in-progress book, mid-chapter. Used by the
    /// single renderer smoke test (docs/CARPLAY_DESIGN.md §8).
    public static func fixtureWithOneInProgressBook() -> CarPlayState {
        let bookID = UUID()
        let book = CarPlayBookSnapshot(
            id: bookID,
            title: "The Time Machine",
            authorLine: "H. G. Wells",
            authors: ["H. G. Wells"],
            chapterCount: 12,
            lastPlayedAt: Date(),
            progress: CarPlayProgress(
                chapterIndex: 4,
                chapterCount: 12,
                chapterTitle: "Ch 5",
                position: 750,
                chapterDuration: 1800,
                bookRemaining: 8_040
            )
        )
        return CarPlayState(
            books: [book],
            recentlyPlayed: [book],
            hasCurrentSession: true,
            currentBookID: bookID
        )
    }
}
