import Foundation

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

public struct GutendexBook: Sendable, Codable {
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

    func toNeed(now: Date) -> NarrationNeed? {
        guard copyright != true else { return nil }
        guard let sourceURL = firstFormat(in: ["text/html", "text/html; charset=utf-8", "text/plain"]),
              let pageURL = URL(string: sourceURL) else { return nil }

        let authorName = authors.first.map(formatAuthor) ?? "Unknown"
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

    private func formatAuthor(_ author: GutendexAuthor) -> String {
        // "Shakespeare, William" → "William Shakespeare"
        let parts = author.name.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count >= 2 {
            return "\(parts[1]) \(parts[0])".trimmingCharacters(in: .whitespaces)
        }
        return author.name
    }
}

public struct GutendexAuthor: Sendable, Codable {
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
