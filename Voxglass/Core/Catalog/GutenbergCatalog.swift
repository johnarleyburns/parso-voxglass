import Foundation

public struct GutenbergBook: Codable, Equatable, Sendable, Identifiable {
    public var id: Int
    public var title: String
    public var authors: [Author]
    public var subjects: [String]
    public var languages: [String]
    public var formats: [String: String]

    public struct Author: Codable, Equatable, Sendable {
        public var name: String
    }

    public var authorLine: String {
        let values = authors.map(\.name).filter { !$0.isEmpty }
        return values.isEmpty ? "Unknown author" : values.joined(separator: ", ")
    }
    public var epubURL: URL? {
        ["application/epub+zip", "application/epub"].compactMap { formats[$0].flatMap(URL.init(string:)) }.first
    }
    /// Gutendex supplies this for most books. The canonical cache URL covers
    /// the fallback HTML search, which does not include a formats map.
    public var coverURL: URL? {
        let formatCover = ["image/jpeg", "image/png", "image/webp"]
            .compactMap { formats[$0] }
            .first
        return URL(string: formatCover ?? "https://www.gutenberg.org/cache/epub/\(id)/pg\(id).cover.medium.jpg")
    }
    public var detailsURL: URL { URL(string: "https://www.gutenberg.org/ebooks/\(id)")! }
}

public struct GutenbergSearchResponse: Codable, Sendable {
    public var results: [GutenbergBook]
}

public struct GutenbergCatalogClient: Sendable {
    /// Interactive-search budget: a stalled endpoint must fail (and fall back)
    /// quickly rather than hold Find for the URLSession default of tens of seconds.
    public static let interactiveRequestTimeout: TimeInterval = 8
    public static let interactiveResourceTimeout: TimeInterval = 12

    public static func interactiveSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = interactiveRequestTimeout
        configuration.timeoutIntervalForResource = interactiveResourceTimeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    private let session: URLSession
    private let baseURL: URL
    private let projectGutenbergSearchURL: URL

    public init(
        session: URLSession = GutenbergCatalogClient.interactiveSession(),
        baseURL: URL = URL(string: "https://gutendex.com/books/")!,
        projectGutenbergSearchURL: URL = URL(string: "https://www.gutenberg.org/ebooks/search/")!
    ) {
        self.session = session
        self.baseURL = baseURL
        self.projectGutenbergSearchURL = projectGutenbergSearchURL
    }

    /// Project Gutenberg's HTML search is primary; Gutendex is only a fallback
    /// for non-cancellation failures of the primary request.
    public func search(_ query: String) async throws -> [GutenbergBook] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        do {
            return try await searchProjectGutenberg(trimmed)
        } catch {
            if Self.isCancellation(error) || Task.isCancelled { throw error }
            return try await searchGutendex(trimmed)
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private func searchGutendex(_ query: String) async throws -> [GutenbergBook] {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "copyright", value: "false"),
            URLQueryItem(name: "languages", value: "en")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Voxglass/1.1 (iOS; Read with AI)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(GutenbergSearchResponse.self, from: data).results.filter { $0.epubURL != nil }
    }

    private func searchProjectGutenberg(_ query: String) async throws -> [GutenbergBook] {
        var components = URLComponents(url: projectGutenbergSearchURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "query", value: query)]
        var request = URLRequest(url: components.url!)
        request.setValue("Voxglass/1.1 (iOS; Read with AI)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let books = Self.parseGutenbergSearchHTML(String(decoding: data, as: UTF8.self))
        // A 200 page with no recognizable result list and no "no results"
        // marker means the markup changed; treat it as a parse failure so the
        // fallback runs.
        if books.isEmpty, !Self.looksLikeEmptyResultPage(data) { throw URLError(.cannotParseResponse) }
        return books
    }

    private static func looksLikeEmptyResultPage(_ data: Data) -> Bool {
        let html = String(decoding: data, as: UTF8.self).lowercased()
        return html.contains("search-results") || html.contains("no books found") || html.contains("no results")
            || html.contains("booklink")
    }

    static func parseGutenbergSearchHTML(_ html: String) -> [GutenbergBook] {
        let pattern = #"(?s)<li[^>]*class=\"[^\"]*booklink[^\"]*\"[^>]*>.*?<a[^>]*href=\"/ebooks/(\d+)\"[^>]*>.*?<span[^>]*class=\"title\"[^>]*>(.*?)</span>(?:.*?<span[^>]*class=\"subtitle\"[^>]*>(.*?)</span>)?"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return expression.matches(in: html, range: range).compactMap { match in
            guard let idRange = Range(match.range(at: 1), in: html),
                  let id = Int(html[idRange]),
                  let titleRange = Range(match.range(at: 2), in: html) else { return nil }
            let title = cleanHTML(String(html[titleRange]))
            guard !title.isEmpty else { return nil }
            let author: [GutenbergBook.Author] = {
                guard match.range(at: 3).location != NSNotFound,
                      let subtitleRange = Range(match.range(at: 3), in: html) else { return [] }
                let value = cleanHTML(String(html[subtitleRange]))
                    .replacingOccurrences(of: "by ", with: "", options: [.caseInsensitive])
                return value.isEmpty ? [] : [GutenbergBook.Author(name: value)]
            }()
            return GutenbergBook(
                id: id, title: title, authors: author, subjects: [], languages: [],
                formats: ["application/epub+zip": "https://www.gutenberg.org/ebooks/\(id).epub.images"]
            )
        }
    }

    private static func cleanHTML(_ value: String) -> String {
        value.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
