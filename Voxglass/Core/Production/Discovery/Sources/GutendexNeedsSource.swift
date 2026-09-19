import Foundation

/// Normalizes the two forms accepted by the Project Gutenberg importer:
/// an ebook number or a gutenberg.org URL. Keeping this in the core discovery
/// module makes the URL contract testable without constructing the recording
/// flow or touching the network.
public enum GutenbergInput {
    public static func ebookID(from rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if value.allSatisfy(\.isNumber) {
            return value
        }

        let candidate = value.lowercased().hasPrefix("http://") || value.lowercased().hasPrefix("https://")
            ? value
            : "https://\(value)"
        guard let url = URL(string: candidate),
              let host = url.host?.lowercased(),
              host == "gutenberg.org" || host.hasSuffix(".gutenberg.org") else {
            return nil
        }

        let components = url.path.split(separator: "/").map(String.init)
        if let ebooksIndex = components.firstIndex(where: { $0.lowercased() == "ebooks" }),
           components.indices.contains(ebooksIndex + 1),
           components[ebooksIndex + 1].allSatisfy(\.isNumber) {
            return components[ebooksIndex + 1]
        }
        if let epubIndex = components.firstIndex(where: { $0.lowercased() == "epub" }),
           components.indices.contains(epubIndex + 1),
           components[epubIndex + 1].allSatisfy(\.isNumber) {
            return components[epubIndex + 1]
        }
        return components.first(where: { $0.allSatisfy(\.isNumber) })
    }
}

/// L2 — Gutendex (NARRATION_NEEDS_SPEC §3.1): `GET gutendex.com/books?copyright=false&languages=en&topic=…&sort=popular`.
/// `copyright=false` guarantees US-PD by query. `formats` yields the citable
/// `sourcePageURL` + EPUB URL. Short/poetry works classify `.short`; prose
/// books classify `.long`. Grade `.submittable` (source host is gutenberg.org).
public struct GutendexNeedsSource: NeedsSource {
    public var id: NeedSourceID { .gutendex }

    public let endpoint: URL

    public init(topic: String? = nil) {
        var components = URLComponents(string: "https://gutendex.com/books")
        components?.queryItems = [
            URLQueryItem(name: "copyright", value: "false"),
            URLQueryItem(name: "languages", value: "en"),
            URLQueryItem(name: "sort", value: "popular")
        ]
        if let topic {
            components?.queryItems?.append(URLQueryItem(name: "topic", value: topic))
        }
        endpoint = components?.url ?? URL(string: "https://gutendex.com/books")!
    }

    public func fetch(using fetcher: any HTTPFetching, clock: any Clock) async throws -> [NarrationNeed] {
        let descriptor = NeedsSourceDescriptors.descriptor(for: id)
        let result = try await fetcher.get(endpoint, timeout: descriptor.defaultTimeout, userAgent: NeedsSourceDescriptors.userAgent(for: id))
        guard result.statusCode == 200 else { throw HTTPFetchError.httpStatus(result.statusCode) }
        return try decode(result.data, clock: clock)
    }

    public func decode(_ data: Data, clock: any Clock) throws -> [NarrationNeed] {
        let response = try NeedsJSONCoding.decoder.decode(GutendexResponse.self, from: data)
        let now = clock.now
        return response.results.compactMap { book in
            book.toNeed(now: now)
        }
    }
}

/// Search client for the explicit Project Gutenberg picker. This is separate
/// from `GutendexNeedsSource`: the needs ladder asks for popular works, while
/// the picker must honor the user's title/author query and pagination.
public struct GutendexSearchClient: Sendable {
    public let endpoint: URL

    public init(endpoint: URL = URL(string: "https://gutendex.com/books")!) {
        self.endpoint = endpoint
    }

    public func search(
        query: String,
        page: Int = 1,
        using fetcher: any HTTPFetching
    ) async throws -> GutendexSearchPage {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        components?.queryItems = [
            URLQueryItem(name: "search", value: trimmed),
            URLQueryItem(name: "page", value: String(max(1, page))),
            URLQueryItem(name: "languages", value: "en"),
            URLQueryItem(name: "copyright", value: "false")
        ]
        guard let url = components?.url else { throw HTTPFetchError.invalidURL }
        let result = try await fetcher.get(
            url,
            timeout: 15,
            userAgent: "Voxglass/1.1 (project-gutenberg-search; contact: hello@parso.guru)"
        )
        guard result.statusCode == 200 else { throw HTTPFetchError.httpStatus(result.statusCode) }
        let response = try NeedsJSONCoding.decoder.decode(GutendexResponse.self, from: result.data)
        return GutendexSearchPage(
            count: response.count,
            next: response.next,
            page: max(1, page),
            results: response.results
        )
    }
}

