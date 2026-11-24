import Foundation
import os

/// A Gutenberg failure that the UI can explain without leaking URLSession text.
public enum GutenbergCatalogError: Error, Equatable, Sendable {
    /// The catalog host is in maintenance, rate-limiting us, or unreachable.
    /// `retryAfter` is the server's `Retry-After` hint when it supplied one.
    case temporarilyUnavailable(retryAfter: TimeInterval?)
    /// A 2xx response did not look like either search format.
    case unexpectedResponse
    /// The host returned a non-success status other than 429/503.
    case httpStatus(Int)

    var isOutage: Bool {
        if case .temporarilyUnavailable = self { return true }
        return false
    }
}

public struct GutenbergBook: Codable, Equatable, Sendable, Identifiable {
    public var id: Int
    public var title: String
    public var authors: [Author]
    public var subjects: [String]
    public var languages: [String]
    public var formats: [String: String]
    /// Gutendex exposes this; the HTML search does not. Optional so both decode.
    public var copyright: Bool? = nil

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
    private static let logger = Logger(subsystem: "guru.parso.voxglass", category: "Gutenberg")

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
    /// for non-cancellation failures of the primary request. A maintenance or
    /// rate-limit response is terminal: waiting for Gutendex's cold origin only
    /// turns a clear outage into an eight-second timeout.
    public func search(_ query: String) async throws -> [GutenbergBook] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        do {
            return try await searchProjectGutenberg(trimmed)
        } catch let error as GutenbergCatalogError where error.isOutage {
            Self.logger.info("Gutenberg primary unavailable; not calling fallback")
            throw error
        } catch {
            if Self.isCancellation(error) || Task.isCancelled { throw error }
            Self.logger.info("Gutenberg primary failed; trying Gutendex")
            do {
                return try await searchGutendex(trimmed)
            } catch let error as GutenbergCatalogError where error.isOutage {
                Self.logger.info("Gutendex unavailable")
                throw error
            } catch {
                if Self.isCancellation(error) || Task.isCancelled { throw error }
                if Self.isConnectivityFailure(error) {
                    Self.logger.info("Gutendex connectivity failure")
                    throw GutenbergCatalogError.temporarilyUnavailable(retryAfter: nil)
                }
                throw error
            }
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private static func isConnectivityFailure(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .networkConnectionLost, .notConnectedToInternet, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    private func searchGutendex(_ query: String) async throws -> [GutenbergBook] {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        // Keep the URL cacheable. Filtering in the client avoids making every
        // query unique, which bypassed Cloudflare's cache while Gutendex's
        // origin was slow or down.
        components.queryItems = [URLQueryItem(name: "search", value: query)]
        var request = URLRequest(url: components.url!)
        request.setValue("Voxglass/1.1 (iOS; Read with AI)", forHTTPHeaderField: "User-Agent")
        let data = try await data(for: request)
        return try JSONDecoder().decode(GutenbergSearchResponse.self, from: data).results.filter {
            $0.epubURL != nil && $0.languages.contains("en") && $0.copyright != true
        }
    }

    private func searchProjectGutenberg(_ query: String) async throws -> [GutenbergBook] {
        var components = URLComponents(url: projectGutenbergSearchURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "query", value: query)]
        var request = URLRequest(url: components.url!)
        request.setValue("Voxglass/1.1 (iOS; Read with AI)", forHTTPHeaderField: "User-Agent")
        let data = try await data(for: request)
        let books = Self.parseGutenbergSearchHTML(String(decoding: data, as: UTF8.self))
        // A 200 page with no recognizable result list and no "no results"
        // marker means the markup changed; treat it as a parse failure so the
        // fallback runs.
        if books.isEmpty, !Self.looksLikeEmptyResultPage(data) {
            throw GutenbergCatalogError.unexpectedResponse
        }
        return books
    }

    private func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GutenbergCatalogError.unexpectedResponse
        }
        if http.statusCode == 429 || http.statusCode == 503 {
            let retryAfter = Self.retryAfter(from: http)
            Self.logger.info("Gutenberg host returned \(http.statusCode, privacy: .public)")
            throw GutenbergCatalogError.temporarilyUnavailable(retryAfter: retryAfter)
        }
        guard (200..<300).contains(http.statusCode) else {
            Self.logger.info("Gutenberg host returned \(http.statusCode, privacy: .public)")
            throw GutenbergCatalogError.httpStatus(http.statusCode)
        }
        return data
    }

    private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty else { return nil }
        return TimeInterval(raw)
    }

    private static func looksLikeEmptyResultPage(_ data: Data) -> Bool {
        let html = String(decoding: data, as: UTF8.self).lowercased()
        // A result-list wrapper alone does not prove a successful empty search.
        // Changed result markup must trigger the fallback rather than hide books.
        return !html.contains("booklink") && (
            html.contains("no books found") || html.contains("no results")
                || html.contains("no records found")
        )
    }

    static func parseGutenbergSearchHTML(_ html: String) -> [GutenbergBook] {
        // Parse each list item independently. An optional subtitle in a single
        // page-wide regex could consume the next book (and borrow its author).
        let pattern = #"(?is)<li\b[^>]*class=["'][^"']*\bbooklink\b[^"']*["'][^>]*>(.*?)</li\s*>"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return expression.matches(in: html, range: range).compactMap { match in
            guard let itemRange = Range(match.range(at: 1), in: html) else { return nil }
            let item = String(html[itemRange])
            guard let idValue = capture(#"href=["']/ebooks/(\d+)["']"#, in: item),
                  let id = Int(idValue),
                  let titleValue = capture(#"(?is)<span\b[^>]*class=["'][^"']*\btitle\b[^"']*["'][^>]*>(.*?)</span>"#, in: item) else { return nil }
            let title = cleanHTML(titleValue)
            guard !title.isEmpty else { return nil }
            let subtitle = capture(#"(?is)<span\b[^>]*class=["'][^"']*\bsubtitle\b[^"']*["'][^>]*>(.*?)</span>"#, in: item)
            let author = subtitle.map(cleanHTML)?
                .replacingOccurrences(of: #"^by\s+"#, with: "", options: [.regularExpression, .caseInsensitive]) ?? ""
            return GutenbergBook(
                id: id, title: title, authors: author.isEmpty ? [] : [.init(name: author)], subjects: [], languages: [],
                formats: ["application/epub+zip": "https://www.gutenberg.org/ebooks/\(id).epub.images"]
            )
        }
    }

    private static func capture(_ pattern: String, in html: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[range])
    }

    private static func cleanHTML(_ value: String) -> String {
        value.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
