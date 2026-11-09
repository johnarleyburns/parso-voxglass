import Foundation
import Testing
@testable import VoxglassCore

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
              {"id":456,"title":"No EPUB","authors":[],"subjects":[],"languages":["en"],"formats":{"text/plain":"https://mock.gutenberg/456.txt"}}
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
            baseURL: URL(string: "https://mock.gutenberg/books/")!
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
        #expect(components.queryItems?.first(where: { $0.name == "search" })?.value == "law")
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

@Suite(.serialized)
struct GutenbergPrimarySearchTests {
    final class Recorder: URLProtocol {
        private final class State: @unchecked Sendable {
            let lock = NSLock()
            var hosts: [String] = []
            var primaryStatus = 200
        }
        private static let state = State()
        static func reset(primaryStatus: Int = 200) {
            state.lock.lock(); state.hosts = []; state.primaryStatus = primaryStatus; state.lock.unlock()
        }
        static var hosts: [String] { state.lock.lock(); defer { state.lock.unlock() }; return state.hosts }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}
        override func startLoading() {
            let host = request.url?.host ?? ""
            Self.state.lock.lock(); Self.state.hosts.append(host); let status = Self.state.primaryStatus; Self.state.lock.unlock()
            let isPrimary = host == "primary.test"
            let body: String
            let code: Int
            if isPrimary {
                code = status
                body = status == 200 && (request.url?.query ?? "").contains("garbage")
                    ? "<html>unrelated</html>"
                    : #"<li class="booklink"><a href="/ebooks/7"><span class="title">Law</span><span class="subtitle">by Doe</span></a></li>"#
            } else {
                code = 200
                body = #"{"results":[{"id":9,"title":"Fallback","authors":[],"subjects":[],"languages":["en"],"formats":{"application/epub+zip":"https://x/9.epub"}}]}"#
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
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

    @Test func primaryTransportFailureFallsBackToGutendex() async throws {
        Recorder.reset(primaryStatus: 503)
        let books = try await client().search("law")
        #expect(books.map(\.id) == [9])
        #expect(Recorder.hosts == ["primary.test", "gutendex.test"])
    }

    @Test func primaryParseFailureFallsBackToGutendex() async throws {
        Recorder.reset()
        let books = try await client().search("garbage")
        #expect(books.map(\.id) == [9])
        #expect(Recorder.hosts == ["primary.test", "gutendex.test"])
    }

    @Test func callerCancellationDoesNotStartFallback() async {
        Recorder.reset(primaryStatus: 503)
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
