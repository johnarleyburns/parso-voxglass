import Foundation

protocol InternetArchiveCatalogClient {
    func searchLibriVox(query: String, rows: Int) async throws -> [InternetArchiveSearchResult]
    func searchCollection(identifier: String, rows: Int) async throws -> [InternetArchiveSearchResult]
    func searchAdvanced(query: String, rows: Int) async throws -> [InternetArchiveSearchResult]
    func searchAdvancedPage(query: String, rows: Int, page: Int) async throws -> InternetArchivePage
    func metadata(for identifier: String) async throws -> InternetArchiveMetadata
}

extension InternetArchiveCatalogClient {
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
}

final class InternetArchiveClient: InternetArchiveCatalogClient {
    private let session: URLSession
    private let decoder: JSONDecoder

    init(session: URLSession = .shared, decoder: JSONDecoder = JSONDecoder()) {
        self.session = session
        self.decoder = decoder
    }

    func searchLibriVox(query: String, rows: Int = 25) async throws -> [InternetArchiveSearchResult] {
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
    static func libriVoxQuery(for rawInput: String) -> String {
        let scopeClause = " AND collection:(librivoxaudio OR audio_bookspoetry)"
        let tokens = rawInput
            .split { !$0.isLetter && !$0.isNumber }
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return "mediatype:audio" + scopeClause }

        // The phrase is rebuilt from sanitized tokens, so it carries no
        // Lucene-reserved characters.
        let phrase = tokens.joined(separator: " ")
        let phraseClause = "title:\"\(phrase)\"^8 OR subject:\"\(phrase)\"^6 OR description:\"\(phrase)\"^4"
        let perToken = tokens.map {
            "(title:\"\($0)\"^4 OR creator:\"\($0)\"^3 OR subject:\"\($0)\"^2 OR description:\"\($0)\"^1)"
        }.joined(separator: " AND ")
        return "mediatype:audio AND ((\(phraseClause)) OR (\(perToken)))" + scopeClause
    }

    func searchCollection(identifier: String, rows: Int = 25) async throws -> [InternetArchiveSearchResult] {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let archiveQuery = "collection:(\(Self.luceneToken(trimmed))) AND mediatype:(audio)"
        return try await searchAdvanced(query: archiveQuery, rows: rows)
    }

    func searchAdvanced(query: String, rows: Int = 25) async throws -> [InternetArchiveSearchResult] {
        try await searchAdvancedPage(query: query, rows: rows, page: 1).results
    }

    func searchAdvancedPage(query: String, rows: Int = 25, page: Int = 1) async throws -> InternetArchivePage {
        guard let url = Self.advancedSearchURL(query: query, rows: rows, page: page) else {
            throw InternetArchiveError.invalidURL
        }

        let data = try await fetch(url)
        let response = try decoder.decode(InternetArchiveSearchResponse.self, from: data)
        return InternetArchivePage(results: response.results, numFound: response.numFound, page: page)
    }

    func metadata(for identifier: String) async throws -> InternetArchiveMetadata {
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
        var metadata = try decoder.decode(InternetArchiveMetadata.self, from: data)
        if metadata.metadata.identifier == nil {
            metadata.metadata.identifier = trimmed
        }
        if metadata.files.isEmpty, !metadata.isCollection {
            throw InternetArchiveError.itemNotFound(trimmed)
        }
        return metadata
    }

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw InternetArchiveError.requestFailed(httpResponse.statusCode)
        }
        return data
    }

    private static func advancedSearchURL(query: String, rows: Int, page: Int) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "archive.org"
        components.path = "/advancedsearch.php"
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "output", value: "json"),
            URLQueryItem(name: "rows", value: String(rows)),
            URLQueryItem(name: "page", value: String(max(1, page))),
            URLQueryItem(name: "sort[]", value: "downloads desc"),
            URLQueryItem(name: "fl[]", value: "identifier"),
            URLQueryItem(name: "fl[]", value: "title"),
            URLQueryItem(name: "fl[]", value: "creator"),
            URLQueryItem(name: "fl[]", value: "description"),
            URLQueryItem(name: "fl[]", value: "collection"),
            URLQueryItem(name: "fl[]", value: "downloads"),
            URLQueryItem(name: "fl[]", value: "date"),
            URLQueryItem(name: "fl[]", value: "language")
        ]
        return components.url
    }

    private static func luceneToken(_ value: String) -> String {
        value.replacingOccurrences(of: #"[^A-Za-z0-9_\-.]"#, with: "", options: .regularExpression)
    }
}

enum InternetArchiveError: Error, LocalizedError, Equatable {
    case invalidURL
    case missingIdentifier
    case unsupportedURL
    case itemNotFound(String)
    case noPlayableAudio(String)
    case requestFailed(Int)

    var errorDescription: String? {
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
