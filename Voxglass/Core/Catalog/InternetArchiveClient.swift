import Foundation

public protocol InternetArchiveCatalogClient {
    func searchLibriVox(query: String, rows: Int) async throws -> [InternetArchiveSearchResult]
    func searchCollection(identifier: String, rows: Int) async throws -> [InternetArchiveSearchResult]
    func searchAdvanced(query: String, rows: Int) async throws -> [InternetArchiveSearchResult]
    func searchAdvancedPage(query: String, rows: Int, page: Int) async throws -> InternetArchivePage
    func searchAdvanced(query: String, rows: Int, sort: CatalogSort) async throws -> [InternetArchiveSearchResult]
    func searchAdvancedPage(query: String, rows: Int, page: Int, sort: CatalogSort) async throws -> InternetArchivePage
    func metadata(for identifier: String) async throws -> InternetArchiveMetadata
}

public extension InternetArchiveCatalogClient {
    func searchLibriVox(query: String) async throws -> [InternetArchiveSearchResult] {
        try await searchLibriVox(query: query, rows: 25)
    }

    func searchCollection(identifier: String) async throws -> [InternetArchiveSearchResult] {
        try await searchCollection(identifier: identifier, rows: 25)
    }

    func searchAdvanced(query: String) async throws -> [InternetArchiveSearchResult] {
        try await searchAdvanced(query: query, rows: 25)
    }

    func searchAdvanced(query: String, rows: Int) async throws -> [InternetArchiveSearchResult] {
        try await searchAdvancedPage(query: query, rows: rows, page: 1).results
    }

    func searchAdvanced(query: String, rows: Int, sort: CatalogSort) async throws -> [InternetArchiveSearchResult] {
        try await searchAdvancedPage(query: query, rows: rows, page: 1, sort: sort).results
    }

    func searchAdvancedPage(query: String, rows: Int, page: Int, sort: CatalogSort) async throws -> InternetArchivePage {
        try await searchAdvancedPage(query: query, rows: rows, page: page)
    }
}

public enum CatalogSort: String, CaseIterable, Identifiable, Sendable {
    case popularity
    case title
    case author
    case recordedDate

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .popularity:
            "Popularity"
        case .title:
            "Title"
        case .author:
            "Author"
        case .recordedDate:
            "Date"
        }
    }

    var archiveSortFields: [String] {
        switch self {
        case .popularity:
            ["downloads desc"]
        case .title:
            ["titleSorter asc", "title asc"]
        case .author:
            ["creatorSorter asc", "creator asc"]
        case .recordedDate:
            ["date asc"]
        }
    }
}

public enum LibriVoxCatalogScope {
    public static let collectionClause = "collection:librivoxaudio"
    public static let query = "\(collectionClause) AND mediatype:audio"

    public static func matching(_ clause: String) -> String {
        let normalized = clause
            .split { $0.isWhitespace }
            .joined(separator: " ")
        return "\(query) AND (\(normalized))"
    }
}

public final class InternetArchiveClient: InternetArchiveCatalogClient {
    private let session: URLSession
    private let decoder: JSONDecoder

    public init(session: URLSession = .shared, decoder: JSONDecoder = JSONDecoder()) {
        self.session = session
        self.decoder = decoder
    }

    public func searchLibriVox(query: String, rows: Int = 25) async throws -> [InternetArchiveSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        return try await searchAdvanced(query: Self.libriVoxQuery(for: trimmed), rows: rows)
    }

    /// Builds a relevance-tuned LibriVox query. Thematic/subject searches
    /// ("greek plays") collapsed under the old title/creator-only anchor, so the
    /// query now:
    ///   - boosts the whole phrase across title/subject/description, and
    ///   - requires every token to match, but lets *any* of title, creator,
    ///     subject, or description satisfy each token (no mandatory
    ///     title/creator anchor).
    /// Keeping token-AND preserves precision; the broadened fields let
    /// subject/description carry thematic queries. Restricted to the LibriVox
    /// audiobook collections.
    public static func libriVoxQuery(for rawInput: String) -> String {
        let scopeClause = " AND \(LibriVoxCatalogScope.query)"
        let tokens = rawInput
            .split { !$0.isLetter && !$0.isNumber }
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return LibriVoxCatalogScope.query }

