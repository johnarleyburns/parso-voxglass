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
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "search", value: trimmed),
            URLQueryItem(name: "copyright", value: "false"),
            URLQueryItem(name: "languages", value: "en")
        ]
        let (data, response) = try await session.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(GutenbergSearchResponse.self, from: data).results.filter { $0.epubURL != nil }
    }
}
