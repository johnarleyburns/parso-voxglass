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
    public init() {}
    public func search(_ query: String) async throws -> [GutenbergBook] {
        var components = URLComponents(string: "https://gutendex.com/books")!
        components.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "copyright", value: "false"),
            URLQueryItem(name: "languages", value: "en")
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(GutenbergSearchResponse.self, from: data).results.filter { $0.epubURL != nil }
    }
}
