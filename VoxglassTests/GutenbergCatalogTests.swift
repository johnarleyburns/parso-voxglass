import Foundation
import Testing
@testable import VoxglassCore

// Serialized: the static `URLProtocol` mock below records process-wide state.
@Suite(.serialized)
struct GutenbergCatalogTests {
    final class MockGutenbergServer: URLProtocol {
        private final class State: @unchecked Sendable {
            let lock = NSLock()
            var requestURL: URL?
        }
        private static let state = State()

        static var lastRequestURL: URL? {
            state.lock.lock(); defer { state.lock.unlock() }
            return state.requestURL
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            Self.state.lock.lock(); Self.state.requestURL = request.url; Self.state.lock.unlock()
            let payload = Data("""
            {"results":[
              {"id":123,"title":"The Law","authors":[{"name":"Doe, Jane"}],"subjects":[],"languages":["en"],"formats":{"application/epub+zip":"https://mock.gutenberg/123.epub","image/jpeg":"https://mock.gutenberg/123.jpg"}},
              {"id":456,"title":"No EPUB","authors":[],"subjects":[],"languages":["en"],"formats":{"text/plain":"https://mock.gutenberg/456.txt"}},
              {"id":789,"title":"Livre français","authors":[],"subjects":[],"languages":["fr"],"formats":{"application/epub+zip":"https://mock.gutenberg/789.epub"}},
              {"id":999,"title":"Still Copyrighted","authors":[],"subjects":[],"languages":["en"],"copyright":true,"formats":{"application/epub+zip":"https://mock.gutenberg/999.epub"}}
            ]}
            """.utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: payload)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private func client() -> GutenbergCatalogClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockGutenbergServer.self]
        return GutenbergCatalogClient(
            session: URLSession(configuration: configuration),
            baseURL: URL(string: "https://mock.gutenberg/books/")!,
            projectGutenbergSearchURL: URL(string: "https://mock.gutenberg/ebooks/search/")!
        )
    }

    @Test func searchUsesTrailingSlashEndpointAndReturnsOnlyEPUBBooks() async throws {
        let books = try await client().search("  law  ")
        #expect(books.map(\.id) == [123])
        #expect(books.first?.authorLine == "Doe, Jane")
        #expect(books.first?.epubURL?.absoluteString == "https://mock.gutenberg/123.epub")
        #expect(books.first?.coverURL?.absoluteString == "https://mock.gutenberg/123.jpg")
        let requestURL = try #require(MockGutenbergServer.lastRequestURL)
        let components = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false))
        #expect(components.path == "/books/")
        #expect(components.queryItems?.map(\.name) == ["search"])
        #expect(components.queryItems?.first(where: { $0.name == "search" })?.value == "law")
    }

    @Test func fallbackFiltersLanguagesAndCopyrightedBooksClientSide() async throws {
        let books = try await client().search("law")
        #expect(books.map(\.id) == [123])
    }

    @Test func parserNeverBorrowsAnAuthorFromTheNextResult() {
        let books = GutenbergCatalogClient.parseGutenbergSearchHTML("""
        <li class="booklink"><a href="/ebooks/1"><span class="title">Anonymous</span></a></li>
        <li class="booklink"><a href="/ebooks/2"><span class="title">Credited</span><span class="subtitle">by Jane Doe</span></a></li>
        """)
        #expect(books.map(\.id) == [1, 2])
        #expect(books.first?.authors.isEmpty == true)
        #expect(books.last?.authorLine == "Jane Doe")
    }

    @Test func parserAcceptsSingleQuotedAttributesAndAdditionalClasses() {
        let books = GutenbergCatalogClient.parseGutenbergSearchHTML("""
        <li class='booklink featured'><a href='/ebooks/8'><span class='title highlighted'>A Book</span><span class='subtitle'>by Jane</span></a></li>
        """)
        #expect(books.map(\.id) == [8])
        #expect(books.first?.authorLine == "Jane")
    }

    @Test func blankSearchAvoidsNetworkRequest() async throws {
        let books = try await client().search("   ")
        #expect(books.isEmpty)
    }

    @Test func fallbackHTMLParserBuildsAPlayableGutenbergBook() {
        let books = GutenbergCatalogClient.parseGutenbergSearchHTML("""
        <li class="booklink"><a href="/ebooks/42"><span class="title">American Law &amp; Practice</span><span class="subtitle">by Doe, Jane</span></a></li>
        """)
        #expect(books.map(\.id) == [42])
        #expect(books.first?.title == "American Law & Practice")
        #expect(books.first?.authors.first?.name == "Doe, Jane")
        #expect(books.first?.epubURL?.absoluteString == "https://www.gutenberg.org/ebooks/42.epub.images")
        #expect(books.first?.coverURL?.absoluteString == "https://www.gutenberg.org/cache/epub/42/pg42.cover.medium.jpg")
    }
}

