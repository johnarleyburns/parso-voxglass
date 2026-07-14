import Foundation

struct Book: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var authors: [String]
    var narrators: [String]
    var summary: String?
    var sourceID: UUID
    var coverURL: URL?
    var createdAt: Date
    var updatedAt: Date
    var isFavorite: Bool

    init(
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

    var authorLine: String {
        authors.isEmpty ? "Unknown author" : authors.joined(separator: ", ")
    }

    var narratorLine: String? {
        narrators.isEmpty ? nil : "Read by \(narrators.joined(separator: ", "))"
    }
}

struct Chapter: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var bookID: UUID
    var title: String
    var sortKey: String
    var index: Int
    var duration: TimeInterval?
    var remoteURL: URL?
    var opusURL: URL?
    var localURL: URL?
    var narrators: [String]

    init(
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

    var playableURL: URL? {
        localURL ?? remoteURL
    }

    func resolvedPlayableURL() -> URL? {
        if let localURL, let remoteURL {
            return FileManager.default.fileExists(atPath: localURL.path) ? localURL : remoteURL
        }
        return localURL ?? remoteURL
    }
}

struct Source: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var kind: SourceKind
    var title: String
    var url: URL?
    var createdAt: Date

    init(
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

enum SourceKind: String, Codable, CaseIterable, Sendable {
    case librivox
    case internetArchive
    case internetArchiveURL
    case localFiles
}

struct BookWithChapters: Identifiable, Equatable, Sendable {
    var book: Book
    var chapters: [Chapter]

    var id: UUID { book.id }

    var totalDuration: TimeInterval? {
        let durations = chapters.compactMap(\.duration)
        guard !durations.isEmpty else { return nil }
        return durations.reduce(0, +)
    }
}

extension Array where Element == Chapter {
    func naturallySorted() -> [Chapter] {
        sorted { lhs, rhs in
            if lhs.index != rhs.index {
                return lhs.index < rhs.index
            }
            return lhs.sortKey.localizedStandardCompare(rhs.sortKey) == .orderedAscending
        }
    }
}