public struct GutendexSearchPage: Sendable, Equatable {
    public let count: Int
    public let next: String?
    public let page: Int
    public let results: [GutendexBook]

    public init(count: Int, next: String?, page: Int, results: [GutendexBook]) {
        self.count = count
        self.next = next
        self.page = page
        self.results = results
    }
}

// MARK: - Decodables

public struct GutendexResponse: Sendable, Codable {
    public var count: Int
    public var next: String?
    public var results: [GutendexBook]

    public init(count: Int, next: String? = nil, results: [GutendexBook]) {
        self.count = count
        self.next = next
        self.results = results
    }
}

public struct GutendexBook: Sendable, Codable, Equatable {
    public var id: Int
    public var title: String
    public var authors: [GutendexAuthor]
    public var bookshelves: [String]
    public var languages: [String]
    public var copyright: Bool?
    public var formats: [String: String]

    public init(
        id: Int,
        title: String,
        authors: [GutendexAuthor] = [],
        bookshelves: [String] = [],
        languages: [String] = [],
        copyright: Bool? = false,
        formats: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.authors = authors
        self.bookshelves = bookshelves
        self.languages = languages
        self.copyright = copyright
        self.formats = formats
    }

    public var authorLine: String {
        authors.isEmpty ? "Unknown author" : authors.map(Self.displayAuthor).joined(separator: ", ")
    }

    public var sourcePageURL: URL? {
        URL(string: "https://www.gutenberg.org/ebooks/\(id)")
    }

    public var textURL: URL? {
        firstFormat(in: ["text/plain; charset=utf-8", "text/plain", "text/html; charset=utf-8", "text/html"])
            .flatMap(URL.init(string:))
    }

    public var epubURL: URL? {
        firstFormat(in: ["application/epub+zip", "application/epub"]).flatMap(URL.init(string:))
    }

    public var isPublicDomain: Bool { copyright != true }

    func toNeed(now: Date) -> NarrationNeed? {
        guard copyright != true else { return nil }
        guard let sourceURL = firstFormat(in: ["text/html", "text/html; charset=utf-8", "text/plain"]),
              let pageURL = URL(string: sourceURL) else { return nil }

        let authorName = authors.first.map(Self.displayAuthor) ?? "Unknown"
        let isPoetry = bookshelves.contains { $0.localizedCaseInsensitiveContains("poetry") }
        let estSeconds = isPoetry ? 180 : 16_200
        let work = NarratableWork(
            title: cleanTitle(title),
            author: authorName,
            subject: isPoetry ? "poem" : "book",
            grade: .submittable,
            estSeconds: estSeconds,
            sourcePageURL: pageURL,
            sourceEPUBURL: firstFormat(in: ["application/epub+zip", "application/epub"]).flatMap(URL.init(string:))
        )
        return NarrationNeed(
            work: work,
            signal: .evergreen,
            strength: 60,
            provenance: NeedProvenance(
                sources: [.gutendex],
                firstSeen: now,
                lastConfirmed: now,
                pdBasis: .gutenbergSourced
            )
        )
    }

    private func firstFormat(in keys: [String]) -> String? {
        for key in keys {
            if let value = formats[key] { return value }
        }
        for (key, value) in formats {
            if keys.contains(where: { key.contains($0) }) {
                return value
            }
        }
        return nil
    }

    private func cleanTitle(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: #"\r\n"#, with: " ")
            .split(separator: "\n")
            .map(String.init)
            .first ?? raw
    }

    private static func displayAuthor(_ author: GutendexAuthor) -> String {
        // "Shakespeare, William" → "William Shakespeare"
        let parts = author.name.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count >= 2 {
            return "\(parts[1]) \(parts[0])".trimmingCharacters(in: .whitespaces)
        }
        return author.name
    }
}

public struct GutendexAuthor: Sendable, Codable, Equatable {
    public var name: String
    public var birthYear: Int?
    public var deathYear: Int?

    public init(name: String, birthYear: Int? = nil, deathYear: Int? = nil) {
        self.name = name
        self.birthYear = birthYear
        self.deathYear = deathYear
    }

    private enum CodingKeys: String, CodingKey {
        case name, birthYear = "birth_year", deathYear = "death_year"
    }
}
