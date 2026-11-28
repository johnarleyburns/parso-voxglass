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

    /// On-device search over the complete catalog. Direct callers pay the
    /// preparation cost on every query; the app caches `preparedForSearch()`.
    public func search(
        _ query: String,
        baseURL: URL,
        limit: Int = 50,
        preferredLanguages: Set<String> = []
    ) -> [GutenbergBook] {
        preparedForSearch().search(
            query,
            baseURL: baseURL,
            limit: limit,
            preferredLanguages: preferredLanguages
        )
    }

    /// Folds every searchable field exactly once. `GutenbergIndexStore` builds
    /// this off the main actor after loading or refreshing the mirror index.
    func preparedForSearch() -> GutenbergPreparedSearchIndex {
        GutenbergPreparedSearchIndex(index: self)
    }

    static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}

/// Maps the user's LibriVox language selection (e.g. `eng`) onto the language
/// codes used by `pg_catalog.csv` (e.g. `en`) and accepts either form when the
/// caller already has an ISO code.
enum GutenbergLanguagePreference {
    /// Enough to lift a preferred-language edition over an equally relevant
    /// foreign edition without overriding a materially tighter match.
    static let bonus = 500

    static func codes(for selection: Set<String>) -> Set<String> {
        guard !selection.isEmpty else { return [] }
        var codes: Set<String> = []
        for rawValue in selection {
            let key = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            if let language = LibriVoxLanguage.all.first(where: { $0.id == key }) {
                codes.insert(normalize(language.id))
                codes.insert(normalize(language.languageCode))
                for token in language.tokens { codes.insert(normalize(token)) }
            } else {
                codes.insert(normalize(key))
            }
        }
        return codes
    }

    static func normalize(_ value: String) -> String {
        let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowered
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init) ?? lowered
    }
}

struct GutenbergPreparedSearchIndex: Sendable {
    struct Record: Sendable {
        let book: GutenbergCatalogIndexBook
        let title: String
        let authors: String
        let subjects: String
        let shelves: String
        let haystack: String
        let languageCodes: Set<String>
    }

    let records: [Record]

    init(index: GutenbergCatalogIndex) {
        records = index.books.map { book in
            let title = GutenbergCatalogIndex.fold(book.title)
            let authors = GutenbergCatalogIndex.fold(book.authors.joined(separator: " "))
            let subjects = GutenbergCatalogIndex.fold(book.subjects.joined(separator: " "))
            let shelves = GutenbergCatalogIndex.fold(book.bookshelves.joined(separator: " "))
            return Record(
                book: book,
                title: title,
                authors: authors,
                subjects: subjects,
                shelves: shelves,
                haystack: [title, authors, subjects, shelves].joined(separator: " "),
                languageCodes: Set(book.languages.map(GutenbergLanguagePreference.normalize))
            )
        }
    }

    func search(
        _ query: String,
        baseURL: URL,
        limit: Int = 50,
        preferredLanguages: Set<String> = []
    ) -> [GutenbergBook] {
        let foldedQuery = GutenbergCatalogIndex.fold(
            query.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !foldedQuery.isEmpty else { return [] }
        let tokens = foldedQuery.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }

        let preferredCodes = GutenbergLanguagePreference.codes(for: preferredLanguages)
        let languageBonus = preferredCodes.isEmpty ? 0 : GutenbergLanguagePreference.bonus

        var scored: [(score: Int, record: Record)] = []
        for record in records {
            guard tokens.allSatisfy({ record.haystack.contains($0) }) else { continue }

            var score = 0
            if record.title == foldedQuery {
                score += 2_000
            } else if record.title.hasPrefix(foldedQuery) {
                score += 1_600
            } else if record.title.contains(foldedQuery) {
                score += 1_200
            }
            if record.authors.contains(foldedQuery) { score += 800 }
            if record.subjects.contains(foldedQuery) || record.shelves.contains(foldedQuery) {
                score += 400
            }

            for token in tokens {
                if record.title == token {
                    score += 500
                } else if record.title.hasPrefix(token) {
                    score += 300
                } else if record.title.contains(token) {
                    score += 200
                }
                if record.authors.contains(token) { score += 100 }
                if record.subjects.contains(token) || record.shelves.contains(token) {
                    score += 50
                }
            }

            if languageBonus != 0,
               !record.languageCodes.isDisjoint(with: preferredCodes) {
                score += languageBonus
            }
            scored.append((score, record))
        }

        scored.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.record.title != $1.record.title { return $0.record.title < $1.record.title }
            return $0.record.book.id < $1.record.book.id
        }

