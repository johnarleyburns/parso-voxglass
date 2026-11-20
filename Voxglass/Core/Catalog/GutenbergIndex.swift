import Foundation
import Observation

/// The compact catalog snapshot served from the public R2 mirror at
/// `gutenberg/catalog/index-<sha>.json.zlib`.
public struct GutenbergCatalogIndex: Codable, Equatable, Sendable {
    public var schema: Int
    public var generatedAt: String
    public var books: [GutenbergCatalogIndexBook]

    public init(schema: Int, generatedAt: String, books: [GutenbergCatalogIndexBook]) {
        self.schema = schema
        self.generatedAt = generatedAt
        self.books = books
    }

    /// On-device search over the complete catalog. The index is intentionally
    /// small enough for a linear pass (tens of thousands of records).
    public func search(_ query: String, baseURL: URL, limit: Int = 50) -> [GutenbergBook] {
        let foldedQuery = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !foldedQuery.isEmpty else { return [] }
        let tokens = foldedQuery.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }

        let scored: [(score: Int, book: GutenbergCatalogIndexBook)] = books.compactMap { book in
            let title = Self.fold(book.title)
            let authors = Self.fold(book.authors.joined(separator: " "))
            let subjects = Self.fold(book.subjects.joined(separator: " "))
            let shelves = Self.fold(book.bookshelves.joined(separator: " "))
            let haystack = [title, authors, subjects, shelves].joined(separator: " ")
            guard tokens.allSatisfy({ haystack.contains($0) }) else { return nil }

            var score = 0
            if title == foldedQuery {
                score += 2_000
            } else if title.hasPrefix(foldedQuery) {
                score += 1_600
            } else if title.contains(foldedQuery) {
                score += 1_200
            }
            if authors.contains(foldedQuery) { score += 800 }
            if subjects.contains(foldedQuery) || shelves.contains(foldedQuery) { score += 400 }

            for token in tokens {
                if title == token {
                    score += 500
                } else if title.hasPrefix(token) {
                    score += 300
                } else if title.contains(token) {
                    score += 200
                }
                if authors.contains(token) { score += 100 }
                if subjects.contains(token) || shelves.contains(token) { score += 50 }
            }
            return (score, book)
        }

        return scored
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.book.title.localizedCaseInsensitiveCompare($1.book.title) == .orderedAscending
            }
            .prefix(limit)
            .map { $0.book.asGutenbergBook(baseURL: baseURL) }
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}

public struct GutenbergCatalogIndexBook: Codable, Equatable, Sendable, Identifiable {
    public var id: Int
    public var title: String
    public var authors: [String]
    public var languages: [String]
    public var subjects: [String]
    public var bookshelves: [String]
    public var issued: String
    /// Path relative to the mirror's `gutenberg/` prefix.
    public var epub: String
    /// Path relative to the mirror's `gutenberg/` prefix.
    public var cover: String

    public init(
        id: Int,
        title: String,
        authors: [String],
        languages: [String],
        subjects: [String],
        bookshelves: [String],
        issued: String,
        epub: String,
        cover: String
    ) {
        self.id = id
        self.title = title
        self.authors = authors
        self.languages = languages
        self.subjects = subjects
        self.bookshelves = bookshelves
        self.issued = issued
        self.epub = epub
        self.cover = cover
    }

    func asGutenbergBook(baseURL: URL) -> GutenbergBook {
        let mirrorRoot = baseURL.appendingPathComponent("gutenberg")
        let epubURL = mirrorRoot.appendingPathComponent(epub).absoluteString
        let coverURL = mirrorRoot.appendingPathComponent(cover).absoluteString
        return GutenbergBook(
            id: id,
            title: title,
            authors: authors.map { GutenbergBook.Author(name: $0) },
            subjects: subjects,
            languages: languages,
            formats: [
                "application/epub+zip": epubURL,
                "image/jpeg": coverURL
            ]
        )
    }
}

public struct GutenbergIndexManifest: Codable, Equatable, Sendable {
    public var schema: Int
    public var version: String
    public var index: String
    public var sha256: String
    public var bytes: Int
    public var bookCount: Int

    public init(schema: Int, version: String, index: String, sha256: String, bytes: Int, bookCount: Int) {
        self.schema = schema
        self.version = version
        self.index = index
        self.sha256 = sha256
        self.bytes = bytes
        self.bookCount = bookCount
    }
}

/// Loads, refreshes, and searches the Gutenberg catalog index. The app only
/// needs the public mirror base URL; no R2 credentials live on the device.
@MainActor
@Observable
public final class GutenbergIndexStore {
    public private(set) var index: GutenbergCatalogIndex?
    public private(set) var manifest: GutenbergIndexManifest?
    public private(set) var isRefreshing = false
    public private(set) var lastRefreshError: String?