        // The phrase is rebuilt from sanitized tokens, so it carries no
        // Lucene-reserved characters.
        let phrase = tokens.joined(separator: " ")
        let phraseClause = "title:\"\(phrase)\"^8 OR subject:\"\(phrase)\"^6 OR description:\"\(phrase)\"^4"
        let perToken = tokens.map {
            "(title:\"\($0)\"^4 OR creator:\"\($0)\"^3 OR subject:\"\($0)\"^2 OR description:\"\($0)\"^1)"
        }.joined(separator: " AND ")
        return "mediatype:audio AND ((\(phraseClause)) OR (\(perToken)))" + scopeClause
    }

    public func searchCollection(identifier: String, rows: Int = 25) async throws -> [InternetArchiveSearchResult] {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let archiveQuery = "collection:(\(Self.luceneToken(trimmed))) AND mediatype:(audio)"
        return try await searchAdvanced(query: archiveQuery, rows: rows)
    }

    public func searchAdvanced(query: String, rows: Int = 25) async throws -> [InternetArchiveSearchResult] {
        try await searchAdvancedPage(query: query, rows: rows, page: 1).results
    }

    public func searchAdvancedPage(query: String, rows: Int = 25, page: Int = 1) async throws -> InternetArchivePage {
        try await searchAdvancedPage(query: query, rows: rows, page: page, sort: .popularity)
    }

    public func searchAdvanced(query: String, rows: Int = 25, sort: CatalogSort) async throws -> [InternetArchiveSearchResult] {
        try await searchAdvancedPage(query: query, rows: rows, page: 1, sort: sort).results
    }

    public func searchAdvancedPage(
        query: String,
        rows: Int = 25,
        page: Int = 1,
        sort: CatalogSort
    ) async throws -> InternetArchivePage {
        guard let url = Self.advancedSearchURL(query: query, rows: rows, page: page, sort: sort) else {
            throw InternetArchiveError.invalidURL
        }

        let data = try await fetch(url)
        let response = try decoder.decode(InternetArchiveSearchResponse.self, from: data)
        return InternetArchivePage(results: response.results, numFound: response.numFound, page: page)
    }

    public func metadata(for identifier: String) async throws -> InternetArchiveMetadata {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw InternetArchiveError.missingIdentifier }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "archive.org"
        components.path = "/metadata/\(trimmed)"
        components.queryItems = [
            URLQueryItem(name: "extended_err", value: "1")
        ]
        guard let url = components.url else {
            throw InternetArchiveError.invalidURL
        }

        let data = try await fetch(url)
        // archive.org returns HTTP 200 with an empty `{}` body for identifiers
        // that don't exist. Decoding that into `InternetArchiveMetadata` throws a
        // raw `DecodingError.keyNotFound` ("The data couldn't be read because it
        // is missing.") with no context. Translate any decode failure here into a
        // named `itemNotFound` so callers can surface the identifier and recover.
        let metadata: InternetArchiveMetadata
        do {
            metadata = try decoder.decode(InternetArchiveMetadata.self, from: data)
        } catch {
            throw InternetArchiveError.itemNotFound(trimmed)
        }
        var resolved = metadata
        if resolved.metadata.identifier == nil {
            resolved.metadata.identifier = trimmed
        }
        if resolved.files.isEmpty, !resolved.isCollection {
            throw InternetArchiveError.itemNotFound(trimmed)
        }
        return resolved
    }

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw InternetArchiveError.requestFailed(httpResponse.statusCode)
        }
        return data
    }

    static func advancedSearchURL(
        query: String,
        rows: Int,
        page: Int,
        sort: CatalogSort = .popularity
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "archive.org"
        components.path = "/advancedsearch.php"
        var queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "output", value: "json"),
            URLQueryItem(name: "rows", value: String(rows)),
            URLQueryItem(name: "page", value: String(max(1, page))),
            URLQueryItem(name: "fl[]", value: "identifier"),
            URLQueryItem(name: "fl[]", value: "title"),
            URLQueryItem(name: "fl[]", value: "creator"),
            URLQueryItem(name: "fl[]", value: "description"),
            URLQueryItem(name: "fl[]", value: "collection"),
            URLQueryItem(name: "fl[]", value: "downloads"),
            URLQueryItem(name: "fl[]", value: "date"),
            URLQueryItem(name: "fl[]", value: "language"),
            URLQueryItem(name: "fl[]", value: "subject")
        ]
        let sortItems = sort.archiveSortFields.map {
            URLQueryItem(name: "sort[]", value: $0)
        }
        queryItems.insert(contentsOf: sortItems, at: 4)
        components.queryItems = queryItems
        return components.url
    }

    private static func luceneToken(_ value: String) -> String {
        value.replacingOccurrences(of: #"[^A-Za-z0-9_\-.]"#, with: "", options: .regularExpression)
    }
}

public enum InternetArchiveError: Error, LocalizedError, Equatable {
    case invalidURL
    case missingIdentifier
    case unsupportedURL
    case itemNotFound(String)
    case noPlayableAudio(String)
    case requestFailed(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The archive.org URL could not be built."
        case .missingIdentifier:
            "The Internet Archive item identifier is missing."
        case .unsupportedURL:
            "Use an archive.org item, collection, list, search, metadata, or download URL."
        case .itemNotFound(let identifier):
            "Internet Archive item not found: \(identifier)."
        case .noPlayableAudio(let identifier):
            "No playable audio files were found for \(identifier)."
        case .requestFailed(let statusCode):
            "Internet Archive request failed with status \(statusCode)."
        }
    }
}