        return scored
            .prefix(limit)
            .map { $0.record.book.asGutenbergBook(baseURL: baseURL) }
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
    /// Folded titles/authors/subjects/shelves, built once per loaded snapshot.
    /// Rebuilding this on every query dominated interactive search latency.
    @ObservationIgnored private var preparedSearchIndex: GutenbergPreparedSearchIndex?
    /// Coalesces overlapping cold-start/search refreshes so only one manifest
    /// and index download can be in flight at a time.
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
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
                let manifestURL = directory.appendingPathComponent("manifest.json")
                let manifest = try JSONDecoder().decode(
                    GutenbergIndexManifest.self,
                    from: Data(contentsOf: manifestURL)
                )
                // A crash between the two atomic writes can leave an old
                // manifest next to a new index. Verify the pair before using
                // anything from disk, then let the network refresh repair it.
                guard compressed.count == manifest.bytes else {
                    throw GutenbergIndexError.sizeMismatch
                }
                guard SHA256Hex.hex(compressed) == manifest.sha256 else {
                    throw GutenbergIndexError.checksumMismatch
                }
                let data = try (compressed as NSData).decompressed(using: .zlib) as Data
                let decoded = try JSONDecoder().decode(GutenbergCatalogIndex.self, from: data)
                return (decoded, manifest, decoded.preparedForSearch())
            }.value
            index = loaded.0
            manifest = loaded.1
            preparedSearchIndex = loaded.2
        } catch {
            // Never publish a corrupt or mismatched snapshot. Keep any older
            // in-memory index that a concurrent refresh may have installed;
            // the next refreshIfNeeded() downloads a verified replacement.
            lastRefreshError = error.localizedDescription
        }
    }

    /// Loads the cached index first, then waits for (or starts) one mirror
    /// refresh when no usable snapshot exists. `DiscoverView` calls this before
    /// it considers the gutenberg.org/Gutendex fallback, so a cold launch uses
    /// the mirror even when the user searches before the background refresh
    /// finishes.
    public func prepareForSearch() async {
        if index == nil {
            await load()
        }
        if index == nil {
            await refreshIfNeeded()
        }
    }

    /// Fetches the tiny manifest, and downloads the versioned index only when
    /// its sha256 differs from the copy on disk. Failures are non-fatal: the
    /// previous index remains usable and the network search fallback remains.
    public func refreshIfNeeded(force: Bool = false) async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRefreshIfNeeded(force: force)
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefreshIfNeeded(force: Bool) async {
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
            let prepared = await Task.detached(priority: .utility) {
                decoded.preparedForSearch()
            }.value

            try fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            // Data.write(.atomic) replaces each file with a single rename.
            // Write the content-addressed payload first and the manifest that
            // points at it second; load() verifies the pair on the next launch.
            try compressed.write(
                to: storageDirectory.appendingPathComponent(Self.indexFileName),
                options: .atomic
            )
            try manifestData.write(
                to: storageDirectory.appendingPathComponent(Self.manifestFileName),
                options: .atomic
            )

            index = decoded
            manifest = remoteManifest
            preparedSearchIndex = prepared
            lastRefreshError = nil
        } catch {
            lastRefreshError = error.localizedDescription
        }
    }

    public func search(
        _ query: String,
        limit: Int = 50,
        preferredLanguages: Set<String> = []
    ) async -> [GutenbergBook] {
        guard let index else { return [] }
        let baseURL = self.baseURL
        let prepared = preparedSearchIndex
        return await Task.detached(priority: .userInitiated) {
            (prepared ?? index.preparedForSearch()).search(
                query,
                baseURL: baseURL,
                limit: limit,
                preferredLanguages: preferredLanguages
            )
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
