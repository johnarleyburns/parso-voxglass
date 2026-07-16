import Foundation

public struct Book: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var authors: [String]
    public var narrators: [String]
    public var summary: String?
    public var sourceID: UUID
    public var coverURL: URL?
    public var createdAt: Date
    public var updatedAt: Date
    public var isFavorite: Bool

    public init(
        id: UUID = UUID(),
        title: String,
        authors: [String],
        narrators: [String] = [],
        summary: String? = nil,
        sourceID: UUID,
        coverURL: URL? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isFavorite: Bool = false
    ) {
        self.id = id
        self.title = title
        self.authors = authors
        self.narrators = narrators
        self.summary = summary
        self.sourceID = sourceID
        self.coverURL = coverURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isFavorite = isFavorite
    }

    public var authorLine: String {
        authors.isEmpty ? "Unknown author" : authors.joined(separator: ", ")
    }

    public var narratorLine: String? {
        narrators.isEmpty ? nil : "Read by \(narrators.joined(separator: ", "))"
    }
}

public struct Chapter: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var bookID: UUID
    public var title: String
    public var sortKey: String
    public var index: Int
    public var duration: TimeInterval?
    public var remoteURL: URL?
    public var opusURL: URL?
    public var localURL: URL?
    public var narrators: [String]

    public init(
        id: UUID = UUID(),
        bookID: UUID,
        title: String,
        sortKey: String? = nil,
        index: Int,
        duration: TimeInterval? = nil,
        remoteURL: URL? = nil,
        opusURL: URL? = nil,
        localURL: URL? = nil,
        narrators: [String] = []
    ) {
        self.id = id
        self.bookID = bookID
        self.title = title
        self.sortKey = sortKey ?? title
        self.index = index
        self.duration = duration
        self.remoteURL = remoteURL
        self.opusURL = opusURL
        self.localURL = localURL
        self.narrators = narrators
    }

    public var playableURL: URL? {
        localURL ?? remoteURL
    }

    public func resolvedPlayableURL() -> URL? {
        if let localURL, let remoteURL {
            return FileManager.default.fileExists(atPath: localURL.path) ? localURL : remoteURL
        }
        return localURL ?? remoteURL
    }
}

public struct Source: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: SourceKind
    public var title: String
    public var url: URL?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: SourceKind,
        title: String,
        url: URL? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.url = url
        self.createdAt = createdAt
    }
}

public enum SourceKind: String, Codable, CaseIterable, Sendable {
    case librivox
    case internetArchive
    case internetArchiveURL
    case localFiles
}

public struct BookWithChapters: Identifiable, Equatable, Sendable {
    public var book: Book
    public var chapters: [Chapter]

    public init(book: Book, chapters: [Chapter]) {
        self.book = book
        self.chapters = chapters
    }

    public var id: UUID { book.id }

    public var totalDuration: TimeInterval? {
        let durations = chapters.compactMap(\.duration)
        guard !durations.isEmpty else { return nil }
        return durations.reduce(0, +)
    }
}

public extension Array where Element == Chapter {
    func naturallySorted() -> [Chapter] {
        sorted { lhs, rhs in
            if lhs.index != rhs.index {
                return lhs.index < rhs.index
            }
            return lhs.sortKey.localizedStandardCompare(rhs.sortKey) == .orderedAscending
        }
    }
}