    public var isAvailable: Bool { index != nil }

    @ObservationIgnored private let baseURL: URL
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let storageDirectory: URL
    private static let indexFileName = "index.json.zlib"
    private static let manifestFileName = "manifest.json"

    public init(
        baseURL: URL,
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        storageDirectory: URL? = nil
    ) {
        self.baseURL = baseURL
        self.session = session
        self.fileManager = fileManager
        self.storageDirectory = storageDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Voxglass/GutenbergIndex", isDirectory: true)
    }

    /// Loads the last successfully downloaded index, if any. Synchronous file
    /// reads and decoding are done off the main actor.
    public func load() async {
        guard index == nil else { return }
        let directory = storageDirectory
        let indexURL = directory.appendingPathComponent(Self.indexFileName)
        guard fileManager.fileExists(atPath: indexURL.path) else { return }

        do {
            let loaded = try await Task.detached(priority: .utility) {
                let compressed = try Data(contentsOf: indexURL)
                let data = try (compressed as NSData).decompressed(using: .zlib) as Data
                let decoded = try JSONDecoder().decode(GutenbergCatalogIndex.self, from: data)
                let manifestURL = directory.appendingPathComponent(Self.manifestFileName)
                let manifest = try? JSONDecoder().decode(
                    GutenbergIndexManifest.self,
                    from: Data(contentsOf: manifestURL)
                )
                return (decoded, manifest)
            }.value
            index = loaded.0
            manifest = loaded.1
        } catch {
            lastRefreshError = error.localizedDescription
        }
    }

    /// Fetches the tiny manifest, and downloads the versioned index only when
    /// its sha256 differs from the copy on disk. Failures are non-fatal: the
    /// previous index remains usable and the network search fallback remains.
    public func refreshIfNeeded(force: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            var request = URLRequest(url: manifestURL)
            request.cachePolicy = .reloadRevalidatingCacheData
            request.timeoutInterval = 20
            let (manifestData, response) = try await session.data(for: request)
            try Self.validate(response)
            let remoteManifest = try JSONDecoder().decode(GutenbergIndexManifest.self, from: manifestData)

            if !force, let manifest, manifest.sha256 == remoteManifest.sha256, index != nil {
                return
            }

            var indexRequest = URLRequest(url: indexURL(for: remoteManifest))
            indexRequest.cachePolicy = .reloadRevalidatingCacheData
            indexRequest.timeoutInterval = 60
            let (compressed, indexResponse) = try await session.data(for: indexRequest)
            try Self.validate(indexResponse)
            guard compressed.count == remoteManifest.bytes else {
                throw GutenbergIndexError.sizeMismatch
            }
            guard SHA256Hex.hex(compressed) == remoteManifest.sha256 else {
                throw GutenbergIndexError.checksumMismatch
            }
            guard let decoded = try await Self.decodeIndex(compressed) else {
                throw GutenbergIndexError.invalidIndex
            }

            try fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            let tempIndex = storageDirectory.appendingPathComponent("\(Self.indexFileName).tmp")
            try compressed.write(to: tempIndex, options: .atomic)
            let finalIndex = storageDirectory.appendingPathComponent(Self.indexFileName)
            if fileManager.fileExists(atPath: finalIndex.path) {
                try fileManager.removeItem(at: finalIndex)
            }
            try fileManager.moveItem(at: tempIndex, to: finalIndex)
            try manifestData.write(
                to: storageDirectory.appendingPathComponent(Self.manifestFileName),
                options: .atomic
            )

            index = decoded
            manifest = remoteManifest
            lastRefreshError = nil
        } catch {
            lastRefreshError = error.localizedDescription
        }
    }

    public func search(_ query: String, limit: Int = 50) async -> [GutenbergBook] {
        guard let index else { return [] }
        let baseURL = self.baseURL
        return await Task.detached(priority: .userInitiated) {
            index.search(query, baseURL: baseURL, limit: limit)
        }.value
    }

    private var manifestURL: URL {
        baseURL.appendingPathComponent("gutenberg/catalog/manifest.json")
    }

    private func indexURL(for manifest: GutenbergIndexManifest) -> URL {
        baseURL.appendingPathComponent("gutenberg/catalog").appendingPathComponent(manifest.index)
    }

    private static func decodeIndex(_ compressed: Data) async throws -> GutenbergCatalogIndex? {
        try await Task.detached(priority: .utility) {
            let data = try (compressed as NSData).decompressed(using: .zlib) as Data
            return try JSONDecoder().decode(GutenbergCatalogIndex.self, from: data)
        }.value
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GutenbergIndexError.httpFailure
        }
    }
}

public enum GutenbergIndexError: Error, Equatable, Sendable {
    case httpFailure
    case sizeMismatch
    case checksumMismatch
    case invalidIndex
}
