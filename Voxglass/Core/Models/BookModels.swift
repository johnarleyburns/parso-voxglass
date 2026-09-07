import Foundation
import os

public enum NarrationKind: String, Codable, Equatable, Sendable {
    case solo
    case mixedOrUnknown
}

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

    public var narrationKind: NarrationKind {
        NarrationClassifier.classify(narrators: narrators)
    }
}

public struct Chapter: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var bookID: UUID
    public var title: String
    public var sortKey: String
    public var index: Int
    /// Absolute position in `localURL`/`remoteURL` where this chapter starts.
    /// Most chapter files start at zero; single-file audiobooks use this to
    /// describe chapters within one shared audio asset.
    public var startTime: TimeInterval
    public var duration: TimeInterval?
    public var remoteURL: URL?
    public var opusURL: URL?
    public var localURL: URL?
    /// A security-scoped bookmark for `localURL`, present when this chapter
    /// references a file left in place on disk (import doesn't copy it into
    /// the app's own storage) rather than a copy the app owns. Needed to
    /// regain read access to it after the app relaunches.
    public var localBookmark: Data?
    public var narrators: [String]

    public init(
        id: UUID = UUID(),
        bookID: UUID,
        title: String,
        sortKey: String? = nil,
        index: Int,
        startTime: TimeInterval = 0,
        duration: TimeInterval? = nil,
        remoteURL: URL? = nil,
        opusURL: URL? = nil,
        localURL: URL? = nil,
        localBookmark: Data? = nil,
        narrators: [String] = []
    ) {
        self.id = id
        self.bookID = bookID
        self.title = title
        self.sortKey = sortKey ?? title
        self.index = index
        self.startTime = startTime
        self.duration = duration
        self.remoteURL = remoteURL
        self.opusURL = opusURL
        self.localURL = localURL
        self.localBookmark = localBookmark
        self.narrators = narrators
    }

    public var playableURL: URL? {
        localURL ?? remoteURL
    }

    /// The URL playback should use. A stale absolute local path (iOS moves the
    /// app container on update) is rebased onto the current container first;
    /// a local file that exists always wins, then the remote URL, then — for
    /// local-only books with no remote fallback — the original local URL so
    /// the caller surfaces a playback error instead of silently skipping.
    public func resolvedPlayableURL() -> URL? {
        if let localBookmark, let resolved = SecurityScopedBookmarkAccess.resolve(localBookmark) {
            return resolved
        }
        guard let localURL else { return remoteURL }
        let local = ContainerPathRebase.rebase(localURL)
        if FileManager.default.fileExists(atPath: local.path) {
            return local
        }
        return remoteURL ?? local
    }
}

/// Security-scoped access for local audiobook files an import leaves in
/// place instead of copying (a folder/file picked via `fileImporter` needs
/// this to stay readable after the app relaunches). Access is started once
/// per URL and deliberately never stopped: Apple's own guidance tolerates an
/// unbalanced start for a small, bounded set of long-lived references — this
/// app never has more than a handful of locally-referenced books — and it
/// avoids threading a start/stop pair through `AVQueuePlayer`'s overlapping
/// preloaded items, where no single, clear teardown point exists.
public enum SecurityScopedBookmarkAccess {
    // `OSAllocatedUnfairLock` carries its own lock-protected state, so the
    // Swift 6 checker can verify this static's Sendability on its own —
    // no unsafe-isolation escape hatch needed for what's otherwise the
    // same NSLock-guarded set.
    private static let started = OSAllocatedUnfairLock<Set<URL>>(initialState: [])

    /// Resolves `bookmark` to a URL and ensures security-scoped access is
    /// active for it, or nil if the bookmark can't be resolved (the file was
    /// moved, deleted, or the bookmark is otherwise invalid).
    public static func resolve(_ bookmark: Data) -> URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }

        let alreadyStarted = started.withLock { started in
            let wasStarted = started.contains(url)
            started.insert(url)
            return wasStarted
        }

        if !alreadyStarted {
            _ = url.startAccessingSecurityScopedResource()
        }
        return url
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

public struct BookWithChapters: Identifiable, Codable, Equatable, Sendable {
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

    public var narrationKind: NarrationKind {
        book.narrationKind
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