// Serialized: the static `URLProtocol` recorder below is process-wide.
@Suite(.serialized)
struct GutenbergPrimarySearchTests {
    final class Recorder: URLProtocol {
        private final class State: @unchecked Sendable {
            let lock = NSLock()
            var hosts: [String] = []
            var urls: [URL] = []
            var primaryStatus = 200
            var primaryRetryAfter: String?
            var fallbackFailsWithTimeout = false
        }
        private static let state = State()
        static func reset(
            primaryStatus: Int = 200,
            primaryRetryAfter: String? = nil,
            fallbackFailsWithTimeout: Bool = false
        ) {
            state.lock.lock()
            state.hosts = []
            state.urls = []
            state.primaryStatus = primaryStatus
            state.primaryRetryAfter = primaryRetryAfter
            state.fallbackFailsWithTimeout = fallbackFailsWithTimeout
            state.lock.unlock()
        }
        static var hosts: [String] { state.lock.lock(); defer { state.lock.unlock() }; return state.hosts }
        static var urls: [URL] { state.lock.lock(); defer { state.lock.unlock() }; return state.urls }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}
        override func startLoading() {
            let host = request.url?.host ?? ""
            Self.state.lock.lock()
            Self.state.hosts.append(host)
            if let url = request.url { Self.state.urls.append(url) }
            let status = Self.state.primaryStatus
            let retryAfter = Self.state.primaryRetryAfter
            let fallbackFails = Self.state.fallbackFailsWithTimeout
            Self.state.lock.unlock()
            let isPrimary = host == "primary.test"
            let body: String
            let code: Int
            var headers: [String: String]?
            if isPrimary {
                code = status
                headers = retryAfter.map { ["Retry-After": $0] }
                body = (request.url?.query ?? "").contains("empty")
                    ? "<html>No records found.</html>"
                    : status == 200 && (request.url?.query ?? "").contains("garbage")
                    ? "<html><div class=\"search-results\"><li class=\"booklink\">Changed markup</li></div></html>"
                    : #"<li class="booklink"><a href="/ebooks/7"><span class="title">Law</span><span class="subtitle">by Doe</span></a></li>"#
            } else if fallbackFails {
                client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
                return
            } else {
                code = 200
                body = #"{"results":[{"id":9,"title":"Fallback","authors":[],"subjects":[],"languages":["en"],"formats":{"application/epub+zip":"https://x/9.epub"}}]}"#
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: code,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private func client() -> GutenbergCatalogClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Recorder.self]
        return GutenbergCatalogClient(
            session: URLSession(configuration: configuration),
            baseURL: URL(string: "https://gutendex.test/books/")!,
            projectGutenbergSearchURL: URL(string: "https://primary.test/ebooks/search/")!
        )
    }

    @Test func successfulPrimaryDoesNotCallGutendex() async throws {
        Recorder.reset()
        let books = try await client().search("law")
        #expect(books.map(\.id) == [7])
        #expect(Recorder.hosts == ["primary.test"])
    }

    @Test func explicitEmptyResultDoesNotCallFallback() async throws {
        Recorder.reset()
        let books = try await client().search("empty")
        #expect(books.isEmpty)
        #expect(Recorder.hosts == ["primary.test"])
    }

    @Test func primaryTransportFailureFallsBackToGutendex() async throws {
        Recorder.reset(primaryStatus: 500)
        let books = try await client().search("law")
        #expect(books.map(\.id) == [9])
        #expect(Recorder.hosts == ["primary.test", "gutendex.test"])
    }

    @Test func primaryMaintenanceFailsFastWithRetryHint() async {
        Recorder.reset(primaryStatus: 503, primaryRetryAfter: "21600")
        do {
            _ = try await client().search("law")
            Issue.record("Expected a GutenbergCatalogError")
        } catch let error as GutenbergCatalogError {
            #expect(error == .temporarilyUnavailable(retryAfter: 21_600))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(Recorder.hosts == ["primary.test"])
    }

    @Test func primaryParseFailureFallsBackToGutendex() async throws {
        Recorder.reset()
        let books = try await client().search("garbage")
        #expect(books.map(\.id) == [9])
        #expect(Recorder.hosts == ["primary.test", "gutendex.test"])
    }

    @Test func fallbackConnectivityFailureBecomesFriendlyOutage() async {
        Recorder.reset(fallbackFailsWithTimeout: true)
        do {
            _ = try await client().search("garbage")
            Issue.record("Expected a GutenbergCatalogError")
        } catch let error as GutenbergCatalogError {
            #expect(error == .temporarilyUnavailable(retryAfter: nil))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(Recorder.hosts == ["primary.test", "gutendex.test"])
    }

    @Test func fallbackRequestStaysCacheable() async throws {
        Recorder.reset()
        _ = try await client().search("garbage")
        let fallbackURL = try #require(Recorder.urls.last)
        let components = try #require(URLComponents(url: fallbackURL, resolvingAgainstBaseURL: false))
        #expect(components.host == "gutendex.test")
        #expect(components.queryItems?.map(\.name) == ["search"])
    }

    @Test func callerCancellationDoesNotStartFallback() async {
        Recorder.reset(primaryStatus: 500)
        let task = Task { try await client().search("law") }
        task.cancel()
        _ = try? await task.value
        #expect(!Recorder.hosts.contains("gutendex.test"))
    }

    @Test func interactiveSessionHasExplicitTimeouts() {
        let configuration = GutenbergCatalogClient.interactiveSession().configuration
        #expect(configuration.timeoutIntervalForRequest == GutenbergCatalogClient.interactiveRequestTimeout)
        #expect(configuration.timeoutIntervalForResource == GutenbergCatalogClient.interactiveResourceTimeout)
        #expect(configuration.timeoutIntervalForResource <= 15)
    }
}
