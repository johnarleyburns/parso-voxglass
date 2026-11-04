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
    public var detailsURL: URL { URL(string: "https://www.gutenberg.org/ebooks/\(id)")! }
}

public struct GutenbergSearchResponse: Codable, Sendable {
    public var results: [GutenbergBook]
}

public struct GutenbergCatalogClient: Sendable {
    private let session: URLSession
    private let baseURL: URL

    public init(session: URLSession = .shared, baseURL: URL = URL(string: "https://gutendex.com/books/")!) {
        self.session = session
        self.baseURL = baseURL
    }
    public func search(_ query: String) async throws -> [GutenbergBook] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        do {
            return try await searchGutendex(trimmed)
        } catch {
            // Gutendex is a convenient catalogue projection, but its hosted
            // service is occasionally unavailable. Fall back to Gutenberg's
            // human-facing search so Find remains useful during those gaps.
            return try await searchProjectGutenberg(trimmed)
        }
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
        var components = URLComponents(string: "https://www.gutenberg.org/ebooks/search/")!
        components.queryItems = [URLQueryItem(name: "query", value: query)]
        var request = URLRequest(url: components.url!)
        request.setValue("Voxglass/1.1 (iOS; Read with AI)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return Self.parseGutenbergSearchHTML(String(decoding: data, as: UTF8.self))
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
